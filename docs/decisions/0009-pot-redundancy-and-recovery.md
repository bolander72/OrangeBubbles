# ADR 0009: Pot redundancy & recovery — surviving lost phones and departed members

**Status:** in progress (2026-08). Built: Layer 1 (iCloud-Keychain share
backup, opt-in device-only), the health model + warning card, Archive/Rejoin
(the everyday action — silent, reversible, keeps the share), and a Refresh entry
point that re-keys the chat's current members. Remaining: the automatic
**old→new sweep** on Refresh (moves real money, device-only to verify — a manual
Spend covers it for now), and liveness/`lastSeen` staleness detection (departure
is currently signalled by an explicit `.left` broadcast). Membership stays
chat-derived per the roster philosophy — to exclude someone they leave the chat,
then Refresh.

## 0. The problem, concretely

A pot is a k-of-n FROST vault. Two very different failures can lose the money,
and today we defend against neither cleanly:

1. **A member loses their phone.** Their key share is stored device-only
   (`VaultStore` uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), so the
   share is *gone*. (Glaring asymmetry: the single-sig wallet *is* iCloud-backed;
   pot shares are not.)
2. **A member goes disinterested / leaves.** They still hold a share but won't
   sign. The pot keeps working only while enough *others* remain.

These compound. In a **2-of-3** where member C has drifted away, you are
**already effectively a 2-of-2 with zero redundancy** — the theft threshold is
still 2, but your *availability* buffer is spent. If member B then loses their
phone (failure #1), only A's share remains: **1 < 2 → funds frozen forever.**

Redundancy has **two independent axes**, and we need a defense for each:

| Axis | Threatened by | Defense |
|---|---|---|
| **Per-member backup** (my share survives *my* device dying) | I lose/replace my phone | **Layer 1: iCloud-Keychain share backup** |
| **Group threshold redundancy** (the pot survives *others* vanishing) | members leave / go dark | **Layer 2: pot health + re-key ("Refresh pot")** |

Layer 1 is about *me*; Layer 2 is about *the group*. They are orthogonal and we
need both.

---

## 1. Layer 1 — per-member share backup (device-loss recovery)

**Change:** store each member's pot share in **iCloud Keychain** instead of
device-only. Concretely, `VaultStore` items become
`kSecAttrSynchronizable = true` with `kSecAttrAccessibleAfterFirstUnlock` (drop
`ThisDeviceOnly`), mirroring how the single-sig wallet is already protected.
Optionally passkey-seal the share (Face ID gate) exactly like the wallet backup.

**Effect:** lose your phone → sign into iCloud on a new one → your share syncs
back → you are a valid signer again. The share was never lost.

**Security analysis (why this is acceptable):**
- iCloud Keychain is **end-to-end encrypted** — Apple cannot read the share.
- An attacker still needs **k separate members' shares** to steal. Backing each
  member's *own* share to *their own* iCloud means an attacker must compromise
  **k distinct iCloud accounts** — the threshold property is preserved. It
  substitutes "each member's device security" with "each member's iCloud
  security" (Apple ID + trusted device / recovery contact), which for a consumer
  pot is a *net win*: real-world fund loss from a lost phone is far more likely
  than a targeted k-way iCloud compromise.
- The device-only default was simply over-conservative for pot shares; we keep
  it available as an opt-in "max-security, no cloud backup" mode for the paranoid
  (with a loud "if you lose this phone, your share is gone" warning).

**This is the highest-priority fix** — it is a small change and it closes the
scariest hole (the exact scenario above becomes recoverable: B restores from
iCloud, A+B sign, funds safe).

---

## 2. Layer 2 — pot health & re-key ("Refresh pot")

Backup does not fix a member who *willfully leaves* — they still hold a share
they won't use, so the group's availability buffer stays eroded. The only way to
restore group redundancy is to **re-key**: run a fresh DKG among a new member set
and **move the funds to the new pot.** A FROST key's `(members, threshold)` is
frozen at creation; you cannot edit it in place.

### 2.1 Health model

For each pot, derive:
- `available` = members who are **live** (reachable/willing) **and** hold a
  recoverable share.
- `buffer` = `available − threshold`.

States:
- 🟢 **Healthy** — `buffer ≥ 1` (at least one member can drop and you can still spend).
- 🟡 **No buffer / at risk** — `buffer == 0` (any single further loss freezes it). ← 2-of-3-with-one-gone.
- 🔴 **Frozen** — `buffer < 0` (already unspendable). Only prevention helps here.

### 2.2 Liveness detection

- **Explicit:** a member taps **Leave** → marked inactive; the group is notified.
- **Implicit:** track `lastSeen` per member (last time they engaged with / were
  reachable for the pot). Flag members stale past a threshold (e.g. 60 days).
- **Optional heartbeat:** a periodic silent "still holding this pot?" check, or a
  prompt when health is at-risk. (Heuristic — we can't *prove* a share is intact
  without the member trying to use it, so we surface *staleness*, not certainty.)

### 2.3 The critical timing constraint (the fuse)

Re-keying **requires a spend from the old pot**, which needs the **old threshold
met by currently-active members.** Therefore:

- You can **only re-key while `available ≥ threshold`.**
- If you wait until a second member is lost (`available < threshold`), you are
  frozen and re-key is **impossible** — the funds are stuck.

So health degradation has a **deadline**, and it degrades **silently**. The app's
core job is to **notice and warn loudly *before* that deadline**, not after.

### 2.4 The Refresh flow

Triggered by: a member leaving, health dropping to 🟡, or manually.

1. Active members agree on the **new lineup** — drop the departed member and/or
   add a replacement (new person, or the same member's fresh device).
2. Run a **fresh DKG** among the new set → new pot + new address (ADR 0008 /
   CloudKit ceremony, ADR-not-yet: see `feedback_orangebubbles_no_server`).
3. **Sweep** the balance from the old pot to the new address — a normal threshold
   spend, satisfiable by the active members (this is why it must happen while
   `available ≥ threshold`).
4. Retire the old pot; its stale shares become inert.

---

## 3. The user's scenario, resolved

**2-of-3, C left, B loses phone:**

| | Today (device-only shares) | With Layer 1 | With Layer 1 + 2 |
|---|---|---|---|
| B loses phone | share gone → **1 left < 2 → FROZEN/LOST** | B restores from iCloud → A+B sign → **safe** | safe, and the group is nudged to **Refresh** to rebuild the buffer C left behind |

Layer 1 turns the catastrophe into a recoverable event. Layer 2 stops the slow
silent erosion (C leaving) from ever reaching the cliff.

---

## 4. Defaults that make this rare

- **Recommend "any 2," not "everyone must approve."** k-of-n with n > k is what
  gives you a buffer at all; "everyone" (k = n) means *any* single loss freezes
  the pot. The create flow already defaults to "any 2"; keep steering there.
- **Back up shares by default** (Layer 1 on).
- **Surface health proactively** so re-key happens inside the window.

---

## 5. Implementation priority

1. **Layer 1 — share backup to iCloud Keychain.** Small, highest value; closes
   the current fund-loss hole. Add the opt-in device-only mode + warning.
2. **Health model + warnings** (available/buffer, `lastSeen`, at-risk banner).
3. **Leave** = mark inactive + notify group + trigger Layer-2 offer (not just a
   local hide).
4. **Refresh (re-key + sweep)** flow.

## 6. Open questions

- Liveness heuristic tuning (what "stale" means; heartbeat vs last-seen).
- Passkey-sealing pot shares (extra Face ID) vs plain synced keychain.
- Re-key sweep fees and who pays (deduct from pot balance).
- Whether a departed member should be *cryptographically* excludable before the
  sweep, or just left inert (inert is simpler and sufficient once funds move).
