-module(agora_post_recorded_v1_tests).

-include_lib("eunit/include/eunit.hrl").

%% The fact is the post as the wire sees it, typed and versioned, every text
%% field tagged so non-BEAM readers get text, absent fields omitted rather
%% than sent as null.
fact_is_the_post_typed_and_text_tagged_test() ->
    Post = agora_test_db:post(#{post_id => <<"p1">>, from => <<"did:key:a">>, body => <<"said">>,
                                posted_at => 5, heard_at => 6, in_reply_to => <<"p0">>,
                                publisher => <<"ab">>, publisher_verified => <<"true">>}),
    Fact = agora_post_recorded_v1:fact(Post),
    ?assertEqual({text, <<"agora_post_recorded">>}, maps:get(type, Fact)),
    ?assertEqual(1, maps:get(version, Fact)),
    ?assertEqual({text, <<"spartan">>}, maps:get(society, Fact)),
    ?assertEqual({text, <<"p1">>}, maps:get(post_id, Fact)),
    ?assertEqual({text, <<"did:key:a">>}, maps:get(from, Fact)),
    ?assertEqual({text, <<"said">>}, maps:get(body, Fact)),
    ?assertEqual({text, <<"p0">>}, maps:get(in_reply_to, Fact)),
    ?assertEqual({text, <<"ab">>}, maps:get(publisher, Fact)),
    ?assertEqual({text, <<"true">>}, maps:get(publisher_verified, Fact)),
    ?assertEqual(5, maps:get(posted_at, Fact)),
    ?assertEqual(6, maps:get(heard_at, Fact)),
    ?assertNot(maps:is_key(home, Fact)).

%% No booleans and no bare binaries ever cross the wire: every value is an
%% integer or a `{text, Bin}'.
fact_carries_only_integers_and_text_test() ->
    Fact = agora_post_recorded_v1:fact(agora_test_db:post(#{})),
    ?assertEqual([], [K || {K, V} <- maps:to_list(Fact), not wire_safe(V)]).

wire_safe(N) when is_integer(N) -> true;
wire_safe({text, B}) when is_binary(B) -> true;
wire_safe(_Other) -> false.

%% The keeper's topic is its own, never a society's square.
topic_is_under_the_keeper_namespace_not_a_society_test() ->
    ?assertEqual(<<"agora/post_recorded">>, agora_post_recorded_v1:topic()),
    ?assertEqual(undefined, agora_societies:society_of_topic(agora_post_recorded_v1:topic())).

%% Without a mesh (this suite) publishing is a no-op that still returns ok:
%% the record is what matters, and the caller has already written it.
publish_without_a_mesh_is_ok_test() ->
    ?assertEqual(ok, agora_post_recorded_v1:publish(agora_test_db:post(#{}))).
