-- livelib_search_menu.lua
-- Search results with a cover slot and a bold author line.
-- Covers load after the list is shown (Hardcover-style lazy load).

local BD              = require("ui/bidi")
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Menu            = require("ui/widget/menu")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget         = require("ui/widget/textwidget")
local UIManager          = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup      = require("ui/widget/verticalgroup")
local VerticalSpan       = require("ui/widget/verticalspan")
local CoverCache         = require("livelib_cover_cache")
local logger             = require("logger")

local Screen = Device.screen

local SearchItem = InputContainer:extend{}

function SearchItem:init()
  self.dimen = self.dimen or Geom:new{ w = 0, h = 0 }
  if Device:isTouchDevice() then
    self.ges_events.TapSelect = {
      GestureRange:new{ ges = "tap", range = self.dimen },
    }
  end
  self:update()
end

function SearchItem:update()
  if self[1] then
    self[1]:free()
    self[1] = nil
  end

  local pad = Size.padding.small
  local linesize = self.linesize or (self.menu and self.menu.linesize) or Size.line.medium
  local line_color = self.line_color or (self.menu and self.menu.line_color) or Blitbuffer.COLOR_DARK_GRAY
  local cover_h = math.max(1, self.dimen.h - Size.padding.tiny * 2 - linesize)
  local cover_w = math.max(Screen:scaleBySize(36), math.floor(cover_h * 0.68))
  local entry = self.entry or {}

  local cover_dimen = Geom:new{ w = cover_w, h = cover_h }
  local cover
  if entry.cover_path then
    local ok, widget = pcall(function()
      return ImageWidget:new{
        file = entry.cover_path,
        width = cover_w,
        height = cover_h,
        scale_factor = 0,
        alpha = true,
      }
    end)
    if ok and widget then
      cover = CenterContainer:new{
        dimen = cover_dimen:copy(),
        widget,
      }
    end
  end
  if not cover then
    -- FrameContainer must have a sized child. An empty CenterContainer
    -- crashes in paintTo (self[1]:getSize() on nil).
    cover = FrameContainer:new{
      bordersize = Size.border.thin,
      padding = 0,
      margin = 0,
      background = Blitbuffer.COLOR_LIGHT_GRAY,
      HorizontalGroup:new{
        HorizontalSpan:new{
          width = math.max(1, cover_w - Size.border.thin * 2),
        },
        VerticalSpan:new{
          width = math.max(1, cover_h - Size.border.thin * 2),
        },
      },
    }
  end

  local text_w = math.max(Screen:scaleBySize(40),
    self.dimen.w - cover_w - pad * 3 - Size.padding.default)
  local title_h = math.floor(self.dimen.h * 0.42)
  local author_h = math.floor(self.dimen.h * 0.32)

  local lines = VerticalGroup:new{ align = "left" }
  table.insert(lines, TextBoxWidget:new{
    text = BD.auto(entry.title or entry.text or ""),
    face = Font:getFace("cfont", 20),
    width = text_w,
    height = title_h,
    height_adjust = true,
    height_overflow_show_ellipsis = true,
    alignment = "left",
    bold = false,
  })
  if entry.authors and entry.authors ~= "" then
    table.insert(lines, TextBoxWidget:new{
      text = BD.auto(entry.authors),
      face = Font:getFace("cfont", 18),
      width = text_w,
      height = author_h,
      height_adjust = true,
      height_overflow_show_ellipsis = true,
      alignment = "left",
      bold = true,
    })
  end
  if entry.rating and entry.rating ~= "" and entry.rating ~= "0" then
    table.insert(lines, TextWidget:new{
      text = "★ " .. entry.rating,
      face = Font:getFace("cfont", 16),
    })
  end

  -- Same row chrome as KOReader MenuItem: content + a table underline.
  self._underline_container = UnderlineContainer:new{
    color = line_color,
    linesize = linesize,
    vertical_align = "center",
    padding = 0,
    dimen = Geom:new{
      x = 0, y = 0,
      w = self.dimen.w,
      h = self.dimen.h,
    },
    FrameContainer:new{
      padding = pad,
      padding_left = Size.padding.default,
      padding_right = Size.padding.default,
      bordersize = 0,
      HorizontalGroup:new{
        align = "center",
        cover,
        HorizontalSpan:new{ width = pad },
        lines,
      },
    },
  }
  self[1] = FrameContainer:new{
    bordersize = 0,
    padding = 0,
    self._underline_container,
  }
  self[1].dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function SearchItem:onTapSelect()
  if self.menu then
    self.menu:onMenuSelect(self.entry)
  end
  return true
