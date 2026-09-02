%% @doc Which societies this keeper records, and how a society maps to its
%% agora topic.
%%
%% A society is a topic namespace (hecate-spartan's own contract, see its
%% `hecate_spartan_society'): the minds of society `Ns' speak on `Ns/agora'.
%% This keeper records one or more societies, named in
%% `HECATE_AGORA_SOCIETIES' as a comma-separated list, defaulting to `spartan'.
%% Recording an extra society whose square is silent costs one idle
%% subscription, so listing `news' beside `spartan' before the news minds
%% exist is fine.
%%
%% Pure, so the parsing is unit-testable without an environment.
-module(agora_societies).

-export([configured/0, parse/1, agora_topic/1, society_of_topic/1]).

-define(DEFAULT, <<"spartan">>).
-define(SUFFIX, <<"/agora">>).
%% The namespace the keeper's own facts are published under
%% (`agora/post_recorded', `agora/post_conflict_detected'). A society by
%% this name would put the keeper's topics inside a society's namespace,
%% which is the one thing the keeper must never do, so the name is refused.
-define(KEEPER_NS, <<"agora">>).

%% @doc The societies to record, from `HECATE_AGORA_SOCIETIES'.
-spec configured() -> [binary(), ...].
configured() ->
    parse(os:getenv("HECATE_AGORA_SOCIETIES")).

%% @doc Parse a comma-separated society list. Blank entries are dropped,
%% duplicates collapse to the first occurrence, and a name carrying a `/' or
%% whitespace is a typo rather than a namespace, so it is dropped too, and
%% so is `agora', the keeper's own namespace. An
%% empty result falls back to the default, because a keeper recording nothing
%% is a deploy that looks healthy and keeps no record.
-spec parse(false | string() | binary()) -> [binary(), ...].
parse(false) ->
    [?DEFAULT];
parse(Csv) when is_list(Csv) ->
    parse(unicode:characters_to_binary(Csv));
parse(Csv) when is_binary(Csv) ->
    Parts = [string:trim(P) || P <- binary:split(Csv, <<",">>, [global])],
    or_default(lists:uniq([P || P <- Parts, valid(P)])).

or_default([]) -> [?DEFAULT];
or_default(Societies) -> Societies.

valid(<<>>) ->
    false;
valid(?KEEPER_NS) ->
    false;
valid(Ns) ->
    binary:match(Ns, [<<"/">>, <<" ">>, <<"\t">>]) =:= nomatch.

%% @doc The agora topic of a society: `Ns/agora'.
-spec agora_topic(binary()) -> binary().
agora_topic(Ns) when is_binary(Ns) ->
    <<Ns/binary, ?SUFFIX/binary>>.

%% @doc The society an agora topic belongs to, or `undefined' for a topic that
%% is not an agora at all.
-spec society_of_topic(binary()) -> binary() | undefined.
society_of_topic(Topic) when is_binary(Topic) ->
    strip_suffix(Topic, byte_size(Topic) - byte_size(?SUFFIX)).

strip_suffix(_Topic, NsLen) when NsLen =< 0 ->
    undefined;
strip_suffix(Topic, NsLen) ->
    suffixed(binary:part(Topic, NsLen, byte_size(?SUFFIX)) =:= ?SUFFIX, Topic, NsLen).

suffixed(true, Topic, NsLen) -> binary:part(Topic, 0, NsLen);
suffixed(false, _Topic, _NsLen) -> undefined.
