%% @doc THE FACT THE KEEPER PUBLISHES WHEN THE RECORD'S INTEGRITY IS
%% CHALLENGED, on `agora/post_conflict_detected': the same `post_id' arrived
%% with different bytes.
%%
%% Mechanical, not semantic. This is `on_agora_post_maybe_record''s
%% `contradiction' outcome: a byte-for-byte comparison of two bodies, no
%% model, no judgment about what was said. It means a producer reused an
%% id, a replay was altered, or an instance re-rendered a post; which one is
%% for a reader (the sentinel, a vigil surface) to decide. A semantic
%% contradiction between minds is a different thing and belongs to whatever
%% eventually adjudicates truths, not to the keeper.
%%
%% Carries pointers and hashes, never the bodies. The record already holds
%% the first one, and repeating the second would put the disputed bytes on
%% the wire under the keeper's own name. `refused_heard_at' is when the
%% conflict was detected: the moment the keeper heard the second post.
%%
%% Same delivery rules as `agora_post_recorded_v1': fire-and-forget, text
%% as `{text, Bin}', no booleans, topic under the keeper's own namespace.
-module(agora_post_conflict_detected_v1).

-export([topic/0, fact/2, publish/2]).

-define(TOPIC, <<"agora/post_conflict_detected">>).

-spec topic() -> binary().
topic() -> ?TOPIC.

%% @doc The fact for a conflict. `Existing' is the stored document (binary
%% keys, the one that stays); `Refused' is the clean post that was not
%% written. Pure.
-spec fact(map(), agora_read_model:post()) -> map().
fact(Existing, #{post_id := PostId, society := Society} = Refused) ->
    agora_read_model:omit_undefined(#{
        type                       => {text, <<"agora_post_conflict_detected">>},
        version                    => 1,
        society                    => {text, Society},
        post_id                    => {text, PostId},
        kept_from                  => agora_read_model:wire_text(maps:get(<<"from">>, Existing, undefined)),
        kept_publisher             => agora_read_model:wire_text(maps:get(<<"publisher">>, Existing, undefined)),
        kept_publisher_verified    => agora_read_model:wire_text(maps:get(<<"publisher_verified">>, Existing, undefined)),
        kept_body_sha256           => {text, sha256_hex(maps:get(<<"body">>, Existing))},
        kept_heard_at              => maps:get(<<"heard_at">>, Existing, undefined),
        refused_from               => {text, maps:get(from, Refused)},
        refused_publisher          => agora_read_model:wire_text(maps:get(publisher, Refused, undefined)),
        refused_publisher_verified => {text, maps:get(publisher_verified, Refused)},
        refused_body_sha256        => {text, sha256_hex(maps:get(body, Refused))},
        refused_heard_at           => maps:get(heard_at, Refused)
    }).

%% @doc Publish the fact for a conflict. Always `ok', for the same reason
%% as `agora_post_recorded_v1:publish/1': the error log already carries
%% the conflict, and the record is untouched by it.
-spec publish(map(), agora_read_model:post()) -> ok.
publish(Existing, Refused) ->
    published(hecate_om_pubsub:publish(?TOPIC, fact(Existing, Refused)), Refused).

published(ok, _Refused) ->
    ok;
published({error, mesh_unavailable}, _Refused) ->
    ok;
published({error, Reason}, #{post_id := PostId}) ->
    logger:warning("[agora] publish ~s for post ~s refused: ~p", [?TOPIC, PostId, Reason]),
    ok.

sha256_hex(Body) when is_binary(Body) ->
    binary:encode_hex(crypto:hash(sha256, Body), lowercase).
