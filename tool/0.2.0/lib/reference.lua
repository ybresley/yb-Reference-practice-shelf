-- reference: the reference-mode adapter (a sibling of reaper_api/preview — one of
-- the few modules allowed to call reaper.*). It owns the crash-safe "latch": while
-- ON, the project's master is muted so pressing play in REAPER auditions the chosen
-- reference sound instead of the project. The preview playback itself is driven by
-- the entry script (it owns the single preview and the one defer loop); this module
-- owns only the safety machinery, so a crash can never leave a master silently muted.
--
-- THE ONE INVARIANT: a master we muted is never left muted without a way to undo it.
-- Everything below exists to keep that true. Three ideas carry it:
--
-- 1. TWO RECORDS, each good at a different job, both written BEFORE the mute lands:
--    * A marker inside the project (project ExtState) holding the prior mute value.
--      This is the authoritative record. It travels WITH the project — through "Save
--      As", through a rename, and it works for a never-saved project — because it is
--      stored in the same place as the mute itself. If the mute survived, the marker
--      survived; if the marker is gone, the mute went with it. A file path can't do
--      this: renaming the project would strand it.
--    * A note on disk (the journal) saying "an obligation is outstanding somewhere",
--      plus the project's name so we can TELL the user which one. Needed because a
--      project that isn't open can't be scanned for markers.
--    NOT ExtState for the disk note: persistent ExtState is only flushed on a clean
--    REAPER exit, so it would not survive the crash it exists to recover from.
--
-- 2. AN OBLIGATION IS ONLY FORGOTTEN ONCE IT IS PROVABLY DISCHARGED. Every restore is
--    read back to confirm it took, and the note is deleted last (and verified gone).
--    If we cannot finish the job — the project was closed, a write failed — we KEEP
--    the note and refuse to latch again until it's settled. Losing the note is the
--    only truly unrecoverable outcome, so we never do it on a guess.
--
-- 3. RESTORE-IF-UNCHANGED, always: if the user unmuted the master by hand, that is
--    their call and we leave it alone.
--
-- Why muting the master gives a clean A/B: the preview routes to a hardware output
-- (through Monitor FX), NOT through the master track, so muting the master silences
-- the PROJECT while the reference preview stays audible.
--
-- Known limitation (documented, not an oversight): if two copies of yb_Reference run
-- at once, the second sees the first's live marker and restores it. The latch then
-- stops working in the first window (its restore-if-unchanged check correctly declines
-- to re-mute), which is visible rather than dangerous. REAPER's own "script already
-- running" prompt makes this rare, so it isn't worth an ownership lease and the
-- staleness bugs that come with one.

local reference = {}

local SEP = package.config:sub(1, 1)

local JOURNAL = reaper.GetResourcePath() .. SEP .. "yb_Reference_ref_journal.txt"

-- The marker lives in the project's own ExtState, so it is saved into the .rpp
-- alongside the mute it describes.
local PROJ_SECTION = "yb_Reference"
local PROJ_KEY     = "ref_recovery"

-- The companion action (a separate one-line script the user binds to a hotkey) pulses
-- this ExtState value to "1"; the main script sees it, toggles the latch, and clears
-- it. The main script also clears it at startup and exit, so a press made while the
-- tool was closed can't silently latch on the next launch.
local EXT_SECTION = "yb_Reference"
local EXT_TOGGLE  = "ref_toggle_request"

-- Live latch state, remembered in memory so turning the latch off never depends on
-- re-reading a file. `proj` is the project we actually latched.
local latch = { on = false, proj = nil, prev_mute = nil, token = nil }

-- Set while an obligation is outstanding that we could NOT discharge (project closed,
-- a write or delete failed). While this is set we refuse to latch anything new, so a
-- second latch can't overwrite the note that is still needed to rescue the first.
local pending = nil

--------------------------------------------------------------- projects

-- REAPER lets the user switch project tabs at any moment, so "the master track" is an
-- ambiguous thing to hold on to. We pin the project we latched and only ever act on
-- THAT one; using whichever project happens to be in front would unmute the wrong
-- project and leave the latched one muted for good.
local function current_project()
  local proj, path = reaper.EnumProjects(-1)
  return proj, path or ""
end

-- A stored project pointer goes stale if the user closes that tab, and touching freed
-- memory is a crash — so every later use is validated first.
local function project_alive(proj)
  if not proj then return false end
  return reaper.ValidatePtr2(0, proj, "ReaProject*")
end

-- Is a project with this file path currently open? Used only to tell "that project is
-- gone" apart from "that project is open and clean" during recovery.
local function project_open(path)
  if path == "" then return false end
  local i = 0
  while true do
    local proj, p = reaper.EnumProjects(i)
    if not proj then return false end
    if p == path then return true end
    i = i + 1
  end
