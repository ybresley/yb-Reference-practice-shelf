-- Safe decisions for opening or creating a library at a chosen location.
--
-- Pure Lua plus the standard io/os library only. The caller owns folder
-- selection and creation; this module owns the data-safety boundary between
-- "use the library already here" and "deliberately make a new one".

local schema = require("core.schema")
local store  = require("core.library_store")

local location = {}

local function check_path(path)
  if type(path) ~= "string" or path == "" then
    error("a library file path is required", 0)
  end
end

-- Open only a real, readable library. Recovery runs first so an interrupted
-- atomic save is treated as the existing library it is, never as an empty
-- location.
function location.open_existing(path)
  check_path(path)
  store.recover(path)

  if store.exists(path) then return store.load(path) end
  if store.present(path) then
    error("library.json exists but could not be opened", 0)
  end
  if store.present(path .. ".bak") then
    error("a library backup exists but could not be restored", 0)
  end
  error("no library.json was found in that folder", 0)
end

-- Classify a destination after the caller has checked whether its folder is
-- empty. Recovery runs first, so a valid backup is an existing library rather
-- than apparently free space.
function location.classify(path, folder_empty)
  check_path(path)
  store.recover(path)

  if store.exists(path) then return "library", store.load(path) end
  if store.present(path)
      or store.present(path .. ".bak")
      or store.present(path .. ".tmp") then
    return "occupied"
  end
  return folder_empty == true and "empty" or "occupied"
end

-- Create only after the caller has proved the destination folder is empty.
-- Never mix a new library into unrelated files or overwrite recovery data.
function location.create_new(path, folder_empty)
  local kind = location.classify(path, folder_empty)
  if kind == "library" then
    error("that folder already contains a library", 0)
  end
  if kind ~= "empty" then
    error("choose an empty folder for the new library", 0)
  end

  local library = schema.starter_library()
  store.save(path, library)
  return library
end

return location
