%% @doc Decodes an `agora_post' fact off the wire into the clean post the
%% policy and the record work with.
%%
%% The fact is hecate-spartan's public contract for speech in the square
%% (`maybe_publish_to_agora:fact/1'):
%%
%%   #{type => agora_post, post_id, from, body, in_reply_to, posted_at,
%%     home, locale, stimulus}
%%
%% `stimulus' is what the speaking mind was reacting to: the news item its
%% own node attached, verbatim, without the model ever touching it. It is
%% therefore the one part of a post that is provenance rather than a claim.
%% Absent for unprompted speech (a committee, a visitor's question, a
%% self-alert), and absent is not the same as empty. Its `item_id' is the
%% THREAD id: every post carrying the same one is the same conversation.
%%
%% A pubsub payload does not arrive as the map the producer built. Keys may
%% be atoms or binaries, a CBOR text value may arrive as `{text, Bin}' or as
%% an atom the receiving VM happened to know, and an absent field arrives as
%% CBOR null. `hecate_om_wire:field/3' takes the key and unwrap hazards;
%% `text/1' here takes the atom one.
%%
%% Provenance comes from the delivery `Meta', not the payload: `publisher'
%% is the wire-level identity that published the frame (the spartan
%% instance the mind is homed on, since a mind rides its instance's
%% connection), and `publisher_verified' says whether that identity signed
%% the frame. `from' inside the payload is the mind's own DID and is
%% self-asserted. Both are kept, and the record says which is which.
%%
%% Pure, so every wire shape is unit-testable without a mesh.
-module(agora_post_fact).

-export([decode/4]).

-define(TYPE, <<"agora_post">>).

%% @doc `{ok, Post}' for a well-formed agora post, `{error, Reason}' for
%% anything else on the topic. Strict on purpose: a post with no id cannot
%% be deduplicated, a post with no body is not speech, and a post with no
%% `posted_at' cannot be placed in the record.
-spec decode(binary(), term(), map(), binary()) ->
    {ok, agora_read_model:post()} | {error, term()}.
decode(Topic, Payload, Meta, Society) when is_map(Payload), is_map(Meta) ->
    typed(text(hecate_om_wire:field(type, Payload)), Topic, Payload, Meta, Society);
decode(_Topic, Payload, _Meta, _Society) ->
    {error, {not_a_map, Payload}}.

typed(?TYPE, Topic, Payload, Meta, Society) ->
    shaped(text(hecate_om_wire:field(post_id, Payload)),
           text(hecate_om_wire:field(from, Payload)),
           text(hecate_om_wire:field(body, Payload)),
           hecate_om_wire:field(posted_at, Payload),
           Topic, Payload, Meta, Society);
typed(Other, _Topic, _Payload, _Meta, _Society) ->
    {error, {not_an_agora_post, Other}}.

shaped(PostId, From, Body, PostedAt, Topic, Payload, Meta, Society)
  when is_binary(PostId), PostId =/= <<>>,
       is_binary(From), From =/= <<>>,
       is_binary(Body), Body =/= <<>>,
       is_integer(PostedAt) ->
    {ok, #{post_id            => PostId,
           society            => Society,
           topic              => Topic,
           from               => From,
           body               => Body,
           in_reply_to        => text(hecate_om_wire:field(in_reply_to, Payload)),
           stimulus           => stimulus(hecate_om_wire:field(stimulus, Payload)),
           posted_at          => PostedAt,
           home               => text(hecate_om_wire:field(home, Payload)),
           locale             => text(hecate_om_wire:field(locale, Payload)),
           publisher          => publisher(maps:get(publisher, Meta, undefined)),
           publisher_verified => verified(maps:get(publisher_verified, Meta, not_signed)),
           heard_at           => erlang:system_time(millisecond),
           heard_via          => text(maps:get(delivered_via, Meta, unknown))}};
shaped(PostId, From, Body, PostedAt, _Topic, _Payload, _Meta, _Society) ->
    {error, {malformed_agora_post, #{post_id => PostId, from => From,
                                     body_present => Body =/= undefined,
                                     posted_at => PostedAt}}}.

%% The stimulus, shaped for the record. Kept only when it carries an
%% `item_id', because that is the thread id and a stimulus that cannot be
%% grouped is not worth storing. Every other field is optional: 21 of the 47
%% live sources publish no picture, and the gazetteer does not place every
%% story. The producer owns this content and we accept it as sent, but a
%% shape that cannot be used is refused rather than half-stored.
stimulus(Carried) when is_map(Carried) ->
    shaped_stimulus(text(hecate_om_wire:field(item_id, Carried)), Carried);
stimulus(_AbsentOrNotAMap) ->
    undefined.

shaped_stimulus(undefined, _Carried) ->
    undefined;
shaped_stimulus(ItemId, Carried) ->
    agora_read_model:omit_undefined(
      #{<<"item_id">>      => ItemId,
        <<"title">>        => text(hecate_om_wire:field(title, Carried)),
        <<"url">>          => text(hecate_om_wire:field(url, Carried)),
        <<"image_url">>    => text(hecate_om_wire:field(image_url, Carried)),
        <<"source">>       => text(hecate_om_wire:field(source, Carried)),
        <<"source_type">>  => text(hecate_om_wire:field(source_type, Carried)),
        <<"topic_class">>  => text(hecate_om_wire:field(topic_class, Carried)),
        <<"topics">>       => tags(hecate_om_wire:field(topics, Carried)),
        <<"emoji">>        => text(hecate_om_wire:field(emoji, Carried)),
        <<"lang">>         => text(hecate_om_wire:field(lang, Carried)),
        %% Two countries: who reported it (exact, from the source's config) and
        %% what it is about (a gazetteer guess). Both codes and both names,
        %% because a flag and a filter need the code, and a name can be absent
        %% while its code is present.
        <<"reporting_country">>      => text(hecate_om_wire:field(reporting_country, Carried)),
        <<"reporting_country_name">> => text(hecate_om_wire:field(reporting_country_name, Carried)),
        <<"subject_country">>        => text(hecate_om_wire:field(subject_country, Carried)),
        <<"subject_country_name">>   => text(hecate_om_wire:field(subject_country_name, Carried)),
        <<"published_at">> => whole(hecate_om_wire:field(published_at, Carried))}).

tags(List) when is_list(List) -> [T || Raw <- List, (T = text(Raw)) =/= undefined];
tags(_AbsentOrNotAList)      -> undefined.

whole(N) when is_integer(N), N >= 0 -> N;
whole(_AbsentOrNotAWholeNumber)     -> undefined.

%% A wire text value after `hecate_om_wire' has unwrapped it: a binary, an
%% atom the VM already knew, or absent.
text(undefined) -> undefined;
text(Bin) when is_binary(Bin) -> Bin;
text(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
text(_Other) -> undefined.

%% The publisher is a raw Ed25519 public key on the wire; the record keeps it
%% as lowercase hex, the same rendering every other read model in this org
%% uses for a node identity.
publisher(Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    binary:encode_hex(Key, lowercase);
publisher(Hex) when is_binary(Hex), byte_size(Hex) =:= 64 ->
    Hex;
publisher(_Absent) ->
    undefined.

%% `not_signed' | `true' | `false' from macula >= 10.16.0; anything else is an
%% older macula that never reported the outcome.
verified(true) -> <<"true">>;
verified(false) -> <<"false">>;
verified(_NotSignedOrUnknown) -> <<"not_signed">>.
