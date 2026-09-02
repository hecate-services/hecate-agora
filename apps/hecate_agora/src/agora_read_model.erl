%% @doc The record of the square: one barrel_docdb document per post, in the
%% database `hecate_agora_service:read_model_id/0' names.
%%
%% Every desk reads and writes through here and never touches `barrel_docdb'
%% any other way: `on_agora_post_maybe_record' writes, the query desks read.
%%
%% A post is immutable speech, so a document is written once and never
%% revised, and nothing here expires: unlike a presence directory
%% (hecate-citizens) or a station list (hecate-stations), where a fact that
%% stops being refreshed must age out, a post that was said stays said. That
%% is the whole point of this service.
%%
%% == Why the document id carries the time ==
%%
%% barrel_docdb's `order_by' is not relied on: in the version resolved when
%% this was written (barrel_docdb 1.4.0) its in-memory sort reads the sort
%% field off the result wrapper rather than the document, so it never
%% reorders anything, and its index-ordered path comes out inverted. Both
%% were observed against a real database by this module's own suite, not
%% inferred. barrel is not ours to patch on the spot, so the record does not
%% ask it to sort.
%%
%% What barrel_docdb DOES do reliably is scan document ids in order,
%% O(matches), with chunking and continuation (`id_prefix' / `id_range'). So
%% the id is built to sort the way the square is read:
%%
%%     <society>/<inverted posted_at, 13 digits>/<post_id>
%%
%% Ids of one society sort newest-first, and `before' becomes a range start.
%% A page by society is an ordered scan; a page across societies is one such
%% scan per society merged in Erlang, over the society list this record keeps
%% for itself (one marker document per society, under an id no society can
%% collide with). Lookup by `post_id' and "replies to X" go through barrel's
%% path index (equality), with the small result ordered in Erlang.
%%
%% Documents use binary keys and OMIT undefined fields rather than writing a
%% null placeholder: barrel_docdb indexes every path automatically and its
%% indexer has no clause for `undefined' (hecate-citizens hit this live).
-module(agora_read_model).

-export([record/1, find/1, page/1, replies_to/2, societies/0, to_wire/1]).
%% Wire shaping shared with the facts this service publishes.
-export([wire_text/1, wire_stimulus/1, omit_undefined/1]).
%% Pure, exported so the id's ordering property is testable on its own.
-export([doc_id/3]).

-type post() :: #{post_id := binary(),
                  society := binary(),
                  topic := binary(),
                  from := binary(),
                  body := binary(),
                  in_reply_to := binary() | undefined,
                  stimulus := map() | undefined,
                  kind := binary() | undefined,
                  posted_at := integer(),
                  home := binary() | undefined,
                  locale := binary() | undefined,
                  publisher := binary() | undefined,
                  publisher_verified := binary(),
                  heard_at := integer(),
                  heard_via := binary()}.
-type page_filters() :: #{society => binary(),
                          from => binary(),
                          %% A stimulus `item_id'. Every post carrying it is
                          %% the same conversation, so asking for one is how a
                          %% reader follows a story rather than a reply chain.
                          story => binary(),
                          %% An ISO-2 code. Matches a post whose stimulus names
                          %% that country on EITHER axis, so "pl" finds both what
                          %% Poland reported and what was reported about Poland.
                          %% One filter rather than two, because a reader asking
                          %% for a country wants the country, and a page that
                          %% makes them pick an axis first has asked them to
                          %% learn the schema.
                          country => binary(),
                          before => integer(),
                          'after' => integer(),
                          limit := pos_integer()}.
-export_type([post/0, page_filters/0]).

