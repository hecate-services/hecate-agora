%% @doc The service contract, asserted locally.
%%
%% hecate_om resolves its six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% primary defence is the `-behaviour(hecate_om_service)' attribute on the
%% service module, which turns a missing callback into a compile error under
%% warnings_as_errors.
%%
%% What this suite adds is everything the compiler cannot see: that the attribute
%% has not been quietly dropped, that the values inside those callbacks are the
%% shapes hecate_om will destructure, and that the names and version this service
%% reports are the ones it actually has. Nothing local boots hecate_om, so
%% asserting the shape by hand is the closest available thing to a rehearsal.
-module(hecate_agora_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, hecate_agora).
-define(SERVICE, hecate_agora_service).

%% Belt and braces with the behaviour attribute, and it survives the attribute
%% being removed. If hecate_om ever adds a SEVENTH required callback this test
%% keeps passing and the deploy still breaks, which is the honest limit of a
%% local assertion about a remote contract.
exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    Missing = [F || {N, A} = F <- Required,
                    not erlang:function_exported(?SERVICE, N, A)],
    ?assertEqual([], Missing).

info_carries_the_three_keys_test() ->
    #{name := Name, version := Vsn, description := Desc} = ?SERVICE:info(),
    ?assert(is_binary(Name)),
    ?assert(is_binary(Vsn)),
    ?assert(is_binary(Desc)),
    ?assertEqual(<<"hecate-agora">>, Name).

%% THE TWO NAMES MUST AGREE. The OTP application is snake_case because it is an
%% Erlang atom; the repository, the container image and the name this service
%% answers to on the mesh are kebab-case. They describe one service, so a
%% scaffold generated with a mismatched pair is caught here on the first eunit
%% run rather than by a puzzled reader months later.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

%% The version in info/0 is what a peer reads off /health, so it disagreeing with
%% the application it describes is a lie that nothing else would catch.
info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

%% Health is the record's health. Without an open record every post that
%% arrives is lost, so that is `down', not a shrug; with one it is green. Both
%% halves are asserted so a future "always ok" regression fails here.
health_is_down_without_the_record_and_green_with_it_test() ->
    persistent_term:erase(hecate_om_read_model_db),
    ?assertEqual({down, no_read_model}, ?SERVICE:health()),
    Db = agora_test_db:setup(),
    ?assertEqual(ok, ?SERVICE:health()),
    ok = agora_test_db:teardown(Db).

