-- loudness: the loudness-measurement adapter (a sibling of reaper_api/preview/peaks
-- — one of the few modules allowed to call reaper.*). It measures a file's loudness
-- and hands back plain numbers; deciding WHAT to measure and what a result means to
-- the library is core/analysis.lua's job.
--
-- Engine: REAPER's own CalculateNormalization, not SWS (decided in Phase 0 — see
-- prototypes/proto_loudness_NOTES.md). Our numbers therefore match REAPER's own
-- render/export loudness stats. The SWS meter reads 0.5–1.7 dB differently; that is
-- a known, accepted difference, not a bug to chase.
--
-- It answers "what gain would bring this file to a target?", so the measurement is
-- derived: measured = target - the gain expressed in dB.
--
-- WHY THIS IS PACED ACROSS FRAMES: the call blocks while it reads the whole file,
-- and each value costs its own full pass. Measured cost is linear and predictable
-- (~485x realtime): each LUFS value ~2.1 ms per second of audio, true peak
-- ~4.3 ms, sample peak and RMS under 1 ms. All six together ~12 ms per second of
-- audio — a 5-second reference is imperceptible, while a 10-minute file would
-- freeze the window for ~7 seconds if done in one go. Doing ONE pass per frame
-- caps that at the single most expensive pass, and the sound is playable
-- throughout — its loudness simply fills in a moment later.
--
-- Unlike waveform peaks, a pass cannot be split any finer: integrated LUFS is gated
-- over the whole file, so it has no meaningful partial answer. (The "loudest moment"
-- values could be sliced and maxed if very long references ever prove annoying —
-- that would need the start-offset argument verifying in REAPER first.)

local loudness = {}

-- An arbitrary reference point: we only ever ask for the gain relative to it and
-- convert back, so the value itself never reaches the user.
local TARGET = -23

-- One entry per stored measurement, in the order they run. Mode numbers are
-- CalculateNormalization's, confirmed in the Phase 0 benchmark (mode 4 reads
-- louder than mode 5 there, exactly as M-max vs S-max should). Only these six
-- are measured — every extra mode is another full pass through the file.
local MODES = {
  { key = "lufs_i",     mode = 0 }, -- integrated loudness: the headline number
  { key = "lufs_m_max", mode = 4 }, -- loudest momentary window (400 ms)
  { key = "lufs_s_max", mode = 5 }, -- loudest short-term window (3 s)
  { key = "true_peak",  mode = 3 }, -- dBTP, the expensive one
  { key = "peak",       mode = 2 }, -- sample peak, dBFS
  { key = "rms",        mode = 1 }, -- average level over the whole file
}

-- The one in-flight job. Module-local because it owns a live PCM source that must
-- survive across frames — nothing outside here ever holds a REAPER object.
local job = nil -- { sound_id, src, length, step, ran, results }

-- Older REAPER builds don't have the call at all. Checked once by the caller so a
-- missing engine becomes a plain message instead of every sound failing.
function loudness.available()
  return reaper.APIExists("CalculateNormalization")
end

-- Gain multiplier -> the measurement it implies, in dB. Anything that isn't a real
-- finite number (silence, a mode the build doesn't support) becomes nil: no
-- measurement rather than a made-up one.
--
-- Rounded to two decimals before it is stored. Loudness readings are only good to
-- about a tenth of a dB, so keeping fourteen digits would be false precision — and
-- it would fill the library file with noise.
local function to_db(gain)
  if type(gain) ~= "number" or gain <= 0 or gain ~= gain or gain == math.huge then return nil end
  local db = TARGET - 20 * math.log(gain, 10)
  if db ~= db or db == math.huge or db == -math.huge then return nil end
  return math.floor(db * 100 + 0.5) / 100
end

-- The sound being measured right now, or nil.
function loudness.current()
  return job and job.sound_id or nil
end

-- Drop the current job and free its source. Safe to call when there's no job.
function loudness.cancel()
  if job then
    reaper.PCM_Source_Destroy(job.src)
    job = nil
  end
end

-- Start measuring a sound. Any previous job is cancelled first, so only one source
-- is ever alive. Returns false if the file can't be opened as audio — the caller
-- marks that sound failed rather than leaving it queued forever.
function loudness.request(sound_id, path)
  loudness.cancel()
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return false end
  local length = reaper.GetMediaSourceLength(src) or 0
  if length <= 0 then
    reaper.PCM_Source_Destroy(src)
    return false
  end
  job = { sound_id = sound_id, src = src, length = length, step = 1, results = {} }
  return true
end

-- Run exactly one measurement pass. Call once per defer frame.
--
-- Returns nil while the job is still going (or when idle). On the frame it finishes
-- returns (sound_id, results) — or (sound_id, nil) when REAPER couldn't measure the
-- file at all, which the caller records as a failure.
function loudness.advance()
  if not job then return nil end

  local m = MODES[job.step]
  -- pcall so an unexpected signature or an unreadable file ends this one sound's
  -- analysis instead of taking the whole tool down mid-frame.
  local ok, gain = pcall(reaper.CalculateNormalization, job.src, m.mode, TARGET, 0, job.length)
  if ok then
    job.results[m.key] = to_db(gain)
  else
    -- ANY pass throwing fails the whole measurement, even if the others worked.
    -- Otherwise a sound that lost only its headline number would be filed as
    -- measured and never retried — permanently blank, with no way back.
    job.threw = true
  end

  job.step = job.step + 1
  if job.step <= #MODES then return nil end

  local id, results, threw = job.sound_id, job.results, job.threw
  reaper.PCM_Source_Destroy(job.src)
  job = nil
  -- A pass that RAN but found nothing measurable is not a failure — that is what
  -- digital silence looks like, and repeating it would find the same nothing.
  return id, (not threw) and results or nil
end

return loudness
