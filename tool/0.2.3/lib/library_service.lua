-- library_service: the operations that change the library AND touch the disk —
-- importing files, sweeping for orphans. It sits between the pure core (which
-- decides names/records but can't see the filesystem) and reaper_api (which does
-- the copying/probing). It calls those two plus the store; it never calls reaper.*
-- or ImGui directly, and it isn't drawn from — the entry script invokes it in
-- response to a UI action.

local importer   = require("core.importer")
local store      = require("core.library_store")
local trash      = require("core.trash")
local reaper_api = require("reaper_api")

local service = {}

-- Import a list of source paths into the library, filing them under an optional
-- category / sub-category. Follows the crash-safe order: for each file, copy it
-- in FIRST, then write its record. Records are saved once at the end — a crash
-- mid-import leaves at worst orphan files (harmless, sweep-detectable), never a
-- record pointing at a file that isn't there.
--
-- Returns a summary { added, duplicates={}, skipped={}, errors={} } so the caller
-- can tell the user what happened without this layer touching the UI.
function service.import_files(state, paths, category, subcategory)
  local lib = state.library

  -- Names already in use = existing records UNION the real files on disk. The
  -- disk half matters: an orphan left by a past crash has no record, and we must
  -- never overwrite it when choosing a collision-free name.
  local taken = importer.taken_filenames(lib)
  for _, name in ipairs(reaper_api.list_audio_files(state.library_dir)) do
    taken[name:lower()] = true
  end

  local summary = { added = 0, duplicates = {}, skipped = {}, errors = {} }

  for _, src in ipairs(paths) do
    local source_name = importer.basename(src)
    local size = reaper_api.file_size(src)

    if importer.find_duplicate(lib, source_name, size) then
      summary.duplicates[#summary.duplicates + 1] = source_name
    else
      local info = reaper_api.probe_audio(src)
      if not info or info.channels < 1 then
        summary.errors[#summary.errors + 1] = source_name .. " — not a readable audio file"
      elseif info.channels > 2 then
        -- v1 is mono/stereo only; refuse loudly rather than mangle (DESIGN scope).
        summary.skipped[#summary.skipped + 1] = source_name .. " — more than stereo"
      else
        local dest_name = importer.unique_filename(source_name, taken)
        local dest_path = reaper_api.join(state.library_dir, dest_name)
        local ok, err = reaper_api.copy_file(src, dest_path)
        if not ok then
          summary.errors[#summary.errors + 1] = source_name .. " — " .. tostring(err)
        else
          taken[dest_name:lower()] = true
          importer.add_sound(lib, {
            filename    = dest_name,
            source_name = source_name,
            size_bytes  = size,
            duration    = info.duration,
            channels    = info.channels,
            category    = category,
            subcategory = subcategory,
          })
          summary.added = summary.added + 1
        end
      end
    end
  end

  -- One save after the whole import (still immediate, not exit-time). The atomic
  -- swap means the on-disk library is either the old set or the full new set.
  if summary.added > 0 then
    store.save(state.library_path, lib)
  end

  return summary
end

--------------------------------------------------------------- deleting

-- Delete a sound: its audio AND a note holding its full record move into the trash
-- folder inside the library, so putting it back brings back the name, filing, note,
-- trim and measurements — not just the file.
--
-- THE ORDER IS THE MIRROR OF IMPORT'S, and it matters just as much. The note is
-- written FIRST, before anything is destroyed, because the whole promise of the
-- feature is that the record survives: audio sitting in the trash with nothing
-- describing it is the one outcome that can't be undone. The costs of stopping
-- part-way, in order:
--
--   after the note, before the move — a stray note beside a sound that is still
--     in the library. Harmless: nothing reads the trash folder on its own.
--   after the move, before the save — the audio is in the trash while the record
--     still lists it, so the sound reads as "file missing" at next startup. Ugly,
--     but every piece of it is still on disk and nothing has been lost.
--
-- Returns true on success, or false + a plain-language reason. Never raises: every
-- way this can fail is something the user needs told, not a script crash.
function service.delete_sound(state, id)
  local lib = state.library

  local record
  for _, s in ipairs(lib.sounds) do
    if s.id == id then record = s; break end
  end
  if not record then return false, "That sound is no longer in your library." end

  -- A stored filename is only ever a plain name inside the library folder. One
  -- carrying a path (from a hand-edited or damaged library file) would send the
  -- move somewhere else entirely, so refuse rather than touch an unrelated file.
  if not importer.is_safe_filename(record.filename) then
    return false, string.format(
      "\"%s\" couldn't be deleted: its stored file name (%s) isn't a plain name inside your library folder. " ..
      "Nothing has been changed.", record.name, tostring(record.filename))
  end

  local trash_dir = reaper_api.join(state.library_dir, trash.DIR)
  reaper_api.ensure_dir(trash_dir)

  -- Work out a name nothing in the trash is using. EVERY file counts, not just the
  -- audio: a note whose audio never arrived (a sound whose file had already
  -- vanished, or a delete stopped part-way) is still the only surviving record of
  -- that sound, and overwriting it would destroy exactly what the trash is for.
  local taken = {}
  for _, name in ipairs(reaper_api.list_files(trash_dir)) do
    local lower = name:lower() -- Windows filenames don't care about case; nor may we
    taken[lower] = true
    local speaks_for = lower:match("^(.+)%.json$")
    if speaks_for then taken[speaks_for] = true end
  end
  local trashed_name = importer.unique_filename(record.filename, taken)
  local note_path    = reaper_api.join(trash_dir, trash.note_filename(trashed_name))
  local audio_src    = reaper_api.join(state.library_dir, record.filename)
  local audio_dest   = reaper_api.join(trash_dir, trashed_name)

  -- The chosen name cleared the listing-based check above, so anything ALREADY at
  -- either path is a collision that check cannot see: a name Windows folds to the
  -- same file (its Unicode case rules go beyond Lua's byte-wise lower()). Writing
  -- the note would replace the only record of an earlier trashed sound — the exact
  -- loss the taken-name set exists to prevent — so refuse before touching anything.
  if reaper_api.path_exists(note_path) or reaper_api.path_exists(audio_dest) then
    return false, string.format(
      "\"%s\" couldn't be deleted: the trash folder already holds a file whose name Windows " ..
      "treats as the same (%s). Rename the sound's file and try again. Nothing has been changed.",
      record.name, trashed_name)
  end

  -- A record whose audio has already vanished still deletes — there is simply
  -- nothing to move, and leaving the row behind would help nobody. The note says so
  -- rather than naming a file that won't be beside it.
  --
  -- Whether it's there is read from the folder LISTING, not by trying to open the
  -- file: something else holding the file open would make it unopenable while it is
  -- very much still there, and calling that "already gone" would drop the record
  -- and leave the audio behind as an orphan.
  local present = {}
  for _, name in ipairs(reaper_api.list_files(state.library_dir)) do
    present[name:lower()] = true
  end
  local has_audio = present[record.filename:lower()] == true

  local wrote, werr = pcall(store.write_json, note_path,
    trash.note(lib, record, { filename = has_audio and trashed_name or nil }))
  if not wrote then
    return false, "Nothing was deleted — the sound's details couldn't be written to the trash folder:\n\n"
      .. tostring(werr)
  end

  if has_audio then
    local moved, merr = reaper_api.move_file(audio_src, audio_dest)
    if not moved then
      os.remove(note_path) -- abandon cleanly — nothing has been destroyed yet
      return false, "Nothing was deleted — the sound's file couldn't be moved to the trash folder:\n\n"
        .. tostring(merr)
    end
  end

  local removed, index = trash.remove(lib, id)
  local saved, serr = pcall(store.save, state.library_path, lib)
  if not saved then
    -- Whatever moved has moved and can't come back on its own, so put the record
    -- back to match what is still on disk. The sound then reads as "file missing"
    -- — visibly wrong, which beats memory and disk quietly disagreeing.
    --
    -- The third return says the audio HAS gone, so the caller doesn't restart the
    -- background work (measuring, waveform) on a file that is no longer there.
    trash.restore(lib, removed, index)
    return false, string.format(
      "\"%s\" couldn't be deleted: your library file wouldn't save.\n\n%s\n\n%s",
      record.name, tostring(serr),
      has_audio
        and string.format("Its file and details have already been moved to the \"%s\" folder inside your " ..
          "library, so the sound is still listed but will show as missing its file.", trash.DIR)
        or "Nothing else has been changed."),
      has_audio
  end

  return true
end

-- Compare the library folder against the records, both ways round, in one scan:
--
--   orphans — audio files no record points at (the residue of an interrupted
--             import). The UI can later offer to adopt or bin them.
--   missing — records whose audio file is no longer there (deleted or moved
--             outside the tool). These matter more: the sound still looks normal
--             in the list, but nothing will play and no waveform will draw, so it
--             has to be said out loud rather than discovered by clicking.
--
-- Neither is written into the library. A file that vanished may well come back
-- (an unplugged drive, a sync still running), and marking the record would make a
-- temporary absence permanent.
function service.check_files(state)
  local known, on_disk = {}, {}
  for _, s in ipairs(state.library.sounds) do
    if s.filename then known[s.filename:lower()] = true end
  end
  for _, name in ipairs(reaper_api.list_audio_files(state.library_dir)) do
    on_disk[name:lower()] = true
  end

  local orphans, missing = {}, {}
  for name in pairs(on_disk) do
    if not known[name] then orphans[#orphans + 1] = name end
  end
  for _, s in ipairs(state.library.sounds) do
    if s.filename and not on_disk[s.filename:lower()] then missing[#missing + 1] = s end
  end
  return orphans, missing
end

return service
