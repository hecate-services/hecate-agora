-module(on_agora_post_maybe_record_tests).

-include_lib("eunit/include/eunit.hrl").

%%% decide/2 -- pure, no database.

an_unseen_post_is_recorded_test() ->
    ?assertEqual(record, on_agora_post_maybe_record:decide(undefined, agora_test_db:post(#{}))).

the_same_post_again_is_a_duplicate_test() ->
    Post = agora_test_db:post(#{}),
    Existing = #{<<"post_id">> => maps:get(post_id, Post), <<"body">> => maps:get(body, Post)},
    ?assertEqual(duplicate, on_agora_post_maybe_record:decide(Existing, Post)).

the_same_id_with_another_body_is_a_contradiction_test() ->
    Post = agora_test_db:post(#{body => <<"I never said that.">>}),
    Existing = #{<<"post_id">> => maps:get(post_id, Post), <<"body">> => <<"I said this.">>},
    ?assertEqual(contradiction, on_agora_post_maybe_record:decide(Existing, Post)).

%%% handle/1 -- against a real record.

handle_test_() ->
    {foreach, fun agora_test_db:setup/0, fun agora_test_db:teardown/1, [
        fun records_then_deduplicates/1,
        fun a_contradiction_keeps_the_first_body/1
    ]}.

records_then_deduplicates(_Db) ->
    Post = agora_test_db:post(#{}),
    First = on_agora_post_maybe_record:handle(Post),
    Second = on_agora_post_maybe_record:handle(Post),
    {ok, Docs} = agora_read_model:page(#{limit => 10}),
    [?_assertEqual(recorded, First),
     ?_assertEqual(duplicate, Second),
     ?_assertEqual(1, length(Docs))].

a_contradiction_keeps_the_first_body(_Db) ->
    Post = agora_test_db:post(#{body => <<"first">>}),
    recorded = on_agora_post_maybe_record:handle(Post),
    Outcome = on_agora_post_maybe_record:handle(Post#{body => <<"second">>}),
    {ok, Doc} = agora_read_model:find(maps:get(post_id, Post)),
    [?_assertEqual(contradiction, Outcome),
     ?_assertEqual(<<"first">>, maps:get(<<"body">>, Doc))].
