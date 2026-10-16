# ADR 0010: Silent payments (BIP352) — send first, receive when the light-client problem is solved

**Status:** accepted (2026-10). Sending core implemented in WalletKit
(`SilentPayment.swift`, all 28 official sending vectors pass); UI wiring
is the next step. Receiving deferred with a concrete trigger.

## 1. Question

Mike asked whether OrangeBubbles can use silent payments to keep privacy
at the forefront. BIP352 gives a receiver one static address
(`sp1…`) that still yields a fresh, unlinkable taproot output for every
payment; only the receiver can tell which outputs are theirs.

## 2. What it would and wouldn't change here

OrangeBubbles already hands out a **fresh BIP84 address per request**,
inside an end-to-end encrypted chat. On chain, a payment to such an
address and a payment to a silent-payment output look the same: one
unlinkable output each. The static-address benefit is for people who
publish one address in public (bios, donation pages); the app has no such
surface. So for *receiving*, BIP352 would mostly protect against a chat
participant linking two requests of yours — something they can already do
by being in the chat.

The clear win is **sending**: more and more people publish `sp1…`
addresses, and a wallet that can't pay them is a wallet people leave. It
also carries a privacy benefit for the *recipient* that we provide at
zero cost to the sender.

## 3. Receiving: why not now

A silent-payment receiver can't ask an Esplora "what came to my address";
there is no address. It must, for every transaction with a taproot
output, sum the input public keys, multiply by its scan key, and compare
derived candidates with the outputs. Light clients do this via a
**tweak index** (33 bytes per eligible transaction, ~7–12 kB per block)
plus BIP158 filters. As of October 2026:

- No public Esplora (mempool.space, blockstream.info) serves tweaks.
- The servers that do are few and heavy: BlindBit Oracle v2 (~109 GB
  index), Cake's Electrs fork (~1.6 TB), Bindex-rs (WIP). Frigate scans
  server-side *with the client's scan key*, i.e. it learns every payment
  you receive.
- The light-client spec is still a draft; libsecp256k1 0.8.0's
  silentpayments module ships full-node scanning only.
- BDK's own BIP352 crates (`bdk-sp`, `silent-payments-receive`) are
  marked experimental and not recommended on mainnet.

Running a tweak server ourselves is ruled out by the no-TW-server policy
(docs/launch-blockers.md); depending on one or two volunteer servers
would put a third party between users and their money. Receiving also
needs a full rescan of history on restore, which the iCloud auto-restore
(ADR 0004) can't absorb on a public index at today's rate limits.

**Trigger to revisit:** a public, Esplora-grade tweak index with more than
one independent operator, or BDK shipping stable light-client receive.
Then: derive scan/spend keys at `m/352'/coin'/0'/1'/0` and
`m/352'/coin'/0'/0'/0` from the existing seed (no new backup material),
show the `sp1…` address in Receive next to the fresh address, scan with
label `m = 0` for change.

## 4. Sending: design

Implemented in WalletKit with no new native code:

- **Math**: `swift-secp256k1` (21-DOT-DEV, pinned `0.23.2`) for ECDH on
  raw points, scalar multiply/add tweaks and x-only keys; CryptoKit for
  the BIP340-style tagged hashes; a 20-line scalar type for summing and
  negating private keys mod n (libsecp256k1 rejects the intermediate zero
  sums the BIP allows); a small RIPEMD-160 for P2PKH key checks; Bech32m
  for `sp1…`/`tsp1…`. ~450 lines, all covered by the official vectors.
- **Keys**: BDK already exposes per-input secret bytes
  (`DescriptorSecretKey.derive(path).secretBytes()`); each input's path is
  `m/84'/coin'/0'/{keychain}/{derivationIndex}` from `LocalOutput`.
- **Coin selection** must happen *before* the output exists (the output
  depends on which inputs are spent). Two-pass build: (1) build with BDK
  against a placeholder taproot script of identical size to learn the fee
  and the selected inputs; (2) derive the real outputs from those inputs
  and rebuild with `addUtxos(...)`/`manuallySelectedOnly()` and the real
  script. Same inputs, same fee, correct output.
- **Eligibility**: this wallet's inputs are P2WPKH (or P2TR with BIP86),
  all eligible. The classifier for mixed inputs exists for completeness
  and tests.
- **Change** stays on our own BIP84 change keychain; the BIP permits any
  extra outputs. (Paying change to our own silent-payment label is only
  meaningful once we can scan.)
- **Network**: `sp1` on mainnet, `tsp1` on signet/testnet; the address
  must match the wallet's network, like any other.

UI (next step): the Send field accepts an `sp1…` address exactly like a
`bc1…` one — valid-address check, "Paste", QR scan all work; the review
sheet shows the silent payment address and a "Silent payment" badge
instead of a bech32 address; the receipt card shows the derived taproot
address with a line that the recipient must scan to see it. Payment
*requests* (Receive cards) keep handing out fresh BIP84 addresses: a
request card is already a one-time address.

## 5. Why not Rust FFI

We just removed the FROST xcframework and the uniffi toolchain with it.
The sending side needs no new primitive beyond what libsecp256k1 (via
swift-secp256k1) already offers, and the BIP's arithmetic is a page.
Keeping it in Swift keeps the build simple and the test vectors in the
same `swift test` run as everything else.

## 6. Consequences

- One new Swift package dependency, compiled from the libsecp256k1
  sources; adds a few hundred KB to the extension.
- `SilentPaymentAddress`, `SilentPaymentInput`, `SilentPaymentSender` in
  WalletKit, exercised by `SilentPaymentTests` against
  `bip-0352/send_and_receive_test_vectors.json` (vendored, 28 vectors).
- Privacy ladder (ADR 0007) Tier 2 becomes "receive" only; sending moves
  into the shipped column once the UI lands.
