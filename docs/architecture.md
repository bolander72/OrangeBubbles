# Architecture

## Components

```
┌─────────────────────────── iPhone ───────────────────────────┐
│                                                               │
│  Messages.app                                                 │
│  └── Satchel (MSMessagesAppViewController)              │
│      ├── SwiftUI UI (MessagesExtension/)                      │
│      │     RootView → Welcome / Home / Receive / Send         │
│      ├── WalletStore  — app state machine, Face ID gating     │
│      └── WalletKit (Swift package)                            │
│          ├── WalletEngine   — BitcoinDevKit descriptor wallet │
│          ├── BackupCrypto   — ChaCha20-Poly1305 + HKDF        │
│          ├── BackupKeyProvider — synced iCloud Keychain key   │
│          ├── ICloudBackupStore — iCloud Drive JSON envelope   │
│          └── FeeEstimator / ChainConfig / PaymentRequest      │
│                                                               │
│  Local storage: BDK sqlite chain cache (Application Support)  │
│  iCloud Keychain: 32-byte backup encryption secret (synced)   │
│  iCloud Drive:   wallet-backup.v1.json (encrypted envelope)   │
└───────────────┬───────────────────────────────────────────────┘
                │ HTTPS (Esplora API)
                ▼
   mempool.space/api  (V0)   ──later──▶   server/ (TS proxy on our domain)
</code>
```

## Key model

- Seed: 12-word BIP39 mnemonic, generated on device by BDK, held in memory
  only while the extension session is unlocked.
- Derivation: BIP84 native SegWit (`wpkh(m/84'/…)`) external + internal
  descriptors. BIP86 Taproot is implemented and one enum value away
  (ADR 0001).
- Token of identity: none. There are no accounts. The wallet *is* the seed;
  possession of the user's iCloud (file + keychain) plus their
  biometrics/passcode is the entire access model.

## Backup format

`iCloud Drive → <container>/Documents/wallet-backup.v1.json`:

```json
{
  "version": 1,
  "cipher": "chacha20poly1305+hkdf-sha256",
  "keyProvider": "synced-keychain",
  "salt": "<base64, 32B, fresh per rewrite>",
  "sealed": "<base64: nonce ‖ ciphertext ‖ tag>",
  "network": "bitcoin",
  "scriptType": "bip84",
  "createdAt": "2026-07-07T00:00:00Z"
}
```

Plaintext inside `sealed` is the `WalletSecrets` JSON: mnemonic, network,
script type, receive/change index hints, creation timestamp. Index hints are
advisory — restore always follows with a BDK full scan (stop gap 25).

The envelope is resealed (fresh salt/nonce) whenever new addresses are
revealed, so index hints stay current and rewrites are unlinkable.

## Flows

### Create
1. Face ID (`deviceOwnerAuthentication`) →
2. `WalletEngine.generateSecrets` (BIP39 on device) →
3. engine boots on a local sqlite cache →
4. random 32-byte key created in **synced** iCloud Keychain →
5. secrets sealed → envelope written to iCloud Drive →
6. Home shows a fresh receive address flow.

### Receive
`revealNextAddress` → backup resealed with new index hint → BIP21 URI + QR →
optional amount → `MSMessage` card inserted into the conversation (user still
taps iMessage send). Tapping the card on the recipient side opens Send
prefilled.

### Send
Address/amount (or prefilled from a tapped card) → fee tier (slow/normal/fast
from mempool.space, fallback Esplora `fee-estimates`) → **Face ID** →
`TxBuilder` builds + signs PSBT (BDK coin selection) → review sheet shows
true fee from the signed tx → broadcast via Esplora `POST /tx` → "Sent" card
with txid link back into the chat. A >75%-of-balance send shows an extra
warning (the only visible "policy" in V0).

### Restore
Fresh install, same Apple ID → `backupExists()` sees the iCloud file →
"Unlock with Face ID" → envelope downloaded, key read from synced keychain →
decrypt → deterministic wallet rebuilt → full scan discovers funds beyond the
index hints.

## Messages integration

Cards are `MSMessage`s whose URL encodes a `PaymentRequest` as query items
(`v`, `address`, `sats`, `label`, `txid`) under
`https://wallet.taprootwizards.com/pay` (request) or `/paid` (receipt). The
domain is currently just a namespace; when we stand it up for real it should
serve a web fallback for non-iOS recipients showing the BIP21 link.

## Network selection

`WALLET_NETWORK` build setting → Info.plist `WalletNetwork` → `ChainConfig`.
Debug = standard signet (faucet money, ~10-minute blocks — good for
demoing the full send/receive loop). Release = mainnet.

## Concurrency

BDK calls are blocking; `WalletStore` (a `@MainActor ObservableObject`) hops
them off the main thread via `Task.detached`. One engine instance per session;
Messages extensions are short-lived so there is no long-running sync loop —
`refresh()` runs on activation and after sends.
