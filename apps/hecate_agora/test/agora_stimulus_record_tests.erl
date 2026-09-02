%% @doc The stimulus, from the wire to the record to the reply.
%%
%% This is the part of a post the SPEAKER did not write: hecate-spartan
%% attaches the news item it handed the mind, verbatim, without the model
%% ever touching it. Three things must hold, and each has a way of going
%% quietly wrong:
%%
%%   1. it survives the wire, at depth, in both key shapes
%%   2. it comes back out `{text, _}'-tagged, at depth, or a non-BEAM reader
%%      gets hex where a headline should be
%%   3. `item_id' groups posts into a story, which is the whole point
-module(agora_stimulus_record_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOPIC, <<"spartan/agora">>).
-define(SOCIETY, <<"spartan">>).

%% --- decoding ---

%% The in-process shape, as maybe_publish_to_agora:fact/1 builds it: atom
%% keys, bare binaries, a nested map.
in_process_stimulus() ->
    #{item_id      => <<"9f2c1a4e7b8d0356">>,
      title        => <<"500-Kilo-Bombe in Oranienburg"/utf8>>,
      url          => <<"https://www.zeit.de/2026-09/oranienburg">>,
      image_url    => <<"https://img.zeit.de/wide__1300x731">>,
      source       => <<"zeit">>,
      source_type  => <<"private">>,
      topic_class  => <<"society">>,
      topics       => [<<"sicherheit">>, <<"brandenburg">>],
      emoji        => <<"🏛"/utf8>>,
      lang         => <<"de">>,
      reporting_country      => <<"de">>,
      reporting_country_name => <<"Germany">>,
      subject_country        => <<"de">>,
      subject_country_name   => <<"Germany">>,
      published_at => 1788344000000}.

post_with(Stimulus) ->
    #{type => agora_post, post_id => <<"p1">>, from => <<"did:key:athena">>,
      body => <<"The evacuation radius is the story, not the bomb.">>,
      in_reply_to => undefined, posted_at => 1756800000000,
      home => <<"did:key:spartan-de">>, locale => <<"de-falkenstein">>,
      stimulus => Stimulus}.

meta() ->
    #{publisher => crypto:strong_rand_bytes(32), publisher_verified => true,
      seq => 7, realm => <<0:256>>, delivered_via => direct}.

decoded(Payload) ->
    {ok, Post} = agora_post_fact:decode(?TOPIC, Payload, meta(), ?SOCIETY),
    maps:get(stimulus, Post).

decodes_the_in_process_shape_test() ->
    S = decoded(post_with(in_process_stimulus())),
    ?assertEqual(<<"9f2c1a4e7b8d0356">>, maps:get(<<"item_id">>, S)),
    ?assertEqual(<<"zeit">>, maps:get(<<"source">>, S)),
    ?assertEqual(<<"private">>, maps:get(<<"source_type">>, S)),
    ?assertEqual([<<"sicherheit">>, <<"brandenburg">>], maps:get(<<"topics">>, S)),
    ?assertEqual(1788344000000, maps:get(<<"published_at">>, S)).

%% The same fact after a real CBOR round trip: binary keys, `{text, _}'
%% values, absent fields as `null' -- at depth, inside the nested map.
decodes_the_wire_shape_test() ->
    Wire = #{<<"type">>      => {text, <<"agora_post">>},
             <<"post_id">>   => {text, <<"p1">>},
             <<"from">>      => {text, <<"did:key:athena">>},
             <<"body">>      => {text, <<"words">>},
             <<"posted_at">> => 1756800000000,
             <<"stimulus">>  => #{<<"item_id">>   => {text, <<"abc">>},
                                  <<"source">>    => {text, <<"ansa">>},
                                  <<"title">>     => {text, <<"Un titolo"/utf8>>},
                                  <<"topics">>    => [{text, <<"energia">>}],
                                  <<"image_url">> => null,
                                  <<"subject_country">> => null}},
    S = decoded(Wire),
    ?assertEqual(<<"abc">>, maps:get(<<"item_id">>, S)),
    ?assertEqual(<<"ansa">>, maps:get(<<"source">>, S)),
    ?assertEqual([<<"energia">>], maps:get(<<"topics">>, S)),
    %% Absent stays absent. A reader must be able to tell "no picture" from
    %% "a picture we mangled", and 21 of the 47 live sources publish none.
    ?assertNot(maps:is_key(<<"image_url">>, S)),
    ?assertNot(maps:is_key(<<"subject_country">>, S)).

