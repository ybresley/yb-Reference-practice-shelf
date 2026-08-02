-- 05b_quiet_fetch.lua — build step 0: find a fetch launch that NEVER flashes a
-- console window. U6 proved the download mechanics (curl 0.60s / PowerShell
-- 0.73s / offline = clean silent 20s timeout) but every launch tried — curl
-- twice and even "-windowstyle hidden" PowerShell — blinked a black console
-- window. The badge feature must not ship until one launch is proven flash-free
-- (HANDOFF "NEXT ACT" step 0).
--
-- WATCH THE SCREEN for the whole run. Two candidates fire in sequence, each
-- after its own console countdown, so any flash can be pinned on the candidate
-- that caused it:
--
--   A) the SHIPPED pattern — a tiny .vbs shim run by wscript.exe. wscript is a
--      windowless (GUI-subsystem) program, so launching it allocates no console;
--      the shim then starts curl with its window HIDDEN, and if curl leaves no
--      file behind (curl missing, HTTP error) it tries hidden PowerShell the
--      same way. This is byte-for-byte the shim lib/updater.lua writes on every
--      check — candidate A passing clean is what clears the badge to ship.
--
--   B) cmd /c start /b curl — the other candidate from the handoff list.
--      cmd.exe is itself a console program, so a flash is EXPECTED here; it
--      runs anyway so the answer is observed, not assumed.
--
-- Also printed, purely for the record:
--   * whether js_ReaScriptAPI / SWS offer any process-spawn call on this
--     install (none is documented — APIExists answers for certain), and
--   * the live returns of ReaPack_GetRepositoryInfo("yb_update_test") — the ONE
--     ReaPack call the real feature uses that U1 never exercised. The
--     reconstruction expects: retval(true), url(string), enabled(bool),
--     autoInstall(number). If the returns sit in a different order, that is a
--     FINDING to report — lib/updater.lua assumes this order.
--
-- Copy ALL console output back to Claude, plus your flash verdict per candidate.

local REPO_URL = "https://raw.githubusercontent.com/ybresley/yb-reapack-test/main/index.xml"

