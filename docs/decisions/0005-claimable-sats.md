# ADR 0005: Claimable sats — send bitcoin to people who don't have Satchel

**Status:** accepted (2026-07-12)

## Problem

The magic Satchel promises is "text bitcoin to anyone in your contacts."
But an on-chain send needs the recipient's address, which needs the
recipient to have a wallet, which needs them to have the app. Identity
directories (phone → address) require a server and a privacy-hostile
registry — rejected under the no-server policy (see ADR 0003 and
docs/launch-blockers.md).

## Decision: sender-funded claim vouchers, secret carried by iMessage

A "gift" is a tiny single-purpose wallet the sender creates and funds:

1. **Sender:** Satchel generates a throwaway BIP39 mnemonic (the *claim
   secret*), derives its first address, and sends the gift amount there
   with a normal on-chain transaction from the sender's wallet (Face ID,
   review sheet — it's a spend like any other).
2. **Transport:** the claim secret rides inside the iMessage card's URL
   payload. iMessage is end-to-end encrypted, so the secret reaches
   exactly the conversation's participants — no server, no directory,
   no address exchange. **The message is the money.**
3. **Recipient:** taps the card. If they have Satchel (auto-wallet means
   they have a wallet the instant they install it), the app rebuilds the
   claim wallet from the secret, checks the chain, and **sweeps** the
   funds into their own wallet. Claiming is receiving — no Face ID.
4. **Reclaim:** the sender keeps a local record of every outstanding
   gift (secret, amount, expiry). Until it's claimed, the sender can
   sweep it back — offered in the UI as "Cancel" before expiry and
   surfaced prominently after (default expiry: 14 days, advisory).

Both parties hold the claim secret, so whoever sweeps first wins; the
chain is the arbiter and double-claims are impossible.

## Why a throwaway *wallet* instead of a bare key

The claim wallet is just `WalletEngine` with generated secrets and a
temp cache directory — sweep is the existing `createSignedDrain`. Zero
new cryptography, zero new signing paths; the entire feature reuses
audited machinery.

## Honest properties (these go in the UI copy)

- **Bearer instrument.** Anyone who can read the message can take the
  money: forwarded card, stolen unlocked phone, iMessage backup on a
  compromised account. This is "mailing cash" — appropriate for
  coffee-money, not rent. UI enforces a soft cap warning and shows
  "anyone with this message can claim it" at send time.
- **Two transactions, two fees.** Funding fee paid by sender on top;
  sweep fee comes out of the gift. Minimum gift is 3,000 sats so a
  sweep at modest fee rates never leaves dust.
- **Expiry is advisory,** not consensus-enforced: after 14 days Satchel
  nudges the sender to reclaim, but an unclaimed gift remains claimable
  until someone sweeps it.
- **Transcript persistence:** the secret lives in the Messages
  transcript (encrypted at rest by Apple, synced via Messages in
  iCloud). Deleting the message after claim is good hygiene, not a
  requirement — a swept voucher is worthless.

## Card protocol

`https://wallet.taprootwizards.com/claim?v=1&m=<mnemonic>&sats=<n>&exp=<unix>`
— same URL-namespace convention as `/pay` and `/paid`; the web fallback
page (launch-blockers item 3) should eventually render "you've been
sent bitcoin — get Satchel to claim it" *without* echoing the secret
into any analytics-bearing context (static page, no logging).

## Rejected alternatives

- **Phone-number-derived addresses:** public input ⇒ anyone derives the
  key. Cryptographically unsound, full stop.
- **Directory lookup (BIP353/Lightning-address style):** needs a server
  and creates the identity→wallet map we refuse to hold.
- **Silent payments (BIP352):** solves address reuse between *existing*
  wallets; doesn't solve pre-install sending, and light clients can't
  scan without an index server. Reconsider post-launch.
