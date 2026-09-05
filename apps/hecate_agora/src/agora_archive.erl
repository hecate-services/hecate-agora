%% @doc The cold half of the record: one barrel_docdb database per society
%% per calendar year, holding posts retired here from the hot record
%% (`agora_read_model') once they age past `agora_read_model:hot_window_days/0'.
%%
%% == Why segments, not one growing archive ==
%%
%% A single ever-growing archive database would need the same per-document
%% TTL bookkeeping the hot record already has, and it would never actually
%% shrink -- disk keeps growing at the archive's own rate forever, just
%% slower than the hot record would have without a cap. Splitting the
%% archive into one database per calendar year turns "prune what's past
%% retention" into deleting whole aged-out databases
%% (`barrel_docdb:delete_db/1'), no per-document bookkeeping in this tier at
%% all, and the boundary matches how a caller actually asks for archived
%% speech: "what did the square say in 2027", not an arbitrary moving
%% cutoff.
%%
%% == Documents are the hot record's own, verbatim ==
%%
%% A retired document is written to its segment exactly as `retire_stale_posts'
%% read it back from the hot record (same `<<"id">>' -- society/inverted
%% posted_at/post_id -- same every other field), so this module never
%% reconstructs a post, and a segment's own id-range scan sorts newest first
%% for free -- the same property `agora_read_model' relies on, using the
%% same `inverted/1' encoding (reused from there rather than copied, so the
%% two can never drift apart).
%%
%% == Idempotent by construction ==
%%
%% A post can be retired more than once: `retire_stale_posts' re-scans
%% everything past its threshold on every tick, and a post stays past that
%% threshold for days before the hot record's own TTL finally reclaims it.
%% Writing the same id twice to the same segment is barrel_docdb's own
%% `{error, conflict}', treated here as success -- the post is already
%% archived, which is exactly what was asked.
%%
%% == A query never creates a segment ==
%%
%% Writing (`archive_post/1') creates a segment on first use. Reading
%% (`search/1') and pruning (`prune_expired_segments/0') only ever open a
%% segment that a directory on disk proves was actually created --
%% otherwise a query touching a year nothing was ever posted in would
%% silently leave behind an empty database forever.
-module(agora_archive).

-export([archive_post/1, search/1, prune_expired_segments/0]).
%% Pure, exported for testability without an environment or a database.
-export([segment_db_name/2, year_of/1, retention_years/0, parse_retention_years/1]).

-type request() :: #{society := binary(), from := integer(), until := integer(),
                     limit => pos_integer()}.
-export_type([request/0]).

-define(RETENTION_YEARS_DEFAULT, 10).
%% Generous bound on how far back to look for a segment that might be due
%% for pruning. A directory-existence check per candidate year costs
%% microseconds, so there is no reason to cut this close.
-define(PRUNE_LOOKBACK_YEARS, 60).
-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 200).
%% Documents fetched per round while scanning one segment, and the most one
%% search may scan (per segment) before giving up on finding more matches --
%% same posture as `agora_read_model''s own `?SCAN_CAP'.
-define(SCAN_CAP, 5000).

%% ---------------------------------------------------------------------
%% Writing
%% ---------------------------------------------------------------------

%% @doc Archive one document, exactly as read back from the hot record
%% (binary keys, `<<"society">>' and `<<"posted_at">>' present), into the
%% segment for its own `posted_at' year -- NOT the year `archive_post/1'
%% happens to run in, so segments stay calendar-accurate regardless of how
%% far behind a migration tick is.
-spec archive_post(map()) -> ok | {error, term()}.
archive_post(#{<<"society">> := Society, <<"posted_at">> := PostedAt} = Doc)
  when is_binary(Society), is_integer(PostedAt) ->
    {ok, DbName} = ensure_segment(Society, year_of(PostedAt)),
    written(barrel_docdb:put_doc(DbName, Doc)).

written({ok, _}) -> ok;
written({error, conflict}) -> ok;
written({error, _} = Error) -> Error.

%% ---------------------------------------------------------------------
%% Reading
%% ---------------------------------------------------------------------

%% @doc Posts of one society with `posted_at' in `[From, Until)' (`Until'
%% exclusive, same convention as `agora_read_model:page/1''s `before'),
%% newest first, across however many yearly segments the range spans.
%% `next_before' pages backward through the range the same way
%% `get_posts_page' does: pass it back in as the next call's `until'.
-spec search(request()) ->
    {ok, #{posts := [map()], next_before := integer() | undefined}} |
    {error, invalid_range}.
search(#{society := Society, from := From, until := Until} = Request)
  when is_binary(Society), is_integer(From), is_integer(Until), From < Until ->
    Limit = clamp(maps:get(limit, Request, ?DEFAULT_LIMIT)),
    Years = lists:seq(year_of(Until - 1), year_of(From), -1),
    Docs = scan_years(Society, Years, From, Until, Limit),
    {ok, #{posts => Docs, next_before => next_before(length(Docs) =:= Limit, Docs)}};
search(_Request) ->
    {error, invalid_range}.

next_before(true, Docs) -> maps:get(<<"posted_at">>, lists:last(Docs));
next_before(false, _Docs) -> undefined.

clamp(N) when is_integer(N), N >= 1, N =< ?MAX_LIMIT -> N;
clamp(N) when is_integer(N), N > ?MAX_LIMIT -> ?MAX_LIMIT;
clamp(_NotAUsableLimit) -> ?DEFAULT_LIMIT.

scan_years(_Society, [], _From, _Until, _Limit) ->
    [];
scan_years(_Society, _Years, _From, _Until, Limit) when Limit =< 0 ->
    [];
scan_years(Society, [Year | Rest], From, Until, Limit) ->
    New = segment_docs(existing_segment(Society, Year), Society, From, Until, Limit),
    New ++ scan_years(Society, Rest, From, Until, Limit - length(New)).

segment_docs(not_found, _Society, _From, _Until, _Remaining) ->
    [];
segment_docs({ok, DbName}, Society, From, Until, Remaining) ->
    Spec = #{id_range => {range_start(Society, Until), range_end(Society, From)}, flat => true},
    collect(barrel_docdb:find(DbName, Spec, #{chunk_size => Remaining}), DbName, Spec, Remaining, 0, []).

collect({ok, Docs, Meta}, DbName, Spec, Limit, Scanned, Acc) ->
    Acc1 = Acc ++ Docs,
    Scanned1 = Scanned + length(Docs),
    more(maps:get(has_more, Meta, false) andalso length(Acc1) < Limit andalso Scanned1 < ?SCAN_CAP,
         Meta, DbName, Spec, Limit, Scanned1, Acc1).

more(true, #{continuation := Token}, DbName, Spec, Limit, Scanned, Acc) ->
    collect(barrel_docdb:find(DbName, Spec, #{continuation => Token}), DbName, Spec, Limit, Scanned, Acc);
more(_Done, _Meta, _DbName, _Spec, Limit, _Scanned, Acc) ->
    lists:sublist(Acc, Limit).

%% `Until' bounds `posted_at' from above (exclusive); a smaller inverted
%% time is a newer post, so this is the id-range's lower/start bound.
range_start(Society, Until) ->
    <<Society/binary, "/", (agora_read_model:inverted(Until - 1))/binary, "/">>.

%% `From' bounds `posted_at' from below (exclusive); this is the id-range's
%% upper/end bound. Exactly `agora_read_model''s own `range_start'/`range_end'
%% pair, renamed to this module's `from'/`until' vocabulary.
range_end(Society, From) ->
    <<Society/binary, "/", (agora_read_model:inverted(From))/binary, "/">>.

%% ---------------------------------------------------------------------
%% Pruning
%% ---------------------------------------------------------------------

%% @doc Delete every segment, of every configured society, whose year is
%% outside `retention_years/0'. Whole-database deletion, not a per-document
%% sweep -- see this module's own doc for why.
-spec prune_expired_segments() -> {ok, non_neg_integer()}.
prune_expired_segments() ->
    Cutoff = current_year() - retention_years(),
    Candidates = [{Society, Year} || Society <- agora_societies:configured(),
                                     Year <- lists:seq(current_year() - ?PRUNE_LOOKBACK_YEARS, Cutoff)],
    {ok, length([ok || {Society, Year} <- Candidates, ok =:= prune_segment(Society, Year)])}.

prune_segment(Society, Year) ->
    DbName = segment_db_name(Society, Year),
    SubDir = segment_dir(DbName),
    pruned(filelib:is_dir(SubDir), DbName, SubDir).

pruned(false, _DbName, _SubDir) ->
    skipped;
pruned(true, DbName, SubDir) ->
    ok = barrel_docdb:delete_db(DbName),
    _ = file:del_dir_r(SubDir),
    ok.

%% ---------------------------------------------------------------------
%% Segment naming and lifecycle
%% ---------------------------------------------------------------------

%% @doc The barrel_docdb database name for one society's segment of one
%% calendar year. Lowercased so a society name that happens to carry a
%% character `barrel_docdb:validate_db_name/1' rejects in a db name (but
%% allows in a topic) doesn't break segment creation -- today's only
%% configured society is already lowercase, so this changes nothing yet.
-spec segment_db_name(binary(), integer()) -> binary().
segment_db_name(Society, Year) when is_binary(Society), is_integer(Year) ->
    <<"hecate_agora_archive_", (string:lowercase(Society))/binary, "_",
      (integer_to_binary(Year))/binary>>.

%% @doc The calendar year (UTC) a `posted_at' unix-ms timestamp falls in.
-spec year_of(integer()) -> integer().
year_of(PostedAtMs) ->
    {{Year, _Month, _Day}, _Time} = calendar:system_time_to_universal_time(PostedAtMs, millisecond),
    Year.

current_year() -> year_of(erlang:system_time(millisecond)).

%% @doc Years of archive kept before a whole segment is pruned, from
%% `HECATE_AGORA_ARCHIVE_YEARS'. Unset or unparseable falls back to the
%% default rather than refusing to boot, same posture as
%% `agora_societies:parse/1'.
-spec retention_years() -> pos_integer().
retention_years() -> parse_retention_years(os:getenv("HECATE_AGORA_ARCHIVE_YEARS")).

%% @doc Pure, exported so parsing is unit-testable without an environment.
-spec parse_retention_years(false | string()) -> pos_integer().
parse_retention_years(false) -> ?RETENTION_YEARS_DEFAULT;
parse_retention_years(Str) when is_list(Str) -> valid_years(parsed_int(Str)).

parsed_int(Str) ->
    case string:to_integer(string:trim(Str)) of
        {N, ""} -> N;
        _NotAnInteger -> ?RETENTION_YEARS_DEFAULT
    end.

valid_years(N) when is_integer(N), N > 0 -> N;
valid_years(_NotPositive) -> ?RETENTION_YEARS_DEFAULT.

%% Creates the segment (and its on-disk directory) on first use. Idempotent:
%% `already_exists' on a later call is success, same shape as
%% `hecate_om_read_model:ensure/2,3'.
ensure_segment(Society, Year) ->
    DbName = segment_db_name(Society, Year),
    SubDir = segment_dir(DbName),
    ok = filelib:ensure_path(SubDir),
    opened(barrel_docdb:create_db(DbName, #{data_dir => SubDir}), DbName).

%% For reading and pruning: only opens a segment a directory on disk proves
%% was actually created. `not_found' for a year nothing was ever archived
%% under -- never creates one just because it was asked about.
existing_segment(Society, Year) ->
    DbName = segment_db_name(Society, Year),
    SubDir = segment_dir(DbName),
    known_segment(filelib:is_dir(SubDir), DbName, SubDir).

known_segment(false, _DbName, _SubDir) ->
    not_found;
known_segment(true, DbName, SubDir) ->
    opened(barrel_docdb:create_db(DbName, #{data_dir => SubDir}), DbName).

opened({ok, _Pid}, DbName) -> {ok, DbName};
opened({error, already_exists}, DbName) -> {ok, DbName};
opened({error, Reason}, DbName) -> {error, {archive_segment_open_failed, DbName, Reason}}.

segment_dir(DbName) ->
    filename:join([hecate_agora_service:data_dir(), "archive", binary_to_list(DbName)]).
