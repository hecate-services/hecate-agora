%% @doc A real, throwaway barrel_docdb record for the suites that write to
%% one -- no mesh, no hecate_om:boot/1.
%%
%% `hecate_om_read_model:ensure/2' is documented "services don't call this
%% module directly" (that is boot/1's job in production), but it is the exact
%% idempotent mechanism boot/1 uses and there is no lighter seam. The
%% persistent_term key is the one `hecate_om:read_model/0' reads, set the way
%% boot/1 sets it, so `agora_read_model' finds the record without knowing it
%% is under test. Same shape hecate-stations' and hecate-citizens' suites use.
-module(agora_test_db).

-export([setup/0, teardown/1, post/1, stimulus/1, hex/0, now_ms/0]).

setup() ->
    {ok, _} = application:ensure_all_started(barrel_docdb),
    %% Wall-clock time in the name: `unique_integer/1' repeats across the
    %% fresh VM `rebar3 eunit' starts per invocation, and an integer-only
    %% name can reopen a crashed past run's leftover directory.
    DbName = <<"hecate_agora_test_",
               (integer_to_binary(erlang:system_time(microsecond)))/binary, "_",
               (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Dir = filename:join(filename:basedir(user_cache, "hecate-agora-test"),
                        binary_to_list(DbName)),
    ok = filelib:ensure_path(Dir),
    ok = hecate_om_read_model:ensure(DbName, Dir),
    persistent_term:put(hecate_om_read_model_db, DbName),
    {DbName, Dir}.

teardown({DbName, Dir}) ->
    persistent_term:erase(hecate_om_read_model_db),
    ok = barrel_docdb:delete_db(DbName),
    _ = file:del_dir_r(Dir),
    ok.

%% A well-formed post as `agora_post_fact:decode/4' would produce it, with
%% overrides. `posted_at' defaults to now, so a suite that cares about order
%% sets it explicitly.
post(Overrides) ->
    Now = now_ms(),
    maps:merge(#{post_id            => hex(),
                 society            => <<"spartan">>,
                 topic              => <<"spartan/agora">>,
                 from               => <<"did:key:athena">>,
                 body               => <<"The board is set. What is any of this for?">>,
                 in_reply_to        => undefined,
                 posted_at          => Now,
                 home               => undefined,
                 locale             => <<"be-brussels">>,
                 publisher          => undefined,
                 publisher_verified => <<"not_signed">>,
                 heard_at           => Now,
                 heard_via          => <<"direct">>},
               Overrides).

%% A stored stimulus as `agora_post_fact:decode/4' shapes one: binary keys,
%% absent fields already dropped. `item_id' is the thread id, so a suite that
%% cares which story a post belongs to sets that.
stimulus(Overrides) ->
    maps:merge(#{<<"item_id">>      => <<"9f2c1a4e7b8d0356">>,
                 <<"title">>        => <<"500-Kilo-Bombe in Oranienburg"/utf8>>,
                 <<"url">>          => <<"https://www.zeit.de/2026-09/oranienburg">>,
                 <<"image_url">>    => <<"https://img.zeit.de/wide__1300x731">>,
                 <<"source">>       => <<"zeit">>,
                 <<"source_type">>  => <<"private">>,
                 <<"topic_class">>  => <<"society">>,
                 <<"topics">>       => [<<"sicherheit">>],
                 <<"emoji">>        => <<"🏛"/utf8>>,
                 <<"lang">>         => <<"de">>,
                 <<"country">>      => <<"Germany">>,
                 <<"published_at">> => 1788344000000},
               Overrides).

hex() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

now_ms() ->
    erlang:system_time(millisecond).
