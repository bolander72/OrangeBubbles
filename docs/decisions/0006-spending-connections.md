# ADR 0006: Spending Connections — capped, revocable delegation to MagicPay

**Status:** proposed (2026-07-21) — OrangeBubbles-side buildable now;
requires MagicPay-side integration (see §7)

## 1. Problem

Users want to pay with their OrangeBubbles bitcoin inside other
experiences (first target: MagicPay checkout) without re-approving in
Messages every time — but with real, user-set constraints: a spending
cap and a timeframe, revocable at will.

Two naive designs fail:

- **Share the wallet passkey ceremony as-is.** Its PRF output decrypts
  the full seed; any "limit" would be enforced only by the connected
  app's good behavior. A limit the limited party enforces is not a
  limit.
- **A policy server that cosigns within limits.** Real enforcement, but
  it makes a company server a spending dependency — rejected under the
  standing no-server policy.

## 2. Decision

A **connection is a separate, purpose-built allowance wallet** whose
seed both parties can derive from the *same passkey* using a
*connection-specific PRF salt*, and whose **balance is the spending
limit** — enforced by Bitcoin itself, not by policy code.

Key insight: the WebAuthn PRF extension is salted. Different salt ⇒
cryptographically independent 32-byte output from the same credential,
each gated by its own Face ID ceremony:

| Salt | Output unlocks |
| --- | --- |
| `orangebubbles/backup-key/v1` (frozen) | Main wallet backup — **never leaves OrangeBubbles** |
| `orangebubbles/connection/v1\|<connectionID>` | One allowance wallet — derivable by any app on the domain's AASA |

The main seed's salt is never used outside OrangeBubbles; a connected
app cannot reach the main wallet even in principle.

## 3. Derivation scheme

```
connectionID     = UUIDv4, minted by OrangeBubbles at connection time
connectionSalt   = SHA-256("orangebubbles/connection/v1|" + connectionID)
prfOutput        = PRF(passkey, connectionSalt)        // 32 bytes, Face ID-gated
allowanceEntropy = prfOutput
allowanceSeed    = BIP39 mnemonic from allowanceEntropy (24 words)
allowanceWallet  = BIP84 descriptor wallet from allowanceSeed (network per build)
```

Properties:

- **The connectionID is not a secret.** Knowing it yields nothing
  without a passkey assertion, which only the user's enrolled devices
  can perform, and only inside apps associated with the relying-party
  domain. It can travel in plaintext links/QRs during setup.
- **Deterministic on both sides.** OrangeBubbles and MagicPay derive
  identical wallets from (passkey, connectionID) with zero shared
  storage, zero servers, zero synced state.
- Both sides MUST derive lazily and hold the seed in memory only;
  nothing about the allowance is persisted except the connectionID,
  label, cap, and expiry (the "connection ledger", mirroring the gift
  ledger of ADR 0005).

## 4. Flows

### Connect (in OrangeBubbles)
1. Entry: "Connect MagicPay" (or an incoming `orangebubbles://connect`
   request from the MagicPay app carrying a display name + callback).
2. User picks **cap** (e.g. 25,000 sats) and **timeframe** (e.g. 30
   days). Copy states plainly: *"MagicPay will be able to spend up to
   this amount without asking. You can take back whatever's left at any
   time."*
3. OrangeBubbles mints `connectionID`, derives the allowance address
   (one passkey ceremony), and funds it from the main wallet — a normal
   Face ID-reviewed send. Records `{connectionID, label, cap,
   fundingTxid, expiresAt}` in the connection ledger.
4. Hands `{connectionID, network}` to MagicPay via its callback URL.

### Pay (in MagicPay)
1. Checkout taps "Pay with OrangeBubbles" → MagicPay asserts the
   passkey with the connection salt (**paying = one Face ID**), derives
   the allowance wallet, syncs it (Esplora, same public-API model),
   builds/signs/broadcasts the payment.
