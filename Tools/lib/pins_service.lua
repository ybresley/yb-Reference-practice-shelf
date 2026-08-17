-- pins_service: the operations behind project pins — pinning a library sound into
-- the current project, unpinning, and adopting a pin into the library. Sits
-- between the pure core (core/pins decides records but can't see the filesystem
-- or the project) and the adapters (reaper_api copies files, project_state holds
-- the per-project storage). Like library_service, it never calls reaper.* or
-- ImGui directly, and it isn't drawn from — the entry script invokes it.
--
-- Pinning follows import's crash-safe order: copy the audio into References/
-- FIRST, write the pin record LAST — a crash in between leaves at worst an
-- orphan file beside the project. Unpinning removes ONLY the record, never the
-- audio: the copy stays in References/ as a harmless leftover. That is a safety
-- decision, not laziness — the pin data only reaches the .RPP when the user
-- saves, so a deleted file could be resurrected as a record by an unsaved
-- project ("close without saving" would bring the pin back with its audio gone),
-- and a second project saved beside the first can reference the same folder.
-- Records may come back from an old save; files, once destroyed, cannot.
--
-- Durability: storing project values does NOT mark the project as needing a save
-- (verified in Phase 4), so every DATA change here also marks the project dirty —
-- otherwise a pin made in an otherwise-untouched project would silently evaporate
-- at close. Selection memory alone deliberately doesn't (see remember_selected).

local pins       = require("core.pins")
local importer   = require("core.importer")
local analysis   = require("core.analysis")
local store      = require("core.library_store")
local reaper_api = require("reaper_api")
local project    = require("project_state")

local product_error = require("product_error")
local service = {}

local function empty_pins(proj, path)
  return {
    proj      = proj,                    -- which project this pin state belongs to
    path      = path,                    -- its .RPP path ("" = never saved)
    dir       = project.refs_dir(path),  -- the References folder (nil until saved)
    data      = pins.new_state(),
    by_origin = {},                      -- library sound id -> pin, for the list's markers
    origin_of = {},                      -- pin id -> library sound id, for "Show in library"
    markers_version = 0,                 -- bumped on every rebuild (see rebuild_markers)
    load_error = nil,
  }
end

local DAMAGED = "This project's pinned references couldn't be read. Changes to pinned " ..
  "references are paused, and the saved data will not be overwritten. Right-click the " ..
  "warning under THIS PROJECT to discard the unreadable data and start with no pinned references."

-- The damaged-data refusal, in one shape. `service.edit` asks it before every
-- change, but an operation that looks a pin UP first has to ask before it does:
-- damaged data loads as an empty list, so the lookup would report a missing pin
-- and hide the real reason from the user.
local function damaged(state)
  if state.pins.load_error then return DAMAGED end
  return nil
end

-- Whether pinning into this project could happen right now — the one check
-- shared by pinning a single sound and by importing a whole batch that will
-- all be pinned (import_and_pin, in the entry script). The batch case needs
-- the answer BEFORE it copies anything into the library: importing first and
-- discovering pinning is refused would strand sounds in the library with none
-- of them pinned, and retrying afterwards would just dedup to "already in
-- library" and never pin them. Returns the refusal message, or nil when
-- pinning is fine.
function service.can_pin(state)
  local ps = state.pins
  local refusal = damaged(state)
  if refusal then return refusal end
  if not ps.dir then
    return "Save the project first. Pinned references are stored in a References folder " ..
      "beside the project file."
  end
  return nil
end

-- Public: the entry script re-derives the markers itself after a library
-- switch (the pins didn't change, but the library they point into did).
--
-- `markers_version` counts the rebuilds. Every pin mutation goes through here,
-- so it's the one honest "the pinned set may have changed" signal — the entry
-- script watches it to re-sort a list that's currently ordered BY the pin
-- column, the same way a finished loudness measurement re-sorts a list ordered
-- by loudness.
function service.rebuild_markers(state)
  local by_origin = pins.markers(state.pins.data, state.library.sounds)
  -- The same map read the other way round, for "Show in library" on a pin's
  -- right-click menu. Built here rather than searched per frame, and from the
  -- SAME verified matches — so the menu item is offered exactly when the
  -- library table would show that sound's pin marker, never on a pin whose
  -- library twin can't be proven (a capture, or a teammate's pin).
  local origin_of = {}
  for sound_id, p in pairs(by_origin) do origin_of[p.id] = sound_id end
  state.pins.by_origin = by_origin
  state.pins.origin_of = origin_of
  state.pins.markers_version = (state.pins.markers_version or 0) + 1
