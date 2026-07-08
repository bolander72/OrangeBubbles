# ADR 0002: Passkey PRF preferred, synced-keychain fallback

**Status:** accepted (2026-07-07); PRF implemented same day, pending
on-device validation

## Decision

The preferred key path is a passkey scoped to `wallet.taprootwizards.com`
whose **PRF extension** output is the HKDF input
(`PasskeyPRFKeyProvider`, iOS 18+). New wallets attempt PRF first;
if registration fails at runtime (domain/AASA unreachable, pre-iOS-18,
user declines), creation falls back to HKDF(random 32-byte secret in the
**synchronized iCloud Keychain**) gated by an LAContext Face ID prompt.
Restore always uses the provider recorded in the envelope's `keyProvider`
field, and never registers a fresh passkey (a new credential has a new PRF
output and could not decrypt the backup).

## Activation checklist (PRF is dormant until these are done)

1. Serve the AASA file at
   `https://wallet.taprootwizards.com/.well-known/apple-app-site-association`
   with `webcredentials.apps = ["<TEAMID>.com.taprootwizards.imessagewallet.MessagesExtension"]`
   — the server has the route (`APPLE_APP_IDS`); static hosting works too.
2. Real signing with the associated-domains entitlement (already in
   project.yml) and the Associated Domains capability on the app ID.
3. On-device validation of the two risky assumptions: PRF availability
   inside a Messages-extension `ASAuthorization` context, and identical PRF
   output across devices after iCloud Keychain passkey sync. Two iPhones,
   one afternoon.

## Why not PRF first

Unvalidated risks, each fatal to a one-tap V0 if hit late:

1. PRF requires iOS 18+ and its behavior inside a Messages extension's
   `ASAuthorizationController` presentation context is undocumented.
2. Passkey registration needs associated domains + an AASA file on a real
   domain — infrastructure V0 doesn't otherwise need.
3. PRF output must be identical across devices for restore to work; this is
   specified, but we want to verify it on hardware before betting backups on it.

The synced-keychain path gives the same UX (Face ID gate, no seed phrase,
cross-device restore via iCloud) with a weaker cryptographic story —
biometrics are enforced by the app layer, not by key derivation. See
docs/security-model.md for the exact tradeoff.

## Migration plan for existing keychain-sealed wallets

Deliberately **not** automatic: silently presenting a passkey-registration
sheet during unlock would be confusing. Ship a one-time "Upgrade wallet
protection" action later (decrypt with keychain provider → register passkey
→ reseal → stamp `keyProvider: "passkey-prf"`). The keychain provider stays
readable indefinitely; the envelope's `keyProvider` field routes each backup
to the right path.