2. Insufficient allowance ⇒ MagicPay deep-links back to OrangeBubbles
   with a top-up request; topping up is another explicit, reviewed send.

### Monitor / revoke (in OrangeBubbles)
- Home shows connections like outstanding gifts: label, **remaining
  balance (live from chain)**, expiry countdown.
- **Disconnect** = sweep remaining funds to the main wallet (the user
  derives the same key). Nobody can veto it; the chain arbitrates
  races exactly as with gift reclaim (ADR 0005).
- At expiry, OrangeBubbles nags to reclaim; auto-reclaim on next open
  is a product option.

## 5. Security analysis

- **Cap enforcement: consensus-grade.** The allowance wallet holds N
  sats; no signature can spend more. Compromise of MagicPay (or of the
  connection salt scheme itself) is bounded to the allowance balance.
- **Main-wallet isolation: cryptographic.** Independent PRF salts;
  MagicPay never receives the backup salt, the envelope, or anything in
  the main wallet's derivation path.
- **Every derivation is a Face ID ceremony**, platform-enforced (same
  PRF property as ADR 0002). No stored allowance key at rest on either
  side.
- **Expiry is advisory in v1**, exactly like gift expiry: both parties
  hold the key, so the timeframe is a reclaim reminder, not consensus
  law. See §8 for why hard expiry is deferred.
- **Privacy:** MagicPay observes the allowance wallet's chain activity
  only — not the main wallet. Allowance funding does link one main-
  wallet UTXO to the connection on-chain (same tradeoff class as
  ADR 0003).

## 6. Constraint semantics (what "limit" and "timeframe" really mean)

| Constraint | Enforced by | Strength |
| --- | --- | --- |
| Spend cap | UTXO balance | Consensus — absolute |
| Revocation | User sweep (user holds key) | Chain-arbitrated — cannot be blocked |
| Timeframe | Reclaim UX + nagging | Advisory |
| Per-tx / per-merchant rules | ❌ not representable | Would require a cosigner or covenants — out of scope |

## 7. MagicPay-side requirements

1. Native iOS use of `AuthenticationServices` with the PRF extension
   (iOS 18+), mirroring `PasskeyPRFKeyProvider`.
2. Its app ID added to the relying-party domain's AASA
   `webcredentials.apps`. (AASA entries may span Apple teams — no org
   consolidation required, though it's expected eventually.)
3. **The ceremony must run in a full app process** — not an app
   extension. Empirically verified (2026-07-21, iPhone 17 Pro, iOS 26):
   WebAuthn association checks fail with error 1004 in appex contexts.
4. Wallet mechanics identical to OrangeBubbles' ClaimVoucher sweep path
   (BDK descriptor wallet, Esplora sync/broadcast) — reusable if
   MagicPay adopts WalletKit.

## 8. Deferred: consensus-enforced expiry

True "MagicPay cannot spend after date T" is not expressible with
shared single keys: Bitcoin script has after-T conditions (CLTV/CSV)
but no before-T condition on a key path. Honest options, all deferred:
2-of-2 with per-payment user cosigning (defeats the UX), pre-signed
reclaim transactions (guarantees the user's exit, still doesn't stop
pre-expiry… which is the allowed window anyway), or future covenant
opcodes. In practice the cap + unilateral revocation are the load-
bearing guarantees; the timeframe is hygiene.

## 9. Relationship to prior ADRs

- ADR 0002/0004: same passkey, same freeze-at-launch salt discipline —
  `orangebubbles/connection/v1` joins the frozen-string list at launch.
- ADR 0005: connections are gift vouchers with a passkey instead of a
  mnemonic-in-a-message, and a counterparty instead of a recipient —
  same ledger UX, same sweep code, same race semantics.
- ADR 0003 / no-server policy: fully preserved. No server ever holds or
  derives key material; both sides talk only to public chain APIs.
