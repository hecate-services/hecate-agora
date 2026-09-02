-module(get_thread_by_post_id_tests).

-include_lib("eunit/include/eunit.hrl").

thread_test_() ->
    {foreach, fun agora_test_db:setup/0, fun agora_test_db:teardown/1, [
        fun a_thread_is_the_root_and_every_descendant_in_order/1,
        fun asking_from_a_leaf_finds_the_same_root/1,
        fun a_reply_to_a_post_never_heard_is_its_own_top/1,
        fun an_unknown_post_is_not_found/1,
        fun the_responder_speaks_wire/1
    ]}.

%% root(1000) <- r1(2000) <- r1a(4000)
%%           <- r2(3000)
%% and an unrelated post at 5000.
seed() ->
    Root = agora_test_db:post(#{posted_at => 1000, body => <<"root">>}),
    RootId = maps:get(post_id, Root),
    R1 = agora_test_db:post(#{posted_at => 2000, in_reply_to => RootId, body => <<"r1">>}),
    R2 = agora_test_db:post(#{posted_at => 3000, in_reply_to => RootId, body => <<"r2">>}),
    R1a = agora_test_db:post(#{posted_at => 4000, in_reply_to => maps:get(post_id, R1), body => <<"r1a">>}),
    Other = agora_test_db:post(#{posted_at => 5000, body => <<"other">>}),
    [ok = agora_read_model:record(P) || P <- [Root, R1, R2, R1a, Other]],
    #{root => Root, r1 => R1, r2 => R2, r1a => R1a}.

bodies(Posts) -> [maps:get(body, P) || P <- Posts].

a_thread_is_the_root_and_every_descendant_in_order(_Db) ->
    #{root := Root} = seed(),
    {ok, #{root := R, posts := Posts}} = get_thread_by_post_id:get(maps:get(post_id, Root)),
    [?_assertEqual(<<"root">>, maps:get(body, R)),
     ?_assertEqual([<<"root">>, <<"r1">>, <<"r2">>, <<"r1a">>], bodies(Posts))].

asking_from_a_leaf_finds_the_same_root(_Db) ->
    #{r1a := R1a} = seed(),
    {ok, #{root := R, posts := Posts}} = get_thread_by_post_id:get(maps:get(post_id, R1a)),
    [?_assertEqual(<<"root">>, maps:get(body, R)),
     ?_assertEqual(4, length(Posts))].

a_reply_to_a_post_never_heard_is_its_own_top(_Db) ->
    Orphan = agora_test_db:post(#{posted_at => 1, in_reply_to => <<"never-heard">>, body => <<"orphan">>}),
    ok = agora_read_model:record(Orphan),
    {ok, #{root := R, posts := Posts}} = get_thread_by_post_id:get(maps:get(post_id, Orphan)),
    [?_assertEqual(<<"orphan">>, maps:get(body, R)),
     ?_assertEqual([<<"orphan">>], bodies(Posts))].

an_unknown_post_is_not_found(_Db) ->
    ?_assertEqual({error, not_found}, get_thread_by_post_id:get(<<"nope">>)).

the_responder_speaks_wire(_Db) ->
    #{r2 := R2} = seed(),
    {ok, S} = get_thread_by_post_id_responder:init([]),
    {reply, Found, S} = get_thread_by_post_id_responder:handle_request(
                          #{<<"post_id">> => {text, maps:get(post_id, R2)}}, S),
    {reply, Missing, S} = get_thread_by_post_id_responder:handle_request(#{post_id => <<"nope">>}, S),
    {reply, Empty, S} = get_thread_by_post_id_responder:handle_request(#{}, S),
    [?_assertEqual(1, maps:get(ok, Found)),
     ?_assertEqual(<<"root">>, maps:get(body, maps:get(root, Found))),
     ?_assertEqual(#{ok => 0, error => <<"not_found">>}, Missing),
     ?_assertEqual(#{ok => 0, error => <<"post_id_required">>}, Empty)].
