# Remediate vulnerable Node.js via Jamf Pro

For scanner findings like:

```
Path: /usr/local/bin/node
Installed version: 24.14.0
Fixed version: 24.17.0
```

## Read the finding correctly

**"Fixed version" is a floor, not a target.** 24.17.0 is simply the release that
fixed *that* CVE (2026-06-17). Installing exactly 24.17.0 leaves the Mac behind on
every release since — including 24.18.1, which is a patch release of the kind that
usually carries further security fixes.

Install the **current release of the same major line** instead. As of 2026-09-07
that is **24.21.0** (LTS "Krypton"). Staying on the 24.x line means no breaking
changes, and it clears this finding plus anything newer.

## Step 0 — Decide: upgrade, or remove?

Ask first whether Node belongs on the machine at all. On a non-developer endpoint
Node is often incidental — installed once for a task, then left behind. **Removing
it is the stronger remediation**: it closes this finding permanently instead of
signing you up for a Node CVE every few weeks.

Only upgrade on machines where somebody actually needs it.

## Step 1 — Find the affected Macs and how Node got there

Add `extension-attribute-node-version.sh` (**Data Type:** String, **Input Type:**
Script). It reports, e.g.:

```
24.14.0 | official pkg | /usr/local/bin/node
```

The install source matters, because remediation differs:

| Source | Typical path | How to fix |
|---|---|---|
| **official pkg** | `/usr/local/bin/node` (has an `org.nodejs.node.pkg` receipt) | Install a newer `.pkg` — the script below |
| **Homebrew** | `/opt/homebrew/bin/node` (Apple silicon), `/usr/local` on Intel | `brew upgrade node` **as the owning user** — never lay the pkg over it |
| **nvm** | `~/.nvm/...` | Per-user; the user updates it themselves |

> On **Apple silicon**, `/usr/local/bin/node` is almost certainly the official
> `.pkg`, because Homebrew lives in `/opt/homebrew`.

Build a Smart Group on this EA (e.g. *does not contain* `24.21.0` *and is not*
`Not installed`) to scope the policy and to watch the count drain afterwards.

## Step 2 — Deploy the upgrade

Add `remediate-nodejs.sh` as a script and attach it to a policy scoped to that
Smart Group. **Trigger:** Recurring Check-in. **Frequency:** Ongoing.

| Parameter | Value |
|---|---|
| 4 | `24.21.0`  *(optional — omit to use the script's default)* |

What the script does:

1. Skips if the Mac is already at or **newer than** the target (numeric compare,
   so `24.9.0` correctly counts as older than `24.21.0`).
2. **Refuses to run** against a Homebrew-managed Node rather than creating a
   second conflicting copy.
3. Downloads the official universal `.pkg` from `nodejs.org`.
4. **Verifies SHA-256 against the official `SHASUMS256.txt`** and aborts on
   mismatch — it will not install an unverified package.
5. Installs, then confirms the resulting version, exiting non-zero on any failure
   so the policy reports a failure instead of a false success.

## Step 3 — Verify

Update Inventory, then re-check the EA. Affected Macs should read
`24.21.0 | official pkg | /usr/local/bin/node`, the Smart Group should drain, and
the next scan should clear the finding.

## Keeping it clear

Node ships new versions constantly. Either:

- **Remove Node** from machines that don't need it (best), or
- Leave this policy **Ongoing** and bump Parameter 4 when you want a newer floor —
  the script is idempotent and no-ops on already-current machines.
