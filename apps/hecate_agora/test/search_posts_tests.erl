-module(search_posts_tests).

-include_lib("eunit/include/eunit.hrl").

%%% tokens/1 and score/2 -- pure.

tokens_lowercase_split_and_dedupe_test() ->
    ?assertEqual([<<"the">>, <<"board">>, <<"is">>, <<"set">>],
                 search_posts:tokens(<<"The board is set. THE BOARD!">>)).

tokens_keep_unicode_letters_test() ->
    ?assertEqual([<<"café"/utf8>>, <<"élan"/utf8>>], search_posts:tokens(<<"Café, élan"/utf8>>)).

tokens_of_punctuation_only_is_empty_test() ->
    ?assertEqual([], search_posts:tokens(<<"... ?! --">>)).

score_counts_distinct_words_and_the_phrase_test() ->
    Doc = #{<<"body">> => <<"Mercury threw the door open again.">>},
    ?assertEqual(3, search_posts:score(Doc, {[<<"door">>, <<"open">>], <<"door open">>})),
    ?assertEqual(1, search_posts:score(Doc, {[<<"open">>, <<"gate">>], <<"open gate">>})),
    ?assertEqual(0, search_posts:score(Doc, {[<<"gate">>], <<"gate">>})).

%%% search/1 -- against a real record.

search_test_() ->
    {foreach, fun agora_test_db:setup/0, fun agora_test_db:teardown/1, [
        fun ranks_the_phrase_above_a_single_word_and_drops_misses/1,
        fun honours_the_society_filter/1,
        fun an_empty_query_is_refused/1,
        fun the_responder_speaks_wire/1
    ]}.

seed() ->
    Bodies = [{1, <<"Heimdall asks who is on the other side of the door.">>},
              {2, <<"Mercury threw the door open again.">>},
              {3, <<"Athena asks what any of it is for.">>}],
    [ok = agora_read_model:record(agora_test_db:post(#{posted_at => T, body => B})) || {T, B} <- Bodies],
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 4, body => <<"An open door in the news.">>,
                                                      society => <<"news">>, topic => <<"news/agora">>})).

ranks_the_phrase_above_a_single_word_and_drops_misses(_Db) ->
    seed(),
    {ok, Hits} = search_posts:search(#{query => <<"door open">>, society => <<"spartan">>}),
    [?_assertEqual([2, 1], [maps:get(posted_at, H) || H <- Hits]),
     ?_assertEqual([3, 1], [maps:get(score, H) || H <- Hits])].

honours_the_society_filter(_Db) ->
    seed(),
    {ok, News} = search_posts:search(#{query => <<"door">>, society => <<"news">>}),
    {ok, All} = search_posts:search(#{query => <<"door">>}),
    [?_assertEqual([4], [maps:get(posted_at, H) || H <- News]),
     ?_assertEqual(3, length(All))].

an_empty_query_is_refused(_Db) ->
    [?_assertEqual({error, query_required}, search_posts:search(#{query => <<"">>})),
     ?_assertEqual({error, query_required}, search_posts:search(#{query => <<"?!">>})),
     ?_assertEqual({error, query_required}, search_posts:search(#{}))].

the_responder_speaks_wire(_Db) ->
    seed(),
    {ok, S} = search_posts_responder:init([]),
    {reply, Found, S} = search_posts_responder:handle_request(
                          #{<<"query">> => {text, <<"asks">>}, <<"limit">> => 1}, S),
    {reply, Refused, S} = search_posts_responder:handle_request(#{}, S),
    [?_assertEqual(1, maps:get(ok, Found)),
     ?_assertEqual(1, length(maps:get(posts, Found))),
     ?_assertEqual(#{ok => 0, error => <<"query_required">>}, Refused)].
