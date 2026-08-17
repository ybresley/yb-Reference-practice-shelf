# yb-Reference practice shelf

This repository serves disposable **yb-Reference TEST** packages for installation and update rehearsals. It is not the beta or release shelf.

Use these packages only in a portable or otherwise disposable REAPER installation. Do not install them over your normal yb-Reference copy.

## Install the current practice package

1. In REAPER, choose **Extensions → ReaPack → Import repositories…**
2. Paste:

   ```text
   https://raw.githubusercontent.com/ybresley/yb-Reference-practice-shelf/main/index.xml
   ```

3. Choose **Extensions → ReaPack → Browse packages…**
4. Search for **yb-Reference TEST**.
5. Select it, choose **Install**, then select **Apply**.
6. Restart REAPER.
7. Open the Action List and run **yb-Reference TEST · packaging rehearsal**.

Search for **ToggleReferenceMode** in the Action List to find the companion TEST action and assign it to a temporary hotkey.

## Current rehearsal

- TEST package: **0.2.16**
- Source snapshot: ReaPack-quarantine commit `0a30f27`
- Automated checks: **701 passed, 0 failed**

Every changed TEST build gets a new version number. Existing versions are not silently replaced, so an installed copy and its feedback reports can always be identified.

The real beta will be published separately as **yb-Reference 0.3.0** only after its frozen build passes the final clean-install gate.
