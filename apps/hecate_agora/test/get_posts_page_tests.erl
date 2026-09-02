-module(get_posts_page_tests).

-include_lib("eunit/include/eunit.hrl").

page_test_() ->
    {foreach, fun agora_test_db:setup/0, fun agora_test_db:teardown/1, [
        fun a_full_page_hands_back_where_the_next_one_starts/1,
        fun the_last_page_has_no_next/1,
        fun an_unusable_limit_falls_back_to_the_default/1,
        fun the_responder_reads_wire_shaped_filters/1,
        fun after_bounds_the_page_from_below/1,
        fun after_and_before_bracket_a_window/1,
        fun an_empty_window_is_an_empty_page/1,
        fun the_responder_reads_after_off_the_wire/1
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

%% `after' is exclusive: a subscriber that last saw posted_at 2000 asks for
%% everything after it and gets only what came later, still newest first.
after_bounds_the_page_from_below(_Db) ->
    seed([1000, 2000, 3000, 4000]),
    #{posts := Posts, next_before := Next} = get_posts_page:get(#{'after' => 2000, limit => 10}),
    [?_assertEqual([4000, 3000], [maps:get(posted_at, P) || P <- Posts]),
     ?_assertEqual(undefined, Next)].

%% Catch-up paging: `after' stays fixed while `before' walks down, and the
%% gap closes exactly, without either boundary post.
after_and_before_bracket_a_window(_Db) ->
    seed([1000, 2000, 3000, 4000, 5000]),
    #{posts := P1, next_before := N1} = get_posts_page:get(#{'after' => 1000, limit => 2}),
    #{posts := P2, next_before := N2} = get_posts_page:get(#{'after' => 1000, before => N1, limit => 2}),
    #{posts := P3, next_before := N3} = get_posts_page:get(#{'after' => 1000, before => N2, limit => 2}),
    [?_assertEqual([5000, 4000], [maps:get(posted_at, P) || P <- P1]),
     ?_assertEqual(4000, N1),
     ?_assertEqual([3000, 2000], [maps:get(posted_at, P) || P <- P2]),
     ?_assertEqual(2000, N2),
     ?_assertEqual([], P3),
     ?_assertEqual(undefined, N3)].

%% Nothing lies strictly between the bounds, or they are the wrong way
%% round: an empty page, never an error from the store.
an_empty_window_is_an_empty_page(_Db) ->
    seed([1000, 2000]),
    #{posts := Posts} = get_posts_page:get(#{'after' => 1000, before => 2000, limit => 10}),
    #{posts := Same} = get_posts_page:get(#{'after' => 2000, before => 1000, limit => 10}),
    [?_assertEqual([], Posts), ?_assertEqual([], Same)].

the_responder_reads_after_off_the_wire(_Db) ->
    seed([1, 2, 3]),
    {ok, S} = get_posts_page_responder:init([]),
    {reply, Reply, S} = get_posts_page_responder:handle_request(#{<<"after">> => 1, <<"limit">> => 10}, S),
    [?_assertEqual(1, maps:get(ok, Reply)),
     ?_assertEqual([3, 2], [maps:get(posted_at, P) || P <- maps:get(posts, Reply)])].
