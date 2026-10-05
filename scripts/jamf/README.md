# Jamf remediation: Tenable macOS findings (mac.lan, 2026-10-04 export)

One script, `remediate-tenable-macos-findings.sh`, closes the 23 in-scope findings
from the scan export. They collapse into four actions:

| Action | Findings | Installed | Required | Path |
|---|---|---|---|---|
| IntelliJ IDEA CE | 9 | 2024.1.2 | 2026.2.3 | `/Applications/IntelliJ IDEA CE.app` |
| PyCharm CE | 3 | 2024.2.4 | 2026.2 | `/Applications/PyCharm CE.app` |
| MongoDB (Homebrew) | 10 | 8.2.3 | 8.2.12 | `/opt/homebrew/Cellar/mongodb-community` |
| OpenSSH | 1 | 10.2 | 10.3 | port 22 listener |

The macOS 26.7 → 26.7.1 finding (plugin 350912) is **out of scope** here and is
handled separately through Jamf Managed Software Updates / DDM.

## Jamf Pro setup

Settings → Computer Management → Scripts → New, paste the script, then label the
parameters (1–3 are reserved by Jamf):

| Param | Label | Default | Notes |
|---|---|---|---|
| 4 | `DRY_RUN` | `false` | `true` reports every change without making one |
| 5 | `COMPONENTS` | `all` | csv of `intellij,pycharm,mongodb,openssh` |
| 6 | `REQUEST_APP_QUIT` | `true` | ask a running IDE to quit; never force-kills |
| 7 | `RESTART_SSHD` | `true` | skipped automatically while SSH sessions are live |
| 8 | `ARCHIVE_SUPERSEDED` | `true` | archive a vulnerable bundle left at an old path |
| 9 | `MONGO_ALLOW_SERIES_JUMP` | `false` | leave `false` unless you have an FCV plan |

Attach it to a policy, execution frequency **Ongoing**, trigger `recurring
check-in`, with Maintenance → Update Inventory enabled so Jamf (and the next
Tenable scan) picks up the new versions. Run it once with `DRY_RUN=true` against
this one host first.

Log: `/var/log/vuln-remediation.log`. The script also emits a one-line
`<result>…</result>` summary suitable for an extension attribute.

## Can this be done without breaking the apps?

Short answer: MongoDB and OpenSSH, yes — those are genuinely safe. The two
JetBrains IDEs cannot break *data*, but they are a two-year version jump and the
developer will notice the difference. Nothing here is silently destructive.

**MongoDB 8.2.3 → 8.2.12 — safe.** A patch upgrade inside one release series
keeps the on-disk data format and `featureCompatibilityVersion` unchanged, so it
is a stop/replace-binary/start. The script makes it safe by refusing to cross a
series boundary: if Homebrew's `mongodb-community` has moved to 8.3.x or 9.0.x,
it stops and tells you to pin `mongodb-community@8.2` instead, because a series
jump requires sequential releases plus an FCV bump and must never happen from a
background policy. It also stops the service cleanly (and aborts rather than
upgrading under a live `mongod`), then returns the service to whatever run state
it found.

**OpenSSH 10.2 → 10.3 — safe, with one caveat.** The script first reads the
actual port-22 banner to decide *which* sshd is answering:
- Homebrew's build → upgrade the formula and restart. Config in `/etc/ssh` and
  `~/.ssh` is untouched; the only impact is that live SSH sessions drop on
  restart, so the script defers the restart while any session is established.
- Apple's `/usr/sbin/sshd` → it reports that there is no supported way to patch
  Apple's OpenSSH from a script. It is fixed by a macOS update (so your 26.7.1
  work may well close this one too), or mitigated by turning off Remote Login,
  which the script will not do unattended.

Note that the finding stays open until the daemon actually restarts — upgrading
the binary alone does not change the banner Tenable reads.

**JetBrains 2024.1.2 → 2026.2.3 — no data risk, real workflow change.** The CVEs
(including the critical path-traversal RCE, CVE-2026-59792, and the Structural
Search RCE, CVE-2026-100256) are only fixed in current releases, so there is no
smaller hop available. Replacing the `.app` does not touch settings, keymaps,
plugins or projects — those live in `~/Library/Application Support/JetBrains` and
`~/Library/Caches/JetBrains`, and the new version migrates them on first launch.
What the user will actually hit: some plugins will be disabled as incompatible
until updated, the New UI is the default now, and caches/indexes rebuild on the
first project open. Both are Community Edition, so there is no licensing change.

The one way an IDE upgrade *can* lose work is replacing the bundle under a
running IDE, so the script never does: it sends a polite quit request and, if the
app is still running after 90 seconds, defers to the next check-in and reports
it. There is no `kill -9` path.

**Watch for the PyCharm product-code change.** JetBrains folded PyCharm Community
into the unified PyCharm distribution, so the `PCC` release feed may not publish
a build that reaches 2026.2, and the new bundle may be named `PyCharm.app` rather
than `PyCharm CE.app`. The script handles both: it logs loudly if the newest
available build is still below the required version, installs to whatever the DMG
is named, and archives the old `PyCharm CE.app` so the vulnerable bundle does not
sit on disk and keep getting reported. If that feed is dead, PyCharm is the one
item that may need a Jamf package deployment of the unified build instead.

## Safety mechanics

- Idempotent — re-checks installed versions first and no-ops when compliant.
- `DRY_RUN=true` touches nothing.
- Downloads are SHA-256 verified against the vendor checksum, `codesign`-verified,
  Gatekeeper-assessed, and the signing authority is pinned to
  `Developer ID Application: JetBrains s.r.o.`. No checksum, no install.
- Download host is restricted to `download*.jetbrains.com`.
- The replaced `.app` is archived under
  `/Library/Application Support/VulnRemediation/archive` (pruned after 14 days)
  and restored automatically if the new bundle fails post-install verification.
- Original bundle ownership is preserved; the quarantine xattr is cleared.
- Homebrew work runs as the Homebrew prefix owner, never as root.
- A lock directory prevents overlapping runs; `caffeinate` keeps the Mac awake;
  mounts and temp files are cleaned up on any exit path.
- Exits non-zero only on real failure — a deferral is reported and exits 0.
