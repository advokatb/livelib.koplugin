-- livelib_menu.lua
-- Plugin menu for KOReader.
-- Registered via self.ui.menu:registerToMainMenu(self) in main.lua.

local _ = require("lib/livelib_i18n").gettext
local T = require("ffi/util").template
local logger = require("logger")

local UIManager     = require("ui/uimanager")
local InfoMessage   = require("ui/widget/infomessage")
local Font          = require("ui/font")
local InputDialog   = require("ui/widget/inputdialog")
local Menu          = require("ui/widget/menu")
local Notification  = require("ui/widget/notification")
local ConfirmBox    = require("ui/widget/confirmbox")

local Api           = require("livelib_api")

--- Load this plugin's _meta.lua by path. 
local function loadPluginMeta()
  local src = debug.getinfo(1, "S").source:match("@(.*)$") or ""
  src = src:gsub("\\", "/")
  local plugin_dir = src:match("^(.*)/[^/]+%.lua$")
  if not plugin_dir then return nil end
  local ok, meta = pcall(dofile, plugin_dir .. "/_meta.lua")
  if ok and type(meta) == "table" then return meta end
  return nil
end

-- LiveLib status codes and menu labels (msgids match livelib_api STATUS_KEYS)
local STATUS_ITEMS = {
  { code = 0,  label_key = "Want to read" },
  { code = 2,  label_key = "Currently reading" },
  { code = 1,  label_key = "Finished" },
  { code = 3,  label_key = "Did not finish" },
  { code = -2, label_key = "Status removed" },
}

local LivelibMenu = {}
LivelibMenu.__index = LivelibMenu

function LivelibMenu:new(o)
  return setmetatable(o or {}, self)
end

local function show_error(text)
  UIManager:show(InfoMessage:new {
    text = text,
    icon = "notice-warning",
  })
end

local function show_notification(text)
  UIManager:show(Notification:new {
    text = text,
    timeout = 3,
  })
end

function LivelibMenu:maybeConfirm(text, callback)
  if self.settings:menuConfirm() then
    UIManager:show(ConfirmBox:new {
      text = text,
      ok_text = _("Yes"),
      ok_callback = callback,
    })
  else
    callback()
  end
end

function LivelibMenu:showLinkBookDialog(force_search, done_callback)
  local props = self.ui.document and self.ui.document:getProps() or {}
  local auto_query = ""
  if props.title and props.title ~= "" then
    auto_query = props.title
    if props.authors and props.authors ~= "" then
      auto_query = auto_query .. " " .. props.authors
    end
  end

  if force_search or auto_query == "" then
    self:_showSearchInput(auto_query, done_callback)
  else
    self:_doSearch(auto_query, done_callback)
  end
end

function LivelibMenu:_showSearchInput(initial_query, done_callback)
  local search_dialog
  search_dialog = InputDialog:new {
    title = _("Search book on Livelib"),
    input = initial_query,
    save_button_text = _("Search"),
    buttons = { {
      {
        text = _("Cancel"),
        callback = function()
          UIManager:close(search_dialog)
        end,
      },
      {
        text = _("Search"),
        is_enter_default = true,
        callback = function()
          local query = search_dialog:getInputText()
          UIManager:close(search_dialog)
          if query and query ~= "" then
            self:_doSearch(query, done_callback)
          end
        end,
      },
    } },
  }
  UIManager:show(search_dialog)
  search_dialog:onShowKeyboard()
end

function LivelibMenu:_doSearch(query, done_callback)
  local loading = InfoMessage:new { text = _("Searching on Livelib…") }
  UIManager:show(loading)

  UIManager:scheduleIn(0.1, function()
    local books = Api:search(query)
    UIManager:close(loading)

    if not books then
      return
    end

    if #books == 0 then
      UIManager:show(ConfirmBox:new {
        text = T(_("Nothing found for \"%1\".\nTry another query?"), query),
        ok_text = _("New query"),
        ok_callback = function()
          self:_showSearchInput(query, done_callback)
        end,
      })
      return
    end

    self:_showSearchResults(query, books, done_callback)
  end)
end

function LivelibMenu:_showSearchResults(query, books, done_callback)
  local menu_items = {}
  for i, book in ipairs(books) do
    local display = book.title
    if book.authors and book.authors ~= "" then
      display = display .. "\n" .. book.authors
    end
    if book.rating and book.rating ~= "" then
      display = display .. " [" .. book.rating .. "]"
    end
    table.insert(menu_items, {
      text      = display,
      book_data = book,
    })
  end

  table.insert(menu_items, {
    text = _("↩ New search"),
    is_search = true,
  })

  local results_menu
  results_menu = Menu:new {
    title      = _("Search results"),
    item_table = menu_items,
    fullscreen = true,
    onMenuSelect = function(menu_self, item)
      if item.is_search then
        UIManager:close(results_menu)
        self:_showSearchInput(query, done_callback)
        return
      end
      UIManager:close(results_menu)
      self:_linkBook(item.book_data, done_callback)
    end,
  }
  UIManager:show(results_menu)
