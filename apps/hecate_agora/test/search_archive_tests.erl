-module(search_archive_tests).

-include_lib("eunit/include/eunit.hrl").

archive_test_() ->
    {foreach, fun agora_archive_test_db:setup/0, fun agora_archive_test_db:teardown/1, [
        fun a_full_page_hands_back_where_the_next_one_starts/1,
        fun a_missing_required_field_is_refused/1,
        fun the_responder_reads_wire_shaped_fields/1,
        fun the_responder_refuses_an_inverted_range/1
    ]}.

%% Shaped exactly like a document `retire_stale_posts' would hand
%% `archive_post/1' -- every field `agora_read_model:to_wire/1' requires
%% without a default (`from', `publisher_verified', `heard_at', `heard_via'),
%% and `<<"id">>' as `agora_read_model:doc_id/3''s own encoding, since
%% id-range search relies on it, same as a real write.
seed(Ts) ->
    [begin
         PostId = id(),
         ok = agora_archive:archive_post(#{<<"id">> => agora_read_model:doc_id(<<"spartan">>, T, PostId),
                                           <<"post_id">> => PostId, <<"society">> => <<"spartan">>,
                                           <<"posted_at">> => T, <<"body">> => <<"a post">>,
                                           <<"from">> => <<"did:key:athena">>,
                                           <<"publisher_verified">> => <<"not_signed">>,
                                           <<"heard_at">> => T, <<"heard_via">> => <<"direct">>})
     end || T <- Ts].

id() -> binary:encode_hex(crypto:strong_rand_bytes(8), lowercase).

a_full_page_hands_back_where_the_next_one_starts(_Fixture) ->
    seed([1000, 2000, 3000]),
    #{posts := Posts, next_before := Next} =
        search_archive:get(#{society => <<"spartan">>, from => 0, until => 4000, limit => 2}),
    [?_assertEqual([3000, 2000], [maps:get(posted_at, P) || P <- Posts]),
     ?_assertEqual(2000, Next)].

a_missing_required_field_is_refused(_Fixture) ->
    ?_assertEqual({error, invalid_range}, search_archive:get(#{society => <<"spartan">>, from => 0})).

the_responder_reads_wire_shaped_fields(_Fixture) ->
    seed([1000, 2000]),
    {ok, S} = search_archive_responder:init([]),
    {reply, Reply, S} = search_archive_responder:handle_request(
                          #{<<"society">> => {text, <<"spartan">>}, <<"from">> => 0,
                            <<"until">> => 3000, <<"limit">> => 10}, S),
    [?_assertEqual(1, maps:get(ok, Reply)),
     ?_assertEqual([2000, 1000], [maps:get(posted_at, P) || P <- maps:get(posts, Reply)]),
     ?_assertNot(maps:is_key(next_before, Reply))].

the_responder_refuses_an_inverted_range(_Fixture) ->
    {ok, S} = search_archive_responder:init([]),
    {reply, Reply, S} = search_archive_responder:handle_request(
                          #{<<"society">> => {text, <<"spartan">>}, <<"from">> => 3000, <<"until">> => 1000}, S),
    [?_assertEqual(0, maps:get(ok, Reply)),
     ?_assertEqual(<<"invalid_range">>, maps:get(error, Reply))].
