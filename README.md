# Satchel — the iMessage Bitcoin Wallet

A standalone Bitcoin wallet that lives entirely inside Messages. No normal
mobile app, no account, no backend dependency for custody. Open Messages, tap
**Create Bitcoin Wallet**, Face ID flashes — and you have a wallet you can
fund, share, restore, and spend from without ever learning wallet
infrastructure exists.

- **Non-custodial** — the seed is generated on device and never leaves it unencrypted.
- **No seed phrase shown** — backup is an encrypted bundle in the user's own iCloud.
- **Face ID before every send** (device passcode fallback).
- **On-chain BTC only** in V0. No Lightning. No visible spend policy.

## Repo layout

```
imessage-bitcoin-wallet/
├── app/                    iOS app (Swift — Messages extensions can't be built in JS/TS)
│   ├── project.yml         XcodeGen project definition (the .xcodeproj is generated)
│   ├── HostApp/            Required container app (single "open Messages" screen)
│   ├── MessagesExtension/  The actual product: SwiftUI UI inside Messages
│   └── WalletKit/          Swift package: wallet engine (BitcoinDevKit), backup crypto, iCloud store
├── server/                 Optional backend (TypeScript/Hono): Esplora proxy + fee estimates
└── docs/                   Architecture, security model, decision records
```

**Why Swift at all?** iMessage app extensions are a native-only target — React
Native/Expo/Capacitor cannot produce a Messages extension. The Swift surface is
kept deliberately thin: all Bitcoin logic (BIP39/84/86 derivation, coin
selection, PSBT construction, signing, Esplora sync) is
[BitcoinDevKit](https://bitcoindevkit.org) — we write zero hand-rolled crypto.
Everything server-side is TypeScript.

## Getting started (iOS app)

Prereqs: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
cd app
xcodegen generate          # produces Satchel.xcodeproj
open Satchel.xcodeproj
```

Then in Xcode: set your team under Signing & Capabilities, pick a simulator or
device, and run the **Satchel** scheme. In the simulator, open Messages →
any conversation → app strip → Satchel.

- **Debug builds run on standard signet** (free coins from e.g.
  [signetfaucet.com](https://signetfaucet.com), ~10-minute blocks). Release
  builds are mainnet. Override with the `WALLET_NETWORK` build setting.
- Real Face ID, iCloud Drive, and iCloud Keychain behavior needs a physical
  device signed into iCloud; the simulator approximates them.

Unit tests:

```bash
cd app/WalletKit && swift test    # engine, backup crypto, payment requests
```

## Getting started (server — reference only, not deployed)

**Product policy: no Taproot Wizards server.** Everything runs on device
against public APIs; users never depend on TW as a third party. The only
hosted pieces are static files (AASA, card-URL fallback page, privacy
policy) — see [docs/launch-blockers.md](docs/launch-blockers.md). This
directory is kept as reference code (Esplora proxy + fee estimates + AASA
route) in case the policy ever changes; it holds **no keys, no seeds, no
xpubs, no accounts**.

```bash
cd server
npm install
npm run dev        # http://localhost:3040
npm test
```

Endpoints: `GET /healthz`, `GET /v1/fees`, and an Esplora subset under
`/esplora/*` (`address/:a`, `address/:a/utxo`, `address/:a/txs`, `tx/:txid`,
`tx/:txid/status`, `tx/:txid/hex`, `POST /tx`, `blocks/tip/height`,
`fee-estimates`). Point the app at it by changing `ChainConfig`.

Config via env: `PORT`, `ESPLORA_UPSTREAM` (default `https://mempool.space/api`),
`MEMPOOL_UPSTREAM` (optional, for `/v1/fees/recommended`), `FEE_CACHE_SECONDS`.

## How it works

Read [docs/architecture.md](docs/architecture.md) for the full picture and
[docs/security-model.md](docs/security-model.md) for the trust analysis. The
one-paragraph version:

On create, the extension generates a BIP39 mnemonic on device and derives a
BIP84 descriptor wallet via BitcoinDevKit. The secret bundle is encrypted
(ChaCha20-Poly1305, key via HKDF from a random 32-byte secret that lives in the
user's **iCloud Keychain**) and written to the user's **iCloud Drive** container.
Restore on a new iPhone = same Apple ID → backup file + key material both sync
down → Face ID → decrypt → deterministic rescan. Receiving derives fresh
addresses and shares them as interactive iMessage cards (BIP21 + QR); sending
builds and signs a PSBT locally after a Face ID prompt and broadcasts through
an Esplora API.

## Status / roadmap

Implementation phases (from the product spec) and where they stand:

| Phase | Status |
| --- | --- |
| 1. iMessage SwiftUI shell | ✅ built |
| 2. Wallet creation + deterministic derivation | ✅ built (BDK, BIP84 default, BIP86 supported) |
| 3. Encrypted iCloud backup + restore | ✅ built (synced-keychain key path) |
| 4. Receive card insert/send | ✅ built |
| 5. Balance/UTXO lookup | ✅ built (Esplora sync) |
| 6. PSBT construction + signing | ✅ built |
| 7. Broadcast + tx status | ✅ built |
| 8. Face ID/passkey unlock polish | 🔶 Face ID done; passkey-PRF provider implemented, activates once the AASA file is live on wallet.taprootwizards.com (ADR 0002) |
| 9. Reinstall/restore testing | ⬜ needs physical devices |
| 10. Physical iPhone testing | ⬜ needs signing + devices |

Open decisions are captured as ADRs in [docs/decisions/](docs/decisions/).
