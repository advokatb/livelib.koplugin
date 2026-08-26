-- livelib_settings.lua
-- Wrapper over LuaSettings (global plugin settings) and DocSettings (per-document sidecar).
--
-- Global settings: <data_dir>/settings/livelib_settings.lua
--
-- Book link stored in document sidecar under key "livelib":
--   {
--     edition_id  = "123456",
--     book_id     = "78901",
--     userbook_id = 0,
--     title       = "Title",
--     authors     = "Author",
--     livelib_url = "https://www.livelib.ru/book/123456-...",
--     status      = 2,
--     rating      = 10,       -- last sent LiveLib rating (0–10)
--     sync        = true,     -- auto-tracking for this book (nil → use always_sync)
--   }

local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local logger = require("logger")

local LivelibSettings = {}
LivelibSettings.__index = LivelibSettings

-- Global setting keys
LivelibSettings.KEY_COOKIE       = "session_cookie"
LivelibSettings.KEY_CONFIRM      = "menu_confirmation"
LivelibSettings.KEY_BACKEND      = "backend"
LivelibSettings.KEY_ALWAYS_SYNC  = "always_sync"
LivelibSettings.KEY_ENABLE_WIFI  = "enable_wifi"
LivelibSettings.KEY_SYNC_RATING  = "sync_rating"
LivelibSettings.KEY_MARK_READING_AT = "mark_reading_at_percent"

function LivelibSettings:new(path, ui)
  local o = setmetatable({}, self)
  o.settings = LuaSettings:open(path)
  o.ui = ui
  return o
end

-- ─── Global settings ─────────────────────────────────────────────────────────

function LivelibSettings:readSetting(key)
  return self.settings:readSetting(key)
end

function LivelibSettings:updateSetting(key, value)
  self.settings:saveSetting(key, value)
  self.settings:flush()
end

function LivelibSettings:getBackend()
  return self:readSetting(LivelibSettings.KEY_BACKEND) or "legacy"
end

function LivelibSettings:setBackend(value)
  self:updateSetting(LivelibSettings.KEY_BACKEND, value)
end

--- Session cookies (from settings or livelib_config.lua fallback)
function LivelibSettings:getCookie()
  local cookie = self:readSetting(LivelibSettings.KEY_COOKIE)
  if not cookie or cookie == "" then
    local ok, config = pcall(require, "livelib_config")
    if ok and config and config.session_cookie and config.session_cookie ~= "" then
      cookie = config.session_cookie
      logger.info("LiveLib: loaded cookie from livelib_config.lua")
    end
  end
  return cookie or ""
end

function LivelibSettings:setCookie(value)
  self:updateSetting(LivelibSettings.KEY_COOKIE, value)
end

function LivelibSettings:menuConfirm()
  return self:readSetting(LivelibSettings.KEY_CONFIRM) == true
end

function LivelibSettings:setMenuConfirm(value)
  self:updateSetting(LivelibSettings.KEY_CONFIRM, value)
end

--- Turn on Wi-Fi on demand during auto-tracking
function LivelibSettings:enableWifiOnDemand()
  return self:readSetting(LivelibSettings.KEY_ENABLE_WIFI) == true
end

function LivelibSettings:setEnableWifiOnDemand(value)
  self:updateSetting(LivelibSettings.KEY_ENABLE_WIFI, value == true)
end

--- Send KOReader summary.rating when marking Finished
function LivelibSettings:syncRatingEnabled()
  local v = self:readSetting(LivelibSettings.KEY_SYNC_RATING)
  if v == nil then return true end
  return v == true
end

function LivelibSettings:setSyncRatingEnabled(value)
  self:updateSetting(LivelibSettings.KEY_SYNC_RATING, value == true)
end

--- Default auto-tracking for books without explicit sidecar.sync
function LivelibSettings:alwaysSync()
  return self:readSetting(LivelibSettings.KEY_ALWAYS_SYNC) == true
