-- 06_browse_filter.lua — U8: the official fallback path - open ReaPack's browser
-- pre-filtered to exactly our package (used by the real feature only if the sync
-- trick ever stops working).
-- RUNS WHILE AN UPDATE IS PENDING (dummy at 1.1, catalog serving 1.2), so the
-- right-click menu should OFFER "Update to v1.2".
-- Expected: the browser opens showing EXACTLY ONE row (the dummy); right-click
-- offers the update + a Versions submenu. LOOK, BUT DO NOT CLICK UPDATE -
-- the U7 test right after this needs that update still pending. Close the
-- browser when done looking.
--
-- The filter uses the package's DISPLAY name (its desc). If the browser opens
-- EMPTY, swap the FILTER lines below and rerun; report which form worked.

local FILTER = '^"YB Dummy Package"$ ^"yb_update_test"$'
-- local FILTER = '^"yb_dummy_package.lua"$ ^"yb_update_test"$'   -- the filename form

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

say("")
say("=== 06_browse_filter (U8) ===")
if not (reaper.APIExists and reaper.APIExists("ReaPack_BrowsePackages")) then
  say("FAIL: ReaPack API not found")
  return
end

say("filter passed: " .. FILTER)
local ok, err = pcall(reaper.ReaPack_BrowsePackages, FILTER)
say("BrowsePackages -> " .. (ok and "called ok" or ("ERROR: " .. tostring(err))))
say("EXPECTED: browser open with exactly ONE row; right-click should OFFER 'Update to v1.2'.")
say("DO NOT actually click Update - U7 needs that update still pending. Close the browser after looking.")
say("=== 06 done - report the row count, the offered menu items, and which FILTER form worked ===")
