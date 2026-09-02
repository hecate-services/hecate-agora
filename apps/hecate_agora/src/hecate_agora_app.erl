%% @doc OTP application entry.
%%
%% hecate_om:boot/1 wires the mesh, the realm identity and health, opens the
%% barrel_docdb record (read_model_id/0 + data_dir/0), registers the three
%% responders (capabilities/0), starts one supervised listener per society
%% (subscriptions/0), and only then starts this service. No reckon-db: the
%% service module exports no store_id/0, because a post is a fact its producer
%% already published and this service keeps it rather than decides it.
-module(hecate_agora_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> hecate_om:boot(hecate_agora_service).

stop(_State) -> ok.
