%% @doc Drives agora_read_model against a real, throwaway barrel_docdb
%% record. Exercising the real find/2 path index is what verifies the query
%% shapes (order_by on a path, compare, flat results) rather than a guess.
-module(agora_read_model_tests).

-include_lib("eunit/include/eunit.hrl").

%%% doc_id/3 -- pure. The whole design rests on this ordering property.

a_newer_post_sorts_before_an_older_one_within_a_society_test() ->
    Newer = agora_read_model:doc_id(<<"spartan">>, 2000, <<"aaaa">>),
    Older = agora_read_model:doc_id(<<"spartan">>, 1000, <<"zzzz">>),
    ?assert(Newer < Older).

posts_in_the_same_millisecond_get_distinct_stable_ids_test() ->
    A = agora_read_model:doc_id(<<"spartan">>, 1000, <<"aaaa">>),
    B = agora_read_model:doc_id(<<"spartan">>, 1000, <<"bbbb">>),
    ?assertNotEqual(A, B),
    ?assertEqual(A, agora_read_model:doc_id(<<"spartan">>, 1000, <<"aaaa">>)).

the_id_starts_with_the_society_and_a_slash_test() ->
    ?assertMatch(<<"news/", _/binary>>, agora_read_model:doc_id(<<"news">>, 1, <<"x">>)).

an_out_of_range_time_is_clamped_in_the_id_not_rejected_test() ->
    ?assert(is_binary(agora_read_model:doc_id(<<"s">>, -5, <<"x">>))),
    ?assert(is_binary(agora_read_model:doc_id(<<"s">>, 99999999999999999, <<"x">>))).

%%% parse_hot_window_days/1 -- pure, same posture as agora_societies:parse/1.

unset_hot_window_falls_back_to_the_default_test() ->
    ?assertEqual(30, agora_read_model:parse_hot_window_days(false)).

an_unparseable_hot_window_falls_back_to_the_default_test() ->
    ?assertEqual(30, agora_read_model:parse_hot_window_days("not a number")),
    ?assertEqual(30, agora_read_model:parse_hot_window_days("0")),
    ?assertEqual(30, agora_read_model:parse_hot_window_days("-5")).

a_valid_hot_window_is_used_test() ->
    ?assertEqual(7, agora_read_model:parse_hot_window_days("7")),
    ?assertEqual(90, agora_read_model:parse_hot_window_days(" 90 ")).

%%% Against a real record.

read_model_test_() ->
    {foreach, fun agora_test_db:setup/0, fun agora_test_db:teardown/1, [
        fun record_then_find_round_trips_every_field/1,
        fun undefined_fields_are_omitted_not_written_as_null/1,
        fun a_second_write_of_the_same_id_is_a_conflict/1,
        fun page_is_newest_first_and_bounded/1,
        fun page_before_is_exclusive/1,
        fun page_filters_by_society_and_author/1,
        fun page_without_a_society_merges_every_society_heard/1,
        fun a_filtered_page_keeps_scanning_past_the_first_chunk/1,
        fun a_society_named_like_a_prefix_of_another_is_kept_apart/1,
        fun replies_to_is_oldest_first/1,
        fun societies_lists_each_once/1,
        fun to_wire_uses_atom_keys_text_tags_and_omits_undefined/1,
        fun a_post_past_its_hot_window_is_gone/1,
        fun a_fresh_post_within_its_hot_window_stays/1
    ]}.

record_then_find_round_trips_every_field(_Db) ->
    Post = agora_test_db:post(#{in_reply_to => <<"parent">>, home => <<"did:key:home">>,
                                publisher => <<"ab", 0:496>>, posted_at => 1000, heard_at => 1001}),
    ok = agora_read_model:record(Post),
    {ok, Doc} = agora_read_model:find(maps:get(post_id, Post)),
    [?_assertEqual(maps:get(post_id, Post), maps:get(<<"post_id">>, Doc)),
     ?_assertEqual(<<"spartan">>, maps:get(<<"society">>, Doc)),
     ?_assertEqual(<<"spartan/agora">>, maps:get(<<"topic">>, Doc)),
     ?_assertEqual(<<"did:key:athena">>, maps:get(<<"from">>, Doc)),
     ?_assertEqual(maps:get(body, Post), maps:get(<<"body">>, Doc)),
     ?_assertEqual(<<"parent">>, maps:get(<<"in_reply_to">>, Doc)),
     ?_assertEqual(1000, maps:get(<<"posted_at">>, Doc)),
     ?_assertEqual(<<"did:key:home">>, maps:get(<<"home">>, Doc)),
     ?_assertEqual(<<"be-brussels">>, maps:get(<<"locale">>, Doc)),
     ?_assertEqual(<<"not_signed">>, maps:get(<<"publisher_verified">>, Doc)),
     ?_assertEqual(1001, maps:get(<<"heard_at">>, Doc)),
     ?_assertEqual(<<"direct">>, maps:get(<<"heard_via">>, Doc))].

