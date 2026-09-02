%% @doc One conversation out of the record: a post, everything it replied to,
%% and everything that replied to it, in the order it was said.
%%
%% A post carries `in_reply_to', the id of what it answers. Walking that up
%% finds the root; walking `replies_to' down from the root finds the whole
%% tree. Both walks are bounded, because a record fed by a live mesh can hold
%% a reply whose parent this keeper never heard (it joined late, or the
%% publish was lost): the walk up stops at the first missing parent and
%% treats the last post it found as the top of what is known, rather than
%% failing the whole thread over one hole.
-module(get_thread_by_post_id).

-export([get/1]).

%% How far up a reply chain to follow. Society replies nest a handful deep;
%% sixty-four is a guard against a cycle in bad data, not a design limit.
-define(MAX_DEPTH, 64).
%% How many posts one thread reply may carry.
-define(MAX_POSTS, 500).
%% Direct replies fetched per post while walking down.
-define(REPLIES_PER_POST, 200).

-spec get(binary()) -> {ok, #{root := map(), posts := [map()]}} | {error, not_found}.
get(PostId) when is_binary(PostId) ->
    threaded(agora_read_model:find(PostId)).

threaded({error, not_found}) ->
    {error, not_found};
threaded({ok, Doc}) ->
    Root = climb(Doc, ?MAX_DEPTH),
    Posts = descend([Root], #{}, []),
    {ok, #{root  => agora_read_model:to_wire(Root),
           posts => [agora_read_model:to_wire(D) || D <- chronological(Posts)]}}.

%% Up: follow in_reply_to until a post that replies to nothing, or to
%% something this keeper does not hold.
climb(Doc, 0) ->
    Doc;
climb(Doc, Left) ->
    parent(maps:get(<<"in_reply_to">>, Doc, undefined), Doc, Left).

parent(undefined, Doc, _Left) ->
    Doc;
parent(ParentId, Doc, Left) ->
    climbed(agora_read_model:find(ParentId), Doc, Left).

climbed({ok, Parent}, _Doc, Left) -> climb(Parent, Left - 1);
climbed({error, not_found}, Doc, _Left) -> Doc.

%% Down: breadth-first over direct replies, each post visited once, the
%% total capped.
descend([], _Seen, Acc) ->
    Acc;
descend(_Queue, _Seen, Acc) when length(Acc) >= ?MAX_POSTS ->
    Acc;
descend([Doc | Rest], Seen, Acc) ->
    Id = maps:get(<<"post_id">>, Doc),
    visit(maps:is_key(Id, Seen), Id, Doc, Rest, Seen, Acc).

visit(true, _Id, _Doc, Rest, Seen, Acc) ->
    descend(Rest, Seen, Acc);
visit(false, Id, Doc, Rest, Seen, Acc) ->
    {ok, Replies} = agora_read_model:replies_to(Id, ?REPLIES_PER_POST),
    descend(Rest ++ Replies, Seen#{Id => true}, [Doc | Acc]).

chronological(Docs) ->
    lists:sort(fun(A, B) -> maps:get(<<"posted_at">>, A) =< maps:get(<<"posted_at">>, B) end,
               Docs).
