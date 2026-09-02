%% @doc LISTENER for one society's agora topic, wired by `hecate_om:boot/1'
%% from `hecate_agora_service:subscriptions/0' into a supervised
%% `macula_subscriber'. Its only job is to decode the fact and hand it to
%% the policy; it decides nothing about whether the post is written.
%%
%% A malformed fact on the topic is logged at warning, not debug: the agora
%% carries exactly one fact shape, so anything else is a producer whose
%% contract moved under us, and a record with a silent hole is worse than a
%% noisy log.
-module(agora_post_listener).

-behaviour(macula_subscriber).

-export([init/1, handle_event/4]).

init(#{society := Society} = Args) when is_binary(Society) ->
    {ok, Args}.

handle_event(Topic, Payload, Meta, #{society := Society} = State) ->
    heard(agora_post_fact:decode(Topic, Payload, Meta, Society), Topic),
    {noreply, State}.

heard({ok, Post}, _Topic) ->
    outcome(on_agora_post_maybe_record:handle(Post), Post);
heard({error, Reason}, Topic) ->
    logger:warning("[agora] dropped a fact on ~s: ~p", [Topic, Reason]).

outcome(recorded, #{post_id := PostId, from := From, society := Society}) ->
    logger:info("[agora] recorded ~s/agora post ~s from ~s", [Society, PostId, From]);
outcome(_DuplicateContradictionOrError, _Post) ->
    ok.
