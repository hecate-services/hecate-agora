%% @doc Every shape the agora_post fact can take off the wire, decoded
%% without a mesh.
-module(agora_post_fact_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOPIC, <<"spartan/agora">>).
-define(SOCIETY, <<"spartan">>).

%% The map exactly as hecate-spartan's maybe_publish_to_agora:fact/1 builds
%% it -- atom keys, atom type, `undefined' for an absent reply target.
in_process_shape() ->
    #{type        => agora_post,
      post_id     => <<"0123456789abcdef0123456789abcdef">>,
      from        => <<"did:key:athena">>,
      body        => <<"The board is set.">>,
      in_reply_to => undefined,
      posted_at   => 1756800000000,
      home        => <<"did:key:spartan-be">>,
      locale      => <<"be-brussels">>}.

%% The same fact after a real CBOR round trip: binary keys, text values
%% `{text, Bin}'-tagged, absent fields as `null'.
wire_shape() ->
    #{<<"type">>        => {text, <<"agora_post">>},
      <<"post_id">>     => {text, <<"0123456789abcdef0123456789abcdef">>},
      <<"from">>        => {text, <<"did:key:athena">>},
      <<"body">>        => {text, <<"The board is set.">>},
      <<"in_reply_to">> => null,
      <<"posted_at">>   => 1756800000000,
      <<"home">>        => null,
      <<"locale">>      => {text, <<"be-brussels">>}}.

publisher() -> crypto:strong_rand_bytes(32).

decodes_the_in_process_shape_test() ->
    Pub = publisher(),
    Meta = #{publisher => Pub, publisher_verified => true, seq => 7,
             realm => <<0:256>>, delivered_via => relay},
    {ok, Post} = agora_post_fact:decode(?TOPIC, in_process_shape(), Meta, ?SOCIETY),
    ?assertEqual(<<"0123456789abcdef0123456789abcdef">>, maps:get(post_id, Post)),
    ?assertEqual(?SOCIETY, maps:get(society, Post)),
    ?assertEqual(?TOPIC, maps:get(topic, Post)),
    ?assertEqual(<<"did:key:athena">>, maps:get(from, Post)),
    ?assertEqual(<<"The board is set.">>, maps:get(body, Post)),
    ?assertEqual(undefined, maps:get(in_reply_to, Post)),
    ?assertEqual(1756800000000, maps:get(posted_at, Post)),
    ?assertEqual(<<"did:key:spartan-be">>, maps:get(home, Post)),
    ?assertEqual(<<"be-brussels">>, maps:get(locale, Post)),
    ?assertEqual(binary:encode_hex(Pub, lowercase), maps:get(publisher, Post)),
    ?assertEqual(<<"true">>, maps:get(publisher_verified, Post)),
    ?assertEqual(<<"relay">>, maps:get(heard_via, Post)),
    ?assert(is_integer(maps:get(heard_at, Post))).

decodes_the_wire_shape_test() ->
    {ok, Post} = agora_post_fact:decode(?TOPIC, wire_shape(), #{}, ?SOCIETY),
    ?assertEqual(<<"0123456789abcdef0123456789abcdef">>, maps:get(post_id, Post)),
    ?assertEqual(<<"did:key:athena">>, maps:get(from, Post)),
    ?assertEqual(<<"The board is set.">>, maps:get(body, Post)),
    ?assertEqual(undefined, maps:get(in_reply_to, Post)),
    ?assertEqual(undefined, maps:get(home, Post)),
    ?assertEqual(<<"be-brussels">>, maps:get(locale, Post)).

a_reply_keeps_its_target_test() ->
    Fact = (in_process_shape())#{in_reply_to => <<"fedcba98765432100123456789abcdef">>},
    {ok, Post} = agora_post_fact:decode(?TOPIC, Fact, #{}, ?SOCIETY),
    ?assertEqual(<<"fedcba98765432100123456789abcdef">>, maps:get(in_reply_to, Post)).

%% No Meta at all (an older macula, or a test) means no publisher, and the
%% signature outcome is `not_signed' rather than a guess.
missing_meta_means_unattributed_and_unsigned_test() ->
    {ok, Post} = agora_post_fact:decode(?TOPIC, in_process_shape(), #{}, ?SOCIETY),
    ?assertEqual(undefined, maps:get(publisher, Post)),
    ?assertEqual(<<"not_signed">>, maps:get(publisher_verified, Post)),
    ?assertEqual(<<"unknown">>, maps:get(heard_via, Post)).

an_invalid_signature_is_recorded_as_false_not_folded_into_unsigned_test() ->
    Meta = #{publisher => publisher(), publisher_verified => false},
    {ok, Post} = agora_post_fact:decode(?TOPIC, in_process_shape(), Meta, ?SOCIETY),
    ?assertEqual(<<"false">>, maps:get(publisher_verified, Post)).

a_publisher_already_in_hex_passes_through_test() ->
    Hex = binary:encode_hex(publisher(), lowercase),
    {ok, Post} = agora_post_fact:decode(?TOPIC, in_process_shape(), #{publisher => Hex}, ?SOCIETY),
    ?assertEqual(Hex, maps:get(publisher, Post)).

another_fact_type_on_the_topic_is_refused_test() ->
    Fact = (in_process_shape())#{type => spartan_broadcast},
    ?assertMatch({error, {not_an_agora_post, <<"spartan_broadcast">>}},
                 agora_post_fact:decode(?TOPIC, Fact, #{}, ?SOCIETY)).

a_post_without_a_body_is_not_speech_test() ->
    ?assertMatch({error, {malformed_agora_post, _}},
                 agora_post_fact:decode(?TOPIC, maps:remove(body, in_process_shape()), #{}, ?SOCIETY)),
    ?assertMatch({error, {malformed_agora_post, _}},
                 agora_post_fact:decode(?TOPIC, (in_process_shape())#{body => <<>>}, #{}, ?SOCIETY)).

a_post_without_an_id_cannot_be_deduplicated_so_it_is_refused_test() ->
    ?assertMatch({error, {malformed_agora_post, _}},
                 agora_post_fact:decode(?TOPIC, maps:remove(post_id, in_process_shape()), #{}, ?SOCIETY)).

a_post_without_a_timestamp_cannot_be_placed_so_it_is_refused_test() ->
    ?assertMatch({error, {malformed_agora_post, _}},
                 agora_post_fact:decode(?TOPIC, (in_process_shape())#{posted_at => <<"soon">>}, #{}, ?SOCIETY)).

a_payload_that_is_not_a_map_is_refused_test() ->
    ?assertMatch({error, {not_a_map, _}},
                 agora_post_fact:decode(?TOPIC, <<"hello">>, #{}, ?SOCIETY)).
