%% @doc Supervises this service's own processes.
%%
%% ONE CHILD: `retire_stale_posts_worker', the timer that migrates hot
%% posts into the archive and prunes expired archive segments. Everything
%% else is wired from this service's hecate_om_service callbacks by
%% hecate_om:boot/1 -- the agora listeners (subscriptions/0) run under
%% hecate_om_pubsub_sup, the four responders (capabilities/0) under
%% hecate_om_capabilities, and the hot record itself is a barrel_docdb
%% database (read_model_id/0) barrel keeps open. Archive segments
%% (agora_archive) are barrel_docdb databases too, but dynamic -- opened
%% and closed by that module directly, never wired here or through
%% hecate_om's boot-time read model.
-module(hecate_agora_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => retire_stale_posts_worker,
             start => {retire_stale_posts_worker, start_link, []}}]}}.
