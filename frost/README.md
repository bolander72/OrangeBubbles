# ob-frost — FROST research track (ADR 0008 §7–8)

**Signet-only. Debug-flagged. Ships to no one** until every box in the
ADR 0008 §8 readiness gate is checked (public audit of the FROST
implementation, externally reviewed bindings, a reviewed nonce/session
state-machine spec for the chat transport, DKG-over-cards with
abort/resume, signet field trial).

Current state: proof of concept — dealer-based 2-of-3 ceremony via
`frost-secp256k1-tr` whose aggregate signature verifies as standard
BIP340 under an independent library (`rust-secp256k1`), i.e. a valid
Taproot keypath spend. Run it: `cargo run --release`.

Research roadmap (order matters):
1. Taproot sighash plumbing: sign a REAL signet keypath spend built by
   BDK against `tr(aggregate_key)` and broadcast it
2. Nonce/session state-machine spec for the iMessage transport (written
   + reviewed BEFORE any Swift integration)
3. uniffi bindings + xcframework (iOS targets), not hand-rolled call
   sites
4. DKG over cards (replace the trusted dealer), incl. abort/resume
5. Signet field trial behind a debug flag

The dealer shortcut is acceptable ONLY here: it means one machine
briefly knows the whole key, which defeats FROST's point in production.
