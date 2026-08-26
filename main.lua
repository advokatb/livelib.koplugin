-- main.lua — livelib.koplugin
-- KOReader plugin to sync reading status with livelib.ru.
--
-- Auth: browser session cookies (copy manually from DevTools).
-- No official API — uses observed HTML endpoints.
--
-- Architecture (based on storygraph.koplugin):
--   main.lua           — WidgetContainer, init, KOReader events
--   livelib_api.lua    — HTTP client facade
--   livelib_parser.lua — HTML parsing
--   livelib_settings.lua — settings and sidecar book links
--   livelib_menu.lua   — menu UI

local DataStorage = require("datastorage")
local Dispatcher  = require("dispatcher")
local logger      = require("logger")
local _           = require("lib/livelib_i18n").gettext
local T           = require("ffi/util").template

local Device      = require("device")
local NetworkMgr  = require("ui/network/manager")
local UIManager   = require("ui/uimanager")

local InfoMessage  = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Api             = require("livelib_api")
local LivelibMenu     = require("livelib_menu")
local LivelibSettings = require("livelib_settings")

-- Minimum interval between automatic status sync requests (seconds)
local MIN_AUTO_SYNC_INTERVAL = 60

local LivelibPlugin = WidgetContainer:extend {
  name         = "livelib",
  is_doc_only  = false,
}

function LivelibPlugin:init()
  self.state = {
    current_status = nil,
    last_auto_sync_at = 0,
    page = nil,
    ensure_remote_pending = false,
  }

  local settings_path = ("%s/%s"):format(
    DataStorage:getSettingsDir(), "livelib_settings.lua"
  )
  self.settings = LivelibSettings:new(settings_path, self.ui)

  Api.settings = self.settings
  Api.on_error = function(err)
    self:_handleApiError(err)
  end

  self.menu = LivelibMenu:new {
    settings = self.settings,
    state    = self.state,
    ui       = self.ui,
    plugin   = self,
  }

  self:onDispatcherRegisterActions()
  self.ui.menu:registerToMainMenu(self)

  logger.info("LiveLib: plugin initialized")
end

function LivelibPlugin:_handleApiError(err)
  if err == "session_expired" then
    UIManager:show(InfoMessage:new {
      text = _([[Livelib: session expired.

Update cookies in Livelib → Settings → Session cookies,
or in livelib_config.lua (DevTools → Application → Cookies → livelib.ru).

You do not need to restart KOReader — changes apply immediately.]]),
      icon = "notice-warning",
    })
  elseif err and err ~= "" then
    UIManager:show(InfoMessage:new {
      text = T(_("Livelib: %1"), tostring(err)),
      icon = "notice-warning",
    })
  end
end

function LivelibPlugin:onDispatcherRegisterActions()
  Dispatcher:registerAction("livelib_link", {
    category = "none",
    event    = "LivelibLink",
    title    = _("Livelib: Link book"),
    general  = true,
  })

  Dispatcher:registerAction("livelib_set_reading", {
    category = "none",
    event    = "LivelibSetReading",
    title    = _("Livelib: Status — Currently reading"),
    general  = true,
  })

  Dispatcher:registerAction("livelib_set_read", {
    category = "none",
    event    = "LivelibSetRead",
    title    = _("Livelib: Status — Finished"),
    general  = true,
  })

  Dispatcher:registerAction("livelib_track", {
    category = "none",
    event    = "LivelibTrack",
    title    = _("Livelib: Enable auto-tracking"),
    general  = true,
  })

  Dispatcher:registerAction("livelib_stop_track", {
    category = "none",
    event    = "LivelibStopTrack",
    title    = _("Livelib: Disable auto-tracking"),
    general  = true,
  })

  Dispatcher:registerAction("livelib_sync_rating", {
    category = "none",
    event    = "LivelibSyncRating",
    title    = _("Livelib: Send rating"),
    general  = true,
  })
end

