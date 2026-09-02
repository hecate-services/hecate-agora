-module(agora_societies_tests).

-include_lib("eunit/include/eunit.hrl").

unset_means_spartan_test() ->
    ?assertEqual([<<"spartan">>], agora_societies:parse(false)).

empty_means_spartan_test() ->
    ?assertEqual([<<"spartan">>], agora_societies:parse("")),
    ?assertEqual([<<"spartan">>], agora_societies:parse(" , ,")).

a_list_is_split_and_trimmed_test() ->
    ?assertEqual([<<"spartan">>, <<"news">>], agora_societies:parse("spartan, news")),
    ?assertEqual([<<"spartan">>, <<"news">>], agora_societies:parse(<<"spartan,news">>)).

duplicates_collapse_to_the_first_test() ->
    ?assertEqual([<<"news">>, <<"spartan">>], agora_societies:parse("news,spartan,news")).

a_name_with_a_slash_or_a_space_is_a_typo_not_a_namespace_test() ->
    ?assertEqual([<<"spartan">>], agora_societies:parse("spartan,news/agora,two words")).

all_invalid_falls_back_to_spartan_test() ->
    ?assertEqual([<<"spartan">>], agora_societies:parse("a/b")).

agora_topic_is_namespace_slash_agora_test() ->
    ?assertEqual(<<"news/agora">>, agora_societies:agora_topic(<<"news">>)).

society_of_topic_strips_the_suffix_test() ->
    ?assertEqual(<<"spartan">>, agora_societies:society_of_topic(<<"spartan/agora">>)).

society_of_a_non_agora_topic_is_undefined_test() ->
    ?assertEqual(undefined, agora_societies:society_of_topic(<<"spartan/feed">>)),
    ?assertEqual(undefined, agora_societies:society_of_topic(<<"/agora">>)),
    ?assertEqual(undefined, agora_societies:society_of_topic(<<"agora">>)).

%% `agora' is the keeper's own namespace (`agora/post_recorded'), so it can
%% never be a society: it is dropped like a typo, and the rest stand.
the_keeper_namespace_is_not_a_society_test() ->
    ?assertEqual([<<"spartan">>], agora_societies:parse("agora")),
    ?assertEqual([<<"news">>], agora_societies:parse("agora,news")).
