%% @doc Supervises this service's own processes.
%%
%% NO CHILDREN OF ITS OWN, and that is the honest shape rather than a
%% placeholder: this service's processes are all wired from its
%% hecate_om_service callbacks by hecate_om:boot/1. The agora listeners
%% (subscriptions/0) run under hecate_om_pubsub_sup, the three responders
%% (capabilities/0) under hecate_om_capabilities, and the record itself is a
%% barrel_docdb database (read_model_id/0) barrel keeps open. Nothing this
%% service does needs a process outside those.
-module(hecate_agora_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
