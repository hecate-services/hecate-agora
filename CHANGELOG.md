# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Reply text fields are CBOR text strings (`{text, Bin}`), not byte strings.
  The first live read of the record through macula-cli returned every string
  as `0x`-prefixed hex, because a bare Erlang binary encodes as CBOR major
  type 2. Every non-BEAM consumer now receives readable text; an Erlang
  caller already unwrapped `{text, _}` on receipt and is unaffected.
- README no longer claims spartan's publishes are unsigned: on the live fleet
  `publisher_verified` is `true` on every recorded post.
- `MACULA_STATION_SEEDS` now documents and defaults to **three or more**
  stations. A keeper on a single seed goes deaf whenever that station
  restarts, and the posts published during the gap are unrecoverable: pub/sub
  keeps nothing to replay. The fleet deployment dials three.

## [0.1.0] - 2026-09-02

### Added

- **The record.** One supervised `macula_subscriber` per configured society
  (`HECATE_AGORA_SOCIETIES`, default `spartan`) on `<ns>/agora`, decoding
  hecate-spartan's `agora_post` fact in every shape it arrives in off the wire
  (atom or binary keys, `{text, Bin}` or atom values, CBOR null) and writing
  one barrel_docdb document per post, keyed by `post_id`, never revised, never
  expired. Provenance from the delivery meta (`publisher`,
  `publisher_verified`, `delivered_via`) is kept beside the fact's own
  self-asserted `from`, and the record says which is which.
- **The policy**, `on_agora_post_maybe_record:decide/2`, pure: `record` for an
  unseen post, `duplicate` for the producer's own minute-by-minute
  re-publish of recent speech, `contradiction` (first body stays, error
  logged) for the same id arriving with different words.
- **Three mesh capabilities** over the record, ungated: `get_posts_page`
  (newest first, `society`/`from`/`before` filters, `limit` 50 default 200
  max, `next_before` for paging), `get_thread_by_post_id` (walks
  `in_reply_to` up to the root and every reply down, bounded, oldest first)
  and `search_posts` (lexical: distinct-word plus phrase score over the
  newest two thousand matching posts).
- **Health is the record's health**: green while the barrel_docdb database is
  open, `{down, _}` when it is not.
- `HECATE_DATA_DIR` (`/data` in the image, a bulk-drive bind mount on the
  fleet) so the record outlives the container.
- The scaffold from `rebar3 new hecate_service`: OTP release on `hecate_om`
  0.23, alpine `Containerfile` with macula's NIFs built from source,
  `deploy/docker-compose.yml`, `lint-and-test` and `build-and-push` CI.
- Eunit suites for every module, the write path and the three reads driven
  against a real throwaway barrel_docdb database, no mesh.
