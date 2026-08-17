-- Missing-library recovery window. This module only draws and reports intent;
-- folder picking, validation, creation and restart stay in the entry script.

local theme = require("ui.theme")

local recovery = {}
local ui = { typed_path = nil, path_source = nil }

local HAS_VIEWPORT = reaper.ImGui_GetMainViewport ~= nil
  and reaper.ImGui_Viewport_GetCenter ~= nil
local HAS_READONLY = reaper.ImGui_InputTextFlags_ReadOnly ~= nil

local function path_field(ctx, state, editable)
  if ui.path_source ~= state.path then
    ui.path_source = state.path
    ui.typed_path = state.path or ""
  end
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  if editable then
    local _, value = reaper.ImGui_InputText(ctx, "##library_recovery_path", ui.typed_path)
    ui.typed_path = value
    return
  end
  if HAS_READONLY then
    reaper.ImGui_InputText(ctx, "##library_recovery_path", state.path or "",
      reaper.ImGui_InputTextFlags_ReadOnly())
  else
    reaper.ImGui_BeginDisabled(ctx)
    reaper.ImGui_InputText(ctx, "##library_recovery_path", state.path or "")
    reaper.ImGui_EndDisabled(ctx)
  end
end

local function status_area(ctx, state)
  local M, T = theme.metrics, theme.tokens
  local top = reaper.ImGui_GetCursorPosY(ctx)
  if state.status and state.status ~= "" then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      state.error and T.DANGER_RED or T.TEXT_TERTIARY)
    reaper.ImGui_Text(ctx, state.status)
    reaper.ImGui_PopStyleColor(ctx)
  end
  -- One standing line keeps the actions still when a message appears, without
  -- the old three-line empty child making the panel look unfinished.
  reaper.ImGui_SetCursorPosY(ctx, top + M.RECOVERY_STATUS_H)
end

local function action_row(ctx, items)
  local M = theme.metrics
  local gap = M.ITEM_SPACING_X
  local buttons_w = M.RECOVERY_ACTION_W * #items + gap * (#items - 1)
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local x = reaper.ImGui_GetCursorPosX(ctx) + math.max(0, (avail - buttons_w) * 0.5)
  reaper.ImGui_SetCursorPosX(ctx, x)
  for i, item in ipairs(items) do
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, gap) end
    local clicked = reaper.ImGui_Button(ctx, item.label, M.RECOVERY_ACTION_W)
    if clicked then return item.action end
  end
end

-- Returns whether the recovery window remains open and at most one action.
function recovery.frame(ctx, state)
  local M, T = theme.metrics, theme.tokens
  local nc, nv, nf = theme.apply(ctx)
  local action

  local mode = state.mode or "missing"
  local heading, body, editable, items
  if mode == "existing_default" then
    heading = "LIBRARY ALREADY EXISTS"
    body = "A library already exists in the default location."
    editable = false
    items = {
      { label = "Back", action = { type = "back" } },
      { label = "Use This Library", action = { type = "use_default" } },
      { label = "Create Elsewhere", action = { type = "create_elsewhere" } },
    }
  elseif mode == "create_elsewhere" then
    heading = "CREATE NEW LIBRARY"
    body = "Enter an empty folder for the new library."
    editable = true
    items = {
      { label = "Back", action = { type = "back" } },
      { label = "Create", action = { type = "create_at", typed_dir = true } },
    }
  else
    heading = "LIBRARY NOT FOUND"
    body = "No library is available at this location."
    editable = not state.folder_picker
    items = {
      { label = "Choose Folder", action = { type = "choose", typed_dir = not state.folder_picker } },
      { label = "Create New", action = { type = "new" } },
    }
  end

  local visible_title = state.copy_label
    and (heading .. "  [" .. state.copy_label .. "]") or heading
  local win_title = visible_title .. "###yb_library_recovery"

  local flags = reaper.ImGui_WindowFlags_NoResize()
    | reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_NoScrollbar()
    | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  if reaper.ImGui_WindowFlags_NoDocking then
    flags = flags | reaper.ImGui_WindowFlags_NoDocking()
  end
  reaper.ImGui_SetNextWindowSize(ctx, M.RECOVERY_WIN_W, M.RECOVERY_WIN_H,
    reaper.ImGui_Cond_Always())
  if HAS_VIEWPORT then
    local cx, cy = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetMainViewport(ctx))
    reaper.ImGui_SetNextWindowPos(ctx, cx, cy, reaper.ImGui_Cond_FirstUseEver(), 0.5, 0.5)
  end

  local visible, open = theme.begin_window(ctx, win_title, true, flags, true)
  if visible then
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, body)
    path_field(ctx, state, editable)
    status_area(ctx, state)
    action = action_row(ctx, items)
    if action and action.typed_dir then
      action.typed_dir = nil
      action.dir = ui.typed_path
    end

    reaper.ImGui_End(ctx)
  end

  theme.unapply(ctx, nc, nv, nf)
  return open, action
end

return recovery
