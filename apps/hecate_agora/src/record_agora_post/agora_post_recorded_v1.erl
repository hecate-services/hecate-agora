%% @doc THE FACT THE KEEPER PUBLISHES WHEN A POST ENTERS THE RECORD, on
%% `agora/post_recorded': one integration fact per post, across every
%% society this keeper records.
%%
%% Published on the `record' outcome only, never for a redelivery, so a
%% subscriber gets each post once, deduplicated and with provenance
%% settled. That is what the raw `<society>/agora' stream cannot give it:
%% every spartan instance re-publishes its recent speech once a minute, and
%% a consumer of the square has to re-implement the keeper's own policy to
%% see one post once.
%%
%% For visualizers and research, not for the minds. A mind already hears
%% every post live on its own square and is given no tool that reads the
%% record (README, "Who should read it"); this topic tells it nothing new.
%% The topic lives under the keeper's own `agora/' namespace, never under a
%% society's, so the keeper still cannot put words in the square it keeps.
%%
%% Fire-and-forget on purpose. The record is written before this goes out,
%% and the mesh replays nothing, so a subscriber that was not listening
%% catches up with `hecate_agora.get_posts_page' and its `after' filter. A
%% refused or impossible publish is logged, never retried, and never fails
%% the write.
%%
%% Every text field goes out as `{text, Bin}' (CBOR text), the wire contract
%% `agora_read_model:to_wire/1' documents. No booleans cross the wire:
%% `publisher_verified' is the text `true' | `false' | `not_signed'.
-module(agora_post_recorded_v1).

-export([topic/0, fact/1, publish/1]).

-define(TOPIC, <<"agora/post_recorded">>).

-spec topic() -> binary().
topic() -> ?TOPIC.

%% @doc The fact for a post just written, from the same clean post the
%% record was written from. Pure.
-spec fact(agora_read_model:post()) -> map().
fact(#{post_id := PostId, society := Society, posted_at := PostedAt} = Post) ->
    agora_read_model:omit_undefined(#{
        type               => {text, <<"agora_post_recorded">>},
        version            => 1,
        society            => {text, Society},
        post_id            => {text, PostId},
        from               => {text, maps:get(from, Post)},
        body               => {text, maps:get(body, Post)},
        in_reply_to        => agora_read_model:wire_text(maps:get(in_reply_to, Post, undefined)),
        %% What the mind was reacting to, so a visualizer subscribing here
        %% sees exactly what a reader of the record sees, without a second
        %% call per post. Omitted entirely for unprompted speech.
        stimulus           => agora_read_model:wire_stimulus(maps:get(stimulus, Post, undefined)),
        posted_at          => PostedAt,
        home               => agora_read_model:wire_text(maps:get(home, Post, undefined)),
        locale             => agora_read_model:wire_text(maps:get(locale, Post, undefined)),
        publisher          => agora_read_model:wire_text(maps:get(publisher, Post, undefined)),
        publisher_verified => {text, maps:get(publisher_verified, Post)},
        heard_at           => maps:get(heard_at, Post),
        heard_via          => {text, maps:get(heard_via, Post)}
    }).

%% @doc Publish the fact for a post just written. Always `ok': the record
%% is the thing that matters and it is already on disk.
-spec publish(agora_read_model:post()) -> ok.
publish(Post) ->
    published(hecate_om_pubsub:publish(?TOPIC, fact(Post)), Post).

published(ok, _Post) ->
    ok;
%% No mesh attached (a suite, or boot before the pool is up): nobody to
%% tell and no way to tell them. The record is written regardless.
published({error, mesh_unavailable}, _Post) ->
    ok;
published({error, Reason}, #{post_id := PostId}) ->
    logger:warning("[agora] publish ~s for post ~s refused: ~p", [?TOPIC, PostId, Reason]),
    ok.
