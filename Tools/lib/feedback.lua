-- feedback: the REAPER-facing half of the Send-feedback panel — it takes a
-- ready payload (core/feedback builds it), delivers it to the doorman in the
-- background, and answers "sent" only when the doorman's literal "ok" came
-- back. Decided end to end in `.brief/_done/send-feedback/`; the delivery
-- route was live-proven from this machine and from inside REAPER before this
-- module was written (2026-08-09).
--
-- THE PROMISE THIS MODULE OWNS: a report is never lost SILENTLY. Success is
-- claimed only on the doorman's own "ok"; every other shape — offline, a slow
-- network, a dead URL, a policy-locked machine — ends in phase "failed", which
-- the UI turns into the loud clipboard-plus-address fallback. Between those
-- two ends there is nothing.
--
-- The send is a TWO-TIER spawn, under 10 s end to end (user's call — 20 was
-- too long):
--   tier 1  the updater's proven wscript/VBS courier: invisible, no console
--           window. On a machine whose policy disables Windows Script Host it
--           does nothing (or shows a policy dialog //B can't suppress) —
--           which is exactly why tier 2 exists.
--   tier 2  curl launched directly. ExecProcess flashes a console window for
--           ~half a second (U6's finding) — accepted HERE and only here,
--           because the user just pressed Send; the updater's background
--           checks must never flash, so don't copy this shortcut there.
--
-- Both tiers write the same reply file: tier 1's curl carries --max-time 4,
-- so it is dead before the 4.5 s watch hands over and the two can't race.
--
-- An adapter, so it calls reaper.* freely. Spec'd against a fake reaper
-- (tests/feedback_spec.lua) under the AGENTS adapter rule: it holds an
-- in-flight send across defer frames, and owns the never-silently-lost
-- sequencing above. A fake can't prove curl or the doorman — the probe and
-- the live setup test did that.

local fb_core = require("core.feedback")

local feedback = {}

local SEP = package.config:sub(1, 1)

-- The doorman's address (the user's own Apps Script deployment, 2026-08-09)
-- and the public support mailbox shown whenever delivery fails. Keeping the
-- mailbox here gives startup failures and the Feedback panel one source of truth.
feedback.URL = "https://script.google.com/macros/s/AKfycbyO_6OjXKDv8kUfqImqqBYz7L1hjy51jn1Ux4_iCBCP8I9wLpt3-evxQq-vGdZ7VqCB/exec"
feedback.ADDRESS = "yoni.ybtools@gmail.com"

-- Each tier gets 4.5 s of watching; its curl gets 4 s of network, so a stalled
-- try is dead before its watch ends. Worst case a report fails in 9 s.
local TIER_WATCH = 4.5
local CURL_SECS = 4

-- What the UI reads (state.feedback in the entry script). One table for the
-- session — mutated, never replaced. phase: nil | "sending" | "sent" |
-- "failed". The entry script fills the display fields (attach line, remembered
-- email) at startup; this module only ever touches phase.
local S = { phase = nil }
feedback.state = S

local P = {
  base = nil,                            -- temp-file stem, set by init
  payload = nil, reply = nil, vbs = nil, -- this send's files, set by start
  flip = 0, -- alternates per send (see start)
  tier = 0,
  deadline = 0,
}

-- The three temp files for one send, suffixed 0 or 1. Two sends never share
-- filenames (Codex, 2026-08-09): a courier from the PREVIOUS send that stalled
-- before launching its curl could otherwise write the reply file after this
-- send staged its own — a stale "ok" claiming a report that didn't land. By
-- the send after next, any such straggler's curl (--max-time 4) is long dead,
-- so two alternating names close the race completely.
local function send_files(n)
  return P.base .. "_payload" .. n .. ".json",
    P.base .. "_reply" .. n .. ".txt",
    P.base .. "_send" .. n .. ".vbs"
end

-- The tier-1 shim: wscript runs curl with its window hidden (style 0), waiting
-- so curl's --max-time bounds the whole thing. Same quoting ground rules as
-- the updater's shim: Windows paths and URLs cannot contain double quotes, so
-- doubling quotes around them inside VBS strings is safe. No PowerShell
-- fallback here — POSTing a file with WebClient is a different shape, and
-- tier 2 already covers a curl-less or WSH-less machine ending in a loud fail.
local function curl_cmd()
  return 'curl -s -L --max-time ' .. CURL_SECS
    .. ' -H "Content-Type: application/json"'
    .. ' -d @"' .. P.payload .. '" -o "' .. P.reply .. '" "' .. feedback.URL .. '"'
end

local function write_shim()
  local f = io.open(P.vbs, "wb")
  if not f then return false end
  f:write('On Error Resume Next\r\n'
    .. 'Set sh = CreateObject("WScript.Shell")\r\n'
    .. 'sh.Run "' .. curl_cmd():gsub('"', '""') .. '", 0, True\r\n')
  f:close()
  return true
end

local function cleanup()
  os.remove(P.payload)
  os.remove(P.reply)
  os.remove(P.vbs)
end

-- Tier 2: the direct, policy-proof launch. Returns false when even starting it
-- failed — then there is nothing in flight and nothing to wait for.
local function launch_direct()
  return reaper.ExecProcess(curl_cmd(), -1) ~= nil
end

local function fail()
  cleanup()
  S.phase = "failed"
end

-- Once at startup. Stale temp files from a run that died mid-send must not
-- satisfy this run's reply poll — both parities go.
function feedback.init()
  P.base = reaper.GetResourcePath() .. SEP .. "yb_reference_feedback"
  for n = 0, 1 do
    local payload, reply, vbs = send_files(n)
    os.remove(payload)
    os.remove(reply)
    os.remove(vbs)
  end
end

-- Kick off a send. `payload_json` comes from core/feedback.payload — already
-- clipped, escaped and non-empty. A send already in flight refuses (the UI's
-- Send button is dead then; two curls aimed at one reply file is the race this
-- guard exists for). Starting over from "sent" or "failed" is the retry path.
function feedback.start(payload_json)
  if S.phase == "sending" or type(payload_json) ~= "string" then return end

  P.flip = 1 - P.flip
  P.payload, P.reply, P.vbs = send_files(P.flip)
  cleanup() -- leftovers from two sends ago; nothing alive can still write them
  local f = io.open(P.payload, "wb")
  if not f then
    -- Can't even stage the payload (resource dir unwritable): fail loudly now
    -- rather than spawning a courier with nothing to carry.
    S.phase = "failed"
    return
  end
  f:write(payload_json)
  f:close()

  S.phase = "sending"
  local quiet = write_shim()
    and reaper.ExecProcess('wscript.exe //B "' .. P.vbs .. '"', -1) ~= nil
  if quiet then
    P.tier = 1
  elseif launch_direct() then
    -- The quiet courier never left the garage — go straight to the visible try.
    P.tier = 2
  else
    fail()
    return
  end
  P.deadline = reaper.time_precise() + TIER_WATCH
end

-- Every defer frame. Idle frames cost one compare; the file poll runs only
-- while a send is in flight, and the whole thing is time-bounded.
function feedback.tick()
  if S.phase ~= "sending" then return end

  local f = io.open(P.reply, "rb")
  if f then
    local reply = f:read("a") or ""
    f:close()
    -- Only the doorman's literal "ok" ends the wait early. Anything else in
    -- the file (an error page, a half-written body) keeps the clock running —
    -- tier 2 truncates and rewrites the same file, so a wrong answer from
    -- tier 1 still gets its second chance.
    if fb_core.is_ok(reply) then
      cleanup()
      S.phase = "sent"
      return
    end
  end

  if reaper.time_precise() >= P.deadline then
    if P.tier == 1 and launch_direct() then
      P.tier = 2
      P.deadline = reaper.time_precise() + TIER_WATCH
    else
      fail()
    end
  end
end

return feedback
