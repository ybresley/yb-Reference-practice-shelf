-- peaks: the waveform-peak adapter (a sibling to reaper_api — it calls reaper.* to
-- read a file's loud/quiet envelope). It returns plain Lua number arrays so nothing
-- REAPER-owned crosses into the UI, which only draws them.
--
-- Building a fresh file's peak cache means reading the whole file once, which would
-- freeze the window on a long sound. So we do it the way REAPER intends: a small
-- slice of work per frame (BuildPeaks "run" mode), driven from the defer loop. The
-- sound plays instantly regardless; the waveform just fills in a moment later and is
-- then cached to a tiny .reapeaks sidecar so it never rebuilds.
--
-- We read a FIXED number of bins per sound, not one per screen pixel: the UI scales
-- this envelope to whatever width it has. So a sound is analysed once per selection,
-- never on resize.

local peaks = {}

peaks.BINS = 2048 -- envelope resolution; ample for any realistic panel width

-- The one in-flight build job. Module-local, because it owns a live PCM source that
-- must survive across frames until the build finishes — nothing outside here holds
-- a reaper object.
local job = nil -- { sound_id, src, length, nch, building }

-- Drop the current job and free its source. Safe to call when there's no job.
function peaks.cancel()
  if job then
    reaper.PCM_Source_Destroy(job.src)
    job = nil
  end
end

-- Start (or replace) a build job for a sound. Any previous job is cancelled first,
-- so there's only ever one source alive. Does nothing if the file can't be opened.
function peaks.request(sound_id, path)
  peaks.cancel()
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return end
  local length = reaper.GetMediaSourceLength(src) or 0
  local nch = reaper.GetMediaSourceNumChannels(src) or 1
  if length <= 0 or nch < 1 then
    reaper.PCM_Source_Destroy(src)
    return
  end
  -- mode 0 asks whether a peak build is needed (0 = already cached, skip straight to
  -- reading; nonzero = we must build it a slice at a time).
  local needs = reaper.PCM_Source_BuildPeaks(src, 0) ~= 0
  job = { sound_id = sound_id, src = src, length = length, nch = nch, building = needs }
end

-- The sound currently being built, or nil — so the UI can show a "reading…" hint.
function peaks.pending()
  return job and job.sound_id or nil
end

-- Read the (already-built) envelope from a job's source into plain Lua arrays,
-- kept PER CHANNEL so the UI can draw one lane each (mono = 1, stereo = 2, ...).
-- Returns an array of length nch, each entry { mins = {...}, maxs = {...} } of BINS.
local function extract(j)
  local n, nch = peaks.BINS, j.nch
  local peakrate = n / j.length -- peaks per second so we get ~n points over the file
  -- SWS packs the result as a block of max values then a block of min values, each
  -- nch*n long, samples interleaved by channel (index = sample*nch + channel).
  local buf = reaper.new_array(nch * n * 2)
  buf.clear()
  local got = reaper.PCM_Source_GetPeaks(j.src, peakrate, 0, nch, n, 0, buf)
  local minbase = nch * n
  local chans = {}
  for c = 1, nch do chans[c] = { mins = {}, maxs = {} } end
  for s = 0, n - 1 do
    for c = 0, nch - 1 do
      local hi, lo = 0.0, 0.0
      if s < got then -- past what the engine returned, leave the bin silent
        local idx = s * nch + c
        hi = buf[idx + 1] or 0            -- reaper.array is 1-based
        lo = buf[minbase + idx + 1] or 0
      end
      chans[c + 1].maxs[s + 1] = hi
      chans[c + 1].mins[s + 1] = lo
    end
  end
  return chans
end

-- Advance the in-flight build by one small slice. Call once per defer frame.
-- Returns (sound_id, channels) on the frame the job finishes, else nil.
function peaks.advance()
  if not job then return nil end
  if job.building then
    -- One time-bounded slice this frame; "run" returns nonzero while work remains.
    if reaper.PCM_Source_BuildPeaks(job.src, 1) ~= 0 then
      return nil -- still building; resume next frame (UI stays responsive)
    end
    reaper.PCM_Source_BuildPeaks(job.src, 2) -- finish the build
    job.building = false
  end
  -- Peaks are ready (just built, or already cached): read them and end the job.
  local chans = extract(job)
  local id = job.sound_id
  reaper.PCM_Source_Destroy(job.src)
  job = nil
  return id, chans
end

return peaks