end

function LivelibSettings:setAlwaysSync(value)
  self:updateSetting(LivelibSettings.KEY_ALWAYS_SYNC, value == true)
end

--- Percent threshold before setting Currently reading (default 1%)
function LivelibSettings:markReadingAtPercent()
  return self:readSetting(LivelibSettings.KEY_MARK_READING_AT) or 1
end

-- ─── Per-document (sidecar) settings ─────────────────────────────────────────

function LivelibSettings:_getDocSettings(filename)
  if self.ui and self.ui.doc_settings and self.ui.document
      and self.ui.document.file == filename then
    return self.ui.doc_settings
  end
  return DocSettings:open(filename)
end

function LivelibSettings:readBookSettings(filename)
  if not filename then return {} end
  local sidecar = self:_getDocSettings(filename)
  return sidecar:readSetting("livelib") or {}
end

function LivelibSettings:readBookSetting(filename, key)
  return self:readBookSettings(filename)[key]
end

--- Merge data into the livelib table in the document sidecar.
function LivelibSettings:updateBookSetting(filename, data)
  if not filename then return end

  local sidecar = self:_getDocSettings(filename)
  local current = sidecar:readSetting("livelib") or {}

  for k, v in pairs(data) do
    current[k] = v
  end

  sidecar:saveSetting("livelib", current)
  sidecar:flush()
end

function LivelibSettings:clearBookSettings(filename)
  if not filename then return end
  local sidecar = self:_getDocSettings(filename)
  sidecar:saveSetting("livelib", nil)
  sidecar:flush()
end

-- ─── Convenience getters for the current book ────────────────────────────────

function LivelibSettings:_currentFile()
  return self.ui and self.ui.document and self.ui.document.file
end

function LivelibSettings:bookLinked()
  local file = self:_currentFile()
  if not file then return false end
  return self:readBookSetting(file, "edition_id") ~= nil
end

function LivelibSettings:getLinkedEditionId()
  local file = self:_currentFile()
  if not file then return nil end
  return self:readBookSetting(file, "edition_id")
end

function LivelibSettings:getLinkedUserbookId()
  local file = self:_currentFile()
  if not file then return nil end
  return self:readBookSetting(file, "userbook_id")
end

function LivelibSettings:getLinkedTitle()
  local file = self:_currentFile()
  if not file then return nil end
  return self:readBookSetting(file, "title")
end

function LivelibSettings:getLinkedStatus()
  local file = self:_currentFile()
  if not file then return nil end
  return self:readBookSetting(file, "status")
end

--- Auto-tracking for a file: sidecar.sync or always_sync
function LivelibSettings:fileSyncEnabled(filename)
  if not filename then return false end
  local sync_value = self:readBookSetting(filename, "sync")
  if sync_value == nil then
    sync_value = self:alwaysSync()
  end
  return sync_value == true
end

function LivelibSettings:syncEnabled()
  return self:fileSyncEnabled(self:_currentFile())
end

function LivelibSettings:setSync(value)
  local file = self:_currentFile()
  if not file then return end
  self:updateBookSetting(file, { sync = value == true })
end

--- Rating from KOReader Book Status (summary.rating, 1–5★)
function LivelibSettings:getKoreaderRating(filename)
  filename = filename or self:_currentFile()
  if not filename then return nil end
  local sidecar = self:_getDocSettings(filename)
  local summary = sidecar:readSetting("summary")
  if summary and summary.rating then
    return tonumber(summary.rating)
  end
  return nil
end

--- KOReader Book Status: "reading" | "complete" | "abandoned" | nil
function LivelibSettings:getKoreaderStatus(filename)
  filename = filename or self:_currentFile()
  if not filename then return nil end
  local sidecar = self:_getDocSettings(filename)
  local summary = sidecar:readSetting("summary")
  if summary and summary.status and summary.status ~= "" then
    return summary.status
  end
  return nil
end

return LivelibSettings