end
local rebuild_markers = service.rebuild_markers

-- Save As moved the project to another folder: the pin records travel inside the
-- project, but their audio doesn't move on its own. Carry the copies forward so
-- the pins keep playing from the new home. Failures don't touch the records —
-- the old folder still holds the audio, and the returned warning says what
-- happened rather than letting the user discover it as silent dead pins.
local function carry_files_forward(old_dir, new_dir, data)
  if #data.pins == 0 then return nil end
  reaper_api.ensure_dir(new_dir)
  local failed = 0
  for _, p in ipairs(data.pins) do
    local dest = reaper_api.join(new_dir, p.filename)
    if not reaper_api.path_exists(dest) then
      local ok = reaper_api.copy_file(reaper_api.join(old_dir, p.filename), dest)
      if not ok then failed = failed + 1 end
    end
  end
  if failed > 0 then
    return string.format(
      "%d pinned reference%s couldn't be copied to the project's new References folder. " ..
        "%s audio remains in the old References folder (%s).",
      failed, failed == 1 and "" or "s", failed == 1 and "Its" or "Their", old_dir)
  end
  return nil
end

-- Bring state.pins in line with the project in front of the user. Called once per
-- frame (two cheap calls and a compare when nothing changed): switching project
-- tabs, opening a project, or Save As all land here. Returns nil when nothing
-- changed, else { selected = <pin id to restore, or nil>, warning = <msg, or nil> }.
--
-- Reloading never loses anything: every pin mutation is written into the
-- project's storage immediately (see persist), so reading it back IS the latest.
--
-- Damaged pin data is reported and treated as read-only-empty rather than
-- blocking the tool: unlike the library (a user's whole collection), this is one
-- project's small list, and the last saved .RPP still holds the stored text.
-- Every mutation is refused until the user explicitly discards it (reset_pins).
function service.refresh(state)
  local proj, path = project.current()
  local ps = state.pins
  if ps and ps.proj == proj and ps.path == path then return nil end

  -- The same project under a new path is Save As, not a switch. The report says
  -- so (`same_project`) because the two deserve different handling upstream —
  -- e.g. a latched reference keeps its restored selection through Save As, but
  -- never inherits one from a genuinely different project.
  local same_project = ps ~= nil and ps.proj == proj
  local moved_from = (same_project and ps.dir and #ps.data.pins > 0) and ps.dir or nil

  local fresh = empty_pins(proj, path)
  local text = project.read_pins(proj)
  if text then
    local ok, result = pcall(pins.decode, text)
    if ok then
      fresh.data = result
    else
      fresh.load_error = DAMAGED
    end
  end

  local warning = nil
  if moved_from and fresh.dir and moved_from ~= fresh.dir then
    warning = carry_files_forward(moved_from, fresh.dir, fresh.data)
  end

  state.pins = fresh
  rebuild_markers(state)
  return { selected = fresh.data.selected, warning = warning, same_project = same_project }
end

-- Write the pin state into the project's storage (in memory at once; it reaches
-- the .RPP when the user saves the project), verified by read-back, and mark the
-- project as needing that save — without the mark, REAPER would never prompt for
-- it and the change would evaporate at close.
--
-- opts.quiet skips the dirty-mark (selection memory only — not worth a save
-- prompt of its own). opts.force allows the one deliberate overwrite of damaged
-- data (reset_pins); everything else is refused while a load error stands, so a
-- broken-but-recoverable stored text can't be clobbered by accident.
--
-- Private on purpose: a bare store is a store with no way back, and a caller who
-- forgets the way back leaves the user looking at a change the project never
-- took. Everything that alters the records goes through service.edit. Three
-- callers below deliberately don't — remember_selected, reset_pins and
-- save_pin_to_library's origin link — and each says why where it calls this;
-- that is the whole list.
local function persist(state, opts)
  opts = opts or {}
  local ps = state.pins
  if ps.load_error and not opts.force then return false end
  if not project.write_pins(ps.proj, pins.encode(ps.data)) then return false end
  if not opts.quiet then project.mark_dirty(ps.proj) end
  return true
end

-- The one way to change pin data. Every operation does the same three things:
-- change the records, store them, and put the change BACK when storing is
-- refused — so what the user sees and what the project holds can never drift
-- apart. Writing that out per operation is exactly how the trim and start/end
-- commits ended up with no way back at all, so it lives here once.
--
-- `fn` makes the change and returns the closure that reverses it — or nil when
-- it changed nothing, in which case there is nothing to store and no save to ask
-- for. A second return value from `fn` is handed back to the caller.
--
-- Returns (true, value) on success. On failure (false, reason), where reason is
-- DAMAGED when the stored text may not be touched at all, and nil when the store
-- itself refused: only the caller knows what was being changed, so only the
-- caller can word that one.
function service.edit(state, fn)
  local refusal = damaged(state)
  if refusal then return false, refusal end
  local undo, value = fn()
  if not undo then return true end
  if not persist(state) then
    undo()
    return false, nil
  end
  return true, value
end
local edit = service.edit

-- Pin a library sound to the current project. Returns (true, message, pin_id) or
-- (false, message[, existing_pin_id when it was already pinned]).
function service.pin_sound(state, sound)
  local ps = state.pins

  local refusal = service.can_pin(state)
  if refusal then return false, refusal end

  local existing = pins.already_pinned(ps.data, sound)
  if existing then
    return false, string.format("\"%s\" is already pinned to this project.", sound.name), existing.id
  end

  reaper_api.ensure_dir(ps.dir)

  -- Names already spoken for = pin records UNION the real folder listing, so a
  -- crash-orphaned copy (or anything else the user keeps there) is never
  -- overwritten — the same rule import applies to the library folder.
  local taken = pins.taken_filenames(ps.data)
  for _, name in ipairs(reaper_api.list_files(ps.dir)) do
    taken[name:lower()] = true
  end
  local dest_name = importer.unique_filename(sound.filename, taken)
  local src = reaper_api.join(state.library_dir, sound.filename)
  local dest = reaper_api.join(ps.dir, dest_name)

  local copied, cerr = reaper_api.copy_file(src, dest)
  if not copied then
    return false, string.format("\"%s\" couldn't be pinned because its audio couldn't be copied " ..
      "to the project's References folder:\n\n%s",
      sound.name, tostring(cerr))
  end

  local opts = pins.snapshot(sound)
  opts.filename = dest_name

  local ok, record = edit(state, function()
    local added = pins.add(ps.data, opts)
    return function()
      -- The record couldn't be stored in the project, so it would not survive the
      -- session — take it back out and remove the copy, leaving things as they were.
      pins.remove(ps.data, added.id)
      os.remove(dest)
    end, added
  end)
  if not ok then
    return false, string.format("\"%s\" couldn't be pinned because the pinned reference " ..
      "couldn't be saved in your project.", sound.name)
  end

  rebuild_markers(state)
  return true, string.format("\"%s\" is pinned to this project. Save the project to keep it.", sound.name),
    record.id
end

-- Unpin: the record leaves the project; the References copy deliberately stays
-- (see the top of this file — an unsaved project can resurrect the record, and a
-- neighbouring project may reference the same folder; a leftover file is
-- harmless, a destroyed one is forever).
function service.unpin(state, pin_id)
  local ps = state.pins
  local refusal = damaged(state)
  if refusal then return false, refusal end
  local p = pins.find(ps.data, pin_id)
  if not p then return false, "That pin is no longer in this project." end

  local ok, reason = edit(state, function()
    local was_selected = ps.data.selected
    -- Also clears it as the remembered selection; `index` lets a failed store put
    -- everything back exactly as it was.
    local removed, index = pins.remove(ps.data, pin_id)
    return function()
      -- Couldn't store the removal: put the record back at the position it held
      -- (plus the remembered selection) so memory and the project agree — a
      -- refusal must not quietly reorder the sidebar.
      table.insert(ps.data.pins, index, removed)
      ps.data.selected = was_selected
    end
  end)
  if not ok then
    return false, reason or
      string.format("\"%s\" couldn't be unpinned because the change couldn't be saved in your project.", p.name)
  end
  rebuild_markers(state)
  return true, string.format(
    "\"%s\" is unpinned. Save the project to keep this change. Its audio remains in the References folder.",
    p.name)
end

-- Set (or clear) a pin's job label. Like every other pin-data change: refused
-- while stored data is damaged, persisted + marks the project dirty on
-- success, rolled back on a failed store. Duplicate labels are allowed — a
-- label describes a job ("Fire"), not an identity.
function service.set_pin_label(state, pin_id, label)
  local ps = state.pins
  local refusal = damaged(state)
  if refusal then return false, refusal end
  local p = pins.find(ps.data, pin_id)
  if not p then return false, "That pin is no longer in this project." end

  local ok, reason = edit(state, function()
    local old = p.label
    pins.set_label(ps.data, pin_id, label)
    return function() p.label = old end
  end)
  if not ok then
    return false, reason or string.format("\"%s\"'s label couldn't be saved in your project.", p.name)
  end
  return true, p.label
    and string.format("\"%s\" labelled \"%s\".", p.name, p.label)
    or string.format("\"%s\"'s label cleared.", p.name)
end

-- Move a pin to another position in the stored order (the picker's edit mode).
-- The order is what the picker's arrows step through, so it's real project data:
-- refused while stored data is damaged, persisted + marks the project dirty on
-- success, and put back exactly where it was if the store fails.
function service.reorder_pin(state, pin_id, to_index)
  local ps = state.pins
  local refusal = damaged(state)
  if refusal then return false, refusal end
  local p = pins.find(ps.data, pin_id)
  if not p then return false, "That pin is no longer in this project." end

  local ok, reason = edit(state, function()
    local from = pins.reorder(ps.data, pin_id, to_index)
    if not from then return nil end -- already there: nothing to store, nothing to say
    return function() pins.reorder(ps.data, pin_id, from) end
  end)
  if not ok then
    return false, reason or
      string.format("\"%s\" couldn't be moved because the new order couldn't be saved in your project.", p.name)
  end
  return true
end

-- Adopt a pin into the library ("save to my library"). Dedup comes first, both
-- ways it can match: a verified origin (the id AND the content facts agree — an
-- id alone can collide with an unrelated sound in someone else's library), or
-- the library already holding the same content. Matching never copies anything;
-- the existing sound is simply pointed out. Returns (ok, message, sound_id,
-- added) — `added` says a new record was created, so the caller can refresh the
-- view and the analysis queue.
function service.save_pin_to_library(state, pin_id)
  local ps = state.pins
  local lib = state.library
  local p = pins.find(ps.data, pin_id)
  if not p then return false, "That pin is no longer in this project." end

  local existing
  for _, s in ipairs(lib.sounds) do
    if pins.origin_match(p, s) then existing = s; break end
  end
  existing = existing or importer.find_duplicate(lib, p.source_name, p.size_bytes)
  if existing then
    -- Remember the link when it was found by content: the marker lights up and
    -- the next check answers instantly. Best-effort — the dedup answer stands
    -- even if the project won't store the updated link right now.
    if p.origin_id ~= existing.id then
      p.origin_id = existing.id
      persist(state)
    end
    rebuild_markers(state)
    return true, string.format("\"%s\" is already in your Library as \"%s\". Nothing was copied.",
      p.name, existing.name), existing.id, false
  end

  if not ps.dir then
    return false, "Save the project first. This pinned reference has no References folder " ..
      "to copy audio from."
  end

  local taken = importer.taken_filenames(lib)
  for _, name in ipairs(reaper_api.list_audio_files(state.library_dir)) do
    taken[name:lower()] = true
  end
  local dest_name = importer.unique_filename(p.filename, taken)
  local src = reaper_api.join(ps.dir, p.filename)
  local dest = reaper_api.join(state.library_dir, dest_name)

  local copied, cerr = reaper_api.copy_file(src, dest)
  if not copied then
    return false, string.format("\"%s\" couldn't be saved to your Library because its audio " ..
      "couldn't be copied:\n\n%s",
      p.name, tostring(cerr))
  end

  local record = importer.add_sound(lib, {
    filename    = dest_name,
    name        = p.name,
    note        = p.note,
    trim_db     = p.trim_db,
    duration    = p.duration,
    channels    = p.channels,
    source_name = p.source_name,
    size_bytes  = p.size_bytes,
  })
  -- The pin's measurements travel with it; only a completed measurement is worth
  -- carrying (pending/failed stays "pending" so the background analysis measures
  -- the new library copy itself). A pin measured under the old three-value
  -- scheme — "done" but with nothing in any of the newer fields — also lands as
  -- "pending": its numbers carry over for the meantime and the background
  -- analysis quietly brings the library copy up to the full six, the same deal
  -- the v2 -> v3 library migration gives existing sounds. (A truly silent pin
  -- gets one cheap pointless re-measure out of this; that beats a library
  -- record frozen at three values forever.)
  if p.analysis == "done" then
    for _, field in ipairs(analysis.FIELDS) do record[field] = p[field] end
    if p.lufs_s_max or p.peak or p.rms then record.analysis = "done" end
  end
  -- The start/end points travel exactly like the trim does.
  record.span_start, record.span_end = p.span_start, p.span_end

  local saved, serr = pcall(store.save, state.library_path, lib)
  if not saved then
    -- Same stance as import: the sound is in the in-memory library, every later
    -- save writes the whole library again, so the tool keeps going — but say so.
    local message = product_error.with_details(
      string.format("\"%s\" was added to your Library, but the Library file couldn't be saved. " ..
        "Saving will be retried on the next change.", p.name), serr)
    return true, message, record.id, true
  end

  -- Link the pin to its new library sound (marker + instant dedup from now on).
  -- Best-effort like the content-match link above.
  p.origin_id = record.id
  persist(state)
  rebuild_markers(state)

  return true, string.format("\"%s\" saved to your Library.", p.name), record.id, true
end

-- Put a pin's live-edited fields back to what the project ACTUALLY stores.
-- Returns whether it could: a project whose pin text has gone missing (or turned
-- unreadable since it was loaded) can't answer, and the caller then says the
-- value is still adrift rather than claiming a rollback that never happened.
local function restore_stored(ps, pin, fields)
  local text = project.read_pins(ps.proj)
  if not text then return false end
  local ok, data = pcall(pins.decode, text)
  if not ok then return false end
  local kept = pins.find(data, pin.id)
  if not kept then return false end
  for _, f in ipairs(fields) do pin[f] = kept[f] end
  return true
end

local TRIM_FIELDS = { "trim_db" }
local SPAN_FIELDS = { "span_start", "span_end" }

-- Store a value the user has ALREADY heard. The trim fader and the start/end
-- handles move the sound live and only reach the project on release, so by the
-- time the commit arrives the change is in the record and there is no "value
-- before this call" to hand back — what the project holds is the value from
-- before the whole gesture, and re-reading it is the only honest way to recover
-- it. `refused` and `adrift` are the two truths a failure can have: the record
-- went back, or it couldn't be put back and still differs from the project.
local function commit_live_edit(state, pin, fields, refused, adrift)
  local restored = false
  local ok, reason = edit(state, function()
    return function() restored = restore_stored(state.pins, pin, fields) end
  end)
  if ok then return true end
  if reason then return false, reason end
  return false, restored and refused or adrift
end

-- Per-pin trim, mirroring the library sound flow: the audio follows the fader
-- live, the value reaches the project on release.
function service.commit_trim(state, pin)
  return commit_live_edit(state, pin, TRIM_FIELDS,
    "The trim couldn't be saved in your project. Its previous value was restored.",
    "The trim couldn't be saved in your project. The current value will reset to the " ..
      "previously saved value when the project changes or reopens.")
end

-- The start/end points, on the trim's exact save rhythm.
function service.commit_span(state, pin)
  return commit_live_edit(state, pin, SPAN_FIELDS,
    "The start and end points couldn't be saved in your project. Their previous values were restored.",
    "The start and end points couldn't be saved in your project. The current values will reset " ..
      "to the previously saved values when the project changes or reopens.")
end

-- Remember the last selected reference for this project. Only ever called with a
-- PIN id — a library id stored in a shared project would name a different sound
-- on a teammate's machine (see core/pins) — or nil, which clears the memory (the
-- user moved on to a library sound; restoring an older pin would be a lie).
-- Quiet: selection memory rides along with the user's own next save, it never
-- earns a save prompt of its own. Best-effort by design.
function service.remember_selected(state, pin_id)
  local ps = state.pins
  if ps.data.selected == pin_id then return end
  ps.data.selected = pin_id
  persist(state, { quiet = true })
end

-- The one deliberate escape from damaged pin data: the user chose to discard it.
-- Overwrites the stored text with a fresh empty state (the previous text remains
-- in the last saved .RPP until they save again — recoverable up to that point).
function service.reset_pins(state)
  local ps = state.pins
  ps.data = pins.new_state()
  if not persist(state, { force = true }) then
    return false, "The damaged pinned-reference data couldn't be replaced. Nothing was changed."
  end
  ps.load_error = nil
  rebuild_markers(state)
  return true, "This project's pinned references were reset. Pinning works here again. " ..
    "Save the project to keep this change."
end

return service
