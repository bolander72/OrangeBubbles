# Security model (V0)

## What we protect

The BIP39 mnemonic. Whoever has it has the money. It exists:

1. In extension memory, only between Face ID unlock and session end.
2. Inside the encrypted envelope in the user's iCloud Drive.

It is **never** shown to the user (no seed phrase ceremony), never logged,
never sent to any Taproot Wizards server, and never stored unencrypted at rest.

## Seed generation (hardened 2026-08 after the Coldcard RNG incident)

Seeds are never drawn from a single library's internal RNG. `SeedEntropy`
combines three sources with HKDF-SHA256 — Apple's kernel CSPRNG
(`SecRandomCopyBytes`, mandatory, fail-closed), a CryptoKit path into the
system RNG, and BitcoinDevKit's Rust RNG (mixed in, not trusted) — so a
silently broken path in any one of them cannot produce predictable seeds.
Main wallets use 24 words (256-bit entropy); disposable gift vouchers use
12 words (128-bit). The encode path is pinned by a BIP39 test vector.

## Encryption path

- AEAD: ChaCha20-Poly1305 (CryptoKit).
- KDF: HKDF-SHA256 over the provider key material with a fresh 32-byte salt
  per rewrite and a fixed context string. Envelopes are unlinkable across
  rewrites; a provider migration (see below) only changes input key material.
- Key material V0: a random 32-byte secret in the **synchronized iCloud
  Keychain** (`kSecAttrSynchronizable`, `AfterFirstUnlock`).

### Why this is acceptable for V0

The envelope (iCloud Drive) and its key (iCloud Keychain) travel in separate
Apple systems, but both are ultimately gated by the user's Apple ID + device
passcode trust circle. iCloud Keychain is end-to-end encrypted and requires an
existing trusted device or the device passcode to join. So the V0 threat model
equals "attacker who fully controls your Apple ID *and* knows your device
passcode" — the same bar as Apple Pay card provisioning.

**Auth model (ADR 0004, auto-wallet):** Face ID gates sending and seed
reveal only; balance visibility and receiving require just the unlocked
device, and a device-local keychain cache of the secrets makes normal opens
promptless. The iCloud envelope remains the cross-device source of truth.

What it does **not** give us: cryptographic enforcement that *sending* requires
biometrics. Face ID before create/unlock/send is enforced at the app layer
(`LAContext`, `deviceOwnerAuthentication` — passcode fallback allowed).
A synchronizable keychain item cannot carry a biometry-bound access control
(access controls are device-local by design), so a jailbroken device with the
user's passcode could read the key without Face ID. Accepted for V0; the
upgrade path is below.

### Upgrade path: passkey PRF (ADR 0002)

Target: a passkey scoped to `wallet.taprootwizards.com` whose **PRF extension**
output is the HKDF input. Then decryption *requires* a platform authenticator
assertion (Face ID), not just keychain access, and the same passkey syncs via
iCloud Keychain for cross-device restore. Blockers to validate: PRF extension
availability inside a Messages-extension presentation context (iOS 18+), and
associated-domains setup. The `BackupKeyProvider` protocol and the envelope's
`keyProvider` field exist so this lands as: new provider + re-seal on next
unlock. Old envelopes remain openable during migration.

## What the server can never see

`server/` (optional, not used by default in V0) proxies public chain data.
By design it must never receive: private keys, seeds, PRF outputs, or even
xpubs/descriptors (V0 privacy choice, ADR 0003 — the client queries by
address, accepting leakage to the API provider instead of giving anyone a
permanent watch-only map of user wallets).

## Ordinal/UTXO hygiene

Not applicable — this wallet handles plain BTC only; no inscriptions logic.

## Residual risks / accepted tradeoffs (V0)

- **Apple ID compromise + device passcode** → funds. Mitigation: keep
  balances small (this is a chat wallet, not cold storage); passkey-PRF
  upgrade tightens this.
- **iCloud Drive off / out of space** → the store falls back to app-local
  storage so create/restore keep working, and Home shows an "iCloud
  unavailable" banner: the wallet is then unprotected against device
  loss/uninstall until iCloud returns. V1 should re-attempt iCloud
  migration automatically and optionally add an advanced manual seed
  export (open decision in the spec).
- **Address-query privacy leak** to the public Esplora provider (ADR 0003).
- **No spend limits/cosigner** — hidden by design in V0; real policy only
  makes sense with a server cosigner, explicitly out of scope.
- **Clipboard** — receive addresses are copied to the system clipboard on
  tap; that is user-initiated and standard for wallets.

## Reviewer checklist for changes touching key material

- No new persistence of `WalletSecrets` or the mnemonic (search for
  `mnemonic` — it must appear only in WalletKit internals and tests).
- No logging of envelope contents, key material, or addresses alongside user
  identifiers.
- Backup format changes bump `version` and keep old versions decryptable.
- Any new key provider goes through `BackupKeyProvider` and stamps
  `keyProvider` in the envelope.
