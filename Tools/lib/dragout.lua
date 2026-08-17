-- dragout: dragging a sound out of the list and dropping it onto REAPER's arrange
-- view as a new item.
--
-- ImGui's own drag-and-drop CANNOT cross into a REAPER window (proven in Phase 0),
-- so the gesture is hand-rolled: the UI spots a row being dragged and the entry
-- script asks this module two things — what is under the mouse right now (for the
-- live readout), and, on release, put the sound there.
--
-- Adapter: the only place the arrange-view and item-creation calls are made. It
-- never draws and never touches the library.

local span = require("core.span")

local dragout = {}

-- What goes into the undo point: media items ONLY (REAPER's UNDO_STATE_ITEMS).
--
-- This matters far more than it looks. The usual -1 means "everything about the
-- project", so the undo point would also record the master's mute and the project's
-- own stored notes. Reference mode mutes the master and writes a marker there, so
-- undoing a drop made while REF was on could put that mute and marker BACK long
-- after REF was switched off — silently re-muting the project, with nothing on disk
-- left to explain it. Adding an item has nothing to do with any of that.
local UNDO_ITEMS = 4

-- Two things REAPER does for its OWN imports and does NOT do for an item built
-- through the API. Both were shipping bugs until 2026-08-08 — every sound
-- dropped from the tool landed nameless and, until the user alt-tabbed, as a
-- blank grey block (found by prototypes/proto_drag_ghost.lua; see
-- docs/RESEARCH.md "Drag OUT to arrange view").

-- REAPER labels an item with its TAKE's name and will not fall back to the
-- file, so a take created by AddTakeToMediaItem shows nothing at all.
local function name_take(take, name, path)
  local label = name
  if not label or label == "" then label = path:match("[^\\/]+$") or path end
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", label, true)
end

-- Attaching a source with SetMediaItemTake_Source never QUEUES the waveform
-- load, so REAPER has nothing in memory to draw and the item is a blank block.
-- This is NOT a repaint problem — UpdateItemInProject, UpdateArrange,
-- SetMediaItemLength(refreshUI), TrackList_AdjustWindows, ClearPeakCache and a
-- real OS-level InvalidateRect over the arrange were each tried and each did
-- nothing. Alt-tabbing worked only because REAPER re-checks its media when it
-- regains focus. This action is that check, asked for directly. Cheap: it
-- touches only what is actually missing peaks.
local function load_missing_peaks()
  reaper.Main_OnCommand(40047, 0) -- Peaks: Build any missing peaks
end

------------------------------------------------------- building one item

-- The picture that rides the timeline during a drag and the item that lands on
-- release are built by the SAME code below, so they can never disagree about
-- what travels — where it sits, how much of the file comes with it, what it is
-- called. They used to carry a copy each of this sequence, kept in step by
-- hand; the promise only held for as long as someone remembered to edit both.
--
-- Three pieces rather than one, because the two callers genuinely need the
-- seams: each comment says why.

-- Snap the way the user has REAPER set, or not at all.
--
-- Its own step because BOTH callers need the snapped time for themselves,
-- outside the build: the ghost compares it against where its item already sits
-- (an unsnapped reading would shuffle the picture around inside one grid cell),
-- and the drop reports it back as where the sound landed.
local function snap_position(position)
  if reaper.GetToggleCommandState(1157) == 1 then
    return reaper.SnapToGrid(0, position)
  end
  return position
end

-- Open the file and confirm there is something playable in it. Returns the
-- source and its length, or nil + a reason; nothing is left open on a refusal.
--
-- Its own step because the real drop asks BEFORE opening its undo block — a
-- file that can't be read is a refusal with nothing to take back, and an undo
-- block that opens for it would be a block opened for no change at all.
local function open_source(path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil, nil, "its file couldn't be read" end
  local length = reaper.GetMediaSourceLength(src)
  if not length or length <= 0 then
    reaper.PCM_Source_Destroy(src)
    return nil, nil, "its file has no playable length"
  end
  return src, length
end

-- Make the item: the take, the audio, the framed stretch, the name, the redraw.
-- `position` is already snapped and `src`/`length` already checked.
--
-- Returns the item and its take, or nil + nil + a reason. On a refusal nothing
-- is left behind — any item made here is taken straight back out, because a
-- silent half-built item (no audio in it, or sitting at the wrong time) would
-- be worse than a plain refusal and the user would have no idea it happened.
local function build_item(track, position, src, length, path, name, span_start, span_end)
  -- The framed span travels (loudness tools, 2026-08-06): the item carries
  -- only the sound's start->end stretch — a take start offset plus a shorter
  -- item. Clamped by core/span.lua's ONE rule (Codex, 2026-08-06 — a local
  -- re-derivation here silently disagreed with playback when the file had
  -- shrunk on disk since the points were stored).
  local offs, span_to = span.range(
    { span_start = type(span_start) == "number" and span_start or nil,
      span_end = type(span_end) == "number" and span_end or nil }, length)

  local item = reaper.AddMediaItemToTrack(track)
  local take = item and reaper.AddTakeToMediaItem(item)
  if not take then
    if item then reaper.DeleteTrackMediaItem(track, item) end
    reaper.PCM_Source_Destroy(src)
    return nil, nil, "REAPER wouldn't create the item"
  end

  -- Attaching hands the source over: once this succeeds the take owns it, and
  -- destroying it ourselves would pull it out from under the project. If it
  -- fails, the source is still ours to free.
  --
  -- Compared against false rather than tested for truth: only an explicit "no"
  -- is a failure, so a build that returns nothing at all isn't mistaken for one
  -- and doesn't throw away an item that was in fact created correctly.
  if reaper.SetMediaItemTake_Source(take, src) == false then
    reaper.DeleteTrackMediaItem(track, item)
    reaper.PCM_Source_Destroy(src)
    return nil, nil, "REAPER wouldn't attach the audio to the item"
  end

  if reaper.SetMediaItemInfo_Value(item, "D_POSITION", position) == false
    or reaper.SetMediaItemInfo_Value(item, "D_LENGTH", span_to - offs) == false
    or (offs > 0 and reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", offs) == false) then
    -- A start offset that didn't take would leave an item whose audio starts
    -- at the wrong moment — worse than a plain refusal, same as the rest. The
    -- source is NOT freed here: the take owns it now, so it goes out with the
    -- item.
    reaper.DeleteTrackMediaItem(track, item)
    return nil, nil, "REAPER wouldn't place the item"
  end

  name_take(take, name, path)
  reaper.UpdateItemInProject(item)
  reaper.UpdateArrange()
  return item, take
end

local function track_label(track)
  if not track then return "a track" end
  local ok, name = reaper.GetTrackName(track)
  if ok and name and name ~= "" then return name end
  return string.format("Track %d", math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")))
end

-- Where the mouse is, as REAPER sees it. BR_GetMouseCursorContext must be called
-- FIRST — it takes the reading that the _Track and _Position calls then report on.
--
-- Returns { over_arrange, track, position, where }. `track` and `position` only
-- mean anything when over_arrange is true; `where` names what the mouse was over
-- instead, so a missed drop can say why.
function dragout.target()
  local window, segment = reaper.BR_GetMouseCursorContext()
  local track = reaper.BR_GetMouseCursorContext_Track()
  local position = reaper.BR_GetMouseCursorContext_Position()
  local over_arrange = window == "arrange" and track ~= nil and position ~= nil and position >= 0
  return {
    over_arrange = over_arrange,
    track        = track,
    position     = position,
    where        = window == "" and "nothing" or (segment ~= "" and (window .. " / " .. segment) or window),
  }
end

-- A plain-language line for the status bar while a drag is in flight, so the user
-- can see where it would land before letting go.
function dragout.hint(t)
  if t.over_arrange then
    return string.format("Drop on %s at %s", track_label(t.track),
      reaper.format_timestr_pos(t.position, "", 0))
  end
  return "Release over REAPER's arrange view to add the sound. Release anywhere else to cancel."
end

--------------------------------------------------------------- the name tag

-- The label that follows the mouse while a drag is in flight (2026-08-02), so
-- the drag OUT carries the sound's name the way a drag IN carries the file's.
--
-- It is REAPER's own tooltip (TrackCtl_SetToolTip), not a window of ours. That
-- matters three ways: it looks native because it IS native, it needs no
-- js_ReaScriptAPI, and it cannot be stranded on screen — one call with an empty
-- string takes it down, and REAPER owns the window either way.
--
-- Offset down-right of the pointer, never under it. REAPER shows this same
-- tooltip while dragging its OWN media items, so it can't be blocking the
-- mouse-context reads dragout.target depends on — but a label sitting under the
-- cursor would still be wrong to look at, and the offset is what every tooltip
-- does anyway.
local TAG_DX, TAG_DY = 22, 20

-- Whether a tag is currently up. Held HERE rather than in the caller so this
-- module owns its own "never leave one on screen" promise: hide_tag is then
-- safe and cheap to call unconditionally, every frame, by anyone.
local tag_up = false

-- Assert the tag for this frame. Called every frame a drag is live, like the
-- cursor — cheap enough, and it keeps the tag glued to the pointer.
-- `name` may be nil (a sound whose record has gone); the destination line alone
-- is still worth showing.
function dragout.show_tag(name, hint)
  local x, y = reaper.GetMousePosition()
  local text = hint or ""
  if name and name ~= "" then
    text = (hint and hint ~= "") and (name .. "\n" .. hint) or name
  end
  reaper.TrackCtl_SetToolTip(text, x + TAG_DX, y + TAG_DY, true)
  tag_up = true
end

-- Take the tag down. A no-op when nothing is up, so the defer loop and the
-- exit handler can both call it without either having to know about the other.
function dragout.hide_tag()
  if not tag_up then return end
  tag_up = false
  reaper.TrackCtl_SetToolTip("", 0, 0, false)
end

---------------------------------------------------------------- the ghost

-- The picture of the sound that rides the timeline while a drag is in flight,
-- so you can see exactly where it will sit before you let go — what REAPER's
-- Media Explorer shows when you drag out of it (asked for 2026-08-08).
--
-- It is a REAL item, not a drawing. That is deliberate and it is the whole
-- design: there is no API anywhere in REAPER, SWS or js_ReaScriptAPI that draws
-- a preview, and no way to start an OS-level drag that would make REAPER draw
-- its own (verified against the installed binaries — docs/RESEARCH.md). The
-- only way to get REAPER's own picture, with its own waveform, name, fades and
-- snapping, is to give REAPER an item. The user's call was explicit: REAPER
-- draws it, we don't paint our own.
--
-- Proved in REAPER before building (prototypes/proto_drag_ghost.lua): a
-- cancelled drag leaves the project needing NO save — creating and deleting an
-- item through the API doesn't dirty it, which is why MarkProjectDirty exists
-- as a separate call — nothing reaches the undo history, and neither ripple
-- editing nor auto-crossfade disturbs the items it passes over.
--
-- Held HERE, module-local, for the same reason the drag tag is: this module
-- owns the promise that one is never left behind, so `hide_ghost` is safe and
-- cheap for anyone to call at any time, including the exit handler.
local ghost = nil -- { item, track, pos }

-- Take it away. A no-op when there is none.
--
-- `atexit` covers every way the script can end INCLUDING a Lua error, which is
-- the realistic way one could be stranded. A REAPER hard crash is not covered,
-- but a ghost only lives for the second or two of a drag and was never saved to
-- disk, so it dies with REAPER's memory. The one residual case — REAPER
-- auto-saving during that second — is left alone deliberately: a startup sweep
-- that DELETED items matching a marker could, on a false positive, silently
-- destroy the user's own work, which is far worse than the stray block it would
-- be cleaning up.
function dragout.hide_ghost()
  local g = ghost
  ghost = nil
  if not g then return end
  if reaper.ValidatePtr2(0, g.item, "MediaItem*")
    and reaper.ValidatePtr2(0, g.track, "MediaTrack*") then
    reaper.DeleteTrackMediaItem(g.track, g.item)
    reaper.UpdateArrange()
  end
end

-- Put it where the mouse is, creating it the first time. Called every frame a
-- drag is live and over the arrange; the entry script calls `hide_ghost` for
-- every other frame, so the picture never claims a landing spot the release
-- wouldn't use.
--
-- Deliberately NOT wrapped in an undo block: an undo point here would put a
-- throwaway into the user's history. The real drop makes its own, separately.
function dragout.show_ghost(track, position, path, name, span_start, span_end)
  if not reaper.ValidatePtr2(0, track, "MediaTrack*") then return dragout.hide_ghost() end

  -- Snapped before anything else, because the fast path below compares this
  -- against where the ghost already sits — and because the picture must
  -- promise the spot the release will honour.
  position = snap_position(position)

  -- Already up: move it. Only touches REAPER when something actually changed —
  -- a per-frame UpdateArrange on an unmoved item is flicker and wasted work.
  if ghost then
    if not reaper.ValidatePtr2(0, ghost.item, "MediaItem*") then
      ghost = nil -- something removed it under us; fall through and rebuild
    elseif ghost.track == track and ghost.pos == position then
      return
    else
      -- A refused move or position write must never be recorded as done.
      -- `hide_ghost` deletes through this bookkeeping, so a track we believe we
      -- moved to but didn't would leave the item stranded on the old one — both
      -- pointers still valid, the delete silently doing nothing, a throwaway
      -- left in the user's project. Dropping the ghost rebuilds it next frame.
      --
      -- Compared against false for the same reason the builder does it: only an
      -- explicit "no" is a failure.
      if ghost.track ~= track then
        if reaper.MoveMediaItemToTrack(ghost.item, track) == false then
          return dragout.hide_ghost()
        end
        ghost.track = track
      end
      if reaper.SetMediaItemInfo_Value(ghost.item, "D_POSITION", position) == false then
        return dragout.hide_ghost()
      end
      ghost.pos = position
      reaper.UpdateItemInProject(ghost.item)
      reaper.UpdateArrange()
      return
    end
  end

  -- Built by the shared builder, so the picture and the item that lands can
  -- never disagree about what travels. A refusal leaves nothing behind and
  -- simply means no ghost this frame; the next frame tries again.
  local src, length = open_source(path)
  if not src then return end
  local item = build_item(track, position, src, length, path, name, span_start, span_end)
  if not item then return end

  -- Never selected: a ghost must not disturb what the user had selected, and a
  -- selected item would ride any action they fire mid-drag. The real drop
  -- leaves selection alone, so this is the ghost's own doing, not the
  -- builder's.
  reaper.SetMediaItemInfo_Value(item, "B_UISEL", 0)
  -- ONCE, when the ghost is born — moving it needs no reload. Without this it
  -- is a blank grey block until the user alt-tabs (see load_missing_peaks).
  load_missing_peaks()

  ghost = { item = item, track = track, pos = position }
end

---------------------------------------------------------- the new-track zone

-- Hovering the TOP SLICE of a track means "drop here and make a NEW track
-- above this one" — REAPER's own behaviour, and only when REAPER's own box is
-- ticked (Preferences -> Media -> Media Import -> "Target top part of track to
-- insert new track").
--
-- That box is bit 8 of `copyimpmedia`, found by snapshotting reaper.ini,
-- toggling it and diffing (27 -> 19, one line, delta exactly 8; searching the
-- program for the option's wording only ever finds the label). We honour
-- REAPER's setting rather than adding our own: someone who deliberately turned
-- this off must not get it from us by the back door.
-- Looked up directly rather than through APIExists (the house idiom): this runs
-- at load, and the specs' deliberately minimal fake REAPERs don't carry
-- APIExists — a feature check shouldn't be the thing that decides whether a
-- module can be required at all.
local HAS_CFG = reaper.SNM_GetIntConfigVar ~= nil

-- NO EXTENSION IS NEEDED FOR THE GEOMETRY (2026-08-08, user's ask). The first
-- build used js_ReaScriptAPI to ask the arrange window where it was. REAPER can
-- answer the same question itself: `GetTrackFromPoint` and `GetThingFromPoint`
-- are core hit-tests — "what is under this screen point?" — so instead of
-- ASKING for the arrange's rectangle we FIND its edges by probing.
--
-- Probing is arguably the better answer anyway: it is REAPER's own hit-test
-- against REAPER's own layout, rather than our arithmetic on a window
-- rectangle. The cost is a handful of calls ONCE per drag (see `probe` below),
-- not per frame.
local HAS_HITTEST = reaper.GetTrackFromPoint ~= nil and reaper.GetThingFromPoint ~= nil

dragout.ZONE = 0.25 -- of the hovered track's height (user's number, 2026-08-08)

-- What the probe learned about the arrange this drag: where its top edge sits
-- on screen (so any track's I_TCPY becomes a screen position), and its left and
-- right edges (so the strip can span it). Cleared between drags — the window
-- can't move mid-drag, but it certainly can between them.
local probe = nil -- { origin_y, left, right }

function dragout.forget_arrange()
  probe = nil
end

-- The screen Y of `track`'s top edge, found by bisection: the highest point
-- that still hit-tests to this track. Bounded by the track's own height, so it
-- settles in about eight steps whatever the zoom.
local function probe_track_top(mx, my, track, height)
  local lo, hi = my - math.ceil(height) - 1, my
  for _ = 1, 12 do
    if hi - lo <= 1 then break end
    local mid = (lo + hi) // 2
    if reaper.GetTrackFromPoint(mx, mid) == track then hi = mid else lo = mid end
  end
  return hi
end

-- One edge of the arrange, found the same way against GetThingFromPoint's
-- answer ("arrange" vs "tcp" vs nothing). `outside` starts beyond any plausible
-- desktop edge and `inside` is a point known to be in the arrange; bisection
-- walks them together and returns the last point still inside. Twenty steps
-- covers a 40,000px span, once per drag.
local function probe_edge(my, outside, inside)
  for _ = 1, 20 do
    if math.abs(inside - outside) <= 1 then break end
    local mid = (outside + inside) // 2
    if select(2, reaper.GetThingFromPoint(mid, my)) == "arrange" then
      inside = mid
    else
      outside = mid
    end
  end
  return inside
end

-- Learn the arrange's geometry from one point inside it. Returns nil unless
-- that point really does hit-test to `track` — the bisection below only
-- converges when its starting point is genuinely inside, and this reading comes
-- from SWS while the bisection asks REAPER's hit-test, two answers that can
-- disagree on a boundary pixel. Refusing costs one frame of the strip;
-- believing it would cache a wrong origin for the whole drag and put the strip
-- (and the drop) on the wrong track.
local function probe_arrange(mx, my, track, height)
  if reaper.GetTrackFromPoint(mx, my) ~= track then return nil end
  local top = probe_track_top(mx, my, track, height)
  local tcpy = reaper.GetMediaTrackInfo_Value(track, "I_TCPY")
  return {
    origin_y = top - tcpy,               -- screen Y of the arrange's own top
    left  = probe_edge(my, -20000, mx),  -- close in from off the left of the desktop
    right = probe_edge(my,  20000, mx),  -- ...and from off the right
  }
end

-- Is the pointer in a track's top slice, and if so where does the strip go?
-- Returns nil when it isn't (or when the feature can't run at all), else
-- { track, x, y, w, h } in SCREEN pixels — the strip is drawn exactly as tall
-- as the slice that triggers it, so what the user sees IS the target they have
-- to hit (their call: one number, not two).
--
-- `target` is a dragout.target() reading, already taken this frame.
function dragout.newtrack_zone(target)
  if not target or not target.over_arrange or not target.track then return nil end
  if not HAS_HITTEST or not HAS_CFG then return nil end
  if (reaper.SNM_GetIntConfigVar("copyimpmedia", 0) & 8) == 0 then return nil end

  local th = reaper.GetMediaTrackInfo_Value(target.track, "I_TCPH")
  if not th or th <= 0 then return nil end
  local mx, my = reaper.GetMousePosition()

  -- Learned once per drag, then pure arithmetic for every frame after it.
  if not probe then
    probe = probe_arrange(mx, my, target.track, th)
    if not probe then return nil end -- refused; try again next frame
  end
  if probe.right - probe.left < 1 then return nil end -- the probe found nothing usable

  local ty = reaper.GetMediaTrackInfo_Value(target.track, "I_TCPY")
  local top = probe.origin_y + ty
  local into = my - top
  local slice = th * dragout.ZONE
  if into < 0 or into >= slice then return nil end
  return { track = target.track, x = probe.left, y = top,
           w = probe.right - probe.left, h = slice }
end

---------------------------------------------------------------- the real drop

-- Create the item. Explicit creation rather than InsertMedia, which would depend on
-- which track happens to be selected and where the edit cursor is — the whole point
-- here is that the sound lands where the mouse is.
--
-- `new_track` (2026-08-08) makes a fresh track directly ABOVE `track` and puts
-- the sound there instead — the drop half of REAPER's top-slice behaviour.
-- Created INSIDE the undo block, so one Ctrl+Z takes the track and the sound
-- away together; `true` for wantdefaults, because this one is the user's real
-- track and should arrive with whatever their template gives a new track.
--
-- Returns true + the position it actually landed at, or false + a reason.
function dragout.insert(path, track, position, name, span_start, span_end, new_track)
  if not reaper.ValidatePtr2(0, track, "MediaTrack*") then
    return false, "That track is no longer there."
  end

  -- Both asked BEFORE the undo block opens: a file we can't play is a refusal
  -- with nothing to take back.
  local src, length, unplayable = open_source(path)
  if not src then
    return false, unplayable
  end

  -- Follow whatever the user has set in REAPER rather than imposing our own rule.
  position = snap_position(position)

  -- A defer script gets no undo point of its own, so this one is explicit — and the
  -- block is closed on every path out, or REAPER would keep collecting the user's
  -- later edits into it.
  reaper.Undo_BeginBlock()

  -- The new track, when the drop landed in a track's top slice. Made INSIDE the
  -- block so one undo removes the track and the sound together, and `track` is
  -- re-pointed at it so everything below is unchanged.
  local made_track
  if new_track then
    local idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
    if idx >= 0 then
      reaper.InsertTrackAtIndex(idx, true)
      made_track = reaper.GetTrack(0, idx)
      if made_track then track = made_track end
    end
  end

  -- What is left to take back when the build refuses. The builder has already
  -- removed its own half-made item (and freed the source, when the take never
  -- took it), so what remains here is the track we added on the way in — a
  -- bare empty track left behind would be a change the user never asked for
  -- and can't explain — and the block, which closes here as it does on success.
  local function give_up(why)
    if made_track and reaper.ValidatePtr2(0, made_track, "MediaTrack*") then
      reaper.DeleteTrack(made_track)
    end
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("yb-Reference: Add Sound to Timeline", UNDO_ITEMS)
    return false, why
  end

  local item, _, build_failed = build_item(track, position, src, length, path, name, span_start, span_end)
  if not item then
    return give_up(build_failed)
  end

  reaper.Undo_EndBlock(string.format("yb-Reference: Add \"%s\" to Timeline", name or "sound"), UNDO_ITEMS)
  -- AFTER the block closes: fetching peaks is not part of the edit, and inside
  -- it REAPER's peak work would be recorded in the user's undo point.
  load_missing_peaks()

  return true, position
end

-- How the drop reads back to the user once it has landed.
function dragout.landed_at(track, position)
  return string.format("Added to %s at %s.", track_label(track),
    reaper.format_timestr_pos(position, "", 0))
end

return dragout