end

local SearchMenu = Menu:extend{}

function SearchMenu:init()
  -- Inset dialog, not edge-to-edge. Hardcover search uses the same ~50px margin.
  if not self.width then
    self.width = math.min(Screen:getWidth() - Screen:scaleBySize(50), Screen:scaleBySize(600))
  end
  if not self.height then
    self.height = Screen:getHeight() - Screen:scaleBySize(50)
  end
  if self.is_popout == nil then
    self.is_popout = true
  end
  if self.is_borderless == nil then
    self.is_borderless = false
  end
  Menu.init(self)
end

function SearchMenu:onClose()
  self:_haltCoverLoads()
  UIManager:close(self._host or self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

function SearchMenu:updateItems(select_number, no_recalculate_dimen)
  self:_haltCoverLoads()

  local old_dimen = self.dimen and self.dimen:copy()
  self.layout = {}
  self.item_group:clear()
  self.page_info:resetLayout()
  self.return_button:resetLayout()
  self.content_group:resetLayout()
  self:_recalculateDimen(no_recalculate_dimen)

  for idx = 1, self.perpage do
    local index = (self.page - 1) * self.perpage + idx
    local item = self.item_table[index]
    if item == nil then break end
    item.idx = index
    if index == self.itemnumber then
      select_number = idx
    end
    local row = SearchItem:new{
      dimen = self.item_dimen:copy(),
      entry = item,
      menu = self,
      linesize = self.linesize,
      line_color = self.line_color,
      show_parent = self.show_parent,
    }
    table.insert(self.item_group, row)
    table.insert(self.layout, { row })
    if self.item_group.dimen then
      if not row.dimen then
        row.dimen = self.item_dimen:copy()
      end
      row.dimen.h = self.item_dimen.h
    end
  end

  self:updatePageInfo(select_number)
  if self.mergeTitleBarIntoLayout then
    self:mergeTitleBarIntoLayout()
  end
  UIManager:setDirty(self.show_parent, function()
    local refresh_dimen =
      old_dimen and old_dimen:combine(self.dimen)
      or self.dimen
    return "ui", refresh_dimen
  end)

  self:_scheduleCoverLoads()
end

function SearchMenu:_haltCoverLoads()
  self._covers_halted = true
  self._cover_gen = (self._cover_gen or 0) + 1
  if self._cover_job then
    UIManager:unschedule(self._cover_job)
    self._cover_job = nil
  end
end

function SearchMenu:_scheduleCoverLoads()
  local batch = {}
  for i = 1, #self.item_group do
    local row = self.item_group[i]
    local entry = row and row.entry
    if entry and entry.cover_url and not entry.cover_path then
      local cached = CoverCache.cached_path(entry.edition_id)
      if cached then
        entry.cover_path = cached
        row:update()
      else
        table.insert(batch, row)
      end
    end
  end
  if #batch == 0 then return end

  self._covers_halted = false
  local menu = self
  local gen = self._cover_gen
  local job
  job = function()
    menu._cover_job = nil
    if menu._covers_halted or menu._cover_gen ~= gen then return end
    local ok_trap, Trapper = pcall(require, "ui/trapper")
    if not ok_trap or not Trapper then
      logger.warn("LiveLib search: Trapper unavailable, skipping covers")
      return
    end
    Trapper:wrap(function()
      for _, row in ipairs(batch) do
        if menu._covers_halted or menu._cover_gen ~= gen then return end
        local entry = row.entry
        if entry and not entry.cover_path and entry.cover_url then
          local url = entry.cover_url
          local edition_id = entry.edition_id
          local completed, ok, body = Trapper:dismissableRunInSubprocess(function()
            return CoverCache.download(url)
          end)
          if not completed then
            return
          end
          if menu._covers_halted or menu._cover_gen ~= gen then return end
          if ok and type(body) == "string" then
            local path = CoverCache.save(edition_id, body)
            if path then
              entry.cover_path = path
              row:update()
              UIManager:setDirty(menu.show_parent, function()
                return "ui", row.dimen
              end)
            end
          end
        end
      end
    end)
  end
  self._cover_job = job
  -- Let the list paint first, then fill covers in (Hardcover waits ~1s).
  UIManager:scheduleIn(0.4, job)
end

function SearchMenu:onCloseWidget()
  self:_haltCoverLoads()
  return Menu.onCloseWidget(self)
end

return SearchMenu
