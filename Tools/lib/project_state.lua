-- project_state: the adapter for per-project storage (a sibling of reaper_api —
-- one of the few modules allowed to call reaper.*). REAPER lets a script store
-- small text values inside the project itself; they are written into the .RPP
-- when the user saves, and travel with it — which is the whole foundation of
-- project pins: the pin list rides in the project file, so a teammate opening the
-- same project from the shared drive reads the same list.
--
-- The one honest caveat, surfaced in the UI rather than hidden: like every other
-- project change, stored values only reach disk when the user SAVES the project.

local project_state = {}

local SEP = package.config:sub(1, 1)

-- Same section as the reference-mode marker (one namespace for the tool), its own
-- key beside it.
local PROJ_SECTION = "yb-Reference"
local PINS_KEY     = "pins"

-- The project in front of the user right now, and its .RPP path ("" = never
-- saved). The caller compares these against what it loaded last to notice tab
-- switches and Save As.
function project_state.current()
  local proj, path = reaper.EnumProjects(-1)
  return proj, path or ""
end

-- Where this project's reference copies live: a References folder beside the
-- .RPP. nil for a never-saved project — there is no folder to put copies in yet,
-- so pinning is refused with a plain "save your project first" until there is.
project_state.REFS_DIR = "References"

function project_state.refs_dir(project_path)
  if not project_path or project_path == "" then return nil end
  local dir = project_path:match("^(.*)[\\/]")
  if not dir then return nil end
  return dir .. SEP .. project_state.REFS_DIR
end

-- The stored pin text for a project, or nil when none has ever been written.
function project_state.read_pins(proj)
  local _, v = reaper.GetProjExtState(proj, PROJ_SECTION, PINS_KEY)
  if not v or v == "" then return nil end
  return v
end

-- Store the pin text and READ IT BACK — a write we merely asked for isn't proof
-- (the same rule reference.lua applies to its marker). A failed write must be
-- reported, not assumed away: the caller's in-memory list would otherwise drift
-- from what the project will actually remember.
function project_state.write_pins(proj, text)
  reaper.SetProjExtState(proj, PROJ_SECTION, PINS_KEY, text)
  local _, got = reaper.GetProjExtState(proj, PROJ_SECTION, PINS_KEY)
  return got == text
end

-- Tell REAPER the project has unsaved changes. Verified in Phase 4 (HANDOFF):
-- storing project values does NOT set this on its own — without this call, a
-- user who pins something and closes without touching anything else would get no
-- save prompt, and the pin would silently evaporate with its copy orphaned.
function project_state.mark_dirty(proj)
  reaper.MarkProjectDirty(proj)
end

return project_state
