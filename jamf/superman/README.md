# Enforce macOS 26.6.2 with S.U.P.E.R.M.A.N. (super) via Jamf Pro

This kit forces every out-of-date Mac onto **macOS 26.6.2**, using
[`super`](https://github.com/Macjutsu/super) (Macjutsu) as the enforcement tool.
It covers two tracks with one deployment:

- **Macs already on 26.x** (that DDM missed) → **minor update** to 26.6.2.
- **Macs on macOS 14 or 15** → **major upgrade** to 26.6.2.

The minor-update track is the DDM cleanup lever; the major-upgrade track pulls the
Sonoma/Sequoia machines all the way up. They differ a lot in weight — read the
**Major-upgrade requirements** section before you scope 14/15 machines in.

Going forward you plan to run **DDM + Nudge** as the normal cadence — this is the
one-time cleanup lever for the machines DDM missed. Once these are caught up,
retire (or narrow the scope of) the policy and profile described here.

> For minor updates (and Apple-silicon upgrades) `super` drives the same Apple
> managed-software-update MDM command DDM uses; for Intel major upgrades it falls
> back to a full-installer (`mist-cli` + `startosinstall`) workflow. Either way it
> adds user messaging, deferral/deadline logic, and MDM→local-auth failover, which
> is what gets the machines that silently stalled to actually move.

---

## Files in this kit

| File | What it is |
|------|------------|
| `com.macjutsu.super.mobileconfig` | Configuration profile (`com.macjutsu.super`) with the 26.6.2 target (minor + major upgrade), deadlines, and Apple-silicon MDM identifiers. |
| `extension-attribute-super-status.sh` | Jamf Extension Attribute (String / Script) that reads `super`'s local plist and reports full status: version, last status line, update target, deferrals used (of your 8), installer-cached state, last check, next launch — plus a full key dump with credentials redacted. |
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
3. Target Macs are **hardware-eligible for macOS 26**. macOS 26 drops some Intel
   models that could run 14/15, so a Mac on Sonoma/Sequoia is **not** automatically
   able to run 26. `super` won't force an incompatible upgrade (it checks
   compatibility first), but ineligible Macs will just loop — scope them out
   (see Step 2). `super` also cannot downgrade.
