# Node.js vulnerability detection and patching for Jamf

Two scripts:

| Script | Role |
|---|---|
| `ea-nodejs-status.sh` | Extension Attribute. Read-only, offline. Tells you which Macs have Node.js and whether it is vulnerable. |
| `node-patch.sh` | Policy script. Detects how Node.js was installed and remediates it. |

## Vulnerability floors

Both scripts share one table, `FLOORS`, in the form `major:minimum-fixed-version`:

```
20:20.20.2  22:22.23.2  24:24.18.1  25:25.8.2  26:26.5.1
```

**Update this table in both files when a new advisory lands.** `node-patch.sh` also
accepts an override as Jamf parameter 6, so you can push a new floor without editing
the script.

A version is classified as:

* `ok` — at or above the floor for its major.
* `vuln` — below the floor.
* `eol` — a major with no floor and below the newest one you list (18, 21, 23 …).
  These lines get no security releases at all, so they are treated as needing action.
* `unknown` — unreadable, or a major newer than anything in the table. **Never patched
  automatically**, so a failed version read can't trigger a surprise upgrade.

## 1. Extension Attribute

Jamf Pro → Settings → Computer Management → Extension Attributes → New

* Display Name: `Node.js Status`
* Data Type: `String`
* Input Type: `Script`
* Paste `ea-nodejs-status.sh`

The first line of the result is the verdict (`None`, `OK`, `Unknown`, `EOL`,
`Vulnerable`); the rest lists every install found.

Smart groups:

* **Macs with Node.js** — `Node.js Status` `not like` `None`
* **Macs with vulnerable Node.js** — `Node.js Status` `like` `Vulnerable`

## 2. Patch policy

Scope the policy to **Macs with vulnerable Node.js**. On a Mac with no Node.js the
script logs one line and exits 0 without touching anything.

Parameters:

| Param | Name | Values | Default |
|---|---|---|---|
| 4 | Mode | `report` \| `patch` | `report` |
| 5 | Version manager action | `report` \| `upgrade` \| `prune` | `report` |
| 6 | Floors override | e.g. `20:20.20.2 22:22.23.2` | built-in table |

Exit codes: `0` = nothing vulnerable remains, `1` = vulnerable Node still present,
`2` = usage or environment error. Jamf shows `1` as a failed policy, which is what you
want for a remediation policy — the failures are your remaining work queue.

Run it with parameter 4 = `report` first against a pilot group and read
`/var/log/nodepatch.log` before switching to `patch`.

## What gets patched

**Automatically in `patch` mode** — machine-wide, root-owned:

* **Homebrew**, at both `/opt/homebrew` and `/usr/local` (they can coexist). `brew` runs
  as the account that owns the prefix, with `-H` so `HOME` is that user's.
* **nodejs.org `.pkg`** — the target release is downloaded from `nodejs.org/dist` and its
  SHA-256 checked against `SHASUMS256.txt` before `installer` runs. Needs outbound HTTPS
  to `nodejs.org`.
* **MacPorts** — `port selfupdate` then `port upgrade` of the installed `nodejsXX` ports.

Every one of these is re-read after patching, so the log says what the version actually
became rather than assuming the upgrade worked.

**Only with parameter 5** — per-developer version managers (nvm, fnm, volta, asdf,
nodenv, n):

* `report` (default) — lists them and the command the developer should run. Nothing
  is changed.
* `upgrade` — installs a current version and makes it the default. The old vulnerable
  version stays on disk, so a scanner will still flag it, and the run still exits 1.
* `prune` — also removes the vulnerable versions. **This breaks projects pinned to
  them.** Announce it before you use it.

The default is `report` on purpose: silently changing a developer's Node version
breaks builds, and these installs are per-user, not machine state.

## Upgrade target selection

For a supported major, the target is the newest release **on that same line** —
22.9.0 → 22.23.2, not a jump to a different major. Note that Node 25 and 26 are
*Current* lines with `lts: false`, so anything that filters on "latest LTS" would
silently **downgrade** a Node 26 machine to Node 24. It doesn't.

For an EOL major (18, 21, 23 …) there are no further releases on that line, so the
target is the newest LTS. That is a major-version bump and is logged as such.

The chosen target is never older than what is installed.

## Logs

* `/var/log/nodepatch.log` — full run log, appended.
* `/Library/Application Support/NodePatch/last_run.txt` — machine-readable summary
  (`status|label|version|note`) from the most recent run.

## Known limits

* Node bundled inside Electron apps (Slack, VS Code, Discord …) is not detected or
  patched. Those ship their own runtime and are fixed by updating the app itself. If
  your scanner flags them, they need separate app-update policies.
* Node inside Docker images, project-local `node_modules/.bin`, and CI runner caches
  are out of scope.
* The `.pkg` path verifies the SHA-256 from `SHASUMS256.txt` over HTTPS. It does not
  verify the detached GPG signature of that file.
