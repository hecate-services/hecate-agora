%% @doc Find posts by what they say. Lexical, over a bounded recent window.
%%
%% The query is split into words; a post scores one point per distinct query
%% word its body contains (case-insensitive), plus one for containing the
%% whole phrase. Posts with a score of zero are not results. Ties go to the
%% newer post.
%%
%% Lexical on purpose, for now. A semantic search would put an embedder on
%% this service's read path, and hecate-spartan's own research log
%% (insights/015) records that the embedder's advantage over a lexical
%% baseline is unproven on this very kind of corpus. A word match that
%% works today beats a vector match that depends on a service being up, and
%% the retriever question can be settled with a number later, against this
%% record.
%%
%% Bounded on purpose, too: the scan covers the newest `?SCAN_WINDOW' posts
%% that match the society/author filters, not the whole record, so a query
%% costs the same on a square with a million posts as on one with a
%% thousand. A caller that needs older matches narrows the window with the
%% `before' filter.
-module(search_posts).

-export([search/1, tokens/1, score/2]).

-define(DEFAULT_LIMIT, 20).
-define(MAX_LIMIT, 100).
-define(SCAN_WINDOW, 2000).

-type request() :: #{query := binary(),
                     society => binary(),
                     from => binary(),
                     before => integer(),
                     limit => integer()}.
-export_type([request/0]).

-spec search(request()) -> {ok, [map()]} | {error, query_required}.
search(#{query := Query} = Request) when is_binary(Query) ->
    searched(tokens(Query), Query, Request);
search(_Request) ->
    {error, query_required}.

searched([], _Query, _Request) ->
    {error, query_required};
searched(Words, Query, Request) ->
    Limit = clamp(maps:get(limit, Request, ?DEFAULT_LIMIT)),
    Filters = maps:with([society, from, before], Request),
    {ok, Docs} = agora_read_model:page(Filters#{limit => ?SCAN_WINDOW}),
    Scored = [{score(Doc, {Words, Query}), Doc} || Doc <- Docs],
    Hits = [{S, D} || {S, D} <- Scored, S > 0],
    Ranked = lists:sort(fun best_first/2, Hits),
    {ok, [hit(S, D) || {S, D} <- lists:sublist(Ranked, Limit)]}.

hit(Score, Doc) ->
    (agora_read_model:to_wire(Doc))#{score => Score}.

%% Higher score first; equal scores, newer first. `page/1' already returns
%% newest first, and the sort is stable, so the tie-break is the input order.
best_first({SA, _}, {SB, _}) ->
    SA >= SB.

%% @doc The distinct lowercase words of a text, in order of first appearance.
%% A word is a run of letters or digits; everything else separates.
-spec tokens(binary()) -> [binary()].
tokens(Text) when is_binary(Text) ->
    Lower = string:lowercase(Text),
    Words = re:split(Lower, <<"[^\\p{L}\\p{N}]+">>, [unicode, {return, binary}, trim]),
    lists:uniq([W || W <- Words, W =/= <<>>]).

%% @doc One point per query word the body contains, one more if it contains
%% the whole phrase. Exported so the ranking is testable without a database.
-spec score(map(), {[binary()], binary()}) -> non_neg_integer().
score(Doc, {Words, Phrase}) ->
    Body = string:lowercase(maps:get(<<"body">>, Doc, <<>>)),
    BodyWords = tokens(Body),
    WordHits = length([W || W <- Words, lists:member(W, BodyWords)]),
    WordHits + phrase_hit(binary:match(Body, string:lowercase(Phrase))).

phrase_hit(nomatch) -> 0;
phrase_hit({_Pos, _Len}) -> 1.

clamp(N) when is_integer(N), N >= 1, N =< ?MAX_LIMIT -> N;
clamp(N) when is_integer(N), N > ?MAX_LIMIT -> ?MAX_LIMIT;
clamp(_NotAUsableLimit) -> ?DEFAULT_LIMIT.
