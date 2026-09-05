%% @doc A real, throwaway `HECATE_DATA_DIR' for suites that write archive
%% segments -- `agora_archive' resolves its base directory via
%% `hecate_agora_service:data_dir/0' on every call (no persistent_term,
%% unlike the hot record), so pointing that env var at a fresh temp
%% directory is the whole setup.
-module(agora_archive_test_db).

-export([setup/0, teardown/1]).

setup() ->
    {ok, _} = application:ensure_all_started(barrel_docdb),
    Dir = filename:join(filename:basedir(user_cache, "hecate-agora-archive-test"),
                        integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    Prior = os:getenv("HECATE_DATA_DIR"),
    true = os:putenv("HECATE_DATA_DIR", Dir),
    {Dir, Prior}.

%% Segment db names are deterministic (society + year), so a later test
%% reusing the same year would otherwise find this run's name still live
%% in barrel_docdb's in-memory registry pointing at a directory this
%% teardown is about to delete out from under it -- close every segment
%% this run touched before the directory goes.
teardown({Dir, Prior}) ->
    [ok = barrel_docdb:delete_db(DbName) || DbName <- barrel_docdb:list_dbs(),
                                            is_segment_db(DbName)],
    restore(Prior),
    _ = file:del_dir_r(Dir),
    ok.

is_segment_db(<<"hecate_agora_archive_", _/binary>>) -> true;
is_segment_db(_Other) -> false.

restore(false) -> true = os:unsetenv("HECATE_DATA_DIR");
restore(Prior) -> true = os:putenv("HECATE_DATA_DIR", Prior).
