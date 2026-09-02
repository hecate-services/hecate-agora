%% @doc RESPONDER for the `hecate_agora.search_posts' mesh capability.
%% Ungated, same reasoning as `get_posts_page_responder'.
%%
%% Payload: `query' (required); `society', `from', `before', `after',
%% `limit' optional. Reply: `#{ok => 1, posts => [...]}' best match first, each post
%% carrying its `score', or `#{ok => 0, error => <<"query_required">>}'.
-module(search_posts_responder).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, []}.

-spec handle_request(map(), term()) -> {reply, map(), term()}.
handle_request(Payload, State) ->
    Request = maps:filter(fun(_K, V) -> V =/= undefined end, #{
        query   => text(hecate_om_wire:field(query, Payload)),
        society => text(hecate_om_wire:field(society, Payload)),
        from    => text(hecate_om_wire:field(from, Payload)),
        before  => integer(hecate_om_wire:field(before, Payload)),
        'after' => integer(hecate_om_wire:field('after', Payload)),
        limit   => integer(hecate_om_wire:field(limit, Payload))
    }),
    {reply, replied(search_posts:search(Request)), State}.

replied({ok, Posts}) -> #{ok => 1, posts => Posts};
replied({error, query_required}) -> #{ok => 0, error => <<"query_required">>}.

text(Bin) when is_binary(Bin), Bin =/= <<>> -> Bin;
text(Atom) when is_atom(Atom), Atom =/= undefined -> atom_to_binary(Atom, utf8);
text(_Other) -> undefined.

integer(N) when is_integer(N) -> N;
integer(_Other) -> undefined.
