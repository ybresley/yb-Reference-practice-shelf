# yb-reapack-test — throwaway update-feature prototype

A disposable ReaPack repository + test scripts proving the mechanisms behind
**yb_Reference's planned in-app update feature** (its HANDOFF.md checklist U0–U9)
*before* any real code is built. Nothing here ships. When the prototype is done,
this whole repo gets deleted (see Cleanup).

## The moving parts

- `index.xml` — the ReaPack catalog REAPER imports. It starts by listing only
  v1.0; Claude advances it from `staging/` at the marked checkpoints.
- `versions/1.0 … 1.3/yb_dummy_package.lua` — the dummy tool. Its window shows
  the version baked into the file **and** what ReaPack's registry says is
  installed. Colour = version: **1.0 grey · 1.1 blue · 1.2 green** (1.3 red is a
  spare stage, only used if a test stage gets burned).
- `tests/01…07_*.lua` — the scratch scripts run in REAPER. Each prints to the
  ReaScript console; copy the output back to Claude after each.

## One-time setup (finishes U0)

1. **ReaPack options:** Extensions → ReaPack → Manage repositories → Options…
   Note whether **"Install new packages when synchronizing"** is ticked, then
   make sure it is **UNTICKED** (the U4 test needs it off; restore it in Cleanup).
2. **Import the repo:** Extensions → ReaPack → Import repositories… → paste
   `https://raw.githubusercontent.com/ybresley/yb-reapack-test/main/index.xml`
3. **Install the dummy:** Extensions → ReaPack → Browse packages… → search
   "dummy" → right-click the row → Install v1.0 → OK/Apply.
4. **Load the test scripts:** Actions → Show action list… → New action… →
   Load ReaScript… → multi-select all seven files in this folder's `tests/`.
5. **Sanity run:** run the dummy from the Action list → a **grey** window saying
   "FILE version 1.0" and "registry says installed version: 1.0".

Keep ReaPack's own windows (Manage repositories / Browse packages) **closed**
while running scripts 02 / 03 / 04 / 07 — they change repo settings and an open
manager could fight them.

## Test run order

1. **`01_signatures`** (U1+U2) — validates the reconstructed API calls.
   Expect: an entry handle, a labelled dump of every GetEntryInfo return
   (return #7 should be "1.0"), a clean FreeEntry, and the five comparisons
   signed positive / zero / negative / negative / positive.
   **→ CHECKPOINT: send Claude the output.** Claude pushes the catalog listing
   v1.1 and confirms GitHub is actually serving it (its cache lags ~5 min),
   then you continue.
2. **`02_gate_check`** (U4) — the trick with autoInstall=2 + global checkbox off.
   Expect: nothing visible happens; after ~12s the console prints "Gate held".
3. **`03_update_trick`** (U3) — the real one-button update.
   Expect: ReaPack's Progress window, a Report listing ONLY the dummy update,
   the script printing the registry change within ~90s — and no other repo's
   packages touched. Relaunch the dummy: **blue** v1.1.
4. **`04_restore`** (U5) — puts auto-install back to "use global setting".
   Expect: totally silent; Manage repositories shows the repo enabled.
5. **`05_background_fetch`** (U6) — the badge's download mechanism, three runs:
   with `MODE = "curl"` as shipped; edited to `MODE = "powershell"`; and once
   with Wi-Fi off (expect the silent 20s timeout, no error dialogs). Watch for
   console-window flashes and UI stutter each time.
   **→ CHECKPOINT: send output.** Claude pushes the v1.2 catalog + confirms the
   cache again.
6. **U7 (old code keeps running):** launch the dummy (blue 1.1), **leave its
   window open**, run `03_update_trick` again. Expect: the window keeps saying
   1.1 while the Report says 1.2 installed; close + relaunch → **green** 1.2.
   Run `04_restore` after.
7. **`06_browse_filter`** (U8) — the official fallback path. Expect: ReaPack's
   browser opens pre-filtered to EXACTLY one row; right-click offers
   Update/Versions. If it opens empty, swap the FILTER lines as commented in
   the script and rerun; report which form worked.
8. **`07_crash_window`** (U9) — simulates dying mid-trick (repo left disabled).
   Check Manage repositories (unticked), optionally run a global Synchronize
   (our repo skipped, others normal), then recover with `04_restore` or by
   re-ticking it by hand. Report what each step showed.

## Cleanup (after the whole prototype)

- ReaPack → Browse packages → right-click the dummy → Uninstall.
- Manage repositories → select `yb_update_test` → Remove.
- Restore the "Install new packages when synchronizing" checkbox to how it was.
- Delete `<REAPER resource>/yb_update_check_test.xml` (script 05's download).
- Tell Claude to delete this GitHub repo + the local folder.

## For Claude (stage advances)

`copy /y staging\index-1.1.xml index.xml` → commit `serve v1.1` → push → curl
the raw index URL until it actually shows 1.1 (GitHub's raw CDN caches ~5 min).
Same for 1.2. `1.3` is the spare — only if a stage got burned (e.g. U4 synced
because the global checkbox was accidentally on).
