-- updater: the REAPER-facing half of the in-app update feature (DESIGN
-- "Distribution, updates & versioning"; mechanics in RESEARCH "In-app update
-- check + one-button update via ReaPack" — every call below was live-proven by
-- the U0–U9 prototype, 2026-08-02, except GetRepositoryInfo, which 05b probes).
--
-- What it does, from the user's side: once a day (and at tool startup) it
-- quietly downloads the tool's own ReaPack catalog and, if a newer version is
-- listed, lights the accent dot on the browser's gear; Settings' UPDATES
-- section then offers "Update now", which makes ReaPack update JUST this tool
-- (its own Progress window shows), then asks for a close-and-reopen. The next
-- launch reads the installed version after ReaPack's report has closed. Every
-- check failure is silent by design — no badge is the only failure mode.
--
-- The whole feature stands down when this copy wasn't installed through ReaPack
-- (dev copies have no registry owner — U1), and start_update refuses while the
-- package is PINNED in ReaPack (pins make syncs skip it — U8), saying so in
-- Settings instead of failing mysteriously.
--
-- CRASH SAFETY — the one dangerous moment this module owns: the single-repo
-- sync trick genuinely DISABLES our repo between its two halves. Dying exactly
-- there leaves the repo unticked in the user's ReaPack until someone fixes it.
-- So, reference.lua-style: a journal (ExtState, persisted) naming the repo is
-- written BEFORE the first call and cleared only after the restore call lands;
-- init() replays the U9-proven one-call recovery whenever it finds one
-- standing. The journal, not atexit, is the real safety net — atexit never
-- runs on a crash.
--
-- HARD RULE, learned live (2026-08-05 U14, then twice in the packaged gate on
-- 2026-08-17): once the second ProcessQueue call starts the sync, this running
-- instance makes ZERO further ReaPack calls — reads included. The one-file
-- prototype tolerated registry polling, but the real 59-file package aborted
-- REAPER while GetOwner/GetEntryInfo polled its changing entry. Removing the
-- later config write and automatic restart did not stop that second abort;
-- removing every post-launch ReaPack call is the smallest honest boundary.
--
-- A successful launch clears the crash journal immediately and deliberately
-- leaves this one-package repo enabled with autoInstall=1. That setting only
-- affects never-installed packages from this repo, and the repo contains only
-- yb-Reference, which is already installed. The journal now survives only an
-- actual failure/crash inside the disable -> re-enable launch window; a later
-- safe startup can still repair that exceptional state.
--
-- An adapter, so it calls reaper.* freely; the catalog parsing and version
-- maths live in core/update_check (pure, unit-tested). This module is spec'd
-- against a fake reaper (tests/updater_spec.lua) under the AGENTS adapter rule:
-- it holds a resource across defer frames (the in-flight fetch) AND owns a
-- safety invariant (never leave the repo broken without a recovery path).

local update_check = require("core.update_check")

local updater = {}

local SEP = package.config:sub(1, 1)

local EXT_SECTION = "yb-Reference"
local EXT_JOURNAL = "update_trick_recovery"

local CHECK_EVERY    = 24 * 60 * 60 -- daily while open (design: tool startup + every 24h)
local FETCH_TIMEOUT  = 20           -- U6: a fetch that hasn't landed by then never will; give up silently

-- What the UI reads (state.update in the entry script). One table for the whole
-- session — mutated, never replaced, per the frame-allocation rules.
--   enabled          false = the feature stood down (see disabled_reason)
--   disabled_reason  "noapi" (no ReaPack) | "dev" (not a ReaPack install) |
--                    "norepo" (repo record unreadable) | "repo_off" (user
--                    disabled our repo in ReaPack — respected, not overridden)
--   installed        the version ReaPack's registry says is installed
--   available        a strictly newer catalog version, or nil (nil = no badge)
--   pinned           the package is pinned in ReaPack (updates stand down)
--   phase            nil | "reopen" (the transaction was launched; no more
--                    ReaPack calls in this instance) | "done" (a manual update
--                    had already landed) | "failed_manual" (launch refused)
local S = {
  enabled = false, disabled_reason = nil,
  installed = nil, available = nil, pinned = false,
  phase = nil,
}
updater.state = S

