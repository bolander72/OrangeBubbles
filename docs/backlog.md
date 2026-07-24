# Backlog — considered, deliberately deferred

Parked items with their reasoning, so future-us doesn't re-litigate from
scratch. Everything here fits the no-TW-server policy or documents where
that policy bites.

## 1. Home Screen / Lock Screen widget (and Watch complication)

Glanceable balance + recent transactions without opening Messages — the
server-free answer to "can I see my balance in Apple Wallet?" (PassKit
passes can only update via a web service + APNs, i.e. a server, so Apple
Wallet is out under the policy.)

Sketch: App Group shared container; the Messages extension writes a
watch-only snapshot (balance, recent txs, timestamp — never keys) on every
refresh; a WidgetKit extension on the host app renders it with honest
"as of" freshness, optionally refreshing on iOS's ~15-min widget budget by
querying Esplora directly with watch-only addresses. Lock Screen privacy
via native widget redaction (blur until Face ID). Bonus: gives the host
app a real purpose, which App Review likes.

**Trigger to build:** after first on-device dogfooding round.

## 2. TestFlight / device-build tooling

An archive + export script (`xcodebuild archive` → `exportArchive` with an
ExportOptions.plist) and a versioning convention, so device builds and
TestFlight uploads are one command instead of Xcode clicking.

**Trigger to build:** the moment Apple Developer enrollment clears —
nothing to do before there's a team to sign with.

## 3. Dollar-denominated amount entry

We display ≈USD everywhere, but amounts are *entered* in sats. Letting
users type "$5" means choosing which number is authoritative when the rate
moves between typing and broadcast, and stale-rate UX at send time.

**Trigger to build:** real-user feedback saying sats entry is a blocker —
not before; the ambiguity cost is real and the workaround (glance at the
≈USD line while typing) is decent.

## 4. Siri / Shortcuts / Apple Intelligence via App Intents

One framework — **App Intents** — is the integration surface for Siri
voice queries, the Shortcuts app, Spotlight, *and* Apple Intelligence
action invocation. Building a handful of intents lights up all four.

The key enabler is the **watch-only descriptor split**: the extension can
export the wallet's *public* descriptor (xpub) plus a state snapshot into
the App Group — never the seed. With that, the host app / intents can
answer read queries and even derive fresh receive addresses without any
key material:

- "What's my bitcoin balance?" → reads the shared snapshot (same one the
  widget uses; these two features share ~all their plumbing).
- "Give me a bitcoin receive address" → derived watch-only, shown with QR.
- **Sending stays out of Siri.** SiriKit's payments domain
  (`INSendPaymentIntent`) exists, but voice-initiated irreversible bitcoin
  transfers are a scam/mis-hearing surface we don't want; sends remain
  Face ID + review sheet in Messages, deliberately.

**Trigger to build:** together with the widget (item 1) — shared App Group
plumbing — after first on-device dogfooding.

## 5. On-device AI (Foundation Models framework)

Apple's Foundation Models framework (iOS 26) exposes the on-device LLM to
apps — **fully on-device, so it fits the no-server policy exactly**.
Plausible uses, in descending order of seriousness:

- Natural-language payment parsing: "request 20 bucks from this chat" →
  prefilled receive card (amount via the display rate).
- Plain-English activity summaries ("you received 2 payments this week").
- Answering security-model questions conversationally (the explainer
  sheet as a mini-assistant).

None of these are V1-critical; all are differentiators for a "wallet that
lives where you talk." Revisit once the core is shipped and the host app
has App Group plumbing.

**Trigger to build:** post-launch polish round; requires iOS 26+ devices.

## 6. Clipboard address-poisoning guard (no AI needed)

Real attack: malware/lookalike contacts get a victim to pay an address
whose first/last characters match a legitimate one (users verify only the
ends). Cheap on-device defense in Send: warn when a pasted address
*almost* matches one previously paid (matching prefix/suffix, different
middle), and encourage QR/card flows over paste. Zero privacy cost.

**Trigger to build:** before mainnet default flips on (it's a
real-money protection).

## 7. Universal Links for card URLs

Once the static site exists, add `applinks:wallet.taprootwizards.com` to
associated domains so tapping a card URL *outside* Messages (forwarded
link, Android→iPhone handoff) opens the app instead of Safari. Needs the
host app to grow a minimal "open this payment in Messages" hand-off view.

**Trigger to build:** with the static site (launch-blockers item 3).

## 8. Spending Connections (MagicPay integration)

Fully specced in [ADR 0006](decisions/0006-spending-connections.md):
capped, revocable allowance wallets derived from the wallet passkey via
per-connection PRF salts — the cap is the balance, enforced by
consensus. OrangeBubbles side is ~70% reusable from gift machinery.

**Trigger to build:** MagicPay team commits to their side (native PRF
assertion + AASA entry); build OB side behind a debug flag first.

## 9. Privacy ladder

Posture and sequencing decided in
[ADR 0007](decisions/0007-privacy-posture.md): Tier 1 network privacy
(own-node endpoint, Tor evaluation, change hygiene) → BIP352 silent
payments → PayJoin. Mixing rejected permanently (legal); "ZK payments"
don't exist on Bitcoin; ecash parked as a deliberate philosophical
question.

**Trigger to build:** Tier 1 alongside the next infrastructure pass;
BIP352 when light-client indexes mature.

## 10. Multi-device same-wallet writes — accepted behavior

Two iPhones on one Apple ID can both unlock the wallet and race the backup
reseal (last writer wins; `NSFileCoordinator` prevents torn writes; the
`.previous` envelope generation protects against a bad seal). Worst case
is stale receive/change index *hints*, which the restore full-scan (stop
gap 25) absorbs. Funds are never at risk; duplicate address handout across
two devices used simultaneously is possible but harmless (both are ours).

**Decision:** accepted for V1. Revisit only if support data shows real
users actively sending from two devices at once — the fix (conflict-aware
envelope merging) isn't worth its complexity today.
