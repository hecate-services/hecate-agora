-module(agora_post_conflict_detected_v1_tests).

-include_lib("eunit/include/eunit.hrl").

%% Pointers and hashes, never bodies: the record already holds the kept one,
%% and the refused bytes never go out under the keeper's name.
fact_carries_hashes_not_bodies_test() ->
    Existing = #{<<"post_id">> => <<"p1">>, <<"from">> => <<"did:key:a">>, <<"body">> => <<"first">>,
                 <<"publisher">> => <<"ab">>, <<"publisher_verified">> => <<"true">>, <<"heard_at">> => 10},
    Refused = agora_test_db:post(#{post_id => <<"p1">>, from => <<"did:key:b">>, body => <<"second">>,
                                   heard_at => 20, publisher_verified => <<"not_signed">>}),
    Fact = agora_post_conflict_detected_v1:fact(Existing, Refused),
    ?assertEqual({text, <<"agora_post_conflict_detected">>}, maps:get(type, Fact)),
    ?assertEqual(1, maps:get(version, Fact)),
    ?assertEqual({text, <<"spartan">>}, maps:get(society, Fact)),
    ?assertEqual({text, <<"p1">>}, maps:get(post_id, Fact)),
    ?assertEqual({text, <<"did:key:a">>}, maps:get(kept_from, Fact)),
    ?assertEqual({text, <<"ab">>}, maps:get(kept_publisher, Fact)),
    ?assertEqual({text, <<"true">>}, maps:get(kept_publisher_verified, Fact)),
    ?assertEqual({text, <<"did:key:b">>}, maps:get(refused_from, Fact)),
    ?assertEqual({text, <<"not_signed">>}, maps:get(refused_publisher_verified, Fact)),
    ?assertEqual({text, sha256(<<"first">>)}, maps:get(kept_body_sha256, Fact)),
    ?assertEqual({text, sha256(<<"second">>)}, maps:get(refused_body_sha256, Fact)),
    ?assertEqual(10, maps:get(kept_heard_at, Fact)),
    ?assertEqual(20, maps:get(refused_heard_at, Fact)),
    ?assertNot(lists:member({text, <<"first">>}, maps:values(Fact))),
    ?assertNot(lists:member({text, <<"second">>}, maps:values(Fact))).

sha256(B) ->
    binary:encode_hex(crypto:hash(sha256, B), lowercase).

fact_carries_only_integers_and_text_test() ->
    Existing = #{<<"post_id">> => <<"p1">>, <<"body">> => <<"first">>, <<"heard_at">> => 1},
    Fact = agora_post_conflict_detected_v1:fact(Existing, agora_test_db:post(#{post_id => <<"p1">>})),
    ?assertEqual([], [K || {K, V} <- maps:to_list(Fact), not wire_safe(V)]).

wire_safe(N) when is_integer(N) -> true;
wire_safe({text, B}) when is_binary(B) -> true;
wire_safe(_Other) -> false.

topic_is_under_the_keeper_namespace_not_a_society_test() ->
    ?assertEqual(<<"agora/post_conflict_detected">>, agora_post_conflict_detected_v1:topic()),
    ?assertEqual(undefined, agora_societies:society_of_topic(agora_post_conflict_detected_v1:topic())).

publish_without_a_mesh_is_ok_test() ->
    Existing = #{<<"post_id">> => <<"p1">>, <<"body">> => <<"first">>, <<"heard_at">> => 1},
    ?assertEqual(ok, agora_post_conflict_detected_v1:publish(
                       Existing, agora_test_db:post(#{post_id => <<"p1">>}))).