end

function LivelibMenu:_linkBook(book_data, done_callback)
  local file = self.ui.document and self.ui.document.file
  if not file then return end

  self.settings:updateBookSetting(file, {
    edition_id  = book_data.edition_id,
    book_id     = book_data.book_id,
    userbook_id = 0,
    title       = book_data.title,
    authors     = book_data.authors,
    livelib_url = book_data.livelib_url,
    status      = nil,
  })

  logger.info("LiveLib: linked book edition_id=" .. tostring(book_data.edition_id)
    .. " title=" .. tostring(book_data.title))

  show_notification(T(_("Book linked: %1"), book_data.title))

  if done_callback then
    done_callback(book_data)
  end
end

function LivelibMenu:_doSetStatus(status_code, menu_instance)
  local file = self.ui.document and self.ui.document.file
  if not file then return end

  local edition_id  = self.settings:getLinkedEditionId()
  local userbook_id = self.settings:getLinkedUserbookId() or 0

  if not edition_id then
    show_error(_("Book is not linked to Livelib"))
    return
  end

  local rating = 0
  if status_code == 1 and self.settings:syncRatingEnabled() then
    rating = Api.koreaderToLivelibRating(self.settings:getKoreaderRating(file))
  elseif status_code == -2 then
    rating = 0
  end

  local loading = InfoMessage:new { text = _("Updating status on Livelib…") }
  UIManager:show(loading)

  UIManager:scheduleIn(0.1, function()
    local result
    if status_code == -2 then
      result = Api:remove_status(edition_id, userbook_id)
    else
      result = Api:set_status(edition_id, status_code, userbook_id, rating)
    end
    UIManager:close(loading)

    if not result or not result.ok then
      return
    end

    local update = {
      userbook_id = result.userbook_id ~= nil and result.userbook_id or userbook_id,
      status      = status_code,
    }
    if status_code == -2 then
      update.userbook_id = 0
      update.rating = nil
    elseif status_code == 1 then
      update.rating = result.rating or 0
    end
    self.settings:updateBookSetting(file, update)

    if self.state then
      self.state.current_status = status_code
      self.state.ensure_remote_pending = false
    end

    local saved_rating = tonumber(result.rating) or 0
    local status_text = Api:statusText(status_code)
    if status_code == 1 and saved_rating > 0 then
      status_text = status_text .. " (" .. tostring(saved_rating / 2) .. "★)"
    end
    show_notification(T(_("Livelib: %1"), status_text))

    if menu_instance and menu_instance.updateItems then
      menu_instance.item_table = self:getStatusSubMenuItems()
      menu_instance:updateItems()
    end
  end)
end

function LivelibMenu:getStatusSubMenuItems()
  local current_status = self.state and self.state.current_status

  if current_status == nil then
    current_status = self.settings:getLinkedStatus()
  end

  local items = {}
  for i, item in ipairs(STATUS_ITEMS) do
    local code  = item.code
    local label = _(item.label_key)
    table.insert(items, {
      text = label,
      radio = true,
      checked_func = function()
        return current_status == code
      end,
      callback = function(menu_instance)
        self:maybeConfirm(
          T(_("Set status \"%1\"?"), label),
          function()
            self:_doSetStatus(code, menu_instance)
          end
        )
      end,
      keep_menu_open = true,
    })
  end

  return items
end

function LivelibMenu:getSettingsSubMenuItems()
  return {
    {
      text = _("Session cookies…"),
      keep_menu_open = true,
      callback = function()
        self:_showCookieInput()
      end,
    },
    {
      text = _("Auto-tracking for new books"),
      checked_func = function()
        return self.settings:alwaysSync()
      end,
      callback = function()
        self.settings:setAlwaysSync(not self.settings:alwaysSync())
      end,
      keep_menu_open = true,
      help_text = _("When enabled, auto-tracking is on for linked books without an explicit per-book toggle."),
    },
    {
      text = _("Sync rating (★)"),
      checked_func = function()
        return self.settings:syncRatingEnabled()
      end,
      callback = function()
        self.settings:setSyncRatingEnabled(not self.settings:syncRatingEnabled())
      end,
      keep_menu_open = true,
      help_text = _("When marking Finished, send the KOReader Book Status rating (1–5★ → 0–10 on Livelib)."),
    },
    {
      text = _("Enable Wi-Fi on demand"),
      checked_func = function()
        return self.settings:enableWifiOnDemand()
      end,
      callback = function()
        self.settings:setEnableWifiOnDemand(not self.settings:enableWifiOnDemand())
      end,
      keep_menu_open = true,
    },
    {
      text = _("Use Beta API"),
      checked_func = function()
        return self.settings:getBackend() == "beta"
      end,
      callback = function()
        local new_backend = self.settings:getBackend() == "beta" and "legacy" or "beta"
        self.settings:setBackend(new_backend)
      end,
      keep_menu_open = true,
      help_text = _("Use beta.api.livelib.ru (REST/JSON) instead of the classic www.livelib.ru endpoints."),
    },
    {
      text = _("Confirm status changes"),
      checked_func = function()
        return self.settings:menuConfirm()
      end,
      callback = function()
        self.settings:setMenuConfirm(not self.settings:menuConfirm())
      end,
      keep_menu_open = true,
    },
  }