-- Private bookkeeping.
local P = {
  own_path = nil,
  repo = nil, category = nil, package = nil, desc = nil, url = nil,
  next_check = math.huge,
  fetching = false, fetch_deadline = 0,
  tmp = nil, vbs = nil,
}

-- ReaPack API retvals are true on success but have come back as false/0/nil in
-- the prototype's failure probes — one rule for all of them (03's helper).
local function ok_ret(ok, ret)
  return ok and ret ~= false and ret ~= 0 and ret ~= nil
end

-- Our own registry entry, freshly read. nil when this copy has no ReaPack owner
-- (dev copy / uninstalled) or the entry can't be read. Positions live-proven by
-- U1: 10 returns — retval, repo, category, package file, desc, type, version,
-- author, flags (pin = nonzero), fileCount.
local function read_registry(path)
  local g_ok, entry = pcall(reaper.ReaPack_GetOwner, path)
  if not g_ok or not entry then return nil end
  local r = { pcall(reaper.ReaPack_GetEntryInfo, entry) }
  pcall(reaper.ReaPack_FreeEntry, entry)
  if not r[1] or r[2] == false or r[2] == 0 or r[2] == nil then return nil end
  if type(r[8]) ~= "string" or r[8] == "" then return nil end
  return {
    repo = r[3], category = r[4], package = r[5], desc = r[6],
    version = r[8],
    pinned = (type(r[10]) == "number" and r[10] ~= 0),
  }
end

local function clear_journal()
  reaper.DeleteExtState(EXT_SECTION, EXT_JOURNAL, true)
end

-- The journal's one-line encoding. Persistent ExtState lives in a line-based
-- ini file, so the value must never contain a newline (Codex, 2026-08-02
-- review: a "repo\nurl" value would be truncated at the newline on disk and
-- come back as just the repo name — a dead recovery note exactly when it
-- matters). Length-prefixing the name needs no separator character at all, so
-- no repo name or URL content can ever collide with the format.
local function encode_journal(name, url)
  return #name .. ":" .. name .. url
end

local function decode_journal(j)
  local len, rest = j:match("^(%d+):(.*)$")
  len = tonumber(len)
  if not len or len < 1 or #rest <= len then return nil end
  return rest:sub(1, len), rest:sub(len + 1)
end

-- Put the repo back to its everyday shape: enabled, auto-install following the
-- global setting. Completely silent (U5), and identical to the U9 crash
-- recovery. The journal is cleared ONLY when both calls land — left standing,
-- a later safe startup replays this.
local function restore_repo(name, url)
  local a_ok, a_ret = pcall(reaper.ReaPack_AddSetRepository, name, url, true, 2)
  if not ok_ret(a_ok, a_ret) then return false end
  if not pcall(reaper.ReaPack_ProcessQueue, true) then return false end
  clear_journal()
  return true
end

-- The flash-free fetch launch. ExecProcess on any console program flashes a
-- console window — U6 saw it from curl AND from "-windowstyle hidden"
-- PowerShell — so the download is started by wscript.exe instead: a windowless
-- (GUI-subsystem) program that allocates no console, running a tiny VBS shim
-- that starts curl with its window HIDDEN and falls back to hidden PowerShell
-- when curl leaves no file (curl missing, HTTP error). --max-time 15 keeps a
-- stalled curl INSIDE the 20s watch window, so the fallback usually lands
-- while someone is still looking for it (Codex, 2026-08-02 — it was 30, past
-- the deadline). A slow PowerShell fallback can still write the file after the
-- watcher gave up; that's accepted — every fetch and every startup deletes the
-- stale file before trusting anything. Mirrored byte-for-byte as candidate A
-- of yb-reapack-test/tests/05b_quiet_fetch.lua, the harness run that proves it
-- flash-free on a real screen.
--
-- Known edge, accepted: on a machine whose policy disables Windows Script Host
-- entirely (a server-hardening measure, not a DAW setup), wscript itself shows
-- a policy dialog //B can't suppress. If that ever bites, this is the one
-- function to rework.
--
-- Windows paths and URLs cannot contain double quotes, so doubling quotes
-- around them inside VBS strings is safe; the PowerShell arguments are
-- single-quoted with any single quotes doubled.
local function write_shim()
  local ps_url = (P.url:gsub("'", "''"))
  local ps_out = (P.tmp:gsub("'", "''"))
  local lines = {
    'On Error Resume Next',
    'Set sh = CreateObject("WScript.Shell")',
    'Set fso = CreateObject("Scripting.FileSystemObject")',
    'sh.Run "curl -f -L --max-time 15 -o ""' .. P.tmp .. '"" ""' .. P.url .. '""", 0, True',
    'ok = False',
    'If fso.FileExists("' .. P.tmp .. '") Then If fso.GetFile("' .. P.tmp .. '").Size > 0 Then ok = True',
    "If Not ok Then sh.Run \"powershell.exe -windowstyle hidden -command \"\"(new-object System.Net.WebClient).DownloadFile('"
      .. ps_url .. "','" .. ps_out .. "')\"\"\", 0, True",
  }
  local f = io.open(P.vbs, "wb")
  if not f then return false end
  f:write(table.concat(lines, "\r\n"), "\r\n")
  f:close()
  return true
