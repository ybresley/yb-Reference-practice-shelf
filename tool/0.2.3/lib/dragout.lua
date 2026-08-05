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
  return "Release over REAPER's arrange view to place the sound (anywhere else cancels)."
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

-- Create the item. Explicit creation rather than InsertMedia, which would depend on
-- which track happens to be selected and where the edit cursor is — the whole point
-- here is that the sound lands where the mouse is.
--
-- Returns true + the position it actually landed at, or false + a reason.
function dragout.insert(path, track, position, name)
  if not reaper.ValidatePtr2(0, track, "MediaTrack*") then
    return false, "That track is no longer there."
  end

  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then
    return false, "its file couldn't be read"
  end
  local length = reaper.GetMediaSourceLength(src)
  if not length or length <= 0 then
    reaper.PCM_Source_Destroy(src)
    return false, "its file has no playable length"
  end

  -- Follow whatever the user has set in REAPER rather than imposing our own rule.
  if reaper.GetToggleCommandState(1157) == 1 then
    position = reaper.SnapToGrid(0, position)
  end

  -- A defer script gets no undo point of its own, so this one is explicit — and the
  -- block is closed on every path out, or REAPER would keep collecting the user's
  -- later edits into it.
  reaper.Undo_BeginBlock()

  -- Every step is checked, and any failure takes the whole thing back out again: a
  -- silent half-built item (no audio in it, or sitting at the wrong time) would be
  -- worse than a plain refusal, and the user would have no idea it had happened.
  local function give_up(item, own_source, why)
    if item then reaper.DeleteTrackMediaItem(track, item) end
    if own_source then reaper.PCM_Source_Destroy(src) end
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("yb_Reference: add to timeline", UNDO_ITEMS)
    return false, why
  end

  local item = reaper.AddMediaItemToTrack(track)
  local take = item and reaper.AddTakeToMediaItem(item)
  if not take then
    return give_up(item, true, "REAPER wouldn't create the item")
  end

  -- Attaching hands the source over: once this succeeds the take owns it, and
  -- destroying it ourselves would pull it out from under the project. If it fails,
  -- the source is still ours to free.
  --
  -- Compared against false rather than tested for truth: only an explicit "no" is a
  -- failure, so a build that returns nothing at all isn't mistaken for one and
  -- doesn't throw away an item that was in fact created correctly.
  if reaper.SetMediaItemTake_Source(take, src) == false then
    return give_up(item, true, "REAPER wouldn't attach the audio to the item")
  end
  if reaper.SetMediaItemInfo_Value(item, "D_POSITION", position) == false
    or reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length) == false then
    return give_up(item, false, "REAPER wouldn't place the item")
  end

  reaper.UpdateItemInProject(item)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(string.format("yb_Reference: add \"%s\" to timeline", name or "sound"), UNDO_ITEMS)

  return true, position
end

-- How the drop reads back to the user once it has landed.
function dragout.landed_at(track, position)
  return string.format("Added to %s at %s.", track_label(track),
    reaper.format_timestr_pos(position, "", 0))
end

return dragout
