# ADR 0008: Shared Vaults — group-chat-native multisig

**Status:** proposed (2026-08) — protocol specced; v1 buildable now on
P2WSH; FROST is the declared v2 target with an explicit readiness gate

## 1. Product

A **shared vault** is a bitcoin account that lives in an iMessage group
chat. Every member is a cosigner; spending requires a threshold (k-of-n)
of members to approve, each with Face ID on their own device. Framing is
"shared account," never "multisig."

Why this wins: multisig adoption has always died on coordination UX —
exchanging keys, shuttling PSBTs. The group chat *is* the coordination
layer: persistent, end-to-end encrypted, identity-attached, and already
where the participants talk. Post-Coldcard, the security story is
equally crisp: **no single device — and no single device's RNG — can
lose or move the money.**

## 2. Architecture principle: vaults are protocol-agnostic

A vault is `(members, threshold, watch descriptor, signing protocol)`.
The chat-card message flow, the vault ledger, backup/recovery, and the
UI are all designed against an abstract signing protocol with
**multi-round capability** (propose → rounds of member messages →
broadcast). Two implementations are planned:

| | v1: `p2wsh-v1` | v2: `frost-v1` |
| --- | --- | --- |
| Script | `wsh(sortedmulti(k, xpubs…))` | `tr(aggregate key)` keypath |
| On-chain appearance | Visibly k-of-n, all keys public | Indistinguishable from single-sig |
| Fees | Grows with n (~2–3× single-sig) | Flat, same as single-sig |
| Threshold | Native | Native (true k-of-n Schnorr) |
| Membership change | New vault + move funds | Re-deal shares in place (no on-chain move) |
| Signing rounds | 1 per signer (PSBT sig accumulation) | 2 interactive rounds (nonces, then partials) |
| Maturity | ~15 years in production; BDK-native | Young implementations; no audited mobile bindings yet |

The card protocol (§4) carries opaque `payload` blobs per protocol
version, so FROST's extra round is a new card type, not a redesign.

## 3. Keys and derivation (v1)

- Each member's cosigner key derives from their existing wallet seed at
  a dedicated multisig path (BIP48: `m/48'/coin'/account'/2'` for
  P2WSH), so **restoring the main wallet restores vault membership** —
  no new seeds, no extra backup ceremony for keys.
- Vault watch descriptor: `wsh(sortedmulti(k, xpub₁ … xpubₙ))`, built
  identically by every member from the collected xpubs. Deterministic:
  same inputs ⇒ same descriptor ⇒ same addresses everywhere.
- **Recovery needs more than seed words.** The descriptor (everyone's
  xpubs + threshold) must survive. It is stored in three redundant
  places: each member's iCloud backup envelope (extended for a vault
  ledger), the recovery escape hatch (Reveal Recovery Phrase gains a
  vault-descriptor section), and — implicitly — the chat history's
  cards, which contain every xpub. Losing all three across ALL members
  simultaneously is the only unrecoverable state.

## 4. Card protocol (all payloads ride MSMessage URLs, E2E via iMessage)

| Card | Path | Carries | Notes |
| --- | --- | --- | --- |
| Vault invite | `/vault/new` | vaultID, name, k, n, creator xpub | Tapping joins: member's app replies with… |
| Join | `/vault/join` | vaultID, member xpub | Public data; safe in transit. App tracks n joins → descriptor finalized, vault card updates in place ("3 of 3 joined — vault live") |
| Deposit request | `/vault/fund` | vault address, amount? | Reuses /pay mechanics against the vault address |
| Spend proposal | `/vault/spend` | vaultID, PSBT (compressed), dest, amount, memo | Proposer signs first; card shows "1 of k signed" |
| Co-sign | `/vault/sign` | vaultID, proposalID, updated PSBT | Each signer taps → Face ID → adds signature → card updates in place with progress; at k, any member's app finalizes + broadcasts |
| Outcome | `/vault/paid` | txid | In-place update of the proposal card |

