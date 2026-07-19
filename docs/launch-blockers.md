# Launch blockers — things code can't fix yet

These are the items standing between the current build and a public App
Store release that **cannot be done in this repo** — they need an Apple
organization account and/or the `wallet.taprootwizards.com` domain.
Everything here honors the standing product policy:

> **No Taproot Wizards server.** Users must never depend on TW as a third
> party for their money. Static file hosting (no request handling, no user
> data, no logs tied to wallets) is acceptable; anything that processes
> user requests is not. The `server/` directory in this repo is *reference
> code only* and is not part of the launch plan.

## 1. Apple organization enrollment (longest pole — start first)

**App Review Guideline 3.1.5(iii): apps that facilitate storage or
transfer of cryptocurrency must be submitted by developers enrolled as an
organization.** An individual account cannot ship this app publicly,
period.

- Enroll **Taproot Wizards** as an Organization at
  developer.apple.com/enroll: requires a **D-U-N-S number** for the legal
  entity, a verifiable public presence, and someone with legal authority
  to bind the company. Check for an existing D-U-N-S first
  (Apple's lookup: developer.apple.com/enroll/duns-lookup) — requesting a
  new one adds days.
- Budget **2–4 weeks** end to end (D-U-N-S + Apple verification, which
  often includes a phone call).
- Mike's individual account remains the day-to-day dev/test vehicle;
  nothing built under it is wasted. When the org account exists: register
  the bundle IDs + iCloud container + capabilities under the org, move
  signing over, and dev/TestFlight/App Store all continue from there.
- Also required at submission: a support URL and the privacy policy URL
  (below).

## 2. Privacy policy at a public URL

App Review requires a privacy policy link for every app; wallets get extra
scrutiny. Ours is straightforward and true:

- No accounts, no analytics, no tracking, no data collection by TW.
- Keys are generated and stay on device; the encrypted backup lives in the
  *user's* iCloud, unreadable by TW or Apple (documented in
  `docs/security-model.md`).
- The app talks directly to public Bitcoin APIs (mempool.space) for chain
  data and price display; those providers see IP + queried addresses, per
  ADR 0003.
- App Privacy "nutrition label" answers: **Data Not Collected** across the
  board (verify nothing changes before each submission).

Host it as a static page on the same site as items 3–4. One afternoon of
writing once the domain exists.

## 3. Static site at wallet.taprootwizards.com

One static site (Cloudflare Pages / GitHub Pages / S3 — anything that
serves files) unlocks three things at once. No server code, no logs
requirement, no user data:

| Path | Purpose |
| --- | --- |
| `/.well-known/apple-app-site-association` | Passkey (PRF) domain association — the file that activates ADR 0002's end-state encryption. JSON with `webcredentials.apps = ["<TEAMID>.com.goldencompany.satchel.MessagesExtension"]`. Must be served as `application/json`, no redirect. |
| `/pay` and `/paid` | Card-URL fallback. Every payment card carries `https://wallet.taprootwizards.com/pay?address=…&sats=…`. On Android/desktop/forwarded contexts that's currently a dead link. A static page (client-side JS reads the query string) should render the amount, address, QR / `bitcoin:` URI, and an App Store link. No data leaves the page. |
| `/privacy` | Item 2. |

After the AASA file is live and the app runs on a real signed device,
do the **two-iPhone PRF validation** from ADR 0002 before trusting
passkey-sealed backups.

## 4. Public Esplora rate limits (resolved on-device — no proxy)

A restore full-scan fires ~50 requests at mempool.space; hundreds of
users doing this behind shared CGNAT IPs will eventually hit rate limits.
The old plan (route through `server/`) is **rejected** under the
no-server policy. On-device mitigations, in order:

1. **Multi-endpoint failover** in `ChainConfig` — ✅ implemented:
   mainnet ships an ordered endpoint list (mempool.space →
   blockstream.info) and sync/broadcast/status checks rotate on
   connectivity failures. No third party gains a privileged position.
2. **Sync discipline** (already in place): incremental
   sync-with-revealed-SPKs for normal opens; full scans only on restore.
3. **User-configurable endpoint** (advanced setting, later): sovereign
   users can point the app at their own esplora/electrs — the strongest
   form of "not relying on us."
4. If volume ever demands a paid API key, that key belongs to a
   **commercial provider relationship, not a TW server** — traffic still
   goes device → provider.

## Sequencing

```
now ──────────────► org enrollment (2–4 wks, blocks App Store only)
now ──────────────► static site: AASA + /pay fallback + /privacy (1 day)
after AASA ───────► PRF two-device validation (1 afternoon)
before submission ► privacy labels + support URL + review notes
at scale ─────────► esplora failover list (client release)
```
