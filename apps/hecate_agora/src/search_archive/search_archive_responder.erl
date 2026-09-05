%% @doc RESPONDER for the `hecate_agora.search_archive' mesh capability.
%%
%% Ungated, same reasoning as `get_posts_page_responder': the square is
%% public speech by the speaker's own choice, and that does not stop being
%% true once a post is old enough to have left the hot record.
%%
%% Payload: `society', `from', `until' (all required, ms), `limit'
%% (optional). Reply: `#{ok => 1, posts => [...], next_before => Ms}', with
%% `next_before' omitted on the last page, or
%% `#{ok => 0, error => <<"invalid_range">>}' when a required field is
%% missing or `from' is not strictly before `until'.
-module(search_archive_responder).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, []}.

-spec handle_request(map(), term()) -> {reply, map(), term()}.
handle_request(Payload, State) ->
    Request = maps:filter(fun(_K, V) -> V =/= undefined end, #{
        society => text(hecate_om_wire:field(society, Payload)),
        from    => integer(hecate_om_wire:field(from, Payload)),
        until   => integer(hecate_om_wire:field(until, Payload)),
        limit   => integer(hecate_om_wire:field(limit, Payload))
    }),
    {reply, replied(search_archive:get(Request)), State}.

replied(#{posts := Posts, next_before := Next}) ->
    with_next(#{ok => 1, posts => Posts}, Next);
replied({error, invalid_range}) ->
    #{ok => 0, error => <<"invalid_range">>}.

with_next(Reply, undefined) -> Reply;
with_next(Reply, Next) -> Reply#{next_before => Next}.

text(Bin) when is_binary(Bin), Bin =/= <<>> -> Bin;
text(Atom) when is_atom(Atom), Atom =/= undefined -> atom_to_binary(Atom, utf8);
text(_Other) -> undefined.

integer(N) when is_integer(N) -> N;
integer(_Other) -> undefined.