**PSBT size:** MSMessage URLs tolerate a few KB; a 2-of-3 P2WSH PSBT
with 1–2 inputs fits after zlib+base64. Mitigations, in order: compress
always; consolidate vault UTXOs opportunistically; cap proposal inputs
(split large spends); if ever needed, chunked multi-card transfer.
Measured limits go in tests, not comments.

**Races:** concurrent proposals are fine (independent proposalIDs);
double-spends of the same UTXOs resolve by chain, like gifts. A
proposal card that can't reach threshold is cancelled by the proposer
(in-place update) or simply expires socially.

## 5. Membership semantics (v1 — must be honest UI)

- The keyset is frozen at creation. Someone leaving the group chat does
  NOT leave the vault. "Remove a member" = create a successor vault and
  move funds (a guided flow, one proposal).
- A member who wipes/loses their wallet without backup reduces the
  vault to (k of n−1) effective signers — survivable while n−1 ≥ k.
  The vault screen surfaces this ("2 of 3 signers reachable") via
  optional liveness pings (a `/vault/ping` card).

## 6. Threshold presets

"Both of us" (2-of-2), "Any 2" (2-of-3), "Majority" (⌈n/2⌉+…), shown
with plain-language consequences ("if one phone is lost, funds are
safe / stuck"). 2-of-2 warns explicitly: lose either signer, lose the
funds — recommend 2-of-3 with a third device or member.

## 7. Why not FROST first (the due-diligence answer)

FROST is the correct destination — true k-of-n under one aggregate
Taproot key: private, flat-fee, and with **re-dealable shares** that
fix membership changes without moving funds. It is also, today, exactly
the kind of cryptography the Coldcard post-mortem warns about shipping
eagerly:

1. **No audited mobile implementation.** `frost-secp256k1-tr` (Zcash
   Foundation's Rust crates, Taproot/BIP340 ciphersuite) is the leading
   candidate; there are no production Swift bindings — we would be
   hand-rolling the FFI and the protocol state machine ourselves and
   becoming, de facto, an unaudited cryptography vendor.
2. **Nonce discipline is catastrophic-on-failure.** Reusing a FROST/
   MuSig2 nonce across signing sessions leaks key shares. Over an
   asynchronous, human-paced, retry-prone channel (people re-tapping
   cards in a group chat), session/nonce state management IS the attack
   surface. This must be designed and reviewed, not improvised.
3. **DKG over iMessage** (distributed key generation) adds an abortable
   multi-round ceremony at vault creation, with resumption semantics.
4. **Signing lives outside BDK**: keypath-spend sighash construction
   and witness injection are manual; wrong sighash code = wrong
   signatures = subtle fund-loss bugs.

**Decision:** ship vault UX on `p2wsh-v1` now; treat FROST as a gated
upgrade, not a rewrite — the protocol abstraction (§2) and round-capable
cards (§4) exist precisely so `frost-v1` is additive.

## 8. FROST readiness gate (all must be true before `frost-v1` ships)

- [ ] An actively maintained BIP340/Taproot FROST implementation with a
      public security audit (or equivalent formal review)
- [ ] Bindings we don't author alone (community/uniffi-maintained), or
      an external review of ours
- [ ] A written nonce/session state-machine spec for the chat transport,
      reviewed by someone who has shipped threshold Schnorr
- [ ] DKG-over-cards spec incl. abort/resume, tested across app kills
- [ ] Signet-only field trial period with debug-flagged vaults
- Migration: existing P2WSH vaults offer "upgrade vault" = one proposal
  moving funds to the new FROST key. No forced migration.

## 9. Relationship to prior ADRs

Extends 0005/0006's card mechanics (in-place updates, chain-arbitrated
races) from 1-party and 2-party to n-party. Inherits 0003/0004: no
servers (the chat is the coordinator), auto-wallet keys feed cosigner
derivation, Face ID gates every signature. Privacy ladder (0007) gains
its multisig rung when FROST lands.
