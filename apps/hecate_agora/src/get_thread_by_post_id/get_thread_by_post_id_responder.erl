%% @doc RESPONDER for the `hecate_agora.get_thread_by_post_id' mesh
%% capability. Ungated, same reasoning as `get_posts_page_responder'.
%%
%% Payload: `post_id'. Reply: `#{ok => 1, root => Post, posts => [...]}'
%% oldest first, or `#{ok => 0, error => <<"not_found">>}'.
-module(get_thread_by_post_id_responder).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, []}.

-spec handle_request(map(), term()) -> {reply, map(), term()}.
handle_request(Payload, State) ->
    {reply, replied(post_id(hecate_om_wire:field(post_id, Payload))), State}.

replied(undefined) ->
    #{ok => 0, error => <<"post_id_required">>};
replied(PostId) ->
    fetched(get_thread_by_post_id:get(PostId)).

fetched({ok, #{root := Root, posts := Posts}}) -> #{ok => 1, root => Root, posts => Posts};
fetched({error, not_found}) -> #{ok => 0, error => <<"not_found">>}.

post_id(Bin) when is_binary(Bin), Bin =/= <<>> -> Bin;
post_id(Atom) when is_atom(Atom), Atom =/= undefined -> atom_to_binary(Atom, utf8);
post_id(_Other) -> undefined.