%% This service exists to answer exactly three reads over the record. This pins
%% the shape hecate_om_capabilities destructures (name, version, handler) so a
%% typo in any of them fails loudly here instead of as a mesh peer's confusing
%% "no such procedure".
announces_the_three_reads_over_the_record_test() ->
    Caps = ?SERVICE:capabilities(),
    ?assertEqual([<<"hecate_agora.get_posts_page">>,
                  <<"hecate_agora.get_thread_by_post_id">>,
                  <<"hecate_agora.search_posts">>],
                 [maps:get(name, C) || C <- Caps]),
    ?assertEqual([get_posts_page_responder, get_thread_by_post_id_responder, search_posts_responder],
                 [Mod || #{handler := {Mod, []}} <- Caps]),
    ?assertEqual([1, 1, 1], [maps:get(version, C) || C <- Caps]),
    %% Every handler is a real macula_response module that loads.
    ?assertEqual([], [Mod || #{handler := {Mod, _}} <- Caps,
                             code:ensure_loaded(Mod) =/= {module, Mod}]).

%% One supervised listener per configured society, each on that society's
%% own agora topic, each a real macula_subscriber module.
subscribes_to_each_society_agora_test() ->
    os:unsetenv("HECATE_AGORA_SOCIETIES"),
    ?assertEqual([{<<"spartan/agora">>, agora_post_listener, #{society => <<"spartan">>}}],
                 ?SERVICE:subscriptions()),
    os:putenv("HECATE_AGORA_SOCIETIES", "spartan,news"),
    ?assertEqual([<<"spartan/agora">>, <<"news/agora">>],
                 [Topic || {Topic, _Mod, _Args} <- ?SERVICE:subscriptions()]),
    os:unsetenv("HECATE_AGORA_SOCIETIES"),
    ?assertEqual({module, agora_post_listener}, code:ensure_loaded(agora_post_listener)).

%% read_model_id/0 without data_dir/0 leaves barrel_docdb idle and the record
%% never opens; hecate_om only wires the read model when BOTH are exported.
exports_the_read_model_pair_test() ->
    _ = code:ensure_loaded(?SERVICE),
    ?assert(erlang:function_exported(?SERVICE, read_model_id, 0)),
    ?assert(erlang:function_exported(?SERVICE, data_dir, 0)),
    ?assertNot(erlang:function_exported(?SERVICE, store_id, 0)),
    ?assertEqual(<<"hecate_agora">>, ?SERVICE:read_model_id()),
    ?assert(is_list(?SERVICE:data_dir())).

identity_spec_has_the_shape_hecate_om_expects_test() ->
    #{scope := Scope, actions := Actions,
      resources := Resources, ttl_days := Ttl} = ?SERVICE:identity_spec(),
    ?assert(is_binary(Scope)),
    ?assert(is_list(Actions)),
    ?assert(is_list(Resources)),
    ?assert(is_integer(Ttl) andalso Ttl > 0).

%% The authority asked for is exactly what is announced, listened to and
%% published: the three reads and the two facts as actions, the agora topics
%% and the two keeper topics as resources. No keeper topic is a society's
%% `<ns>/agora', so this service still cannot put words in the square it keeps.
authority_matches_what_is_announced_heard_and_published_test() ->
    os:unsetenv("HECATE_AGORA_SOCIETIES"),
    #{actions := Actions, resources := Resources} = ?SERVICE:identity_spec(),
    Announced = [binary:part(N, byte_size(<<"hecate_agora.">>), byte_size(N) - byte_size(<<"hecate_agora.">>))
                 || #{name := N} <- ?SERVICE:capabilities()],
    Published = [agora_post_recorded_v1:topic(), agora_post_conflict_detected_v1:topic()],
    ?assertEqual(Announced ++ [<<"post_recorded">>, <<"post_conflict_detected">>], Actions),
    ?assertEqual([Topic || {Topic, _, _} <- ?SERVICE:subscriptions()] ++ Published, Resources),
    ?assertEqual([], [T || T <- Published, agora_societies:society_of_topic(T) =/= undefined]).

%% The supervisor starts and stops cleanly on its own, without hecate_om. It has
%% no children of its own, and that is the honest shape: the listeners are
%% supervised by hecate_om_pubsub_sup and the responders by
%% hecate_om_capabilities, both wired from this service's callbacks by
%% hecate_om:boot/1.
supervisor_starts_and_stops_test() ->
    {ok, Pid} = hecate_agora_sup:start_link(),
    ?assert(is_process_alive(Pid)),
    ?assertEqual([], supervisor:which_children(Pid)),
    unlink(Pid),
    exit(Pid, shutdown).

%%==============================================================================
%% The runtime is pinned in two places, and neither is the one you are running
%%==============================================================================

%% ⚠ THIS GUARD EXISTS BECAUSE A SIBLING SERVICE DID NOT HAVE IT, AND IT COST
%% THREE COMMITS AND AN IMAGE THAT SHIPPED ANYWAY.
%%
%% Its `Containerfile' said 27 while development ran on 28. So `rebar3 eunit'
%% passing locally meant "passing on 28" and nothing more, CI failed on a crash
%% that does not occur on 28 at all, and because the image build is a separate
%% workflow the image went to the fleet regardless.
%%
%% The release is pinned in TWO files, and the version actually running is a
%% third thing that agrees with neither by default. **A comment in each file
%% saying they must match is not a mechanism**, and both files carried one.
%%
%% ⚠⚠ IT FAILS RATHER THAN WARNS WHEN YOUR VM DIFFERS, AND THAT IS DELIBERATE.
%% Developing on a release you do not ship makes a green suite mean less than it
%% appears to. If you want to work on another release, move both pins and find
%% out what breaks, which is the whole point of having them.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    Image = pinned("Containerfile", "FROM docker.io/erlang:([0-9]+)"),
    Ci = pinned(".github/workflows/lint.yml", "image: erlang:([0-9]+)"),
    Running = list_to_binary(erlang:system_info(otp_release)),
    %% Sorted and deduplicated, so a failure prints all three rather than the
    %% first pair that happened to be compared.
    ?assertEqual([Image], lists:usort([Image, Ci, Running])).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern,
                                [{capture, all_but_first, binary}]),
    Version.

%% Relative to the beam rather than the working directory, because eunit runs
%% from wherever the developer happens to be standing.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) ->
    climb(filename:dirname(Dir), Name, Left - 1).
