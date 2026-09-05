%% @doc Drives retire_stale_posts against a real, throwaway hot record AND a
%% real, throwaway archive -- this is the one suite that exercises the
%% actual hot -> archive hand-off, not either side alone.
-module(retire_stale_posts_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DAY_MS, 86_400_000).

%%% migration_threshold_ms/0 -- pure.

threshold_is_the_hot_window_minus_the_lead_time_test() ->
    true = os:putenv("HECATE_AGORA_HOT_WINDOW_DAYS", "10"),
    Result = retire_stale_posts:migration_threshold_ms(),
    true = os:unsetenv("HECATE_AGORA_HOT_WINDOW_DAYS"),
    ?assertEqual(5 * ?DAY_MS, Result).

%% A hot window shorter than the lead time still migrates something (one
%% day), rather than a zero or negative threshold that would migrate
%% every post ever written the instant it lands.
threshold_floors_at_one_day_when_the_hot_window_is_very_short_test() ->
    true = os:putenv("HECATE_AGORA_HOT_WINDOW_DAYS", "2"),
    Result = retire_stale_posts:migration_threshold_ms(),
    true = os:unsetenv("HECATE_AGORA_HOT_WINDOW_DAYS"),
    ?assertEqual(1 * ?DAY_MS, Result).

%%% Against a real hot record and a real archive.

retire_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun a_stale_post_migrates_but_stays_in_hot_until_its_own_ttl/1,
        fun a_fresh_post_is_not_migrated/1,
        fun run_also_prunes_expired_archive_segments/1
    ]}.

setup() ->
    true = os:putenv("HECATE_AGORA_HOT_WINDOW_DAYS", "10"),
    {agora_test_db:setup(), agora_archive_test_db:setup()}.

teardown({HotDb, ArchiveDb}) ->
    true = os:unsetenv("HECATE_AGORA_HOT_WINDOW_DAYS"),
    ok = agora_test_db:teardown(HotDb),
    ok = agora_archive_test_db:teardown(ArchiveDb).

%% Hot window 10 days, lead 5 -- migration threshold is posts older than 5
%% days. Six days old is past that threshold but still inside the 10-day
%% hot window, so it must be migrated AND still readable from hot: only
%% the hot record's own TTL sweep (barrel_docdb, not this module) ever
%% removes it from there.
a_stale_post_migrates_but_stays_in_hot_until_its_own_ttl(_Fixture) ->
    SixDaysAgo = agora_test_db:now_ms() - 6 * ?DAY_MS,
    Post = agora_test_db:post(#{posted_at => SixDaysAgo}),
    ok = agora_read_model:record(Post),
    #{migrated := Migrated} = retire_stale_posts:run(),
    PostId = maps:get(post_id, Post),
    {ok, #{posts := Archived}} = agora_archive:search(#{society => <<"spartan">>,
                                                        from => SixDaysAgo - 1, until => SixDaysAgo + 1}),
    StillHot = agora_read_model:find(PostId),
    [?_assertEqual(1, Migrated),
     ?_assertEqual([PostId], [maps:get(<<"post_id">>, P) || P <- Archived]),
     ?_assertMatch({ok, _}, StillHot)].

a_fresh_post_is_not_migrated(_Fixture) ->
    Now = agora_test_db:now_ms(),
    Post = agora_test_db:post(#{posted_at => Now}),
    ok = agora_read_model:record(Post),
    #{migrated := Migrated} = retire_stale_posts:run(),
    {ok, #{posts := Archived}} = agora_archive:search(#{society => <<"spartan">>,
                                                        from => Now - 1, until => Now + 1}),
    [?_assertEqual(0, Migrated), ?_assertEqual([], Archived)].

run_also_prunes_expired_archive_segments(_Fixture) ->
    true = os:putenv("HECATE_AGORA_ARCHIVE_YEARS", "2"),
    OldYear = calendar:datetime_to_gregorian_seconds({{1999, 6, 1}, {0, 0, 0}}) * 1000 -
              calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}) * 1000,
    ok = agora_archive:archive_post(#{<<"id">> => agora_read_model:doc_id(<<"spartan">>, OldYear, <<"x">>),
                                      <<"post_id">> => <<"x">>,
                                      <<"society">> => <<"spartan">>, <<"posted_at">> => OldYear}),
    #{pruned := Pruned} = retire_stale_posts:run(),
    {ok, #{posts := Gone}} = agora_archive:search(#{society => <<"spartan">>,
                                                    from => OldYear - 1, until => OldYear + 1}),
    true = os:unsetenv("HECATE_AGORA_ARCHIVE_YEARS"),
    [?_assert(Pruned >= 1), ?_assertEqual([], Gone)].
