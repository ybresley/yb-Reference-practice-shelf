-- 10_restart_probe.lua — can a running defer script cleanly RESTART ITSELF
-- (terminate + relaunch from disk, no dialogs)? REAPER 7's set_action_options
-- is the designed mechanism; the update feature's planned "Restart now" button
-- rides it, so it gets proven here first — on this probe, not on the tool.
--
-- What should happen: run it ONCE from the Action list. It prints "launch #1",
-- arms auto-restart, and ~2s later re-invokes its own action while still
-- running. REAPER should silently terminate this instance and start a fresh
-- one, which prints "launch #2 - RESTART WORKED". The whole point is what you
-- DON'T see: no "script already running" prompt, no dialog, no hiccup.
--
-- Report: both launch lines, any dialogs, anything odd. If launch #2 never
-- prints, or a prompt appears, the Restart button falls back to close-only.

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end
local SECTION, KEY = "yb_restart_probe", "count"

local n = (tonumber(reaper.GetExtState(SECTION, KEY)) or 0) + 1
reaper.SetExtState(SECTION, KEY, tostring(n), false)

local _, _, sectionID, cmdID = reaper.get_action_context()

say("")
say("=== 10_restart_probe: launch #" .. n .. " ===")

-- The relaunched instance (or anything beyond it): report and STOP — the
-- counter is the guard that makes an accidental loop impossible.
if n >= 2 then
  reaper.DeleteExtState(SECTION, KEY, true)
  if n == 2 then
    say("RESTART WORKED - this is the fresh instance, started from disk.")
    say("If no dialog appeared between the two launches, the mechanism is proven.")
  else
    say("FINDING: launch #" .. n .. " - more instances than expected. Report this.")
  end
  say("=== 10 done - report both launch lines + any dialogs ===")
  return
end

if not reaper.set_action_options then
  reaper.DeleteExtState(SECTION, KEY, true)
  say("set_action_options is ABSENT (REAPER older than 7?) - the Restart button")
  say("will fall back to close-only. Report this.")
  return
end

-- 1 = terminate this instance if the action is invoked again while running;
-- 2 = then start a fresh instance. Together: a clean self-restart.
reaper.set_action_options(1 | 2)
say("armed (cmdID " .. tostring(cmdID) .. ", section " .. tostring(sectionID) .. ").")
say("Re-invoking myself in ~2s - eyes open for any dialog...")

local t0 = reaper.time_precise()
local fired = false
local function tick()
  local dt = reaper.time_precise() - t0
  if not fired and dt >= 2 then
    fired = true
    say("re-invoking NOW.")
    reaper.Main_OnCommand(cmdID, 0)
  end
  -- Keep this instance deliberately ALIVE after the re-invoke: the test is
  -- that REAPER terminates a RUNNING script and replaces it. If we're still
  -- ticking 3s later, the terminate never came - that's the finding.
  if fired and dt >= 5 then
    reaper.DeleteExtState(SECTION, KEY, true)
    say("FINDING: still running 3s after the re-invoke - no auto-terminate.")
    say("Report this (plus any dialog that appeared instead).")
    say("=== 10 done ===")
    return
  end
  reaper.defer(tick)
end
reaper.defer(tick)
