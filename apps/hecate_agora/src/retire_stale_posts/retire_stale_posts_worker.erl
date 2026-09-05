%% @doc Runs `retire_stale_posts:run/0' on a timer. The one child of
%% `hecate_agora_sup' -- see that supervisor's own doc for why it had none
%% before this.
%%
%% A crash inside a tick (an unhandled error from `retire_stale_posts:run/0')
%% takes this process down; `hecate_agora_sup' restarts it and the next tick
%% starts clean. Nothing is lost across a restart -- see
%% `retire_stale_posts''s own doc on why re-scanning from scratch every
%% tick is the whole recovery story, not a gap in one.
-module(retire_stale_posts_worker).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% One hour: far more frequent than the multi-day migration lead time
%% (`retire_stale_posts:migration_threshold_ms/0'), so a run that's briefly
%% slow or a single missed tick is not a risk to any post's hot-window
%% deadline.
-define(INTERVAL_MS, 3_600_000).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = schedule(),
    {ok, #{}}.

handle_info(retire, State) ->
    _ = retire_stale_posts:run(),
    _ = schedule(),
    {noreply, State};
handle_info(_Other, State) ->
    {noreply, State}.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Request, State) -> {noreply, State}.

schedule() -> erlang:send_after(?INTERVAL_MS, self(), retire).
