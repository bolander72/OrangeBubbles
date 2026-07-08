# ADR 0003: Public Esplora API queried per-address; no xpub upload

**Status:** accepted (2026-07-07)

## Decision

V0 clients talk directly to a public Esplora-compatible API
(mempool.space, mainnet and signet) for UTXOs, tx status,
fee rates, and broadcast. We do **not** upload xpubs/descriptors to any
Taproot Wizards backend, and the optional `server/` proxy only ever sees the
same per-address queries.

## Why

- Uploading a descriptor would give us a permanent watch-only map of every
  user wallet — a privacy liability and an attractive dataset to breach.
  The spec explicitly prefers avoiding that.
- Per-address querying leaks wallet clustering to the API provider instead.
  Accepted for V0: the provider is swappable, the leak is not tied to any
  Taproot Wizards account/identity, and BDK's sync batches keep it modest.

## Path off public infra

`server/` already speaks the same Esplora subset (allowlisted, validated),
so moving traffic onto our domain is a `ChainConfig` URL change. Later:
self-hosted esplora/electrs behind it. The client contract never changes.
