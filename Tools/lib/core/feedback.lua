-- feedback (core): the pure half of the Send-feedback panel — building the
-- report payload and describing what rides along. Decided end to end in
-- `.brief/_done/send-feedback/` (DESIGN "Send feedback"); the REAPER-facing
-- sender lives in lib/feedback.lua.
--
-- Pure Lua: no reaper.*, no ImGui. Everything REAPER knows (versions, install
-- state) arrives here as plain values.

local json = require("vendor.json")

local feedback = {}

-- The message cap (user's call, 2026-08-09, revised same day: "like 1000 —
-- generous but not insane"). The composer stops taking more; the doorman clips
-- again server-side (at its own 2000 — deliberately looser, so this number can
-- move without redeploying the helper), so junk knocking directly on the URL
-- can't balloon the sheet either.
feedback.MAX_MESSAGE = 1000

-- The email field rides along unvalidated (decided: no format nagging), but
-- never unbounded.
feedback.MAX_EMAIL = 200

-- Cut to a CHARACTER count, never through the middle of a character (Codex,
-- 2026-08-09: a byte cap can split a multi-byte character — an é, a ü, an
-- emoji — leaving broken text in the box and in the payload). Invalid bytes
-- fall back to the byte cap: there is no character boundary to respect.
local function utf8_clip(text, max_chars)
  if utf8.len(text) then
    if utf8.len(text) <= max_chars then return text end
    return text:sub(1, utf8.offset(text, max_chars + 1) - 1)
  end
  return text:sub(1, max_chars)
end

-- Clip a draft to the cap. Used by the composer every frame the box changes,
-- so the cap is one number living in one place.
function feedback.clip(text)
  if type(text) ~= "string" then return "" end
  return utf8_clip(text, feedback.MAX_MESSAGE)
end

-- How full the draft is, for the composer's counter: characters, matching the
-- cap's own unit.
function feedback.count(text)
  if type(text) ~= "string" then return 0 end
  return utf8.len(text) or #text
end

-- "7.66/x64" -> "7.66". REAPER's GetAppVersion carries the platform after a
-- slash; the panel and the sheet both want just the number (the platform is
-- always Windows 64-bit — saying it told the reader nothing, user's call).
function feedback.reaper_version(raw)
  if type(raw) ~= "string" then return "?" end
  local v = raw:match("^([^/]+)")
  return (v and v ~= "") and v or "?"
end

-- Which kind of copy is running, from the update feature's own standing state.
-- "ReaPack install" vs "manual copy" is the word that decodes a report whose
-- version number doesn't match its behaviour (a hand-copied build may be older
-- or newer than its @version claims). `repo_off` still means ReaPack owns the
-- copy — the user only disabled the repo.
function feedback.install_kind(enabled, disabled_reason)
  if enabled or disabled_reason == "repo_off" then return "ReaPack install" end
  return "manual copy"
end

-- The wire payload for the doorman (JSON; vendor.json owns the escaping).
-- Returns nil for a message that is empty once trimmed — the Send button is
-- dead then, so reaching here empty would be a caller bug surfaced as no-op.
function feedback.payload(fields)
  local msg = feedback.clip(fields.message)
  if msg:match("^%s*$") then return nil end
  return json.encode({
    message = msg,
    email = utf8_clip(tostring(fields.email or ""), feedback.MAX_EMAIL),
    tool = tostring(fields.tool or "?"),
    reaper = tostring(fields.reaper or "?"),
    install = tostring(fields.install or "?"),
  })
end

-- The doorman's success signal is the literal body "ok" (live-proven at setup,
-- 2026-08-09). Whitespace tolerated; anything else — an error page, a "bad",
-- half a file — is not success.
function feedback.is_ok(reply)
  if type(reply) ~= "string" then return false end
  return reply:match("^%s*(.-)%s*$") == "ok"
end

return feedback