end

function LivelibMenu:_showCookieInput()
  local current = self.settings:getCookie()
  local dialog
  dialog = InputDialog:new {
    title = _("livelib.ru session cookies"),
    description = _([[Copy all livelib.ru cookies from your browser:
DevTools → Application → Cookies → livelib.ru
(all cookies in one line: name1=value1; name2=value2)]]),
    input = current,
    input_type = "text",
    save_button_text = _("Save"),
    buttons = { {
      {
        text = _("Cancel"),
        callback = function()
          UIManager:close(dialog)
        end,
      },
      {
        text = _("Save"),
        is_enter_default = false,
        callback = function()
          local value = dialog:getInputText()
          UIManager:close(dialog)
          if value and value ~= "" then
            self.settings:setCookie(value)
            show_notification(_("Cookies saved"))
          end
        end,
      },
    } },
  }
  UIManager:show(dialog)
  dialog:onShowKeyboard()
end

function LivelibMenu:getSubMenuItems()
  local has_book = self.ui and self.ui.document ~= nil
  local items = {}

  if has_book then
    table.insert(items, {
      text_func = function()
        if self.settings:bookLinked() then
          local title = self.settings:getLinkedTitle()
          return T(_("Book: %1"), title or self.settings:getLinkedEditionId())
        else
          return _("Link book…")
        end
      end,
      callback = function(menu_instance)
        local force_search = self.settings:bookLinked()
        self:showLinkBookDialog(force_search, function()
          menu_instance:updateItems()
        end)
      end,
      hold_callback = function(menu_instance)
        if self.settings:bookLinked() then
          local file = self.ui.document.file
          self:maybeConfirm(
            _("Unlink book from Livelib?"),
            function()
              self.settings:clearBookSettings(file)
              if self.state then
                self.state.current_status = nil
              end
              show_notification(_("Link removed"))
              menu_instance:updateItems()
            end
          )
        end
      end,
      keep_menu_open = true,
    })
  end

  if has_book then
    table.insert(items, {
      text = _("Auto-track progress"),
      checked_func = function()
        return self.settings:syncEnabled()
      end,
      enabled_func = function()
        return self.settings:bookLinked()
      end,
      callback = function()
        self.settings:setSync(not self.settings:syncEnabled())
      end,
      help_text = _("Automatically set Currently reading while reading and Finished at ~100% / Book Status."),
      keep_menu_open = true,
    })
  end

  if has_book then
    table.insert(items, {
      text = _("Change status"),
      enabled_func = function()
        return self.settings:bookLinked()
      end,
      sub_item_table_func = function()
        return self:getStatusSubMenuItems()
      end,
    })
  end

  if has_book then
    table.insert(items, {
      text_func = function()
        local rating = self.settings:getKoreaderRating()
        if rating and rating > 0 then
          return T(_("Send rating (%1★)"), tostring(rating))
        end
        return _("Send rating")
      end,
      enabled_func = function()
        return self.settings:bookLinked() and self.settings:getKoreaderRating() ~= nil
      end,
      callback = function()
        if self.plugin then
          self.plugin:_withWifi(function()
            self.plugin:syncRatingNow(true)
          end)
        end
      end,
      help_text = _("Take ★ from KOReader Book Status and send to Livelib (scale 1–5 → 0–10)."),
      keep_menu_open = true,
      separator = true,
    })
  end

  table.insert(items, {
    text = _("Settings"),
    sub_item_table_func = function()
      return self:getSettingsSubMenuItems()
    end,
  })

  table.insert(items, {
    text = _("About"),
    keep_menu_open = true,
    callback = function()
      local meta        = loadPluginMeta()
      local name        = (meta and meta.fullname) or _("Livelib")
      local version     = (meta and meta.version) or "?"
      local description = (meta and meta.description) or ""
      local github = "github.com/advokatb/livelib.koplugin"
      local info_text = name .. " v" .. version
        .. "\n\n" .. description
        .. "\n\n" .. github
      UIManager:show(InfoMessage:new {
        text = info_text,
        face = Font:getFace("cfont", 18),
        show_icon = false,
      })
    end,
  })

  return items
end

function LivelibMenu:mainMenu()
  return {
    text_func = function()
      if self.ui and self.ui.document and self.settings:bookLinked() then
        return _("Livelib ✓")
      end
      return _("Livelib")
    end,
    sub_item_table_func = function()
      return self:getSubMenuItems()
    end,
  }
end

return LivelibMenu
