-- livelib_identifiers.lua
-- Extract a LiveLib edition id from document metadata or EPUB OPF.
--
-- Calibre (custom plugin) writes identifiers such as:
--   livelib:1008958702-glubokie-vody-patritsiya-hajsmit
--   livelib-edition:1008958702
--
-- KOReader creengine surfaces OPF identifiers via getProps().identifiers
-- as a multiline (or comma-separated) "scheme:value" string. Custom
-- opf:scheme is included (lowercased). If that field is missing (PDF/FB2,
-- or a CRE build that drops unknown schemes), fall back to reading
-- META-INF/container.xml + content.opf from the EPUB zip.

local logger = require("logger")

local SITE = "https://www.livelib.ru"

local LivelibIdentifiers = {}

local function trim(s)
  return s and s:match("^%s*(.-)%s*$") or ""
end

--- Numeric edition id, optional slug (URL tail after "id-").
local function parseLivellibValue(raw)
  if not raw or raw == "" then return nil, nil end
  raw = trim(tostring(raw))
  raw = raw:gsub("[,%s]+$", "")
  local from_url = raw:match("livelib%.ru/book/([^%s%?/]+)")
  if from_url then
    raw = from_url
  end
  local id, slug = raw:match("^(%d+)%-(.+)$")
  if id then
    slug = trim(slug):gsub("/+$", "")
    if slug == "" then slug = nil end
    return id, slug
  end
  if raw:match("^%d+$") then
    return raw, nil
  end
  return nil, nil
end

--- Parse a KOReader identifiers string or table into { scheme_lower = value }.
function LivelibIdentifiers.parse(identifiers)
  local result = {}
  if identifiers == nil then return result end

  if type(identifiers) == "table" then
    for k, v in pairs(identifiers) do
      if type(k) == "string" and v ~= nil then
        result[k:lower()] = trim(tostring(v))
      end
    end
    return result
  end

  if type(identifiers) ~= "string" or identifiers == "" then
    return result
  end

  -- Calibre may emit one line: "livelib:id-slug, livelib-edition:id"
  local normalized = identifiers:gsub(",", "\n")
  for line in normalized:gmatch("[^\r\n]+") do
    line = trim(line)
    if line ~= "" then
      local scheme, value = line:match("^([^:]+):%s*(%S+)")
      if scheme and value then
        result[scheme:lower()] = value:gsub("[,%s]+$", "")
      end
    end
  end
  return result
end

--- @return edition_id, slug_or_nil
function LivelibIdentifiers.editionFromMap(map)
  if not map then return nil, nil end

  local edition = map["livelib-edition"] or map["livelib_edition"]
    or map.livelibedition
  local edition_id = parseLivellibValue(edition)
  local slug

  local livelib = map.livelib or map.ll
  local from_ll, from_slug = parseLivellibValue(livelib)
  if from_slug then
    slug = from_slug
  end
  if not edition_id then
    edition_id = from_ll
  end
  return edition_id, slug
end

function LivelibIdentifiers.bookUrl(edition_id, slug)
  if not edition_id then return nil end
  if slug and slug ~= "" then
    return SITE .. "/book/" .. edition_id .. "-" .. slug
  end
  return SITE .. "/book/" .. edition_id
end

local function identifiersFromDocument(ui)
  if not ui then return nil end

  if ui.document and ui.document.getProps then
    local ok, props = pcall(function() return ui.document:getProps() end)
    if ok and props and props.identifiers then
      return props.identifiers
    end
  end

  if ui.doc_settings then
    local doc_props = ui.doc_settings:readSetting("doc_props")
    if doc_props and doc_props.identifiers then
      return doc_props.identifiers
    end
  end

  return nil
end

local function isEpubPath(path)
  if not path or path == "" then return false end
  local lower = path:lower()
  return lower:match("%.epub$") or lower:match("%.epub%.zip$")
end

local function findArchiveEntry(arc, wanted)
  local wanted_lower = wanted:lower():gsub("\\", "/")
  for _, entry in ipairs(arc.entries or {}) do
    if type(entry) == "table" and entry.path then
      local p = entry.path:gsub("\\", "/"):lower()
      if p == wanted_lower or p:sub(-#wanted_lower) == wanted_lower then
        return entry.path
      end
    end
  end
  return nil
end

local function readZipEntry(filepath, inner_path)
  local ok, Archiver = pcall(require, "ffi/archiver")
  if not ok or not Archiver or not Archiver.Reader then
    logger.dbg("LiveLib: ffi/archiver not available")
    return nil
  end

  local arc = Archiver.Reader:new()
  if not arc:open(filepath) then
    logger.dbg("LiveLib: failed to open EPUB zip: " .. tostring(filepath))
    return nil
  end

  for _ in arc:iterate() do end

  local key = findArchiveEntry(arc, inner_path) or inner_path
  local content = arc:extractToMemory(key)
  arc:close()
  return content
end

local function parseOpfIdentifiers(opf_xml)
  local map = {}
  if not opf_xml or opf_xml == "" then return map end

  for tag in opf_xml:gmatch("<dc:identifier[^>]*>.-</dc:identifier>") do
    local inner = tag:match(">(.-)<") or ""
    local value = trim(inner:gsub("%s+", " "):gsub("<[^>]+>", ""))
    if value ~= "" then
      local scheme = tag:match('[sS]cheme=["\']([^"\']+)["\']')
      if not scheme then
        scheme = tag:match('%sid=["\']([^"\']+)["\']')
      end
      if scheme then
        map[scheme:lower()] = value
      end
      local prefixed_scheme, prefixed_value = value:match("^([%w_%-]+):(%S+)$")
      if prefixed_scheme and prefixed_value then
        map[prefixed_scheme:lower()] = prefixed_value
      end
    end
  end
  return map
end

function LivelibIdentifiers.fromOpf(filepath)
  if not isEpubPath(filepath) then return nil end

  local container = readZipEntry(filepath, "META-INF/container.xml")
  if not container then return nil end

  local opf_path = container:match('full%-path=["\']([^"\']+)["\']')
  if not opf_path or opf_path == "" then
    logger.dbg("LiveLib: container.xml has no rootfile path")
    return nil
  end

  local opf = readZipEntry(filepath, opf_path)
  if not opf then
    logger.dbg("LiveLib: failed to read OPF " .. opf_path)
    return nil
  end

  return parseOpfIdentifiers(opf)
end

--- @return { edition_id, slug, livelib_url } or nil
function LivelibIdentifiers.getEditionInfo(ui)
  local function from_map(map, source)
    local edition_id, slug = LivelibIdentifiers.editionFromMap(map)
    if not edition_id then return nil end
    if source then
      logger.info("LiveLib: read edition_id " .. edition_id .. " from " .. source)
    end
    return {
      edition_id  = edition_id,
      slug        = slug,
      livelib_url = LivelibIdentifiers.bookUrl(edition_id, slug),
    }
  end

  local raw = identifiersFromDocument(ui)
  local info = from_map(LivelibIdentifiers.parse(raw))
  if info then return info end

  local file = ui and ui.document and ui.document.file
  if not file then return nil end

  return from_map(LivelibIdentifiers.fromOpf(file), "EPUB OPF")
end

return LivelibIdentifiers
