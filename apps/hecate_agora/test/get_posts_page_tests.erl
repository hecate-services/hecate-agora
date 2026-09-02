-module(get_posts_page_tests).

-include_lib("eunit/include/eunit.hrl").

page_test_() ->
    {foreach, fun agora_test_db:setup/0, fun agora_test_db:teardown/1, [
        fun a_full_page_hands_back_where_the_next_one_starts/1,
        fun the_last_page_has_no_next/1,
        fun an_unusable_limit_falls_back_to_the_default/1,
        fun the_responder_reads_wire_shaped_filters/1
    ]}.

seed(Ts) ->
    [ok = agora_read_model:record(agora_test_db:post(#{posted_at => T})) || T <- Ts].

a_full_page_hands_back_where_the_next_one_starts(_Db) ->
    seed([1000, 2000, 3000]),
    #{posts := Posts, next_before := Next} = get_posts_page:get(#{limit => 2}),
    [?_assertEqual([3000, 2000], [maps:get(posted_at, P) || P <- Posts]),
     ?_assertEqual(2000, Next)].

the_last_page_has_no_next(_Db) ->
    seed([1000, 2000, 3000]),
    #{posts := Posts, next_before := Next} = get_posts_page:get(#{limit => 2, before => 2000}),
    [?_assertEqual([1000], [maps:get(posted_at, P) || P <- Posts]),
     ?_assertEqual(undefined, Next)].

an_unusable_limit_falls_back_to_the_default(_Db) ->
    seed([1000]),
    #{posts := Posts} = get_posts_page:get(#{limit => 0}),
    ?_assertEqual(1, length(Posts)).

the_responder_reads_wire_shaped_filters(_Db) ->
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 1, from => <<"did:key:a">>})),
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 2, from => <<"did:key:b">>})),
    {ok, S} = get_posts_page_responder:init([]),
    {reply, Reply, S} = get_posts_page_responder:handle_request(
                          #{<<"from">> => {text, <<"did:key:a">>}, <<"limit">> => 10}, S),
    [?_assertEqual(1, maps:get(ok, Reply)),
     ?_assertEqual([1], [maps:get(posted_at, P) || P <- maps:get(posts, Reply)]),
     ?_assertNot(maps:is_key(next_before, Reply))].