%% A committee, a visitor's question, a self-alert. Not an error.
unprompted_speech_decodes_without_one_test() ->
    Post = maps:remove(stimulus, post_with(undefined)),
    {ok, Decoded} = agora_post_fact:decode(?TOPIC, Post, meta(), ?SOCIETY),
    ?assertEqual(undefined, maps:get(stimulus, Decoded)).

%% item_id is the thread id. A stimulus that cannot be grouped is not worth
%% storing, so it is dropped rather than half-kept.
stimulus_without_an_item_id_is_refused_test() ->
    S = maps:remove(item_id, in_process_stimulus()),
    ?assertEqual(undefined, decoded(post_with(S))).

junk_in_the_stimulus_slot_is_no_stimulus_test() ->
    ?assertEqual(undefined, decoded(post_with(<<"not a map">>))),
    ?assertEqual(undefined, decoded(post_with(null))).

%% --- the record, and the reply ---

record_test_() ->
    {foreach, fun agora_test_db:setup/0, fun agora_test_db:teardown/1, [
        fun the_record_keeps_it/1,
        fun the_reply_tags_every_text_at_depth/1,
        fun an_unprompted_post_replies_without_the_key/1,
        fun a_story_is_every_post_that_reacted_to_the_same_item/1,
        fun a_story_filter_excludes_unprompted_speech/1,
        fun the_responder_reads_a_story_off_the_wire/1,
        fun the_published_fact_carries_it_tagged/1,
        fun the_published_fact_omits_it_for_unprompted_speech/1,
        fun a_country_finds_what_it_reported_and_what_it_is_about/1,
        fun the_responder_reads_a_country_off_the_wire/1
    ]}.

seed(Overrides) ->
    Post = agora_test_db:post(Overrides),
    ok = agora_read_model:record(Post),
    Post.