function LivelibPlugin:onLivelibLink()
  if not self.ui.document then
    UIManager:show(InfoMessage:new { text = _("Livelib: open a book to link it") })
    return
  end
  self:_withWifi(function()
    self.menu:showLinkBookDialog(false)
  end)
end

function LivelibPlugin:onLivelibSetReading()
  self:_quickSetStatus(2)
end

function LivelibPlugin:onLivelibSetRead()
  self:_quickSetStatus(1)
end

function LivelibPlugin:onLivelibTrack()
  if not self.ui.document then return end
  if not self.settings:bookLinked() then
    UIManager:show(InfoMessage:new {
      text = _("Livelib: link a book first"),
    })
    return
  end
  self.settings:setSync(true)
  UIManager:show(Notification:new {
    text = _("Livelib: auto-tracking enabled"),
    timeout = 2,
  })
end

function LivelibPlugin:onLivelibStopTrack()
  if not self.ui.document then return end
  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Livelib: auto-tracking disabled"),
    timeout = 2,
  })
end

function LivelibPlugin:onLivelibSyncRating()
  if not self.ui.document or not self.settings:bookLinked() then
    UIManager:show(InfoMessage:new {
      text = _("Livelib: link a book and open it"),
    })
    return
  end
  self:_withWifi(function()
    self:syncRatingNow(true)
  end)
end

--- LiveLib rating (0–10) from KOReader summary.rating when sync_rating is enabled.
function LivelibPlugin:_resolveRating(filename, status_code)
  if not self.settings:syncRatingEnabled() then
    return 0
  end
  if status_code ~= nil and status_code ~= 1 then
    return 0
  end
  local kr = self.settings:getKoreaderRating(filename)
  return Api.koreaderToLivelibRating(kr)
end

--- Set status without a dialog (Dispatcher / auto-tracking).
-- @param status_code  status code
-- @param opts         { silent=bool, force=bool, ensure=bool, filename=string }
function LivelibPlugin:_quickSetStatus(status_code, opts)
  opts = opts or {}
  local file = opts.filename or (self.ui.document and self.ui.document.file)
  if not file then return end

  if not self.settings:readBookSetting(file, "edition_id") then
    if not opts.silent then
      UIManager:show(InfoMessage:new {
        text = _("Livelib: link a book first via Livelib → Link book")
      })
    end
    return
  end

  local current = self.settings:readBookSetting(file, "status")
  local userbook_id = tonumber(self.settings:readBookSetting(file, "userbook_id")) or 0
  -- Skip only when local status already matches *and* we are not forcing a
  -- remote re-sync (stale sidecar after the book was removed on the website).
  if not opts.force and not opts.ensure and current == status_code and userbook_id ~= 0 then
    if status_code == 1 and self.settings:syncRatingEnabled() then
      local new_rating = self:_resolveRating(file, 1)
      local old_rating = tonumber(self.settings:readBookSetting(file, "rating")) or 0
      if new_rating == old_rating then
        return
      end
    else
      return
    end
  end

  self:_withWifi(function()
    local edition_id  = self.settings:readBookSetting(file, "edition_id")
    local userbook_id = self.settings:readBookSetting(file, "userbook_id") or 0
    local rating      = self:_resolveRating(file, status_code)

    local result = Api:set_status(edition_id, status_code, userbook_id, rating)
    if result and result.ok then
      local update = {
        userbook_id = result.userbook_id or userbook_id,
        status      = status_code,
      }
      -- Persist what the server accepted. Beta may return rating=0 if the
      -- status PATCH succeeded but the separate rating PATCH failed.
      if status_code == 1 then
        update.rating = result.rating or 0
      end
      self.settings:updateBookSetting(file, update)
      if self.ui.document and self.ui.document.file == file then
        self.state.current_status = status_code
      end
      self.state.last_auto_sync_at = os.time()
      -- Book is already on the server — skip the open-book ensure re-push.
      self.state.ensure_remote_pending = false
      if not opts.silent then
        UIManager:show(Notification:new {
          text = T(_("Livelib: %1"), Api:statusText(status_code)),
          timeout = 3,
        })
      end
    end
  end, opts.silent)