local function say(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

say("")
say("=== 05b_quiet_fetch (build step 0) ===")
say("WATCH FOR CONSOLE-WINDOW FLASHES from now until the summary line.")

--------------------------------------------------------------- probes (instant)

say("")
say("-- probe: process-spawn APIs on this install --")
for _, name in ipairs({ "JS_ShellExecute", "JS_Process_Create", "JS_Exec", "CF_ShellExecute" }) do
  local here = reaper.APIExists and reaper.APIExists(name)
  say(string.format("  %-18s %s", name, here and "EXISTS" or "absent"))
end
say("  (CF_ShellExecute exists in SWS but takes a single file/URL and cannot")
say("   hide the launched window — informational only, not a candidate.)")

say("")
say("-- probe: ReaPack_GetRepositoryInfo (unproven in U1; the real feature needs it) --")
if reaper.APIExists and reaper.APIExists("ReaPack_GetRepositoryInfo") then
  local r = { pcall(reaper.ReaPack_GetRepositoryInfo, "yb_update_test") }
  if r[1] then
    say("  returned " .. (#r - 1) .. " values:")
    for i = 2, #r do
      say(string.format("    return #%d: [%s] %s", i - 1, type(r[i]), tostring(r[i])))
    end
    say("  expected: #1 true, #2 the raw index URL, #3 enabled(bool), #4 autoInstall(number).")
    say("  Any other order/shape is a FINDING - updater.lua assumes this one.")
  else
    say("  pcall ERROR: " .. tostring(r[2]) .. "  <- FINDING, report it")
  end
else
  say("  ReaPack_GetRepositoryInfo absent - FINDING, report it (ReaPack too old?)")
end

--------------------------------------------------------------- the candidates

local res = reaper.GetResourcePath()
local out_A = res .. "/yb_05b_A.xml"
local out_B = res .. "/yb_05b_B.xml"
local vbs   = res .. "/yb_05b_shim.vbs"

-- The shim, byte-for-byte what lib/updater.lua ships (keep the two in step by
-- hand — this harness is a separate repo). Windows paths and URLs cannot contain
-- double quotes, so doubling quotes around them inside VBS strings is safe; the
-- PowerShell arguments are single-quoted with any single quotes doubled.
-- --max-time 30 bounds a stalled curl so no invisible zombie outlives the test.
local function write_shim(out_path)
  local ps_url = (REPO_URL:gsub("'", "''"))
  local ps_out = (out_path:gsub("'", "''"))
  local lines = {
    'On Error Resume Next',
    'Set sh = CreateObject("WScript.Shell")',
    'Set fso = CreateObject("Scripting.FileSystemObject")',
    'sh.Run "curl -f -L --max-time 30 -o ""' .. out_path .. '"" ""' .. REPO_URL .. '""", 0, True',
    'ok = False',
    'If fso.FileExists("' .. out_path .. '") Then If fso.GetFile("' .. out_path .. '").Size > 0 Then ok = True',
    "If Not ok Then sh.Run \"powershell.exe -windowstyle hidden -command \"\"(new-object System.Net.WebClient).DownloadFile('"
      .. ps_url .. "','" .. ps_out .. "')\"\"\", 0, True",
  }
  local f = io.open(vbs, "wb")
  if not f then return false end
  f:write(table.concat(lines, "\r\n"), "\r\n")
  f:close()
  return true
end

local candidates = {
  {
    key = "A", out = out_A,
    label = "wscript + hidden-launch VBS shim (THE SHIPPED PATTERN)",
    build = function()
      if not write_shim(out_A) then return nil, "could not write the .vbs shim" end
      return 'wscript.exe //B "' .. vbs .. '"'
    end,
  },
  {
    key = "B", out = out_B,
    label = "cmd /c start /b curl (flash EXPECTED - observing, not assuming)",
    build = function()
      return 'cmd.exe /c start /b curl -f -L -o "' .. out_B .. '" "' .. REPO_URL .. '"'
    end,
  },
}

-- One state machine over defer frames: countdown -> launch -> poll -> next.
local idx, phase, t0, frames, gap_until = 1, "countdown", nil, 0, reaper.time_precise() + 3
local last_whole = nil

local function finish()
  say("")
  say("=== 05b summary ===")
  say("Report, for A and then B: flash or no flash, and the arrival lines above.")
  say("A clean = the shim ships as-is (Claude writes it into RESEARCH.md).")
  say("A flashing = STOP, report it - the badge feature stays parked until a new")
  say("candidate is designed with you watching.")
  say("Downloads kept for inspection: " .. out_A .. " / " .. out_B)
  os.remove(vbs)
  say("(the .vbs shim itself has been deleted)")
  say("=== 05b done ===")
end

local function step()
  local now = reaper.time_precise()
  local c = candidates[idx]
  if not c then finish() return end

  if phase == "countdown" then
    local left = gap_until - now
    if last_whole ~= math.ceil(left) and left > 0 then
      last_whole = math.ceil(left)
      say(string.format("candidate %s in %d... (eyes on the screen)", c.key, last_whole))
    end
    if now >= gap_until then
      say("")
      say(string.format("-- candidate %s: %s --", c.key, c.label))
      os.remove(c.out)
      local cmd, err = c.build()
      if not cmd then
        say("  SKIPPED: " .. tostring(err))
        idx, phase, gap_until, last_whole = idx + 1, "countdown", now + 3, nil
      else
        say("  cmd: " .. cmd)
        local ret = reaper.ExecProcess(cmd, -1) -- -1 = fire and forget (U6: returns "259" = launched)
        say("  ExecProcess returned: [" .. type(ret) .. "] " .. tostring(ret))
        say("  WATCH: any flash just now belongs to candidate " .. c.key)
        phase, t0, frames = "poll", now, 0
      end
    end
  elseif phase == "poll" then
    frames = frames + 1
    local f = io.open(c.out, "rb")
    if f then
      local content = f:read("a") or ""
      f:close()
      -- Only the closing tag proves the download is complete (U6's rule).
      if content:find("</index>", 1, true) then
        say(string.format("  file arrived COMPLETE after %d frames (%.2fs), %d bytes",
          frames, now - t0, #content))
        idx, phase, gap_until, last_whole = idx + 1, "countdown", now + 3, nil
      end
    end
    if phase == "poll" and now - t0 > 20 then
      say("  TIMEOUT: no complete file after 20s - if you are online, that is a")
      say("  FINDING for candidate " .. c.key .. " (report it); offline, it is the wanted silence.")
      idx, phase, gap_until, last_whole = idx + 1, "countdown", now + 3, nil
    end
  end
  reaper.defer(step)
end
reaper.defer(step)
