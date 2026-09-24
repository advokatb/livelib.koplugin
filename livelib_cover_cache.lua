-- livelib_cover_cache.lua
-- Downloads and caches livelib.ru cover thumbnails to local files.
-- Never call fetch() on the UI thread before showing a widget — it blocks.

local DataStorage = require("datastorage")
local http        = require("socket.http")
local ltn12       = require("ltn12")
local logger      = require("logger")
local lfs         = require("libs/libkoreader-lfs")
local socketutil  = require("socketutil")

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/livelib_covers"
local MIN_BYTES = 200

local LivelibCoverCache = {}

local function ensure_cache_dir()
  if not lfs.attributes(CACHE_DIR, "mode") then
    lfs.mkdir(DataStorage:getDataDir() .. "/cache")
    lfs.mkdir(CACHE_DIR)
  end
end

local function cache_path(edition_id)
  return CACHE_DIR .. "/" .. tostring(edition_id) .. ".jpg"
end

--- Make protocol-relative / site-relative URLs requestable.
local function normalize_url(url)
  if not url or url == "" then return nil end
  url = url:match("^%s*(.-)%s*$")
  if url == "" or url:match("^data:") then return nil end
  if url:sub(1, 2) == "//" then
    return "https:" .. url
  end
  if url:sub(1, 1) == "/" then
    return "https://www.livelib.ru" .. url
  end
  return url
end

--- Local file if already downloaded. Does not hit the network.
function LivelibCoverCache.cached_path(edition_id)
  if not edition_id then return nil end
  ensure_cache_dir()
  local path = cache_path(edition_id)
  local attr = lfs.attributes(path)
  if attr and attr.mode == "file" and (attr.size or 0) >= MIN_BYTES then
    return path
  end
  return nil
end

--- Disk-only alias so callers never accidentally block on download.
function LivelibCoverCache.get(edition_id, _cover_url)
  return LivelibCoverCache.cached_path(edition_id)
end

--- HTTP GET cover bytes. Safe to call from a Trapper subprocess.
-- Returns true, body  or  false, err  (Hardcover ImageLoader style).
function LivelibCoverCache.download(url)
  local cover_url = normalize_url(url)
  if not cover_url then
    return false, "no url"
  end

  local sink = {}
  local sink_fn = ltn12.sink.table(sink)
  if socketutil.table_sink then
    sink_fn = socketutil.table_sink(sink)
  end

  logger.info("LiveLib cover cache: GET " .. cover_url)
  socketutil:set_timeout(5, 8)
  local pok, ok, code = pcall(http.request, {
    url     = cover_url,
    method  = "GET",
    headers = {
      ["User-Agent"] = "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36",
      ["Accept"]     = "image/jpeg,image/png,image/webp,image/*,*/*;q=0.8",
      ["Referer"]    = "https://www.livelib.ru/",
    },
    sink    = sink_fn,
  })
  socketutil:reset_timeout()

  if not pok then
    logger.warn("LiveLib cover cache: request error: " .. tostring(ok))
    return false, tostring(ok)
  end
  if not ok or tonumber(code) ~= 200 then
    logger.warn("LiveLib cover cache: download failed for " .. cover_url
      .. " code=" .. tostring(code))
    return false, tostring(code)
  end

  local body = table.concat(sink)
  if #body < MIN_BYTES then
    logger.warn("LiveLib cover cache: tiny body (" .. tostring(#body) .. " B) for " .. cover_url)
    return false, "tiny body"
  end
  return true, body
end

--- Write downloaded bytes to the cover cache. Call on the UI thread.
function LivelibCoverCache.save(edition_id, body)
  if not edition_id or type(body) ~= "string" or #body < MIN_BYTES then
    return nil
  end
  ensure_cache_dir()
  local path = cache_path(edition_id)
  local file = io.open(path .. ".tmp", "wb")
  if not file then
    logger.warn("LiveLib cover cache: cannot write " .. path)
    return nil
  end
  file:write(body)
  file:close()
  os.rename(path .. ".tmp", path)
  return path
end

--- Download cover to cache. May block up to ~8s — prefer Trapper subprocess.
-- @return local path or nil
function LivelibCoverCache.fetch(edition_id, cover_url)
  local existing = LivelibCoverCache.cached_path(edition_id)
  if existing then return existing end
  local ok, body = LivelibCoverCache.download(cover_url)
  if not ok then return nil end
  return LivelibCoverCache.save(edition_id, body)
end

--- Delete cached covers older than max_age_days.
function LivelibCoverCache.prune(max_age_days)
  max_age_days = max_age_days or 30
  ensure_cache_dir()
  local now = os.time()
  for name in lfs.dir(CACHE_DIR) do
    if name ~= "." and name ~= ".." then
      local full = CACHE_DIR .. "/" .. name
      local attr = lfs.attributes(full)
      if attr and attr.modification and (now - attr.modification) > max_age_days * 86400 then
        os.remove(full)
      end
    end
  end
end

return LivelibCoverCache