end

--- Send current KOReader rating to Livelib (Finished status).
function LivelibPlugin:syncRatingNow(show_feedback)
  local file = self.ui.document and self.ui.document.file
  if not file then return false end

  local kr = self.settings:getKoreaderRating(file)
  if not kr or kr <= 0 then
    if show_feedback then
      UIManager:show(InfoMessage:new {
        text = _([[Livelib: no rating in KOReader Book Status (★).
Set stars and try again.]]),
      })
    end
    return false
  end

  local status = self.settings:getLinkedStatus() or 1
  if status ~= 1 then
    status = 1
  end

  local edition_id  = self.settings:getLinkedEditionId()
  local userbook_id = self.settings:getLinkedUserbookId() or 0
  local rating      = Api.koreaderToLivelibRating(kr)

  local result = Api:set_status(edition_id, status, userbook_id, rating)
  if result and result.ok then
    self.settings:updateBookSetting(file, {
      userbook_id = result.userbook_id or userbook_id,
      status      = status,
      rating      = result.rating or 0,
    })
    self.state.current_status = status
    if result.error_text then
      -- Status saved; rating PATCH failed (warning already shown via on_error)
      return false
    end
    if show_feedback then
      UIManager:show(Notification:new {
        text = T(_("Livelib: rating %1★ sent"), tostring(kr)),
        timeout = 3,
      })
    end
    return true
  end
  return false
end

function LivelibPlugin:_withWifi(callback, silent)
  if NetworkMgr:isWifiOn() or NetworkMgr:isConnected() then
    callback()
    return
  end

  if self.settings:enableWifiOnDemand()
      and Device:hasWifiRestore()
      and G_reader_settings:nilOrFalse("airplanemode") then
    local original_on = NetworkMgr.wifi_was_on
    NetworkMgr:restoreWifiAsync()
    NetworkMgr:scheduleConnectivityCheck(function()
      NetworkMgr.wifi_was_on = original_on
      G_reader_settings:saveSetting("wifi_was_on", original_on)
      callback()
    end)
    return
  end

  if silent then
    return
  end

  NetworkMgr:promptWifiOn(function()
    callback()
  end)
end

function LivelibPlugin:_canAutoSync(filename, opts)
  opts = opts or {}
  if not filename then return false end
  if not self.settings:readBookSetting(filename, "edition_id") then
    logger.dbg("LiveLib: auto-track skip — book not linked")
    return false
  end
  if not self.settings:fileSyncEnabled(filename) then
    logger.dbg("LiveLib: auto-track skip — auto-tracking off")
    return false
  end
  if opts.ensure then return true end
  local now = os.time()
  if now - (self.state.last_auto_sync_at or 0) < MIN_AUTO_SYNC_INTERVAL then
    logger.dbg("LiveLib: auto-track skip — throttle")
    return false
  end
  return true
end

--- Start reading → Currently reading; ~100% → Finished.
-- @param opts { ensure=bool }  re-push status even if sidecar already matches
function LivelibPlugin:_maybeAutoTrackProgress(opts)
  opts = opts or {}
  if not self.ui.document then return end
  local file = self.ui.document.file
  if not self:_canAutoSync(file, opts) then return end

  local current = self.settings:readBookSetting(file, "status")
  if current == 1 or current == 3 then
    logger.dbg("LiveLib: auto-track skip — finished/DNF locally")
    return
  end

  local percent = nil
  if self.ui.doc_settings then
    percent = tonumber(self.ui.doc_settings:readSetting("percent_finished"))
  end
  if not percent and self.ui.document.getPageCount and self.state.page then
    local total = self.ui.document:getPageCount()
    if total and total > 0 then
      percent = self.state.page / total
    end
  end
  if not percent then
    logger.dbg("LiveLib: auto-track skip — no percent_finished")
    return
  end

  local pct = percent * 100
  local silent_opts = { silent = true, filename = file, ensure = opts.ensure }
  if pct >= 99.5 then
    logger.info("LiveLib: auto-track Finished (" .. string.format("%.1f", pct) .. "%)")
    self:_quickSetStatus(1, silent_opts)
  elseif pct >= self.settings:markReadingAtPercent() then
    if current ~= 2 or opts.ensure then
      logger.info("LiveLib: auto-track Currently reading (" .. string.format("%.1f", pct) .. "%)")
      self:_quickSetStatus(2, silent_opts)
    end
  end