%% 13 digits of milliseconds carry the record to the year 2286.
-define(MAX_MS, 9_999_999_999_999).
-define(ID_WIDTH, 13).
%% Society markers live under a prefix that starts with `/', which no society
%% name can (agora_societies refuses names carrying one), so no scan over a
%% society's posts can ever include them.
-define(SOCIETIES_PREFIX, <<"/societies/">>).
%% Documents fetched per round while scanning for a filtered page, and the
%% most one page request may scan before giving up on finding more matches.
-define(CHUNK, 200).
-define(SCAN_CAP, 5000).

%% @doc Write a post once. `{error, conflict}' when this exact document
%% already exists, which the policy treats as a duplicate delivery.
-spec record(post()) -> ok | {error, term()}.
record(#{post_id := PostId, society := Society, posted_at := PostedAt} = Post)
  when is_binary(PostId), is_binary(Society), is_integer(PostedAt) ->
    Doc = omit_undefined(#{
        <<"id">>                 => doc_id(Society, PostedAt, PostId),
        <<"post_id">>            => PostId,
        <<"society">>            => Society,
        <<"topic">>              => maps:get(topic, Post),
        <<"from">>               => maps:get(from, Post),
        <<"body">>               => maps:get(body, Post),
        <<"in_reply_to">>        => maps:get(in_reply_to, Post, undefined),
        <<"stimulus">>           => maps:get(stimulus, Post, undefined),
        <<"kind">>               => maps:get(kind, Post, undefined),
        <<"posted_at">>          => PostedAt,
        <<"home">>               => maps:get(home, Post, undefined),
        <<"locale">>             => maps:get(locale, Post, undefined),
        <<"publisher">>          => maps:get(publisher, Post, undefined),
        <<"publisher_verified">> => maps:get(publisher_verified, Post),
        <<"heard_at">>           => maps:get(heard_at, Post),
        <<"heard_via">>          => maps:get(heard_via, Post)
    }),
    written(barrel_docdb:put_doc(db(), Doc), Society).

written({ok, _}, Society) -> remember_society(Society);
written({error, _} = Error, _Society) -> Error.

%% @doc The id a post is stored under: society, then inverted time so newer
%% sorts first, then the post id so two posts in the same millisecond still
%% have distinct, stable ids. `posted_at' outside the 13-digit range is
%% clamped for the id only; the document keeps the value as published.
-spec doc_id(binary(), integer(), binary()) -> binary().
doc_id(Society, PostedAt, PostId) ->
    <<Society/binary, "/", (inverted(PostedAt))/binary, "/", PostId/binary>>.

inverted(PostedAt) ->
    N = ?MAX_MS - min(max(PostedAt, 0), ?MAX_MS),
    Digits = integer_to_binary(N),
    <<(binary:copy(<<"0">>, ?ID_WIDTH - byte_size(Digits)))/binary, Digits/binary>>.

-spec find(binary()) -> {ok, map()} | {error, not_found}.
find(PostId) when is_binary(PostId) ->
    one(barrel_docdb:find(db(), #{where => [{path, [<<"post_id">>], PostId}],
                                   limit => 1, flat => true})).

one({ok, [Doc | _], _Meta}) -> {ok, Doc};
one({ok, [], _Meta}) -> {error, not_found}.

%% @doc A page of posts, newest first. `before' and `after' are both
%% exclusive on `posted_at': a caller pages backwards by passing the last
%% post's `posted_at' back in as `before', and a subscriber catching up on
%% what it missed asks for everything `after' the last post it saw. Without
%% `society' every society this record has ever heard is merged.
-spec page(page_filters()) -> {ok, [map()]}.
page(#{limit := Limit} = Filters) when is_integer(Limit), Limit > 0 ->
    Before = maps:get(before, Filters, undefined),
    After = maps:get('after', Filters, undefined),
    Keep = #{from => maps:get(from, Filters, undefined),
             story => maps:get(story, Filters, undefined),
             country => maps:get(country, Filters, undefined)},
    Scans = [scan(S, Before, After, Keep, Limit) || S <- scope(maps:get(society, Filters, undefined))],
    {ok, lists:sublist(newest_first(lists:append(Scans)), Limit)}.

scope(undefined) -> societies();
scope(Society) -> [Society].

%% One society, newest first, at most Limit posts matching From, scanning
%% chunk by chunk from the range start until enough matched, the range ran
%% out, or the scan cap was hit.
scan(Society, Before, After, Keep, Limit) ->
    window(empty_window(Before, After), Society, Before, After, Keep, Limit).

%% Both bounds are exclusive, so the window holds something only if at
%% least one millisecond lies strictly between them.
empty_window(Before, After) when is_integer(Before), is_integer(After) -> After + 1 >= Before;
empty_window(_Before, _After) -> false.

window(true, _Society, _Before, _After, _Keep, _Limit) ->
    [];