the_record_keeps_it(_Db) ->
    seed(#{post_id => <<"p1">>, stimulus => agora_test_db:stimulus(#{})}),
    {ok, Doc} = agora_read_model:find(<<"p1">>),
    S = maps:get(<<"stimulus">>, Doc),
    [?_assertEqual(<<"9f2c1a4e7b8d0356">>, maps:get(<<"item_id">>, S)),
     ?_assertEqual(<<"zeit">>, maps:get(<<"source">>, S))].

%% macula encodes a bare binary as a CBOR BYTE string and `{text, Bin}' as a
%% TEXT string. A headline that goes out bare reaches macula-cli, macula-mcp
%% and every non-BEAM SDK as hex -- which is exactly what the first live read
%% of this record did. Depth does not exempt it.
the_reply_tags_every_text_at_depth(_Db) ->
    seed(#{post_id => <<"p1">>, stimulus => agora_test_db:stimulus(#{})}),
    {ok, Doc} = agora_read_model:find(<<"p1">>),
    S = maps:get(stimulus, agora_read_model:to_wire(Doc)),
    [?_assertEqual({text, <<"9f2c1a4e7b8d0356">>}, maps:get(item_id, S)),
     ?_assertEqual({text, <<"zeit">>}, maps:get(source, S)),
     ?_assertEqual({text, <<"https://img.zeit.de/wide__1300x731">>},
                   maps:get(image_url, S)),
     ?_assertEqual([{text, <<"sicherheit">>}], maps:get(topics, S)),
     %% Both countries, both halves, all tagged. A bare binary two levels down
     %% reaches a non-BEAM reader as hex exactly like a top-level one does.
     ?_assertEqual({text, <<"de">>}, maps:get(reporting_country, S)),
     ?_assertEqual({text, <<"Germany">>}, maps:get(subject_country_name, S)),
     %% Integers stay integers. A tagged one is not a number any more.
     ?_assertEqual(1788344000000, maps:get(published_at, S))].

an_unprompted_post_replies_without_the_key(_Db) ->
    seed(#{post_id => <<"p1">>}),
    {ok, Doc} = agora_read_model:find(<<"p1">>),
    ?_assertNot(maps:is_key(stimulus, agora_read_model:to_wire(Doc))).

%% The point of the whole exercise: minds reply to the world far more often
%% than to each other, so a thread built from `in_reply_to' alone shows
%% almost nothing. Sharing a stimulus IS the conversation.
a_story_is_every_post_that_reacted_to_the_same_item(_Db) ->
    Bomb = agora_test_db:stimulus(#{<<"item_id">> => <<"bomb">>}),
    Penguins = agora_test_db:stimulus(#{<<"item_id">> => <<"penguins">>}),
    seed(#{posted_at => 1000, from => <<"did:key:saga">>, stimulus => Bomb}),
    seed(#{posted_at => 2000, from => <<"did:key:metis">>, stimulus => Penguins}),
    seed(#{posted_at => 3000, from => <<"did:key:mercury">>, stimulus => Bomb}),
    #{posts := Posts} = get_posts_page:get(#{limit => 10, story => <<"bomb">>}),
    [?_assertEqual([3000, 1000], [maps:get(posted_at, P) || P <- Posts])].

a_story_filter_excludes_unprompted_speech(_Db) ->
    seed(#{posted_at => 1000, stimulus => agora_test_db:stimulus(#{})}),
    seed(#{posted_at => 2000}),
    #{posts := Posts} = get_posts_page:get(#{limit => 10,
                                             story => <<"9f2c1a4e7b8d0356">>}),
    [?_assertEqual([1000], [maps:get(posted_at, P) || P <- Posts])].

%% A subscriber to `agora/post_recorded' must see what a reader of the record
%% sees, without a second call per post -- and must see it as text, not hex.
the_published_fact_carries_it_tagged(_Db) ->
    Post = seed(#{post_id => <<"p1">>, stimulus => agora_test_db:stimulus(#{})}),
    S = maps:get(stimulus, agora_post_recorded_v1:fact(Post)),
    [?_assertEqual({text, <<"9f2c1a4e7b8d0356">>}, maps:get(item_id, S)),
     ?_assertEqual({text, <<"zeit">>}, maps:get(source, S)),
     ?_assertEqual(1788344000000, maps:get(published_at, S))].

the_published_fact_omits_it_for_unprompted_speech(_Db) ->
    Post = seed(#{post_id => <<"p1">>}),
    ?_assertNot(maps:is_key(stimulus, agora_post_recorded_v1:fact(Post))).

%% One filter, either axis. An Irish broadcaster on Poland answers to `pl'
%% because the story is about Poland, and to `ie' because Ireland told it.
%% Making a reader choose an axis first is asking them to learn the schema.
a_country_finds_what_it_reported_and_what_it_is_about(_Db) ->
    Irish = agora_test_db:stimulus(#{<<"item_id">> => <<"i1">>,
                                     <<"reporting_country">> => <<"ie">>,
                                     <<"subject_country">> => <<"pl">>}),
    Polish = agora_test_db:stimulus(#{<<"item_id">> => <<"p1">>,
                                      <<"reporting_country">> => <<"pl">>,
                                      <<"subject_country">> => <<"ua">>}),
    seed(#{posted_at => 1000, stimulus => Irish}),
    seed(#{posted_at => 2000, stimulus => Polish}),
    seed(#{posted_at => 3000}),
    #{posts := ByPl} = get_posts_page:get(#{limit => 10, country => <<"pl">>}),
    #{posts := ByIe} = get_posts_page:get(#{limit => 10, country => <<"ie">>}),
    #{posts := ByZz} = get_posts_page:get(#{limit => 10, country => <<"zz">>}),
    [?_assertEqual([2000, 1000], [maps:get(posted_at, P) || P <- ByPl]),
     ?_assertEqual([1000], [maps:get(posted_at, P) || P <- ByIe]),
     %% Unprompted speech names no country and is never a country's result.
     ?_assertEqual([], ByZz)].

the_responder_reads_a_country_off_the_wire(_Db) ->
    seed(#{posted_at => 1000,
           stimulus => agora_test_db:stimulus(#{<<"subject_country">> => <<"ua">>})}),
    seed(#{posted_at => 2000}),
    {ok, S} = get_posts_page_responder:init([]),
    {reply, Reply, S} = get_posts_page_responder:handle_request(
                          #{<<"country">> => {text, <<"ua">>}, <<"limit">> => 10}, S),
    [?_assertEqual([1000], [maps:get(posted_at, P) || P <- maps:get(posts, Reply)])].

the_responder_reads_a_story_off_the_wire(_Db) ->
    seed(#{posted_at => 1000,
           stimulus => agora_test_db:stimulus(#{<<"item_id">> => <<"bomb">>})}),
    seed(#{posted_at => 2000,
           stimulus => agora_test_db:stimulus(#{<<"item_id">> => <<"penguins">>})}),
    {ok, S} = get_posts_page_responder:init([]),
    {reply, Reply, S} = get_posts_page_responder:handle_request(
                          #{<<"story">> => {text, <<"penguins">>},
                            <<"limit">> => 10}, S),
    [?_assertEqual(1, maps:get(ok, Reply)),
     ?_assertEqual([2000], [maps:get(posted_at, P) || P <- maps:get(posts, Reply)])].
