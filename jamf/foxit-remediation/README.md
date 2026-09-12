# Remediate Foxit PDF Reader via Jamf Pro

Scanner finding:

```
Path: /Applications/Foxit PDF Reader.app
Installed version: 11.1.2
Fixed version: 2024.2
```

## Recommendation: remove it, don't patch it

For most managed Mac fleets, **uninstalling is the better remediation**:

1. **macOS already has Preview**, which reads, annotates and fills PDF forms
   natively. Foxit PDF Reader is usually redundant on a Mac.
2. **11.1.2 -> 2024.2 crosses a versioning scheme change** (Foxit moved from
   `11.x` to year-based `2024.x`). That is effectively a different product, not
   an in-place point upgrade — expect to uninstall and reinstall anyway.
3. **There is no Installomator label for Foxit PDF Reader.** Only
   `foxitpdfeditor` exists upstream, so patching the Reader is bespoke work
   every time.
4. **PDF readers are a recurring CVE source** and a classic malicious-document
   delivery surface. Removing it shrinks attack surface permanently rather than
   putting you on a patch treadmill.

That version is also years stale, which is itself a signal: if nobody noticed it
never updating, it is likely nobody is using it.

## Step 1 — Find it, and find out if anyone uses it

Add `extension-attribute-foxit-reader.sh` (**Data Type:** String, **Input Type:**
Script). It reports version *and* last-used date:

```
11.1.2 | last used: 2024-03-11 09:22:14 +0000
```

The last-used date is the decision-maker. A Mac that has not opened Foxit in
months does not need it reinstalled — remove and move on. Build a Smart Group on
this EA to scope the policy and watch the count drain.

## Step 2a — Remove it (recommended)

Add `uninstall-foxit-reader.sh` as a script and attach it to a policy scoped to
that Smart Group.

It quits the app, removes the bundle, forgets Foxit package receipts, and clears
Foxit's system and per-user support/preference/cache files. **It does not touch
any PDF documents.**

Set any users who complain back up with Preview, or handle them under 2b.

## Step 2b — Upgrade instead (only where Foxit is genuinely required)

If specific users depend on Foxit-only features, or it is mandated:

1. Download the current **Foxit PDF Reader for Mac** installer from Foxit.
   > **Verify this yourself** — Foxit's site was not reachable from the
   > environment this runbook was written in, so no download URL or current
   > version number is asserted here. Do not trust a URL nobody checked.
2. **Verify the signature before packaging.** Foxit's Apple Developer Team ID is
   `8GN47HTP75` (as used by the upstream `foxitpdfeditor` Installomator label):
   ```bash
   pkgutil --check-signature /path/to/FoxitReader.pkg    # expect 8GN47HTP75
   spctl -a -vv /Applications/Foxit\ PDF\ Reader.app     # after install
   ```
3. Because of the version-scheme jump, **run the uninstall script first**, then
   install the new build, rather than upgrading 11.1.2 in place.
4. Re-run inventory and confirm the EA reports the new version.

## Step 3 — Verify

Update Inventory, then check the EA. Removed Macs report `Not installed`, the
Smart Group drains, and the next scan clears the finding.
