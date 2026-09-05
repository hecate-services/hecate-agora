%% @doc Periodic maintenance for the hot/archive split: copy hot posts
%% approaching their own expiry into the archive, then prune whole archive
%% segments past retention. Runs on a timer (`retire_stale_posts_worker'),
%% never on the request path -- neither `get_posts_page' nor
%% `search_posts' nor `search_archive' calls this.
%%
%% == The migration threshold, not the hot window itself ==
%%
%% A post must be copied into the archive before the hot-tier TTL SWEEP
%% actually reaps it: barrel_docdb's lazy expiry (invisible on read past
%% `expires_at', no sweep needed) only applies to
%% `get_doc'/`get_docs'/`fold_docs' -- the scan this module uses to find
%% posts to migrate (`agora_read_model:page/1') goes through `find/2,3',
%% which never checks expiry (confirmed by reading `barrel_query.erl', not
%% assumed), so a stale post stays visible to this scan right up until
%% `hecate_agora_service:read_model_ttl_sweep/0' physically deletes it.
%% The real constraint this threshold protects against is simpler than "a
%% read makes it vanish instantly": this module and the sweep both run on
%% their own timer, so migration just needs to have run AT LEAST ONCE
%% before the sweep's tombstone-writing pass reaches a given post. The
%% threshold below sits `?MIGRATION_LEAD_DAYS' before the hot window's own
%% edge, a wide safety margin against both timers' run intervals.
%%
%% == Idempotent, so a crash mid-tick costs nothing ==
%%
%% `agora_archive:archive_post/1' is idempotent (see its own doc), so this
%% module makes no attempt to track what it has already migrated across
%% ticks -- it re-scans everything past the threshold every time, and a
%% post already archived just archives again as a no-op. A crash partway
%% through one tick (an unhandled `archive_post/1' error, a supervisor
%% restart) abandons the rest of THAT tick, but the next tick re-finds and
%% re-migrates everything still in the hot record, so nothing is lost.
-module(retire_stale_posts).

-export([run/0, migration_threshold_ms/0]).

%% Days of margin before the hot record's own expiry. At
%% `retire_stale_posts_worker''s default one-hour run interval this is a
%% huge multiple of how often a tick actually happens, so one missed or
%% slow tick is not a real risk.
-define(MIGRATION_LEAD_DAYS, 5).
-define(DAY_MS, 86_400_000).
%% Bound on how many posts one migration pass moves per society, so a
%% society that fell far behind (a long outage) doesn't try to walk its
%% entire eligible backlog in one call. A slower catch-up over several
%% ticks is fine; an unbounded one is not.
-define(MIGRATION_BATCH, 1000).

-spec run() -> #{migrated := non_neg_integer(), pruned := non_neg_integer()}.
run() ->
    Migrated = lists:sum([migrate(Society) || Society <- agora_societies:configured()]),
    {ok, Pruned} = agora_archive:prune_expired_segments(),
    #{migrated => Migrated, pruned => Pruned}.

migrate(Society) ->
    Threshold = erlang:system_time(millisecond) - migration_threshold_ms(),
    {ok, Docs} = agora_read_model:page(#{society => Society, before => Threshold,
                                          limit => ?MIGRATION_BATCH}),
    lists:foreach(fun archive_one/1, Docs),
    length(Docs).

archive_one(Doc) ->
    ok = agora_archive:archive_post(Doc).

%% @doc How far back from now a post must be, by its OWN `posted_at', to be
%% migrated: `agora_read_model:hot_window_days/0' minus the lead time,
%% floored at one day so a hot window shorter than the lead time still
%% migrates something rather than nothing.
-spec migration_threshold_ms() -> pos_integer().
migration_threshold_ms() ->
    max(1, agora_read_model:hot_window_days() - ?MIGRATION_LEAD_DAYS) * ?DAY_MS.