end

local function get_master_mute(proj)
  return reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(proj), "B_MUTE")
end

-- Set the mute and READ IT BACK. A write we merely asked for isn't proof: if it
-- silently didn't take and we deleted the recovery note on that assumption, the mute
-- would be stranded with nothing left to fix it.
local function set_master_mute(proj, v)
  reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(proj), "B_MUTE", v)
  return get_master_mute(proj) == v
end

--------------------------------------------------------------- the project marker

-- Write the marker and READ IT BACK, for the same reason every mute write is read
-- back: this is the AUTHORITATIVE record, and a write we merely asked for is not
-- proof. If the marker never landed and we muted anyway, a later recovery would find
-- the note's project open but carrying no marker, conclude it had reloaded clean,
-- delete the note and walk away — leaving the master muted with nothing left to
-- describe it. That is the one unrecoverable outcome.
local function marker_write(proj, token, prev_mute)
  local value = ("%s|%d"):format(token, prev_mute)
  reaper.SetProjExtState(proj, PROJ_SECTION, PROJ_KEY, value)
  local _, got = reaper.GetProjExtState(proj, PROJ_SECTION, PROJ_KEY)
  return got == value
end

local function marker_read(proj)
  local _, v = reaper.GetProjExtState(proj, PROJ_SECTION, PROJ_KEY)
  if not v or v == "" then return nil end
  local token, prev = v:match("^([^|]*)|(%d+)$")
  if not token then return nil end
  return { token = token, prev = tonumber(prev) }
end

-- Clear the marker and confirm it is gone — same reasoning as verifying the note's
-- deletion. A marker left behind describes a mute we have already put back, so a
-- later startup would "restore" it over whatever the user has deliberately chosen
-- since (deliberately muting their own master, say).
local function marker_clear(proj)
  reaper.SetProjExtState(proj, PROJ_SECTION, PROJ_KEY, "")
  return marker_read(proj) == nil
end

--------------------------------------------------------------- journal

-- Returns true only when the note is completely on disk. A half-written note is worse
-- than none, so a failed write removes the remains and reports failure — latch_on then
-- refuses to mute anything.
--
-- Written to a temp file first, then renamed into place: REAPER itself dying mid-write
-- would otherwise leave a torn note that the next run reads as damaged and locks the
-- latch over — a false alarm, since the mute only ever lands AFTER this returns. A
-- stray temp from such a crash is swept at recovery. (Windows: rename won't overwrite,
-- and no journal can exist here — latching is refused while one is outstanding.)
local function journal_write(token, prev_mute, project_path)
  local tmp = JOURNAL .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  local written = f:write(("set_mute=1\nprev_mute=%d\ntoken=%s\nproject=%s\n")
    :format(prev_mute, token, project_path))
  local closed = f:close() -- a full disk usually only surfaces at close
  if not written or not closed or not os.rename(tmp, JOURNAL) then
    os.remove(tmp)
    return false
  end
  return true
end

local function journal_read()
  local f = io.open(JOURNAL, "r")
  if not f then return nil end
  local txt = f:read("*a")
  f:close()
  -- A note that opens but won't read is damaged, not absent: fall through to the
  -- damaged-note handling rather than crashing on a nil here.
  if type(txt) ~= "string" then txt = "" end
  return {
    set     = tonumber(txt:match("set_mute=(%d+)")),
    prev    = tonumber(txt:match("prev_mute=(%d+)")),
    token   = txt:match("token=([^\n]*)"),
    project = txt:match("project=([^\n]*)") or "",
  }
end

-- Confirm the note is actually gone. A delete that quietly failed would leave a note
-- describing a mute we already put back — and the next startup would "restore" it over
-- a value the user has since chosen deliberately.
local function journal_delete()
  os.remove(JOURNAL)
  local f = io.open(JOURNAL, "r")
  if f then f:close(); return false end
  return true
end

--------------------------------------------------------------- latch

function reference.is_latched() return latch.on end

-- The outstanding-obligation message, or nil when everything is settled.
function reference.pending() return pending end

local function new_token()
  return ("%d-%d"):format(os.time(), math.floor(reaper.time_precise() * 1000) % 1000000)
end