end

-- The version this running copy actually IS, read from the entry script's own
-- ReaPack header. Every path below where the registry can't answer used to
-- leave `installed` nil, and Settings drew "v?" — honest (ReaPack has no record
-- of a hand-installed or junction-linked copy) but it reads as broken, and a
-- beta tester who can't say which build they're on is a bug report you can't
-- act on (2026-08-08, user's call, `.brief/settings-rows`).
--
-- The registry still WINS wherever there is one: that is the number ReaPack
-- compares against, and the two must never disagree about what an update means.
-- This is only the answer for copies ReaPack doesn't know about.
local function header_version(own_path)
  local f = io.open(own_path, "r")
  if not f then return nil end
  -- The header is the first handful of lines — stop there rather than reading
  -- a few thousand lines of script looking for something that isn't coming.
  local v
  for _ = 1, 40 do
    local line = f:read("l")
    if not line then break end
    v = line:match("^%-%-%s*@version%s+([%w%.%+%-]+)")
    if v then break end
  end
  f:close()
  return v
end

-- Once at startup. `own_path` is the entry script's absolute path — the thing
-- ReaPack's registry is asked about.
function updater.init(own_path)
  -- Set before every early return below, so no path can leave the version
  -- unknown; the registry overwrites it further down whenever there is one.
  S.installed = header_version(own_path)

  if not (reaper.APIExists("ReaPack_GetOwner")
      and reaper.APIExists("ReaPack_AddSetRepository")
      and reaper.APIExists("ReaPack_GetRepositoryInfo")
      and reaper.APIExists("ReaPack_CompareVersions")) then
    S.disabled_reason = "noapi"
    return
  end

  -- Crash recovery FIRST, before the owner check: a standing journal means a
  -- previous run died (or was closed) mid-trick and the repo may be sitting
  -- disabled. Safe to replay from ANY copy — re-enabling an already-enabled
  -- repo with autoInstall=2 is a silent config write (U5) — and it must not
  -- wait for a ReaPack-owned copy to be the next thing opened.
  local j = reaper.GetExtState(EXT_SECTION, EXT_JOURNAL)
  if j and j ~= "" then
    local name, url = decode_journal(j)
    if name then
      restore_repo(name, url) -- clears the journal only when it landed
    else
      clear_journal() -- unparseable: nothing actionable in it
    end
  end

  local reg = read_registry(own_path)
  if not reg then
    S.disabled_reason = "dev" -- the designed self-disable for non-ReaPack copies (U1)
    return
  end

  -- The repo's URL comes from ReaPack itself — never hard-coded, so the feature
  -- follows wherever the release shelf is imported from. Defensive shape checks
  -- because this is the one call the prototype never exercised (05b probes it).
  local g_ok, g_ret, g_url, g_enabled = pcall(reaper.ReaPack_GetRepositoryInfo, reg.repo)
  if not ok_ret(g_ok, g_ret) or type(g_url) ~= "string" or not g_url:match("^https?://") then
    S.disabled_reason = "norepo"
    return
  end
  -- A repo the user DISABLED in ReaPack is their call: no checks, no badge, and
  -- Settings says how to turn it back on rather than the tool silently
  -- re-enabling what they switched off.
  if g_enabled == false then
    S.disabled_reason = "repo_off"
    S.installed = reg.version
    return
  end

  P.own_path = own_path
  P.repo, P.category, P.package, P.desc = reg.repo, reg.category, reg.package, reg.desc
  P.url = g_url
  S.installed, S.pinned = reg.version, reg.pinned
  S.enabled = true

  local res = reaper.GetResourcePath()
  P.tmp = res .. SEP .. "yb_reference_update_check.xml"
  P.vbs = res .. SEP .. "yb_reference_update_fetch.vbs"
  os.remove(P.tmp) -- stale leftovers from a run that died mid-fetch
  os.remove(P.vbs)
  P.next_check = 0 -- first check on the first frame (design: at tool startup)
end

-- Every defer frame. Costs three compares on an idle frame; the file poll runs
-- only while a fetch is in flight (U6: ~20 frames) and is time-bounded.
function updater.tick()
  if not S.enabled then return end
  -- The transaction owns ReaPack now. Even read-only registry calls aborted the
  -- real multi-file package while its entry was changing, so this is a complete
  -- extension-API quarantine until the user closes the report and reopens.
  if S.phase == "reopen" then return end
  local now = reaper.time_precise()

  -- A fetch in flight: watch for the file. Only the closing tag counts — a
  -- partial file is still being written (U6's rule).
  if P.fetching then
    local f = io.open(P.tmp, "rb")
    if f then
      local content = f:read("a") or ""
      f:close()
      if content:find("</index>", 1, true) then
        P.fetching = false
        os.remove(P.tmp)
        os.remove(P.vbs)
        -- Fresh registry read before comparing: the user may have updated
        -- through ReaPack itself since the last look, and the badge must
        -- compare against what IS installed, not what was at startup. The
        -- identity fields follow too — a reinstall from a different shelf
        -- mid-session renames the repo under us, and the trick must aim at
        -- the repo that owns the package NOW.
        local reg = read_registry(P.own_path)
        if reg then
          P.repo, P.category, P.package, P.desc = reg.repo, reg.category, reg.package, reg.desc
          S.installed, S.pinned = reg.version, reg.pinned
          S.available = update_check.newer_available(content, P.package, P.category, reg.version)
        else
          -- No owner any more: the package was uninstalled while the tool ran.
          -- Stand the whole feature down, the dev-copy way.
          S.enabled, S.disabled_reason, S.available = false, "dev", nil
        end
        P.next_check = now + CHECK_EVERY
        return
      end
    end
    if now >= P.fetch_deadline then
      -- Silent give-up (U6's offline run): no badge IS the failure mode.
      P.fetching = false
      os.remove(P.tmp)
      os.remove(P.vbs)
      P.next_check = now + CHECK_EVERY
    end
    return
  end

  -- Time for the daily check. The next slot is claimed up front so no failure
  -- shape below can make this retry any sooner than the design says.
  if now >= P.next_check then
    P.next_check = now + CHECK_EVERY
    os.remove(P.tmp) -- a stale complete file must not satisfy the poll instantly
    if write_shim() then
      local ret = reaper.ExecProcess('wscript.exe //B "' .. P.vbs .. '"', -1)
      -- -1 = fire and forget; a launch returns the string "259" (STILL_ACTIVE,
      -- U6) and nil means it never started — then there is nothing to wait
      -- for, and the shim it would have read is cleaned up right here (Codex,
      -- 2026-08-02: this was the one path that left the .vbs behind).
      if ret ~= nil then
        P.fetching = true
        P.fetch_deadline = now + FETCH_TIMEOUT
      else
        os.remove(P.vbs)
      end
    end
  end
end

-- A fresh registry read for the display fields — called when Settings opens, so
-- the version line and the pinned state describe NOW, not the last daily check
-- (unpinning in ReaPack would otherwise leave Settings claiming "paused" for
-- up to a day). It stands down completely after an update starts: opening
-- Settings must not punch through the post-launch ReaPack quarantine.
function updater.refresh_registry()
  if not S.enabled or S.phase == "reopen" then return end
  local reg = read_registry(P.own_path)
  if not reg then
    S.enabled, S.disabled_reason, S.available = false, "dev", nil
    return
  end
  P.repo, P.category, P.package, P.desc = reg.repo, reg.category, reg.package, reg.desc
  S.installed, S.pinned = reg.version, reg.pinned
end

-- The Settings button. Runs the U3-proven single-repo sync trick:
-- disable -> ProcessQueue -> enable(autoInstall=1) -> ProcessQueue queues a real
-- sync scoped to our repo alone (ReaPack's own Progress window shows). The
-- autoInstall on the re-enable MUST be 1 — 2 defers to the global "install new
-- packages" checkbox (usually off) and the gate closes, syncing nothing (U4).
-- After the second ProcessQueue begins, this instance never calls ReaPack again.
function updater.start_update()
  if not S.enabled or S.phase == "reopen" then return end

  -- Fresh looks at everything the trick rides on — session-old answers could
  -- have changed underneath us (a pin set five minutes ago, a manual sync, the
  -- repo removed or disabled in Manage repositories).
  local reg = read_registry(P.own_path)
  if not reg then
    S.enabled, S.disabled_reason = false, "dev"
    return
  end
  P.repo, P.category, P.package, P.desc = reg.repo, reg.category, reg.package, reg.desc
  S.installed, S.pinned = reg.version, reg.pinned
  if reg.pinned then return end -- Settings explains the pin; a sync would silently skip us (U8)

  local g_ok, g_ret, g_url, g_enabled = pcall(reaper.ReaPack_GetRepositoryInfo, P.repo)
  if not ok_ret(g_ok, g_ret) or type(g_url) ~= "string" or not g_url:match("^https?://")
    or g_enabled == false then
    S.phase = "failed_manual"
    return
  end
  P.url = g_url -- follow a re-imported repo to its current URL

  -- Nothing left to install? A manual ReaPack sync can land the update
  -- mid-session — the files on disk are new even though this running code is
  -- old. That IS the updated state: say "close and reopen", don't re-sync.
  if S.available then
    local c_ok, c = pcall(reaper.ReaPack_CompareVersions, S.available, reg.version)
    if c_ok and type(c) == "number" and c <= 0 then
      S.available = nil
      S.phase = "done"
      return
    end
  end

  -- The crash window opens here. Journal first, always — persisted ExtState,
  -- exactly like reference.lua's recovery note: what to put back, written
  -- BEFORE anything is touched. And VERIFIED: the journal is the only safety
  -- net, so it's read straight back, and if what's stored isn't what was
  -- written (a write refused or mangled), the update refuses to start rather
  -- than open the crash window unprotected — the same "no record laid down,
  -- no mutation" rule reference.lua latches by.
  local note = encode_journal(P.repo, P.url)
  reaper.SetExtState(EXT_SECTION, EXT_JOURNAL, note, true)
  if reaper.GetExtState(EXT_SECTION, EXT_JOURNAL) ~= note then
    clear_journal()
    S.phase = "failed_manual"
    return
  end

  local d_ok, d_ret = pcall(reaper.ReaPack_AddSetRepository, P.repo, P.url, false, 2)
  if not ok_ret(d_ok, d_ret) then
    -- The disable itself was refused: nothing changed. Restore clears the
    -- journal; if even that fails the journal stands for the next startup.
    restore_repo(P.repo, P.url)
    S.phase = "failed_manual"
    return
  end
  local q1 = pcall(reaper.ReaPack_ProcessQueue, true)
  if not q1 then
    -- No sync was requested: this queue only applied the disabled state, so an
    -- immediate restore is safe. The journal remains if that repair also fails.
    restore_repo(P.repo, P.url)
    S.phase = "failed_manual"
    return
  end

  local e_ok, e_ret = pcall(reaper.ReaPack_AddSetRepository, P.repo, P.url, true, 1)
  if not ok_ret(e_ok, e_ret) then
    -- Still before the sync request, so restoring now cannot overlap one.
    restore_repo(P.repo, P.url)
    S.phase = "failed_manual"
    return
  end

  -- From this call onward: ZERO ReaPack APIs in this instance. Even if pcall
  -- reports an error, the extension may have started enough work that another
  -- call would race it. The standing journal then repairs the repo only on a
  -- later launch; a normal successful return can clear the note because the
  -- repo is already enabled and deliberately remains at autoInstall=1.
  local q2 = pcall(reaper.ReaPack_ProcessQueue, true)
  if q2 then clear_journal() end
  S.phase = "reopen"
end

return updater
