%% @doc Drives agora_archive against real, throwaway archive segments.
-module(agora_archive_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Pure.

segment_db_name_is_lowercased_and_year_scoped_test() ->
    ?assertEqual(<<"hecate_agora_archive_spartan_2027">>,
                 agora_archive:segment_db_name(<<"spartan">>, 2027)),
    ?assertEqual(<<"hecate_agora_archive_spartan_2027">>,
                 agora_archive:segment_db_name(<<"SPARTAN">>, 2027)).

year_of_is_the_utc_calendar_year_test() ->
    %% 2027-01-01T00:00:00Z
    ?assertEqual(2027, agora_archive:year_of(1798761600000)),
    %% 2026-12-31T23:59:59.999Z, one ms before the same boundary.
    ?assertEqual(2026, agora_archive:year_of(1798761599999)).

unset_retention_falls_back_to_the_default_test() ->
    ?assertEqual(10, agora_archive:parse_retention_years(false)).

an_unparseable_retention_falls_back_to_the_default_test() ->
    ?assertEqual(10, agora_archive:parse_retention_years("not a number")),
    ?assertEqual(10, agora_archive:parse_retention_years("0")).

a_valid_retention_is_used_test() ->
    ?assertEqual(3, agora_archive:parse_retention_years("3")).

%%% Against real, throwaway segments.

archive_test_() ->
    {foreach, fun agora_archive_test_db:setup/0, fun agora_archive_test_db:teardown/1, [
        fun archive_then_search_round_trips/1,
        fun archiving_the_same_post_twice_is_a_no_op/1,
        fun a_post_is_filed_under_its_own_posted_at_year/1,
        fun search_spans_more_than_one_yearly_segment/1,
        fun search_is_newest_first_and_bounded/1,
        fun a_range_touching_a_year_with_nothing_archived_is_empty_not_an_error/1,
        fun an_inverted_range_is_refused/1,
        fun prune_removes_only_segments_past_retention/1
    ]}.

%% Shaped exactly like a document `retire_stale_posts' would actually hand
%% `archive_post/1' -- id-range search relies on `<<"id">>' being
%% `agora_read_model:doc_id/3''s own encoding of society/posted_at/post_id,
%% same as a real hot-record write, not an arbitrary key.
doc(Overrides) ->
    Base = maps:merge(#{<<"post_id">> => id(), <<"society">> => <<"spartan">>,
                        <<"body">> => <<"a post">>, <<"posted_at">> => year_ms(2027, 6)},
                      Overrides),
    #{<<"post_id">> := PostId, <<"society">> := Society, <<"posted_at">> := PostedAt} = Base,
    Base#{<<"id">> => agora_read_model:doc_id(Society, PostedAt, PostId)}.

id() -> binary:encode_hex(crypto:strong_rand_bytes(8), lowercase).

%% Milliseconds for the first of Month, Year, UTC.
year_ms(Year, Month) ->
    calendar:datetime_to_gregorian_seconds({{Year, Month, 1}, {0, 0, 0}}) * 1000 -
        calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}) * 1000.

archive_then_search_round_trips(_Fixture) ->
    Doc = doc(#{}),
    ok = agora_archive:archive_post(Doc),
    {ok, #{posts := Posts}} = agora_archive:search(#{society => <<"spartan">>,
                                                     from => year_ms(2027, 1),
                                                     until => year_ms(2028, 1)}),
    ?_assertEqual([maps:get(<<"post_id">>, Doc)], [maps:get(<<"post_id">>, P) || P <- Posts]).

archiving_the_same_post_twice_is_a_no_op(_Fixture) ->
    Doc = doc(#{}),
    ok = agora_archive:archive_post(Doc),
    %% barrel_docdb's own {error, conflict} on the identical id, treated as
    %% success -- see agora_archive:archive_post/1's own doc.
    ?_assertEqual(ok, agora_archive:archive_post(Doc)).

a_post_is_filed_under_its_own_posted_at_year(_Fixture) ->
    Doc2026 = doc(#{<<"posted_at">> => year_ms(2026, 6)}),
    ok = agora_archive:archive_post(Doc2026),
    {ok, #{posts := In2026}} = agora_archive:search(#{society => <<"spartan">>,
                                                      from => year_ms(2026, 1), until => year_ms(2027, 1)}),
    {ok, #{posts := In2027}} = agora_archive:search(#{society => <<"spartan">>,
                                                      from => year_ms(2027, 1), until => year_ms(2028, 1)}),
    [?_assertEqual(1, length(In2026)), ?_assertEqual(0, length(In2027))].

search_spans_more_than_one_yearly_segment(_Fixture) ->
    ok = agora_archive:archive_post(doc(#{<<"posted_at">> => year_ms(2025, 6)})),
    ok = agora_archive:archive_post(doc(#{<<"posted_at">> => year_ms(2026, 6)})),
    ok = agora_archive:archive_post(doc(#{<<"posted_at">> => year_ms(2027, 6)})),
    {ok, #{posts := Posts}} = agora_archive:search(#{society => <<"spartan">>,
                                                     from => year_ms(2025, 1), until => year_ms(2028, 1)}),
    ?_assertEqual([year_ms(2027, 6), year_ms(2026, 6), year_ms(2025, 6)],
                 [maps:get(<<"posted_at">>, P) || P <- Posts]).

search_is_newest_first_and_bounded(_Fixture) ->
    [ok = agora_archive:archive_post(doc(#{<<"posted_at">> => T})) ||
        T <- [year_ms(2027, 1), year_ms(2027, 3), year_ms(2027, 6), year_ms(2027, 9)]],
    {ok, #{posts := Posts, next_before := Next}} =
        agora_archive:search(#{society => <<"spartan">>, from => year_ms(2027, 1),
                               until => year_ms(2028, 1), limit => 2}),
    [?_assertEqual([year_ms(2027, 9), year_ms(2027, 6)], [maps:get(<<"posted_at">>, P) || P <- Posts]),
     ?_assertEqual(year_ms(2027, 6), Next)].

a_range_touching_a_year_with_nothing_archived_is_empty_not_an_error(_Fixture) ->
    {ok, #{posts := Posts, next_before := Next}} =
        agora_archive:search(#{society => <<"spartan">>, from => year_ms(1999, 1), until => year_ms(2000, 1)}),
    [?_assertEqual([], Posts), ?_assertEqual(undefined, Next)].

an_inverted_range_is_refused(_Fixture) ->
    ?_assertEqual({error, invalid_range},
                 agora_archive:search(#{society => <<"spartan">>, from => year_ms(2028, 1),
                                        until => year_ms(2027, 1)})).

%% HECATE_AGORA_ARCHIVE_YEARS=2, current year is whatever "now" is when the
%% suite runs -- a segment archived far in the past (1999) is well outside
%% any realistic retention window, and one archived "now" is always inside
%% it, so the assertion holds regardless of the actual run date.
prune_removes_only_segments_past_retention(_Fixture) ->
    true = os:putenv("HECATE_AGORA_ARCHIVE_YEARS", "2"),
    Now = erlang:system_time(millisecond),
    ok = agora_archive:archive_post(doc(#{<<"posted_at">> => Now})),
    OldYearMs = year_ms(1999, 6),
    ok = agora_archive:archive_post(doc(#{<<"posted_at">> => OldYearMs})),
    {ok, PrunedCount} = agora_archive:prune_expired_segments(),
    {ok, #{posts := StillThere}} = agora_archive:search(#{society => <<"spartan">>,
                                                          from => Now - 1, until => Now + 1}),
    {ok, #{posts := Gone}} = agora_archive:search(#{society => <<"spartan">>,
                                                    from => year_ms(1999, 1), until => year_ms(2000, 1)}),
    true = os:unsetenv("HECATE_AGORA_ARCHIVE_YEARS"),
    [?_assert(PrunedCount >= 1), ?_assertEqual(1, length(StillThere)), ?_assertEqual([], Gone)].
