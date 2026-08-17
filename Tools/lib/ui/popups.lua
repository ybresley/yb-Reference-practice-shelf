-- popups: the one single-field text popup used across screens — add category,
-- add sub-category, rename, a pin's label. Defined once (the same discipline
-- ui.widgets applies to controls) so every such popup opens, focuses and submits
-- identically. The caller supplies its OWN scratch table (`edit`) so each screen
-- keeps its transient popup text apart from the others' — this module holds no
-- state of its own. A ui/ module: reaper.ImGui_* only.

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
    -- The popup's own heading, in the app's one heading grammar: small caps,
    -- TEXT_PRIMARY. Upper-cased HERE rather than at each call site, so a popup
    -- added later can't arrive in a different case. (2026-08-08.)
    reaper.ImGui_TextColored(ctx, T.TEXT_PRIMARY, tostring(title):upper())
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

-- (The post-update restart popup lived here from 2026-08-05 until 2026-08-08.
-- It is gone: an update now restarts the tool the moment it lands rather than
-- asking, and the What's New card greets the new code on the way back up —
-- `ui/whatsnew.lua`, and the "done" handling in the entry script. Deleting it
-- also removed this module's one piece of module-level state.)

return popups
