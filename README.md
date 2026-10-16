# OrangeBubbles — the orange bubble in your chats

A standalone Bitcoin wallet that lives entirely inside Messages. No app to
set up, no account, no server. Open OrangeBubbles in a conversation and the
wallet is simply there — auto-created, backed up to your own iCloud, ready
to receive. Face ID appears exactly when money moves.

- **No wallet ceremony** — silent create/restore on first open (ADR 0004).
- **Non-custodial, serverless** — keys on device; encrypted backup in the
  user's own iCloud; chain data straight from public Esplora APIs.
- **Send to anyone — even without the app**: claimable gifts ride inside
  the iMessage card itself (ADR 0005).
- **Face ID guards spending and the recovery phrase**; balance and
  receiving are mailbox-open.
- **On-chain BTC only** in V1. No Lightning yet.

## Repo layout

```
orangebubbles/
├── app/                    iOS app (Swift — Messages extensions can't be built in JS/TS)
│   ├── project.yml         XcodeGen project definition (the .xcodeproj is generated)
│   ├── HostApp/            Required container app (single "open Messages" screen)
│   ├── MessagesExtension/  The actual product: SwiftUI UI inside Messages
│   ├── WalletWidget/       Home/Lock Screen balance widget (watch-only snapshot)
│   ├── Shared/             App Group snapshot shared with widget + Siri intents
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
xcodegen generate          # produces OrangeBubbles.xcodeproj
open OrangeBubbles.xcodeproj
```

Then in Xcode: set your team under Signing & Capabilities, pick a simulator or
device, and run the **OrangeBubbles** scheme. In the simulator, open Messages →
any conversation → app strip → OrangeBubbles.

- **Debug builds run on standard signet** (free coins from e.g.
  [alt.signetfaucet.com](https://alt.signetfaucet.com), ~10-minute blocks). Release
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

On first open the extension silently generates a BIP39 mnemonic and derives
a BIP84 descriptor wallet via BitcoinDevKit. The secret bundle is encrypted
(ChaCha20-Poly1305, key via HKDF from a random 32-byte secret in the user's
**iCloud Keychain** — upgradeable to passkey-PRF in Settings) and written to
the user's **iCloud Drive**; a device-local keychain cache makes every later
open instant and promptless. New iPhone, same Apple ID → the wallet restores
itself and rescans. Receiving shares fresh addresses as card images in the
chat (BIP21 + QR); sending signs a PSBT locally behind Face ID and
broadcasts via public Esplora APIs with multi-endpoint failover. Gifts fund
a one-time claim wallet whose secret travels inside the iMessage card —
recipients sweep it the moment they install.

## Status

The original V0 spec (phases 1–10: shell, derivation, backup/restore,
cards, sync, signing, broadcast, Face ID, reinstall testing, physical
device testing) is **complete and field-tested on a real iPhone** with
real signet coins — including cross-device payments, camera QR sends, and
iCloud restore across reinstalls.

Shipped beyond the original spec:

- **Auto-wallet** — no creation ceremony at all (ADR 0004)
- **Claimable gifts** — send bitcoin to people without the app; the claim
  secret rides in the iMessage card, sender can reclaim (ADR 0005)
- Live in-chat balance refresh, tappable cards with live chain status and
  in-place bubble updates, Send Max, RBF speed-up, dust guard,
  address-poisoning warnings, BIP21 + QR scanning, smart amount entry
  ("$5", "21k sats"; on-device AI on iOS 26+), fiat display,
  Home/Lock Screen widget, Siri/Shortcuts intents (read-only by design),
  recovery-phrase escape hatch, and a semantic color system

Remaining before public release (needs the org account/domain, not code):
[docs/launch-blockers.md](docs/launch-blockers.md). The one dormant
feature: **passkey-PRF backup encryption** is fully implemented behind
Settings → "Upgrade to passkey protection", and activates once a domain
serves the AASA file (ADR 0002; relying-party domain TBD). Deferred ideas
with triggers live in [docs/backlog.md](docs/backlog.md); decisions are
ADRs in [docs/decisions/](docs/decisions/).
