-- trash: what "delete a sound" means to the library DATA — taking the record out,
-- and building the self-contained note that travels into the trash folder beside
-- the audio. The note carries the whole record (name, filing, note, trim, every
-- measurement), which is the point of the feature: putting a sound back has to
-- bring back everything, not just the file.
--
-- Pure Lua. Moving the audio and writing the note to disk is library_service's job.

local categories = require("core.categories")

local trash = {}

-- The folder deleted sounds go to, directly inside the library folder. Named here
-- because both the delete path and anything that later reads the trash must agree.
trash.DIR = "trash"

-- Format version of the note itself, independent of the library's schema version:
-- a note written today must still be readable by a much later version of the tool.
trash.VERSION = 1

-- Take a sound out of the library and return its record AND the position it held.
-- The position is what lets a caller put it straight back if the delete can't be
-- finished. Raises if the id isn't there — a delete that quietly matched nothing
-- would look like it had worked.
function trash.remove(lib, id)
  for i, s in ipairs(lib.sounds) do
    if s.id == id then
      table.remove(lib.sounds, i)
      return s, i
    end
  end
  error("no such sound: " .. tostring(id))
end

-- Put a removed record back where it was. Used when the delete falls over after the
-- record is out, so what's in memory still matches what's on disk.
function trash.restore(lib, record, index)
  table.insert(lib.sounds, math.min(index or (#lib.sounds + 1), #lib.sounds + 1), record)
  return record
end

-- A copy of a category as it stands right now, so a restore can rebuild the filing
-- even if the category itself is deleted later. The record only stores ids, and an
-- id whose category has gone means nothing to anybody.
local function snapshot(lib, id)
  local c = id and categories.get(lib, id)
  if not c then return nil end
  return { id = c.id, name = c.name, color = c.color, parent = c.parent }
end

-- The note that gets written beside the audio, holding everything a restore needs.
--
-- `opts.filename` is what the audio ended up called INSIDE the trash folder, which
-- isn't always the record's own filename (deleting a second "Kick.wav" can't
-- overwrite the first one in there). It is deliberately absent when there was no
-- audio to move, so the note never claims a file that isn't beside it.
function trash.note(lib, record, opts)
  opts = opts or {}
  return {
    version     = trash.VERSION,
    deleted     = opts.date or os.date("%Y-%m-%d"), -- os.date is pure Lua, not reaper.*
    filename    = opts.filename,
    sound       = record,
    category    = snapshot(lib, record.category),
    subcategory = snapshot(lib, record.subcategory),
  }
end

-- The note's own filename: the audio's name with ".json" on the end, so the pair
-- sort together in the folder and the note can never be mistaken for a sound.
function trash.note_filename(trashed_filename)
  return trashed_filename .. ".json"
end

return trash
