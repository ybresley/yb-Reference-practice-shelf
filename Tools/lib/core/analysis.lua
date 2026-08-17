-- analysis: the bookkeeping around loudness measurement — which sounds still need
-- measuring, and how a finished measurement lands on a record.
--
-- Pure Lua. No reaper.*, no disk access. The measuring itself is REAPER's job and
-- lives in lib/loudness.lua; this module only decides what to measure next and
-- what a result does to the library, so that policy is unit-testable.
--
-- A record's `analysis` field is the single source of truth:
--   "pending" — never measured (the state importer.add_sound creates)
--   "done"    — measured; the loudness fields hold whatever was found
--   "failed"  — measuring was attempted and REAPER couldn't read the file
--
-- "failed" is deliberately re-queued rather than remembered forever: the usual
-- cause is a file that was missing or locked at the time, so the next run simply
-- tries again. Retrying costs one failed file-open per broken sound per launch.

local analysis = {}

-- The measurements a completed analysis stores. Kept in one place because the
-- reaper layer fills them and the list displays them — both must agree on names.
analysis.FIELDS = { "lufs_i", "lufs_m_max", "lufs_s_max", "true_peak", "peak", "rms" }

-- Is this the name of a stored measurement? Guards a remembered display choice: a
-- setting written by an older version (or edited by hand) must fall back to a real
-- measurement rather than leave the list showing a permanently empty column.
function analysis.is_field(name)
  for _, f in ipairs(analysis.FIELDS) do
    if f == name then return true end
  end
  return false
end

-- Does this sound still need measuring? Anything that isn't a finished measurement
-- does, including a record from an older library that has no `analysis` field.
function analysis.needs(sound)
  return sound.analysis ~= "done"
end

-- The ids of every sound waiting to be measured, in library order. `exclude_id` is
-- the sound already being measured right now — without it, rebuilding the queue
-- (after an import, say) would line up a second pass over a sound mid-flight.
function analysis.queue(lib, exclude_id)
  local ids = {}
  for _, s in ipairs(lib.sounds) do
    if analysis.needs(s) and s.id ~= exclude_id then
      ids[#ids + 1] = s.id
    end
  end
  return ids
end

-- Store a finished measurement. A missing value stays missing (digital silence has
-- no meaningful loudness, and the list shows "—" for it) — the sound is still
-- "done", because measuring it did happen and repeating it would find the same
-- nothing.
function analysis.apply(sound, result)
  for _, field in ipairs(analysis.FIELDS) do
    sound[field] = result and result[field] or nil
  end
  sound.analysis = "done"
  return sound
end

-- REAPER couldn't read the file at all. Clear any stale numbers so the list can't
-- show a measurement that no longer belongs to the file on disk.
function analysis.mark_failed(sound)
  for _, field in ipairs(analysis.FIELDS) do
    sound[field] = nil
  end
  sound.analysis = "failed"
  return sound
end

return analysis
