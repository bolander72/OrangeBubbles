# ADR 0007: Privacy posture and roadmap

**Status:** accepted (2026-07-21) — posture and sequencing decided;
individual tiers ship separately

## 1. Ground truth (what is technically possible)

Bitcoin's base layer is a permanently public ledger. Addresses,
amounts, and the transaction graph are visible to everyone forever.
Bitcoin Script cannot verify zero-knowledge proofs; "ZK-hidden"
payments (Zcash-style shielded amounts/parties) **do not exist on
Bitcoin and cannot be shipped by any wallet**, including this one.
BitVM/OP_CAT-adjacent research is years from consumer relevance.

Bitcoin privacy is therefore about **breaking linkability**, not hiding
data. Every claim this product ever makes must respect that line:
*"hard to link" is achievable; "cryptographically hidden" is a lie.*

## 2. What already ships (and is underrated)

- **No company database.** No server, no accounts, no analytics — there
  is nothing linking identities to wallets for anyone to subpoena,
  breach, or sell. This is the strongest privacy property OrangeBubbles
  has, and most wallets structurally cannot match it.
- **Fresh address per receive**, reuse discouraged in-UI.
- **No xpub ever leaves the device** (ADR 0003) — no provider holds a
  watch-map of any user's wallet.
- **iMessage transport is end-to-end encrypted** — payment cards
  (addresses, gift secrets) are visible only to conversation
  participants, though Apple sees messaging metadata and the chain
  sees everything on-chain, as always.

Known leak accepted in ADR 0003: chain queries send address clusters +
IP to public Esplora providers.

## 3. The roadmap, in order

### Tier 1 — network privacy & hygiene (build first)
- **User-configurable Esplora endpoint** (backlog): sovereign users
  point the app at their own node; the strongest per-user fix.
- **Tor routing for chain queries** (evaluate): removes the IP half of
  the ADR 0003 leak for everyone, at the cost of embedding Tor on iOS
  (nontrivial: binary size, connection latency, App Review questions).
- **Change-output hygiene**: avoid needlessly linking UTXOs when
  building transactions (coin-selection awareness, no address-type
  fingerprint mismatches).

### Tier 2 — silent payments (BIP352, receiving)
A static receiving identity that yields a fresh, sender-computed,
unlinkable address per payment — the most substantive *real* privacy
tech on Bitcoin today. Already in the backlog; honest blocker is
light-client scanning (needs specialized indexes public Esplora doesn't
serve). Revisit as BIP352 indexer availability matures.

### Tier 3 — PayJoin (BIP78, sending)
Collaborative transactions that break the "all inputs belong to the
payer" heuristic chain-analysis relies on. Legitimate, per-payment,
opt-in, requires receiver support. Ship when enough receivers exist to
matter.

### Separate epoch — Lightning
Onion-routed payments with no per-payment on-chain footprint: a real
privacy improvement *and* the fix for small-payment fees. Largest lift
on any roadmap discussed for this product; remains deliberately out of
V1. When Lightning is evaluated, privacy is one input, not the driver.

## 4. Explicitly rejected

### Built-in CoinJoin / mixing — **never**
Not a technical judgment; a legal one. The Samourai Wallet founders
were criminally indicted (2024) for shipping coordinator-based mixing;
Wasabi shut down its coordinator under the same pressure; Apple has
removed wallets over these features. Shipping mixing in a US consumer
app is personal legal exposure for the maintainer, independent of code
quality. This decision does not expire with a product pivot — it would
take new legislation or precedent to revisit.

### "ZK payments" marketing — never
See §1. Any copy implying cryptographic hiding of amounts or parties
on Bitcoin is false advertising and will not ship.

## 5. Deliberate open question — ecash (Cashu/Fedimint)

Chaumian blind signatures deliver the thing users actually mean by
"identities can't be identified": a mint that mathematically cannot
link deposits to spends, with instant/free bearer-token UX that would
fit the gift mechanics well. The cost is disqualifying under current
principles: **it is custodial** — the mint holds the bitcoin.

Decision: ecash is not a feature to slip in; it is a philosophical
debate to have deliberately, if ever, as a clearly-labeled opt-in
"spending purse" distinct from the non-custodial core. Parked with no
trigger.

## 6. Honesty standard

Whenever privacy features ship, the security-model doc and in-app copy
must state what is and is not protected against: chain analysts,
network observers, counterparties, Apple, and (vacuously) the company.
The bar: a technically literate skeptic reads the claim and nods.