-- Latch ON: silence the project. Returns (false, reason) having changed NOTHING if the
-- records can't be laid down first, or if an earlier obligation is still outstanding —
-- latching again would overwrite the note that is still needed to rescue it.
-- Silencing happens here, never at play-detection, so no blip of project audio can
-- leak out before the mute lands.
function reference.latch_on()
  if latch.on then return true end

  -- An outstanding obligation might have become resolvable since we last looked (the
  -- user may have reopened the project), so re-check before refusing. This is what
  -- stops an unresolved note becoming a dead end the user can't get out of.
  if pending then
    reference.recover()
    if pending then return false, pending end
  end

  local proj, path = current_project()

  -- A marker already sitting in this project is a crash survivor: the project was
  -- saved while latched, then crashed, and was only reopened after startup recovery
  -- had already settled the disk note (an unsaved-at-the-time project's note carries
  -- no path, so recovery can't wait for it). That marker's prior value is the truth
  -- about this master — the CURRENT mute is our own crash residue, and recording it
  -- as "prior" would restore the mute on un-latch and strand the master muted with
  -- both records gone. Adopting the surviving value makes pressing REF the rescue.
  --
  -- Adopted ONLY while the residue is still in place (master still muted). If the
  -- master is unmuted, the user already resolved the crash by hand, and their
  -- latest choice — not the marker's memory of an older one — is what un-latch must
  -- restore. The stale marker is then simply replaced by the new latch's own.
  local survivor = marker_read(proj)
  local current = get_master_mute(proj)
  local prev = (survivor and current == 1) and survivor.prev or current
  local token = new_token()

  -- Both records go down BEFORE the mute, and both are verified. If we die between
  -- them they describe a mute that never happened — and restore-if-unchanged then
  -- correctly does nothing. If either can't be laid down, nothing is muted at all.
  if not marker_write(proj, token, prev) then
    return false, "Reference mode couldn't start — it couldn't store a recovery marker inside your project, so your project was left alone."
  end
  if not journal_write(token, prev, path) then
    marker_clear(proj)
    return false, "Reference mode couldn't start — its safety note couldn't be saved, so your project was left alone."
  end

  if not set_master_mute(proj, 1) then
    marker_clear(proj)
    -- The journal describes a mute that never landed, so it must go — and if it
    -- WON'T go, fail closed: a leftover journal would block every later latch at
    -- the write step anyway (the atomic rename refuses to overwrite), so say why
    -- once, honestly, and let recovery settle it at the next opportunity.
    if not journal_delete() then
      pending = "Reference mode couldn't mute your project, and its leftover safety note " ..
                "couldn't be removed (" .. JOURNAL .. "). Delete that file by hand, or simply " ..
                "reopen the tool."
      return false, pending
    end
    return false, "Reference mode couldn't mute your project, so it was left alone."
  end

  latch.on, latch.proj, latch.prev_mute, latch.token = true, proj, prev, token
  return true
end

-- Latch OFF: put the master back the way we found it, then forget the obligation —
-- but only once it is provably discharged. Returns true when fully settled.
function reference.latch_off()
  if not latch.on then return true end
  local proj, prev = latch.proj, latch.prev_mute
  latch.on, latch.proj, latch.prev_mute, latch.token = false, nil, nil, nil

  -- The project we muted has been closed. If it was saved while latched, that mute is
  -- in the file and outlives us, so the note MUST stay — dropping it here is what
  -- would strand the user's master for good.
  if not project_alive(proj) then
    pending = "Reference mode: the project you were referencing against was closed before it could be " ..
              "un-muted. Open it again and yb_Reference will restore its master."
    return false
  end

  -- Restore-if-unchanged: only put our value back if the master still holds the mute
  -- we set. If the user unmuted it by hand, that's theirs to keep.
  if get_master_mute(proj) == 1 and not set_master_mute(proj, prev) then
    pending = "Reference mode couldn't un-mute your project. Its master is still muted — " ..
              "unmute it by hand, or reopen the project and yb_Reference will try again."
    return false
  end

  -- Both records have to be provably gone before the obligation is forgotten — the
  -- note is kept either way, so the next run retries the cleanup.
  if not marker_clear(proj) then
    pending = "Reference mode restored your project, but couldn't clear the recovery marker stored inside " ..
              "it. Save the project (or restart REAPER) so a later run doesn't act on a marker that is " ..
              "already dealt with."
    return false
  end
  if not journal_delete() then
    pending = "Reference mode: your project was restored, but its recovery note couldn't be removed " ..
              "(" .. JOURNAL .. "). Delete that file by hand."
    return false
  end
  pending = nil
  return true
end

--------------------------------------------------------------- startup recovery

-- Runs at startup (and again whenever an outstanding obligation might have become
-- resolvable). Restores every open project still carrying our marker, then settles the
-- disk note. Returns (message, urgent) — urgent means the user must act.
--
-- Driving this from the markers rather than the note means it still rescues a project
-- that was renamed via "Save As", and still works when the note itself is damaged.
function reference.recover()
  if latch.on then return nil end -- we own the live records; nothing here is stale

  local j = journal_read()
  os.remove(JOURNAL .. ".tmp") -- a torn write from a crash mid-journal; never a real note
  if reaper.APIExists("CF_Preview_StopAll") then
    reaper.CF_Preview_StopAll() -- a dead script couldn't stop its own preview
  end

  -- Sweep every open project for our marker. Each one is self-sufficient: it carries
  -- the prior value, so it can be honoured without the note.
  local restored, failed, stuck, seen = 0, 0, 0, {}
  local i = 0
  while true do
    local proj = reaper.EnumProjects(i)
    if not proj then break end
    local m = marker_read(proj)
    if m then
      seen[m.token] = true
      local ok = true
      if get_master_mute(proj) == 1 then ok = set_master_mute(proj, m.prev) end
      -- Three outcomes, kept apart so the user is told the truth about which one
      -- happened: the master couldn't be put back, it was put back but the marker
      -- describing it wouldn't clear, or the job is genuinely done.
      if not ok then
        failed = failed + 1
      elseif not marker_clear(proj) then
        stuck = stuck + 1
      else
        restored = restored + 1
      end
    end
    i = i + 1
  end

  local recovered_msg = restored > 0
    and "Reference mode recovered from an unexpected close — your master mute was restored."
    or nil

  if failed > 0 then
    pending = "Reference mode couldn't un-mute a project it had silenced. Please check your master " ..
              "track and unmute it by hand."
    return pending, true
  end

  -- The master is correct, but a marker we can't remove would be read again next
  -- time — and by then the user's own mute setting may be something they chose.
  if stuck > 0 then
    pending = "Reference mode put your project's master back, but couldn't clear the recovery marker " ..
              "stored inside the project. Save the project (or restart REAPER) so a later run doesn't " ..
              "act on a marker that is already dealt with."
    return pending, true
  end

  if not j then
    pending = nil
    return recovered_msg, false
  end

  -- No marker turned up for this note, which has two very different meanings. Telling
  -- them apart matters both ways: guess "gone" and we lock the latch over a project
  -- that is perfectly fine; guess "clean" and we strand a muted master.
  --
  -- REAPER does NOT mark the project dirty when we mute the master (verified in REAPER),
  -- so our change only ever reaches the .rpp if the user saved for their own reasons —
  -- and the marker is saved by that same save. So a project that is OPEN and carries no
  -- marker was reloaded clean: nothing of ours survived, and there is nothing to undo.
  -- Same for a project that had never been saved when we latched (no path), since an
  -- unsaved project cannot carry anything across a restart.
  if j.token and not seen[j.token] and not (j.project == "" or project_open(j.project)) then
    -- Genuinely not open. If it WAS saved while latched, its master is still muted
    -- inside the file and only a later run, with it open, can put that right.
    pending = "Reference mode was interrupted in \"" .. j.project .. "\" — open that project and " ..
              "yb_Reference will restore its master."
    return pending, true
  end

  -- A damaged note with nothing to match it against: we can't prove the obligation was
  -- discharged, so we don't pretend it was.
  if not j.token and restored == 0 then
    pending = "Reference mode: a recovery note was damaged (" .. JOURNAL .. "). If a project's master " ..
              "is muted unexpectedly, unmute it by hand, then delete that file."
    return pending, true
  end

  -- Delete the note LAST, once the master is provably back. Deleting it first would
  -- mean a crash in between leaves the mute with no note left to recover it.
  if not journal_delete() then
    pending = "Reference mode: your project was restored, but its recovery note couldn't be removed " ..
              "(" .. JOURNAL .. "). Delete that file by hand."
    return pending, true
  end

  pending = nil
  return recovered_msg, false
end

--------------------------------------------------------------- transport + hotkey

-- Is the LATCHED project's transport playing? Deliberately not the global play state:
-- with several project tabs open, pressing play in a different tab would otherwise
-- trigger the reference while that other project stayed audible.
function reference.transport_playing()
  if not project_alive(latch.proj) then return false end
  return reaper.GetPlayStateEx(latch.proj) & 1 == 1
end

-- Read and clear the companion hotkey's toggle pulse.
function reference.take_toggle_request()
  if reaper.GetExtState(EXT_SECTION, EXT_TOGGLE) == "1" then
    reaper.DeleteExtState(EXT_SECTION, EXT_TOGGLE, false)
    return true
  end
  return false
end

-- Clear any stale toggle pulse (at startup and exit, so a press made while the tool was
-- closed can't latch it on launch).
function reference.clear_toggle_request()
  reaper.DeleteExtState(EXT_SECTION, EXT_TOGGLE, false)
end

-- Best-effort exit cleanup (window closed or script unloaded normally). Never runs on a
-- crash — that is what the records are for — but on a clean exit it restores the master
-- immediately rather than leaving it to the next startup.
function reference.cleanup()
  if latch.on then reference.latch_off() end
  reference.clear_toggle_request()
end

return reference