4. For the **14/15 → 26 major-upgrade** track, read
   **[Major-upgrade requirements](#major-upgrade-requirements)** below — free space,
   `mist-cli` for Intel, and longer install time all apply.
5. Enforcement is **8 deferrals, 1 hour apart** (`DeadlineCountHard=8`,
   `DeferralTimerDefault=60`) — already set in the profile; no dates to manage.

---

## Major-upgrade requirements

Everything below applies to the **14/15 → 26.6.2** machines (the minor-update track
doesn't need any of it). These are already reflected in the config profile
(`InstallMacOSMajorUpgrades` + `InstallMacOSMajorVersionTarget=26.6.2`).

- **Hardware eligibility** — the #1 gotcha. macOS 26 doesn't run on every Mac that
  runs 14/15. Scope ineligible Macs out (Step 2). `super` self-checks and won't
  force an impossible upgrade, but you don't want those Macs looping and nagging.
- **Free disk space** — a major upgrade pulls a **full installer (~14 GB)** and
  needs room to apply it. Ensure roughly **25–30 GB free**. Consider a pre-flight
  Smart Group on *Boot Drive Available MB* and remediate low-space Macs first.
- **`mist-cli` (Intel Macs)** — for the local full-installer upgrade path `super`
  uses [`mist-cli`](https://github.com/ninxsoft/mist-cli). Deploy it to the Intel
  machines first (Installomator label `mistcli`, or package the release). Apple
  silicon going through the **MDM push** path (your Jamf API creds) does **not**
  need mist-cli.
- **Apple silicon auth** — your Jamf API client (Step 1) drives the MDM upgrade the
  same way it drives minor updates, so no new credentials. The profile's
  `AuthMDMFailoverToUser=ALWAYS` lets a user authenticate locally if the MDM push
  fails (more common on the heavier upgrade workflow). If you'd rather use the more
  reliable **local** auth path instead of MDM, see the super wiki *Apple Silicon
  Local Credentials* — but MDM is fine to start.
- **Time** — the upgrade download + install can take well over an hour. The 8×1h
  deferral window governs when the user can no longer postpone; the actual
  download/install then runs on top of that, so expect a major-upgrade Mac to be
  busy for a while after the deadline is hit.

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

Create a Smart Computer Group, e.g. **"macOS below 26.6.2 (super enforcement)"**.
Because we now include 14/15, the group is simply *anything below 26.6.2* that is
enforceable and eligible:

```
Operating System Version   less than       26.6.2
   and
Bootstrap Token Escrowed   is              Yes         (Apple silicon needs this to enforce)
```

Jamf compares OS versions numerically, so "less than 26.6.2" matches 14.x, 15.x,
and any 26.x below 26.6.2 — all three get pulled in.

**Add an exclusion group for hardware that can't run macOS 26** (this is the
important one now that 14/15 are in scope). Use Jamf's **built-in Model Identifier
field** — no custom script needed:
- Build a second Smart Group **"Not macOS 26 eligible"** listing the Model
  Identifiers (e.g. `MacBookPro15,1`) that macOS 26 does **not** support, taken
  from Apple's official macOS 26 compatibility list, and set it as an **exclusion**
  on your enforcement scope.
- Not sure which of your models are affected? The optional
  `extension-attribute-super-status.sh` reports each Mac's current OS; combine that
  with the built-in Model Identifier field to audit your 14/15 fleet before you
  flip enforcement on.
- `super`'s own compatibility check is the backstop: even if an ineligible Mac
  slips into scope, `super` reports "no compatible upgrade" rather than forcing it.

Also:
- "Operating System Version less than 26.6.2" auto-empties as machines update, so
  the group naturally drains — that is your progress meter.
- Add an exclusion for any Macs you must not touch (execs mid-travel, lab, etc.).

## Step 3 — Deploy the configuration profile

Deploy `com.macjutsu.super.mobileconfig` **before** the policy runs.

1. Open the file and set:
   - `InstallMacOSMinorVersionTarget` → already `26.6.2` (pins the 26.x track).
   - `InstallMacOSMajorUpgrades` = `true` and `InstallMacOSMajorVersionTarget` =
     `26.6.2` → already set; these enable and cap the 14/15 → 26 upgrade.
   - `DeferralTimerDefault=60` and `DeadlineCountHard=8` → already set. This gives
     users 8 deferrals, 1 hour apart (an 8-hour window), then a forced install +
     restart. Nothing to change unless you want a different count/interval.
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

1. Scope the policy + profile to test Macs that cover every path you're shipping:
   **one on 26.x** (minor update) and **one on 14 or 15** (major upgrade), and if
   you have both CPU types, an **Apple silicon** and an **Intel** of each. Confirm
   `mist-cli` is present on the Intel upgrade test Mac.
2. On a test Mac, watch it work:
   ```bash
   # Simulate reaching the hard deadline (count 0) to see the forced-restart path:
   sudo /usr/local/bin/super --test-mode --install-macos-minor-version-target=26.6.2 \
     --deadline-count-hard=0
   tail -f /Library/Management/super/super.log   # older builds: /var/log/super/super.log
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
- **"Inactive Error: Apple silicon authentication options could not be validated
  and no failover option was specified"** → the Jamf API client/secret failed to
  validate (client not created/enabled, wrong secret, role missing privileges, or
  Jamf unreachable), and there was no credential failover to fall back on. Fix:
  (1) confirm the API **Client** exists, is **Enabled**, bound to the role, with
  the correct secret and all 7 privileges; (2) make sure the profile carries
  **`AuthCredentialFailoverToUser=true`** (added) — this is the failover for a
  *validation* failure, distinct from `AuthMDMFailoverToUser` which only covers an
  MDM push failure *after* creds validate; (3) clear the bad state and re-run:
  `sudo /usr/local/bin/super --reset-super --verbose-mode` and watch the log for
  the exact HTTP result (401 = bad client/secret, 403 = missing privilege).
### macOS 14 (and older): "Unable to resolve a valid Jamf Pro Management ID"

**This is a bug in super, not your config.** On Jamf Pro 11.28+, super must resolve
the computer's Management ID before it can authenticate. In super 5.1.1,
`get_jamf_api_management_id()` parses the Jamf API response two different ways:

```bash
if [[ $macos_version_major -ge 15 ]]; then
    jamf_management_id=$(... | jq -r ".general.managementId")     # macOS 15+
else
    jamf_management_id=$(... | grep 'managementId' | awk -F '"' '{print $4}')
fi
[[ ! "${jamf_management_id}" =~ ${REGEX_VALID_UUID} ]] && auth_error_jamf="TRUE"
```

`jq` only ships in **macOS 15+**. On macOS 14 and older super uses the `awk`
fallback, which mis-parses the API's minified single-line JSON, fails the UUID
check, and aborts auth — surfacing as *"Apple silicon authentication options could
not be validated."* Same profile, same credentials: a 26.x Mac succeeds and a 14.x
Mac fails.

**Two fixes, in order of preference:**

1. **Make the profile deliver the Management ID** so super never runs the broken
   parser (it reads the managed value first and skips API resolution entirely).
   The EA's `Profile delivers:` line shows what's actually arriving — if
   `AuthJamfManagementID` is `<empty>` or the literal `$MANAGEMENTID`, the Jamf
   payload variable is not substituting. Confirm your Jamf Pro version supports
   the `$MANAGEMENTID` payload variable and that the profile is scoped/installed.
   Tell-tale: if super wrote `AuthJamfComputerID` into its *local* plist, the
   `$JSSID` variable didn't substitute either — super resolved it itself.
2. **Use local authentication for the old Macs** and bypass the Jamf API path
   completely (super's docs call local auth "more reliable and performant" than
   MDM). Add `AuthAskUserToSavePassword=true` in a **second profile scoped only to
   a "macOS below 15" Smart Group**.

> **Do NOT add `AuthAskUserToSavePassword` to the main profile.** super allows only
> one Apple silicon auth method, with local end-user password taking priority
> *over* the Jamf API credentials. Putting it in the shared profile would switch
> your healthy 26.x Macs off the silent MDM push and start prompting every user
> for their password. Scope it to the old Macs only.

`AuthCredentialFailoverToUser=true` (in the profile) is the safety net either way:
it is the first branch super checks on an auth-validation error, so instead of the
dead-end exit it falls over to user authentication and the upgrade still proceeds.

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
