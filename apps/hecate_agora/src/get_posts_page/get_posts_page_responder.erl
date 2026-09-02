%% @doc RESPONDER for the `hecate_agora.get_posts_page' mesh capability.
%%
%% Ungated: the square is public speech by the speaker's own choice (it is
%% the one body-bearing fact hecate-spartan publishes into the open), so its
%% record is public too.
%%
%% Payload, all optional: `society', `from', `story' (a stimulus `item_id',
%% which is the thread id), `before' and `after' (ms, both exclusive),
%% `limit'. Reply: `#{ok => 1, posts => [...], next_before => Ms}', with
%% `next_before' omitted on the last page. No booleans cross the wire.
-module(get_posts_page_responder).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, []}.

-spec handle_request(map(), term()) -> {reply, map(), term()}.
handle_request(Payload, State) ->
    Request = maps:filter(fun(_K, V) -> V =/= undefined end, #{
        society => text(hecate_om_wire:field(society, Payload)),
        from    => text(hecate_om_wire:field(from, Payload)),
        story   => text(hecate_om_wire:field(story, Payload)),
        before  => integer(hecate_om_wire:field(before, Payload)),
        'after' => integer(hecate_om_wire:field('after', Payload)),
        limit   => integer(hecate_om_wire:field(limit, Payload))
    }),
    #{posts := Posts, next_before := Next} = get_posts_page:get(Request),
    {reply, with_next(#{ok => 1, posts => Posts}, Next), State}.

with_next(Reply, undefined) -> Reply;
with_next(Reply, Next) -> Reply#{next_before => Next}.

text(Bin) when is_binary(Bin), Bin =/= <<>> -> Bin;
text(Atom) when is_atom(Atom), Atom =/= undefined -> atom_to_binary(Atom, utf8);
text(_Other) -> undefined.

integer(N) when is_integer(N) -> N;
integer(_Other) -> undefined.
