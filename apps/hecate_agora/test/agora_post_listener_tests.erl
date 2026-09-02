%% @doc The listener end to end, without a mesh: a fact shaped exactly as
%% hecate-spartan publishes it goes in through handle_event/4 and lands in
%% the record once.
-module(agora_post_listener_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOPIC, <<"spartan/agora">>).

fact(PostId, Body) ->
    #{<<"type">>        => {text, <<"agora_post">>},
      <<"post_id">>     => {text, PostId},
      <<"from">>        => {text, <<"did:key:metis">>},
      <<"body">>        => {text, Body},
      <<"in_reply_to">> => null,
      <<"posted_at">>   => 1756800000000,
      <<"home">>        => {text, <<"did:key:spartan-fr">>},
      <<"locale">>      => {text, <<"fr-paris">>}}.

meta() ->
    #{publisher => crypto:strong_rand_bytes(32), publisher_verified => not_signed,
      seq => 1, realm => <<0:256>>, delivered_via => relay}.

listener_test_() ->
    {foreach, fun agora_test_db:setup/0, fun agora_test_db:teardown/1, [
        fun a_heard_post_is_recorded/1,
        fun a_redelivered_post_is_recorded_once/1,
        fun a_malformed_fact_is_dropped_and_nothing_is_written/1
    ]}.

a_heard_post_is_recorded(_Db) ->
    {ok, State} = agora_post_listener:init(#{society => <<"spartan">>}),
    Id = agora_test_db:hex(),
    {noreply, State} = agora_post_listener:handle_event(?TOPIC, fact(Id, <<"Who is on the other side?">>), meta(), State),
    {ok, Doc} = agora_read_model:find(Id),
    [?_assertEqual(<<"Who is on the other side?">>, maps:get(<<"body">>, Doc)),
     ?_assertEqual(<<"spartan">>, maps:get(<<"society">>, Doc)),
     ?_assertEqual(<<"did:key:metis">>, maps:get(<<"from">>, Doc)),
     ?_assertEqual(<<"relay">>, maps:get(<<"heard_via">>, Doc)),
     ?_assertEqual(64, byte_size(maps:get(<<"publisher">>, Doc)))].

a_redelivered_post_is_recorded_once(_Db) ->
    {ok, State} = agora_post_listener:init(#{society => <<"spartan">>}),
    Id = agora_test_db:hex(),
    Fact = fact(Id, <<"Said once.">>),
    {noreply, State} = agora_post_listener:handle_event(?TOPIC, Fact, meta(), State),
    {noreply, State} = agora_post_listener:handle_event(?TOPIC, Fact, meta(), State),
    {ok, Docs} = agora_read_model:page(#{limit => 10}),
    ?_assertEqual(1, length(Docs)).

a_malformed_fact_is_dropped_and_nothing_is_written(_Db) ->
    {ok, State} = agora_post_listener:init(#{society => <<"spartan">>}),
    {noreply, State} = agora_post_listener:handle_event(?TOPIC, #{<<"type">> => {text, <<"spartan_broadcast">>}}, meta(), State),
    {noreply, State} = agora_post_listener:handle_event(?TOPIC, <<"not even a map">>, meta(), State),
    {ok, Docs} = agora_read_model:page(#{limit => 10}),
    ?_assertEqual([], Docs).