end

function LivelibPlugin:onPageUpdate(page)
  self.state.page = page
  self:_maybeAutoTrackProgress()
end

function LivelibPlugin:onPosUpdate(_, page)
  if page then
    self:onPageUpdate(page)
  end
end

function LivelibPlugin:onEndOfBook()
  local file = self.ui.document and self.ui.document.file
  if not file or not self.settings:fileSyncEnabled(file) then return end
  if not self.settings:readBookSetting(file, "edition_id") then return end

  local mark_read = false
  if G_reader_settings:isTrue("end_document_auto_mark") then
    mark_read = true
  end
  if not mark_read then
    local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
    mark_read = action == "mark_read"
    if action == "pop-up" then
      mark_read = "later"
    end
  end
  if not mark_read then return end

  local do_mark = function()
    self:_quickSetStatus(1, { silent = false, force = true, filename = file })
  end

  if mark_read == "later" then
    UIManager:scheduleIn(30, function()
      local status = self.settings:getKoreaderStatus(file)
      if status == "complete" then
        do_mark()
      end
    end)
  else
    do_mark()
  end
end

--- Sync when KOReader Book Status changes (reading/complete/abandoned).
function LivelibPlugin:onDocSettingsItemsChanged(file, doc_settings)
  if not file or not doc_settings or not doc_settings.summary then return end
  if not self.settings:fileSyncEnabled(file) then return end
  if not self.settings:readBookSetting(file, "edition_id") then return end

  local kr_status = doc_settings.summary.status
  local status_code
  if kr_status == "complete" then
    status_code = 1
  elseif kr_status == "reading" then
    status_code = 2
  elseif kr_status == "abandoned" then
    status_code = 3
  end
  if not status_code then return end

  self:_quickSetStatus(status_code, { silent = false, force = true, filename = file })
end

function LivelibPlugin:onReaderReady()
  if not self.ui.document then return end

  local cached_status = self.settings:getLinkedStatus()
  self.state.current_status = cached_status
  self.state.page = self.ui:getCurrentPage()
  self.state.ensure_remote_pending = true

  if cached_status ~= nil then
    logger.info("LiveLib: restored cached status=" .. tostring(cached_status)
      .. " for " .. self.ui.document.file)
  end

  -- Re-push "Currently reading" after open: sidecar may still say status=2
  -- after the book was removed on livelib.ru (no request would otherwise fire).
  UIManager:scheduleIn(2, function()
    self:_runPendingEnsure()
  end)
end

function LivelibPlugin:_runPendingEnsure()
  if not self.state.ensure_remote_pending then return end
  if not self.ui.document then return end
  if not self.settings:syncEnabled() then
    self.state.ensure_remote_pending = false
    return
  end
  if not (NetworkMgr:isWifiOn() or NetworkMgr:isConnected()) then
    logger.info("LiveLib: auto-track wait — no network yet")
    return
  end
  self.state.ensure_remote_pending = false
  self:_maybeAutoTrackProgress({ ensure = true })
end

function LivelibPlugin:onNetworkConnected()
  self:_runPendingEnsure()
end

function LivelibPlugin:onDocumentClose()
  self.state.current_status = nil
  self.state.page = nil
  self.state.ensure_remote_pending = false
end

function LivelibPlugin:addToMainMenu(menu_items)
  menu_items["livelib"] = self.menu:mainMenu()
end

return LivelibPlugin
