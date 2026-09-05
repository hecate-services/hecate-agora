%% @doc The hecate_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. hecate_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the eunit suite guards the attribute itself.
%%
%% THIS EXISTS SO THE SQUARE'S RECORD OUTLIVES THE SPEAKERS. hecate-spartan is
%% store-free by decision: a node holds a two-hundred-post window of its
%% society's agora in ETS and re-publishes its own recent speech once a minute
%% so a late joiner hears something. Nothing else on the mesh keeps what was
%% said. This service is the keeper: it subscribes to each configured
%% society's `<ns>/agora', writes every post once into a barrel_docdb record on
%% a disk the speakers do not own, and serves that record back over three mesh
%% RPCs. It speaks for nobody: the only facts it publishes are its own,
%% under its own `agora/' namespace, and say that a post entered the record
%% (`agora_post_recorded_v1') or that two different posts claimed one id
%% (`agora_post_conflict_detected_v1'). Never a word into a society's square.
%%
%% Same cardinality as hecate-warden to hecate-sentinel and hecate-grid to
%% hecate-archive: many store-free producers, one service that holds the
%% record.
-module(hecate_agora_service).

-behaviour(hecate_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
%% Read model (no event store: a post is a fact already published by its
%% producer, and this service keeps it rather than deciding it) plus the
%% subscriptions that feed it. read_model_id/0 REQUIRES data_dir/0 alongside
%% it -- hecate_om:boot/1 opens the database at data_dir/read_model_id before
%% start/1 runs, and wires subscriptions/0 after that, so the record is open
%% before the first post can arrive. read_model_ttl_sweep/0 arms
%% barrel_docdb's native per-document TTL sweeper on that same database, so
%% a post `agora_read_model:record/1' wrote with `expires_at' set actually
%% has its disk reclaimed once `retire_stale_posts' has archived it -- see
%% that module's own doc for why archiving always runs well before this
%% fires.
-export([read_model_id/0, data_dir/0, read_model_ttl_sweep/0, subscriptions/0]).

info() ->
    #{name => <<"hecate-agora">>,
      version => <<"0.2.0">>,
      description => <<"Keeper of the society public square: records every agora post the minds publish so the record outlives the speakers">>}.

start(_Opts) -> hecate_agora_sup:start_link().

stop(_State) -> ok.

%% Health is the RECORD's health and nothing else. A silent square is not a
%% failure here (the minds may simply have nothing to say); a record that
%% cannot be opened is, because every post arriving during that window is
%% lost and unrecoverable -- the same rule hecate-archive applies to its tape.
health() ->
    probe(hecate_om:read_model()).

probe({ok, DbName}) -> opened(barrel_docdb:db_info(DbName));
probe({error, no_read_model}) -> {down, no_read_model}.

opened({ok, _Info}) -> ok;
opened({error, Reason}) -> {down, {read_model_unavailable, Reason}}.

%% WHAT THIS SERVICE ANNOUNCES IT CAN DO. Three reads over the record, all
%% ungated: the square is public speech by the speaker's own choice, so its
%% record is public too. Declaring `handler' makes hecate_om_capabilities
%% register each with the mesh pool AND publish the signed direct-dial DHT
%% record at boot, re-advertised on a timer.
capabilities() ->
    [#{name => <<"hecate_agora.get_posts_page">>, version => 1,
       handler => {get_posts_page_responder, []}},
     #{name => <<"hecate_agora.get_thread_by_post_id">>, version => 1,
       handler => {get_thread_by_post_id_responder, []}},
     #{name => <<"hecate_agora.search_posts">>, version => 1,
       handler => {search_posts_responder, []}},
     #{name => <<"hecate_agora.search_archive">>, version => 1,
       handler => {search_archive_responder, []}}].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more:
%% the three reads it serves and the two facts it publishes, over the agora
%% topics it listens on and the two keeper topics it publishes to. Neither
%% of those is a society's `<ns>/agora', so it can never put words in the
%% square it keeps.
identity_spec() ->
    #{scope => <<"hecate-agora">>,
      actions => [<<"get_posts_page">>, <<"get_thread_by_post_id">>, <<"search_posts">>,
                  <<"search_archive">>, <<"post_recorded">>, <<"post_conflict_detected">>],
      resources => [agora_societies:agora_topic(S) || S <- agora_societies:configured()]
                   ++ [agora_post_recorded_v1:topic(), agora_post_conflict_detected_v1:topic()],
      ttl_days => 30}.

%% @doc The barrel_docdb database the record lives in. `agora_read_model'
%% writes and reads by this same name -- hecate_om_service's own doc: "PRJ code
%% writes to it with barrel_docdb directly".
-spec read_model_id() -> binary().
read_model_id() -> <<"hecate_agora">>.

%% @doc Where the record lives on disk. Defaults to a path inside the
%% container; the fleet keeps application data on its `/bulk' drives, so the
%% deploy compose mounts a volume there and sets this. A container without the
%% mount loses the record on every recreate, which is the same as not keeping
%% one.
-spec data_dir() -> string().
data_dir() -> os:getenv("HECATE_DATA_DIR", "/var/lib/hecate-agora").

%% @doc Arms barrel_docdb's native per-document TTL sweeper on the hot
%% record, so a post `agora_read_model:record/1' wrote with `expires_at'
%% set genuinely has its disk reclaimed once it's past its hot window.
%% Arming this alone expires nothing FOR THIS SERVICE'S OWN READS: barrel's
%% lazy expiry (a document past its deadline is invisible on read with no
%% sweep needed) is real, but only for `get_doc'/`get_docs'/`fold_docs' --
%% every read this service does (`page/1', `find/1', `agora_archive:search/1')
%% goes through `find/2,3', which `barrel_query' compiles and executes
%% without ever checking expiry (confirmed by reading that module, not
%% assumed). So a post stays visible to this service's own reads until this
%% sweeper has actually run and turned it into a real tombstone -- it is
%% the only thing that makes `expires_at' matter here, not a backstop for
%% something already invisible. One hour between passes, well under the
%% days-long margin `retire_stale_posts' keeps before a post's own expiry,
%% so the sweeper always gets several chances to run before that matters.
-spec read_model_ttl_sweep() -> #{interval_ms := pos_integer(), batch := pos_integer()}.
read_model_ttl_sweep() -> #{interval_ms => 3_600_000, batch => 1000}.

%% @doc One supervised listener per configured society, on that society's
%% agora topic. `HECATE_AGORA_SOCIETIES' names them; `spartan' by default.
-spec subscriptions() -> [{binary(), module(), map()}].
subscriptions() ->
    [{agora_societies:agora_topic(S), agora_post_listener, #{society => S}}
     || S <- agora_societies:configured()].
