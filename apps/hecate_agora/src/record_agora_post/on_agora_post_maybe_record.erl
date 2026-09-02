%% @doc POLICY: whether an incoming agora post is written to the record.
%%
%% `decide/2' is the whole decision and a pure function. Three outcomes:
%%
%%   record        -- never seen this post_id: write it.
%%   duplicate     -- same post_id, same body: a redelivery. The square's
%%                    own producer re-publishes its recent posts every
%%                    minute so late joiners hear them, so duplicates are the
%%                    common case, not an anomaly.
%%   contradiction -- same post_id, DIFFERENT body. Two different things
%%                    claim to be one post. The first stays; the second is
%%                    logged as an error and never silently preferred, the
%%                    same rule hecate-archive applies to a seq that arrives
%%                    twice with different bytes.
%%
%% There is no `stale' outcome, unlike a presence read model: speech does
%% not expire and a late delivery of an old post is still a post.
-module(on_agora_post_maybe_record).

-export([handle/1, decide/2]).

-type outcome() :: recorded | duplicate | contradiction | {error, term()}.
-export_type([outcome/0]).

-spec handle(agora_read_model:post()) -> outcome().
handle(#{post_id := PostId} = Post) ->
    acted(decide(existing(PostId), Post), Post).

existing(PostId) ->
    found(agora_read_model:find(PostId)).

found({ok, Doc}) -> Doc;
found({error, not_found}) -> undefined.

-spec decide(map() | undefined, agora_read_model:post()) ->
    record | duplicate | contradiction.
decide(undefined, _Incoming) ->
    record;
decide(#{<<"body">> := Body}, #{body := Body}) ->
    duplicate;
decide(_Existing, _Incoming) ->
    contradiction.

acted(record, Post) ->
    written(agora_read_model:record(Post), Post);
acted(duplicate, _Post) ->
    duplicate;
acted(contradiction, #{post_id := PostId, from := From, society := Society}) ->
    logger:error("[agora] contradiction on ~s/agora: post ~s from ~s arrived "
                 "with a different body than the one on record; keeping the first",
                 [Society, PostId, From]),
    contradiction.

written(ok, _Post) ->
    recorded;
%% The same post landed twice between the existence check and the write --
%% a redelivery racing itself. The first write stands.
written({error, conflict}, _Post) ->
    duplicate;
written({error, Reason}, #{post_id := PostId}) ->
    logger:error("[agora] could not record post ~s: ~p", [PostId, Reason]),
    {error, Reason}.
