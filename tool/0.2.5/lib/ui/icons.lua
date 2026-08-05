-- icons: the house icon set. yb_Reference and its sibling app SoundVault both draw
-- their icons from Lucide (https://lucide.dev, ISC-licensed), so the two tools share
-- one visual language. Here the Lucide font (assets/fonts/lucide.ttf) is rendered as
-- glyphs — tinted by the text colour, crisp at any size, and every Lucide icon is
-- available by name.
--
-- The font is created and attached ONCE at startup (see ui/app.lua) — never in the
-- frame loop. This module only draws with it.
--
-- Add an icon: look its codepoint up in assets/fonts/lucide-info.json (the `unicode`
-- field, e.g. folder = 57559 = 0xE0D7) and add a line to NAMES.
--
-- A ui/ module: it may call reaper.ImGui_* only.

local theme = require("ui.theme")
local T = theme.tokens

local icons = {}

-- Lucide name -> Private-Use-Area codepoint. Only the ones we actually use.
icons.NAMES = {
  ["folder"]      = 0xE0D7,
  ["folder-open"] = 0xE247,
  ["trash-2"]     = 0xE18E,
  ["settings"]    = 0xE154,
  ["search"]      = 0xE151,
  ["file-text"]   = 0xE0CC,
  ["plus"]        = 0xE13D,
  ["play"]        = 0xE13C,
  ["pause"]       = 0xE12E,
  ["square"]      = 0xE167, -- stop (Lucide has no "stop"; its square is the convention)
  ["repeat"]      = 0xE146, -- loop
  ["ear"]         = 0xE382, -- auto-audition (hear a sound the moment you select it)
  ["library"]     = 0xE100, -- the working view's Library button (opens the browser popup)
  ["pin"]         = 0xE259, -- the sound table's pinned-to-project column (2026-07-29 redesign)
}

-- Vector fallback, used ONLY when the Lucide font couldn't be loaded (a ReaImGui
-- older than 0.10, or a missing file). A plain folder outline so the button still
-- means something rather than showing an empty box. Matches the Lucide folder's
-- shape closely enough for a fallback.
local STROKE = 1.5
function icons.draw_folder(dl, cx, cy, col)
  local left, right = cx - 7, cx + 7
  local top, bottom = cy - 3, cy + 5
  local tab_top = cy - 5
  local function seg(x1, y1, x2, y2)
    reaper.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, col, STROKE)
  end
  seg(left, tab_top, left, bottom)
  seg(left, bottom, right, bottom)
  seg(right, bottom, right, top)
  seg(right, top, cx - 1, top)
  seg(cx - 1, top, cx - 2, tab_top)
  seg(cx - 2, tab_top, left, tab_top)
end

-- Plus fallback for the add-sounds button: a simple centred cross.
function icons.draw_plus(dl, cx, cy, col)
  reaper.ImGui_DrawList_AddLine(dl, cx - 5, cy, cx + 5, cy, col, STROKE)
  reaper.ImGui_DrawList_AddLine(dl, cx, cy - 5, cx, cy + 5, col, STROKE)
end

-- Magnifier fallback for the search field's embedded glyph.
function icons.draw_search(dl, cx, cy, col)
  reaper.ImGui_DrawList_AddCircle(dl, cx - 1.5, cy - 1.5, 4, col, 12, STROKE)
  reaper.ImGui_DrawList_AddLine(dl, cx + 1.5, cy + 1.5, cx + 5.5, cy + 5.5, col, STROKE)
end

-- Pushpin fallback for the pinned column: head, body, needle — reads as a pin
-- even at 13px, which an abstract dot (the old marker) did not.
function icons.draw_pin(dl, cx, cy, col)
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - 2, cy - 6, cx + 2, cy - 3, col)
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - 3.5, cy - 3, cx + 3.5, cy + 1, col)
  reaper.ImGui_DrawList_AddLine(dl, cx, cy + 1, cx, cy + 6, col, STROKE)
end

-- Gear fallback for the settings button: a ring with a hub and short teeth.
function icons.draw_gear(dl, cx, cy, col)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, 5, col, 12, STROKE)
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, 1.5, col, 8, STROKE)
  for i = 0, 7 do
    local a = i * math.pi / 4
    local dx, dy = math.cos(a), math.sin(a)
    reaper.ImGui_DrawList_AddLine(dl, cx + dx * 5, cy + dy * 5, cx + dx * 7.5, cy + dy * 7.5, col, STROKE)
  end
end

-- Paints the named glyph centred over the item submitted just before this call
-- (a button, usually). Centring by the measured glyph size (rather than letting
-- Button align its label) is what keeps it from sitting slightly off. Returns
-- false — so the caller can fall back to a text label — when the font is missing
-- or the name unknown. opts = { glyph_size, color, inset_right }.
-- `inset_right` narrows the area the glyph centres in, from the right — for an
-- item that has something else living in its right edge (the sound table's pin
-- header, which shares its cell with ImGui's sort arrow).
function icons.paint_over_item(ctx, font, name, opts)
  local cp = icons.NAMES[name]
  if not (font and cp) then return false end
  opts = opts or {}
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
  x1 = x1 - (opts.inset_right or 0)
  local gs = opts.glyph_size or 16
  local glyph = utf8.char(cp)
  reaper.ImGui_PushFont(ctx, font, gs)
  local tw, th = reaper.ImGui_CalcTextSize(ctx, glyph)
  reaper.ImGui_PopFont(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddTextEx(dl, font, gs,
    (x0 + x1) * 0.5 - tw * 0.5, (y0 + y1) * 0.5 - th * 0.5,
    opts.color or T.TEXT_SECONDARY, glyph)
  return true
end

-- A square icon button. When the Lucide font is available the icon is that font's
-- glyph, rendered as the button's (centred, theme-tinted) label; otherwise it falls
-- back to a drawn shape. Fixed square size so it never changes shape. Returns true
-- when clicked.
--   font = the attached Lucide font (or nil)
--   name = a key in icons.NAMES
--   opts = { size, glyph_size, tip, fallback }  (fallback: a draw fn like draw_folder)
function icons.button(ctx, font, id, name, opts)
  opts = opts or {}
  local size = opts.size or reaper.ImGui_GetFrameHeight(ctx) -- square, matches row height

  if font and icons.NAMES[name] then
    local clicked = reaper.ImGui_Button(ctx, "##" .. id, size, size)
    icons.paint_over_item(ctx, font, name, opts)
    if opts.tip and reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, opts.tip) end
    return clicked
  end

  -- No icon font: a plain square button with the drawn fallback painted over it.
  local clicked = reaper.ImGui_Button(ctx, "##" .. id, size, size)
  if opts.fallback then
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    opts.fallback(reaper.ImGui_GetWindowDrawList(ctx), (x0 + x1) * 0.5, (y0 + y1) * 0.5, opts.color or T.TEXT_SECONDARY)
  end
  if opts.tip and reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, opts.tip) end
  return clicked
end

return icons
