%% @doc A page of the ARCHIVE, one society and one explicit `[from, until)'
%% window at a time -- "select archive from-until, then query it," as one
%% ordinary stateless call rather than a session: every other capability
%% this service answers is request/reply with no session concept anywhere
%% in it or in hecate_om's own capability model, and resolving the window
%% to its covering yearly segment(s) fresh on each call costs one more
%% id-range lookup, not a real price, for a use case that is "what did the
%% square say in this window", not repeat queries against one fixed
%% selection.
%%
%% `society', `from' and `until' are all required, unlike `get_posts_page':
%% the hot record can default to "every society, however far back the
%% scan cap reaches" because it is small and bounded on its own terms, but
%% the archive can span years, and a query with no explicit bounds at all
%% is exactly the kind of "let it grow forever" habit that made a bounded
%% hot record necessary in the first place.
-module(search_archive).

-export([get/1]).

-type request() :: #{society := binary(), from := integer(), until := integer(),
                     limit => integer()}.
-export_type([request/0]).

%% @doc `posts' newest first; `next_before' is the oldest post's `posted_at'
%% when the page was full, so the caller pages backward through the window
%% the same way `get_posts_page' does, by passing it back in as `until'.
-spec get(request()) ->
    #{posts := [map()], next_before := integer() | undefined} | {error, invalid_range}.
get(#{society := _, from := _, until := _} = Request) ->
    case agora_archive:search(maps:with([society, from, until, limit], Request)) of
        {ok, #{posts := Docs} = Result} ->
            Result#{posts => [agora_read_model:to_wire(D) || D <- Docs]};
        {error, invalid_range} = Error ->
            Error
    end;
get(_Request) ->
    {error, invalid_range}.