undefined_fields_are_omitted_not_written_as_null(_Db) ->
    Post = agora_test_db:post(#{}),
    ok = agora_read_model:record(Post),
    {ok, Doc} = agora_read_model:find(maps:get(post_id, Post)),
    [?_assertNot(maps:is_key(<<"in_reply_to">>, Doc)),
     ?_assertNot(maps:is_key(<<"home">>, Doc)),
     ?_assertNot(maps:is_key(<<"publisher">>, Doc))].

a_second_write_of_the_same_id_is_a_conflict(_Db) ->
    Post = agora_test_db:post(#{}),
    ok = agora_read_model:record(Post),
    ?_assertEqual({error, conflict}, agora_read_model:record(Post)).

page_is_newest_first_and_bounded(_Db) ->
    [ok = agora_read_model:record(agora_test_db:post(#{posted_at => T})) || T <- [3000, 1000, 4000, 2000]],
    {ok, Docs} = agora_read_model:page(#{limit => 3}),
    ?_assertEqual([4000, 3000, 2000], [maps:get(<<"posted_at">>, D) || D <- Docs]).

page_before_is_exclusive(_Db) ->
    [ok = agora_read_model:record(agora_test_db:post(#{posted_at => T})) || T <- [1000, 2000, 3000]],
    {ok, Docs} = agora_read_model:page(#{limit => 10, before => 2000}),
    ?_assertEqual([1000], [maps:get(<<"posted_at">>, D) || D <- Docs]).

page_filters_by_society_and_author(_Db) ->
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 1, from => <<"a">>})),
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 2, from => <<"b">>})),
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 3, from => <<"a">>,
                                                      society => <<"news">>, topic => <<"news/agora">>})),
    {ok, ByAuthor} = agora_read_model:page(#{limit => 10, from => <<"a">>}),
    {ok, BySociety} = agora_read_model:page(#{limit => 10, society => <<"news">>}),
    {ok, Both} = agora_read_model:page(#{limit => 10, society => <<"spartan">>, from => <<"a">>}),
    [?_assertEqual([3, 1], [maps:get(<<"posted_at">>, D) || D <- ByAuthor]),
     ?_assertEqual([3], [maps:get(<<"posted_at">>, D) || D <- BySociety]),
     ?_assertEqual([1], [maps:get(<<"posted_at">>, D) || D <- Both])].

page_without_a_society_merges_every_society_heard(_Db) ->
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 1})),
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 3, society => <<"news">>, topic => <<"news/agora">>})),
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 2})),
    {ok, Docs} = agora_read_model:page(#{limit => 10}),
    ?_assertEqual([3, 2, 1], [maps:get(<<"posted_at">>, D) || D <- Docs]).

%% 450 posts, two authors; the wanted author's posts are the OLDEST ones, so
%% a scan that stopped at its first chunk of 200 would find nothing.
a_filtered_page_keeps_scanning_past_the_first_chunk(_Db) ->
    Docs = [agora_test_db:post(#{posted_at => T, from => author(T)}) || T <- lists:seq(1, 450)],
    lists:foreach(fun(P) -> ok = agora_read_model:record(P) end, Docs),
    {ok, Found} = agora_read_model:page(#{limit => 3, from => <<"did:key:early">>}),
    ?_assertEqual([10, 9, 8], [maps:get(<<"posted_at">>, D) || D <- Found]).

author(T) when T =< 10 -> <<"did:key:early">>;
author(_T) -> <<"did:key:late">>.

a_society_named_like_a_prefix_of_another_is_kept_apart(_Db) ->
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 1, society => <<"news">>, topic => <<"news/agora">>})),
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 2, society => <<"news2">>, topic => <<"news2/agora">>})),
    {ok, News} = agora_read_model:page(#{limit => 10, society => <<"news">>}),
    ?_assertEqual([1], [maps:get(<<"posted_at">>, D) || D <- News]).

societies_lists_each_once(_Db) ->
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 1})),
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 2})),
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 3, society => <<"news">>, topic => <<"news/agora">>})),
    ?_assertEqual([<<"news">>, <<"spartan">>], lists:sort(agora_read_model:societies())).

