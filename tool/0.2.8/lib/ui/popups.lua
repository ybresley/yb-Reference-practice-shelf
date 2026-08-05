-- popups: the one single-field text popup used across screens — add category,
-- add sub-category, rename, a pin's label. Defined once (the same discipline
-- ui.widgets applies to controls) so every such popup opens, focuses and submits
-- identically. The caller supplies its OWN scratch table (`edit`) so each screen
-- keeps its transient popup text apart from the others' — this module never
-- holds state of its own, with ONE deliberate exception: the update-done popup
-- below is a singleton announced from two windows, so its shown/owner scratch
-- has no per-screen home and lives here. A ui/ module: reaper.ImGui_* only.

local theme = require("ui.theme")
local T = theme.tokens
local M = theme.metrics

local popups = {}

-- Returns the entered text on submit, else nil. Focuses the field when the
-- popup first opens and submits on the OK button. `opts.allow_empty` lets an
-- empty string through (a pin's label popup uses this: empty clears the label,
-- rather than "" being read as "nothing typed yet, cancel").
function popups.edit_popup(ctx, edit, id, title, key, opts)
  opts = opts or {}
  local submitted
  if reaper.ImGui_BeginPopup(ctx, id) then
    reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY, title)
    if reaper.ImGui_IsWindowAppearing(ctx) then reaper.ImGui_SetKeyboardFocusHere(ctx) end
    reaper.ImGui_SetNextItemWidth(ctx, M.FIELD_W)
    -- Plain InputText (NOT EnterReturnsTrue): with that flag ReaImGui only returns
    -- the edited text on the frame Enter is pressed, so an OK click would read a
    -- stale value and clear the box. Without it the returned buffer is always the
    -- current text, so it accumulates correctly and OK can read it.
    local _, val = reaper.ImGui_InputText(ctx, "##" .. id, edit[key] or "")
    edit[key] = val
    reaper.ImGui_Dummy(ctx, 0, 4)
    local ok = reaper.ImGui_Button(ctx, "OK", M.POPUP_BTN_W)
    reaper.ImGui_SameLine(ctx)
    local cancel = reaper.ImGui_Button(ctx, "Cancel", M.POPUP_BTN_W)
    if ok and (opts.allow_empty or edit[key] ~= "") then
      submitted = edit[key]
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif cancel then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return submitted
end

-- The post-update restart popup (2026-08-05, user-requested — and its timing
-- fixed the same day: it must appear the INSTANT the update lands, even while
-- the Settings modal is up, because that is exactly what the user is watching
-- during "Updating…"). ImGui only stacks a modal opened from inside the parent
-- modal's scope, so this is announced from two call sites: draw_settings
-- (site "settings", stacks over the modal, may always open) and app.frame
-- (site "app", opens only while no popup is up anywhere). Whichever site opens
-- it becomes the owner and keeps drawing it until a button closes it; it fires
-- once per landed update (a second update can't run without the restart).
--
-- Returns the pressed intent as an action ({ type = "restart_tool" }) or nil.
-- The modal blocks every other control, so the frame's single action slot is
-- free whenever a button here is clicked.
local ud = { shown = false, owner = nil }

function popups.update_done(ctx, state, site, can_open)
  local u = state.update
  if u and u.phase == "done" and not ud.shown and can_open then
    ud.shown, ud.owner = true, site
    reaper.ImGui_OpenPopup(ctx, "yb_Reference updated###yb_update_done")
  end
  if ud.owner ~= site then return nil end

  -- Centre the popup over the window announcing it — the Settings modal when
  -- stacked, the working view otherwise. Without this hint ImGui places a
  -- fresh modal wherever its window memory last had one, which read as
  -- "appeared elsewhere on the screen" (user, 2026-08-05). Appearing-only,
  -- so it can still be dragged once shown.
  if reaper.ImGui_Cond_Appearing ~= nil then
    local wx, wy = reaper.ImGui_GetWindowPos(ctx)
    local ww, wh = reaper.ImGui_GetWindowSize(ctx)
    reaper.ImGui_SetNextWindowPos(ctx, wx + ww * 0.5, wy + wh * 0.5,
      reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  end

  local action
  if reaper.ImGui_BeginPopupModal(ctx, "yb_Reference updated###yb_update_done", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY,
      string.format("Updated to v%s.", (u and u.installed) or "?"))
    if state.can_restart then
      reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
        "Restart the tool to start using the new version.")
      reaper.ImGui_Dummy(ctx, 0, 4)
      if reaper.ImGui_Button(ctx, "Restart now", M.POPUP_BTN_W + 30) then
        action = { type = "restart_tool" }
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_SameLine(ctx)
      -- Later = just dismiss; Settings' UPDATES row keeps the "close and
      -- reopen" reminder until the restart really happens.
      if reaper.ImGui_Button(ctx, "Later", M.POPUP_BTN_W) then
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
    else
      reaper.ImGui_TextColored(ctx, T.TEXT_SECONDARY,
        "Close the tool and reopen it to finish.")
      reaper.ImGui_Dummy(ctx, 0, 4)
      if reaper.ImGui_Button(ctx, "OK", M.POPUP_BTN_W) then
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return action
end

return popups
