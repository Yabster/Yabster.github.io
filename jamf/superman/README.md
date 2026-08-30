# Enforce macOS 26.6.2 with S.U.P.E.R.M.A.N. (super) via Jamf Pro

This kit forces a macOS **minor update to 26.6.2** on the Macs that your DDM
(Declarative Device Management / Jamf Managed Software Updates) enforcement did
**not** get onto 26.6.2. It uses [`super`](https://github.com/Macjutsu/super)
(Macjutsu) as the enforcement tool, scoped only to the stragglers.

Going forward you plan to run **DDM + Nudge** as the normal cadence — this is the
one-time cleanup lever for the machines DDM missed. Once these are caught up,
retire (or narrow the scope of) the policy and profile described here.

> `super` drives the same Apple managed-software-update MDM command that DDM uses,
> but adds user messaging, deferral/deadline logic, and an MDM→local-auth failover,
> which is what makes it effective on the machines that silently stalled.

---

## Files in this kit

| File | What it is |
|------|------------|
| `com.macjutsu.super.mobileconfig` | Configuration profile (`com.macjutsu.super`) with the 26.6.2 target, deadlines, and Apple-silicon MDM identifiers. |
| `extension-attribute-super-status.sh` | Optional Jamf Extension Attribute to report each Mac's `super` status for a Smart Group / dashboard. |
| `README.md` | This runbook. |

Nothing here contains secrets. The Jamf API **client id/secret go in the Jamf
policy Script Parameters**, never in the repo or the profile.

---

## Prerequisites (check these first)

1. **Jamf Pro** with the **Managed Software Updates** feature enabled (10.48+;
   11.28+ adds a Management ID requirement handled below).
2. **Bootstrap token escrowed** for the target Macs. Apple silicon **cannot** be
   force-updated over MDM without it. Verify with a Smart Group on
   *Bootstrap Token Escrowed = Yes* (or `profiles status -type bootstraptoken`).
   Macs missing an escrowed token are the usual reason DDM "silently" did nothing.
3. Target Macs are **eligible for 26.6.2** (already on macOS 26.x and supported
   hardware). `super` cannot downgrade, and pinning to 26.6.2 will not upgrade a
   Mac that is on an older major version to 26 — handle major upgrades separately.
4. Decide your **deadline dates** (see below).

---

## Step 1 — Create a Jamf Pro API Role & Client for super

super sends the managed-update MDM command through the Jamf Pro API. Create an
**API Role** with the *new* Managed Software Updates privileges:

- Create Managed Software Updates
- Read Computers
- Read Managed Updates
- Read Mobile Devices
- Send Computer Remote Command to Download and Install OS X Update
- Send Mobile Device Remote Command to Download and Install iOS Update
- View MDM command information in Jamf Pro API  *(Jamf Pro 11.28+)*

Then create an **API Client** bound to that role and generate a **client secret**.
Record the **client id** and **secret** — they go into the policy in Step 4.

## Step 2 — Scope the stragglers (Smart Computer Group)

Create a Smart Computer Group, e.g. **"macOS below 26.6.2 (super enforcement)"**:

```
Operating System Version   less than       26.6.2
   and
Operating System Version   greater than    26          (only touch Macs already on 26.x)
   and
Bootstrap Token Escrowed   is              Yes         (Apple silicon needs this to enforce)
```

Notes:
- "Operating System Version less than 26.6.2" auto-empties as machines update, so
  the group naturally drains — that is your progress meter.
- Add an exclusion for any Macs you must not touch (executives mid-travel, lab
  machines, etc.). You can also gate the policy on the optional Extension
  Attribute in this kit (super status) once it's live.

## Step 3 — Deploy the configuration profile

Deploy `com.macjutsu.super.mobileconfig` **before** the policy runs.

1. Open the file and set:
   - `InstallMacOSMinorVersionTarget` → already `26.6.2` (pins the target).
   - `DeadlineDateFocus` / `DeadlineDateSoft` / `DeadlineDateHard` → your dates
     (format `YYYY-MM-DD:HH:MM`, order must be focus < soft < hard).
   - `AuthJamfComputerID` = `$JSSID` and `AuthJamfManagementID` = `$MANAGEMENTID`
     — leave the `$` variables exactly as written; Jamf fills them per-computer.
   - `PayloadOrganization` → your org name.
2. In Jamf Pro: **Computers → Configuration Profiles → Upload**, scope it to the
   Smart Group from Step 2.

Recommended companion: also deploy an **Apple software update settings** profile
that enables automatic download of updates (so super doesn't wait on-demand) and
sets your deferral policy. See the super wiki, *Apple Software Update Settings*.

## Step 4 — Create the Jamf Pro policy that runs super

1. Add the `super` script to Jamf (**Settings → Scripts**) — download the current
   release from <https://github.com/Macjutsu/super> (use a pinned release, not a
   moving `main`, so you know what you shipped). When a policy runs it, super
   installs/updates itself on the Mac.
2. Create a policy, e.g. **"Install super — enforce macOS 26.6.2"**:
   - **Scope**: the Smart Group from Step 2.
   - **Trigger**: `recurring check-in` (super relaunches itself on its own timer
     afterward, so you don't need an aggressive trigger).
   - **Frequency**: `Ongoing`.
   - **Script**: `super`, with these **Script Parameters** (one option per field —
     do **not** use quotes in Jamf parameter fields):

     | Parameter | Value |
     |-----------|-------|
     | 4 | `--auth-jamf-client=REPLACE_ME_CLIENT_ID` |
     | 5 | `--auth-jamf-secret=REPLACE_ME_CLIENT_SECRET` |
     | 6 | `--reset-super` |

   The version target, deadlines, MDM identifiers, and failover all come from the
   configuration profile in Step 3, so they don't need policy parameters. Keep the
   secret out of the profile — parameters are the only safe place for it.

> **Do not** add a Jamf inventory-collection step (Update Inventory / recon) to
> this same policy if "Collect available software updates" is enabled in your
> inventory settings — two processes calling `softwareupdate` at once can hang it.

## Step 5 — Test on a pilot before broad release

1. Scope the policy + profile to **one or two test Macs** first (Apple silicon
   **and** Intel if you have both).
2. On a test Mac, watch it work:
   ```bash
   sudo /usr/local/bin/super --test-mode --install-macos-minor-version-target=26.6.2 \
     --deadline-date-soft=2020-01-03 --deadline-date-hard=2020-01-07
   tail -f /var/log/super/super.log      # or /Library/Management/super/super.log on newer builds
   ```
   The past dates simulate an expired deadline so you can see the soft/hard dialogs
   without waiting.
3. Confirm the MDM command reaches the Mac (Jamf **Managed Software Updates** /
   the computer's **Management History → Commands**) and that it lands on 26.6.2.
4. Then widen the scope to the full Smart Group.

---

## Rollback / stand-down

- **Stop enforcing:** unscope the policy and the configuration profile from the
  Smart Group (or disable the policy). Removing the profile clears the pinned
  target and deadlines.
- **Clear local state on a Mac:** run super with `--reset-super` (already in the
  policy) or fully remove with the uninstall steps in the super wiki.
- Never "fix" a stuck Mac by disabling/removing FileVault or the bootstrap token —
  re-escrow the token instead (see Troubleshooting).

## Troubleshooting the "DDM missed them" machines

These are the usual reasons a Mac ignored DDM, and how super gets past each:

- **No / invalid bootstrap token** → MDM can't enforce. super checks the token and,
  with `AuthMDMFailoverToUser`, can prompt the user to re-escrow it, or you can
  re-escrow with `sudo profiles install -type bootstraptoken`.
- **A stuck/last DDM plan still pending** → in Jamf **Managed Software Updates**,
  cancel the stale plan for that computer so super's new command isn't ignored as
  a "managed software update deferral" (super deliberately respects those).
- **MDM push unreliable** → `AuthMDMFailoverToUser=ALWAYS` (set in the profile)
  lets the logged-in user authenticate locally so the install still completes.
- **Not enough free space / on-demand download waiting** → super will defer while
  the OS pre-downloads; the companion Apple software-update settings profile that
  enables automatic download speeds this up.
- **Read the log** on-device: `super.log` (path above) explains exactly what super
  decided and why on each run.

## References

- super wiki — Install macOS Updates and Upgrades:
  <https://github.com/Macjutsu/super/wiki/Install-macOS-Updates-and-Upgrades>
- super wiki — Date Deadlines:
  <https://github.com/Macjutsu/super/wiki/Date-Deadlines>
- super wiki — Apple Silicon Jamf Pro API Credentials:
  <https://github.com/Macjutsu/super/wiki/Apple-Silicon-Jamf-Pro-API-Credentials>
- super wiki — Jamf Pro Deployment:
  <https://github.com/Macjutsu/super/wiki/Jamf-Pro-Deployment>