replies_to_is_oldest_first(_Db) ->
    Root = agora_test_db:post(#{posted_at => 1}),
    ok = agora_read_model:record(Root),
    RootId = maps:get(post_id, Root),
    [ok = agora_read_model:record(agora_test_db:post(#{posted_at => T, in_reply_to => RootId})) || T <- [30, 10, 20]],
    ok = agora_read_model:record(agora_test_db:post(#{posted_at => 40})),
    {ok, Replies} = agora_read_model:replies_to(RootId, 10),
    ?_assertEqual([10, 20, 30], [maps:get(<<"posted_at">>, D) || D <- Replies]).

to_wire_uses_atom_keys_text_tags_and_omits_undefined(_Db) ->
    Post = agora_test_db:post(#{}),
    ok = agora_read_model:record(Post),
    {ok, Doc} = agora_read_model:find(maps:get(post_id, Post)),
    Wire = agora_read_model:to_wire(Doc),
    [?_assertEqual({text, maps:get(post_id, Post)}, maps:get(post_id, Wire)),
     ?_assertEqual({text, <<"spartan">>}, maps:get(society, Wire)),
     ?_assertEqual({text, maps:get(body, Post)}, maps:get(body, Wire)),
     ?_assert(is_integer(maps:get(posted_at, Wire))),
     ?_assertNot(maps:is_key(in_reply_to, Wire)),
     ?_assertNot(maps:is_key(publisher, Wire)),
     ?_assertEqual([], [K || K <- maps:keys(Wire), not is_atom(K)]),
     %% Every binary-valued field is a CBOR text string on the wire, never a
     %% byte string that a non-BEAM reader would see as hex.
     ?_assertEqual([], [K || K := V <- Wire, is_binary(V)])].

%% barrel_docdb's lazy expiry (an expired document is gone the instant its
%% expires_at deadline passes, no sweep required -- see
%% barrel_docdb_reader:expired/1's own doc comment) is real, but it is a
%% property of get_doc/get_docs/fold_docs specifically. find/2,3 (what
%% every read in this module actually uses -- page/1, find/1,
%% replies_to/2, societies/0, and agora_archive:search/1) is compiled and
%% executed by barrel_query, which never calls expired/1 at all: confirmed
%% by grepping barrel_query.erl for it, not assumed. So this record's own
%% read paths keep serving a post past its expires_at until the TTL
%% sweeper (hecate_agora_service:read_model_ttl_sweep/0) has actually run
%% and converted it to a real tombstone -- these two tests check what
%% record/1 is actually responsible for (that expires_at is set to a
%% deadline that already passed, or hasn't, for the given posted_at) via
%% barrel_docdb:get_doc/2 directly, the one read path that DOES honor it,
%% rather than asserting something agora_read_model:find/1 was never going
%% to exhibit.
a_post_past_its_hot_window_is_gone(_Db) ->
    true = os:putenv("HECATE_AGORA_HOT_WINDOW_DAYS", "1"),
    %% posted_at two days ago: one day past the one-day hot window.
    TwoDaysAgo = agora_test_db:now_ms() - 2 * 86_400_000,
    Post = agora_test_db:post(#{posted_at => TwoDaysAgo}),
    ok = agora_read_model:record(Post),
    Result = get_doc_directly(TwoDaysAgo, maps:get(post_id, Post)),
    true = os:unsetenv("HECATE_AGORA_HOT_WINDOW_DAYS"),
    ?_assertEqual({error, not_found}, Result).

a_fresh_post_within_its_hot_window_stays(_Db) ->
    true = os:putenv("HECATE_AGORA_HOT_WINDOW_DAYS", "1"),
    Now = agora_test_db:now_ms(),
    Post = agora_test_db:post(#{posted_at => Now}),
    ok = agora_read_model:record(Post),
    Result = get_doc_directly(Now, maps:get(post_id, Post)),
    true = os:unsetenv("HECATE_AGORA_HOT_WINDOW_DAYS"),
    ?_assertMatch({ok, _}, Result).

get_doc_directly(PostedAt, PostId) ->
    {ok, DbName} = hecate_om:read_model(),
    barrel_docdb:get_doc(DbName, agora_read_model:doc_id(<<"spartan">>, PostedAt, PostId)).