window(false, Society, Before, After, Keep, Limit) ->
    Spec = #{id_range => {range_start(Society, Before), range_end(Society, After)}, flat => true},
    collect(barrel_docdb:find(db(), Spec, #{chunk_size => ?CHUNK}), Spec, Keep, Limit, 0, []).

collect({ok, Docs, Meta}, Spec, Keep, Limit, Scanned, Acc) ->
    Acc1 = Acc ++ [D || D <- Docs, kept(Keep, D)],
    Scanned1 = Scanned + length(Docs),
    more(maps:get(has_more, Meta, false) andalso length(Acc1) < Limit andalso Scanned1 < ?SCAN_CAP,
         Meta, Spec, Keep, Limit, Scanned1, Acc1).

more(true, #{continuation := Token}, Spec, Keep, Limit, Scanned, Acc) ->
    collect(barrel_docdb:find(db(), Spec, #{continuation => Token}), Spec, Keep, Limit, Scanned, Acc);
more(_Done, _Meta, _Spec, _Keep, Limit, _Scanned, Acc) ->
    lists:sublist(Acc, Limit).

%% Post-scan filters. Both are equality on a stored field, applied after the
%% id-range scan rather than by an index, which is the same trade the `from'
%% filter has always made: the range is already bounded by time, and a
%% secondary index on either would be a second write per post.
kept(#{from := From, story := Story, country := Country}, Doc) ->
    spoken_by(From, Doc) andalso about(Story, Doc) andalso touches(Country, Doc).

spoken_by(undefined, _Doc) -> true;
spoken_by(From, Doc) -> maps:get(<<"from">>, Doc, undefined) =:= From.

about(undefined, _Doc) -> true;
about(Story, Doc) -> story_of(maps:get(<<"stimulus">>, Doc, undefined)) =:= Story.

story_of(Stimulus) when is_map(Stimulus) -> maps:get(<<"item_id">>, Stimulus, undefined);
story_of(_Unprompted)                    -> undefined.

touches(undefined, _Doc) -> true;
touches(Country, Doc)    -> lists:member(Country, countries_of(maps:get(<<"stimulus">>, Doc, undefined))).

countries_of(S) when is_map(S) ->
    [C || Key <- [<<"reporting_country">>, <<"subject_country">>],
          (C = maps:get(Key, S, undefined)) =/= undefined];
countries_of(_Unprompted) ->
    [].

%% Every post of the society when no `before'; otherwise every post with
%% posted_at =< Before - 1, which is exactly posted_at < Before, since the
%% inverted time of Before - 1 is one more than that of Before and a `/'
%% sorts below every digit.
range_start(Society, undefined) -> <<Society/binary, "/">>;
range_start(Society, Before) -> <<Society/binary, "/", (inverted(Before - 1))/binary, "/">>.

%% Without `after': `0' is the byte after `/', so this ends the range right
%% after the last id of this society and before any society whose name
%% merely extends it. With `after': a post with posted_at > After has a
%% smaller inverted time than After's, so its id sorts before
%% `<society>/<inverted After>/', while a post AT After sorts after it.
%% That is exactly posted_at > After: `after' is exclusive, like `before'.
range_end(Society, undefined) -> <<Society/binary, "0">>;
range_end(Society, After) -> <<Society/binary, "/", (inverted(After))/binary, "/">>.

%% @doc The direct replies to a post, oldest first. The set of direct replies
%% to one post is small; it is fetched by path equality and ordered here.
-spec replies_to(binary(), pos_integer()) -> {ok, [map()]}.
replies_to(PostId, Limit) when is_binary(PostId), is_integer(Limit), Limit > 0 ->
    {ok, Docs, _Meta} = barrel_docdb:find(db(), #{where => [{path, [<<"in_reply_to">>], PostId}],
                                                  limit => Limit, flat => true}),
    {ok, lists:sublist(oldest_first(Docs), Limit)}.

%% @doc Every society this record has heard at least one post from.
-spec societies() -> [binary()].
societies() ->
    {ok, Docs, _Meta} = barrel_docdb:find(db(), #{id_prefix => ?SOCIETIES_PREFIX, flat => true}),
    [maps:get(<<"society">>, D) || D <- Docs].

remember_society(Society) ->
    Id = <<?SOCIETIES_PREFIX/binary, Society/binary>>,
    marked(barrel_docdb:get_doc(db(), Id), Id, Society).

marked({ok, _Existing}, _Id, _Society) ->
    ok;
marked({error, not_found}, Id, Society) ->
    written_marker(barrel_docdb:put_doc(db(), #{<<"id">> => Id, <<"society">> => Society})).

written_marker({ok, _}) -> ok;
%% Two posts of a brand-new society racing the first marker write; either
%% one's marker will do.
written_marker({error, conflict}) -> ok.

newest_first(Docs) ->
    lists:sort(fun(A, B) -> posted_at(A) >= posted_at(B) end, Docs).

oldest_first(Docs) ->
    lists:sort(fun(A, B) -> posted_at(A) =< posted_at(B) end, Docs).

posted_at(Doc) -> maps:get(<<"posted_at">>, Doc).

%% @doc A stored document, shaped for an RPC reply: atom keys, undefined
%% fields omitted, nothing barrel-internal, and every text field tagged
%% `{text, Bin}'.
%%
%% The tag is the wire contract, not decoration. macula encodes a bare
%% Erlang binary as a CBOR BYTE string (major type 2) and `{text, Bin}' as a
%% CBOR TEXT string (major type 3) -- see macula_record_cbor's value table.
%% A reply that puts prose in bare binaries reaches every non-BEAM consumer
%% (macula-cli, macula-mcp, the Go/Rust/.NET/PHP SDKs) as hex-encoded bytes,
%% which is exactly what the first live read of this record returned. The
%% record exists to be read by people and their tools, so its text goes out
%% as text. Integers stay integers.
-spec to_wire(map()) -> map().
to_wire(Doc) ->
    omit_undefined(#{
        post_id            => text(maps:get(<<"post_id">>, Doc)),
        society            => text(maps:get(<<"society">>, Doc)),
        from               => text(maps:get(<<"from">>, Doc)),
        body               => text(maps:get(<<"body">>, Doc)),
        in_reply_to        => text(maps:get(<<"in_reply_to">>, Doc, undefined)),
        stimulus           => wire_stimulus(maps:get(<<"stimulus">>, Doc, undefined)),
        kind               => text(maps:get(<<"kind">>, Doc, undefined)),
        posted_at          => maps:get(<<"posted_at">>, Doc),
        home               => text(maps:get(<<"home">>, Doc, undefined)),
        locale             => text(maps:get(<<"locale">>, Doc, undefined)),
        publisher          => text(maps:get(<<"publisher">>, Doc, undefined)),
        publisher_verified => text(maps:get(<<"publisher_verified">>, Doc)),
        heard_at           => maps:get(<<"heard_at">>, Doc),
        heard_via          => text(maps:get(<<"heard_via">>, Doc))
    }).

text(undefined) -> undefined;
text(Bin) when is_binary(Bin) -> {text, Bin}.

%% @doc The stimulus for the wire, or `undefined' to be omitted.
%%
%% It goes out under the same text contract as everything else, at depth: a
%% nested bare binary reaches a non-BEAM reader as hex exactly like a
%% top-level one does, and this map is nothing BUT prose and links. Exported
%% for the same reason `wire_text/1' is -- the facts this service publishes
%% follow the same contract as its replies.
-spec wire_stimulus(map() | undefined) -> map() | undefined.
wire_stimulus(S) when is_map(S) ->
    omit_undefined(#{
        item_id      => text(maps:get(<<"item_id">>, S)),
        title        => text(maps:get(<<"title">>, S, undefined)),
        url          => text(maps:get(<<"url">>, S, undefined)),
        image_url    => text(maps:get(<<"image_url">>, S, undefined)),
        source       => text(maps:get(<<"source">>, S, undefined)),
        source_type  => text(maps:get(<<"source_type">>, S, undefined)),
        topic_class  => text(maps:get(<<"topic_class">>, S, undefined)),
        topics       => tags_wire(maps:get(<<"topics">>, S, undefined)),
        emoji        => text(maps:get(<<"emoji">>, S, undefined)),
        lang         => text(maps:get(<<"lang">>, S, undefined)),
        reporting_country      => text(maps:get(<<"reporting_country">>, S, undefined)),
        reporting_country_name => text(maps:get(<<"reporting_country_name">>, S, undefined)),
        subject_country        => text(maps:get(<<"subject_country">>, S, undefined)),
        subject_country_name   => text(maps:get(<<"subject_country_name">>, S, undefined)),
        published_at => maps:get(<<"published_at">>, S, undefined)});
wire_stimulus(_Unprompted) ->
    undefined.

tags_wire(Tags) when is_list(Tags) -> [text(T) || T <- Tags, is_binary(T)];
tags_wire(_Absent)                 -> undefined.

%% @doc A text field for the wire, or `undefined' to be omitted. The facts
%% this service publishes follow the same contract as its replies.
-spec wire_text(binary() | undefined) -> {text, binary()} | undefined.
wire_text(Value) ->
    text(Value).

%% @doc A wire map without its absent fields.
-spec omit_undefined(map()) -> map().
omit_undefined(Map) ->
    maps:filter(fun(_K, V) -> V =/= undefined end, Map).

db() ->
    {ok, DbName} = hecate_om:read_model(),
    DbName.
