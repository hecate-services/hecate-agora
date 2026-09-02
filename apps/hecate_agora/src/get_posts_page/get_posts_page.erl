%% @doc A page of the record, newest first, optionally narrowed to one
%% society, one speaker or one STORY, paged backwards in time with `before', and
%% bounded from below with `after' so a subscriber to `agora/post_recorded'
%% that missed facts can ask for everything since the last post it saw:
%% page with `after' fixed until the reply is not full, and the gap is
%% closed.
%%
%% Bounded on purpose: `limit' defaults to 50 and caps at 200, so a caller
%% that wants the whole square walks it page by page using the `next_before'
%% the reply hands back, and no single call can ask this service to
%% serialise its entire history onto the wire.
%%
%% `story' is a stimulus `item_id'. Every post carrying it is the same
%% conversation, so asking for one is how a reader follows a story rather
%% than a reply chain -- which matters because minds in this square reply to
%% the world far more often than to each other, and a thread built only from
%% `in_reply_to' would show almost nothing.
-module(get_posts_page).

-export([get/1]).

-define(DEFAULT_LIMIT, 50).
-define(MAX_LIMIT, 200).

-type request() :: #{society => binary(),
                     from => binary(),
                     story => binary(),
                     before => integer(),
                     'after' => integer(),
                     limit => integer()}.
-export_type([request/0]).

%% @doc `posts' newest first; `next_before' is the oldest post's `posted_at'
%% when the page was full, so the caller can ask for the page before it.
-spec get(request()) -> #{posts := [map()], next_before := integer() | undefined}.
get(Request) ->
    Limit = clamp(maps:get(limit, Request, ?DEFAULT_LIMIT)),
    Filters = maps:with([society, from, story, before, 'after'], Request),
    {ok, Docs} = agora_read_model:page(Filters#{limit => Limit}),
    #{posts       => [agora_read_model:to_wire(D) || D <- Docs],
      next_before => next_before(length(Docs) =:= Limit, Docs)}.

next_before(true, Docs) -> maps:get(<<"posted_at">>, lists:last(Docs));
next_before(false, _Docs) -> undefined.

clamp(N) when is_integer(N), N >= 1, N =< ?MAX_LIMIT -> N;
clamp(N) when is_integer(N), N > ?MAX_LIMIT -> ?MAX_LIMIT;
clamp(_NotAUsableLimit) -> ?DEFAULT_LIMIT.
