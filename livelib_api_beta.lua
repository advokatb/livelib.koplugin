-- livelib_api_beta.lua
-- Beta REST/JSON API (beta.api.livelib.ru/trisolaris/api/).
--
-- Spec from DevTools + live probe (2026-08-23):
--   GET  /search?query=&limit=20          → 200 JSON payload.data[]
--   POST /users/me/collections            → 201 { user_collection_art_id }
--   PATCH /users/me/collections/{id}      → 204 empty
--   PATCH /users/me/collections/{id}/rating → 204 empty
--   DELETE /users/me/collections/{id}     → 204 empty
--
-- art_status: wants | readings | reads | unreads
-- Search: use type=="art_editions" only (editions); skip art_works / authors.

local _  = require("lib/livelib_i18n").gettext
local T  = require("ffi/util").template
local logger     = require("logger")
local http       = require("socket.http")
local ltn12      = require("ltn12")
local json       = require("json")
local NetworkMgr = require("ui/network/manager")
local socketutil = require("socketutil")

local API_BASE   = "https://beta.api.livelib.ru/trisolaris/api"
local SITE_ORIGIN = "https://beta.livelib.ru"

-- Legacy numeric status → beta art_status string
local STATUS_TO_ART = {
  [0] = "wants",
  [1] = "reads",
  [2] = "readings",
  [3] = "unreads",
}

local LivelibApiBeta = {
  settings = nil,
  on_error = nil,
}

local function urlencode(str)
  if not str then return "" end
  str = tostring(str)
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return str
end

local function report_error(self, err)
  logger.warn("LiveLib API Beta error:", err)
  if self.on_error then self.on_error(err) end
end

local function make_headers(self, extra)
  local cookie = self.settings and self.settings:getCookie() or ""
  local headers = {
    ["User-Agent"]      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    ["Accept"]          = "application/json, */*",
    ["Accept-Language"] = "ru-RU,ru;q=0.9,en;q=0.8",
    ["Origin"]          = SITE_ORIGIN,
    ["Referer"]         = SITE_ORIGIN .. "/",
    ["Cookie"]          = cookie,
  }
  if extra then
    for k, v in pairs(extra) do headers[k] = v end
  end
  return headers
end

function LivelibApiBeta:_update_cookies_from_response(set_cookie_header)
  if not set_cookie_header or not self.settings then return end
  local current_cookie = self.settings:getCookie()
  if not current_cookie or current_cookie == "" then return end

  local changed = false
  for name, value in set_cookie_header:gmatch("(%w[%w_%-]*)=([^;,\n\r]+)") do
    if name:match("^__ddg") then
      local new_cookie, n = current_cookie:gsub(name .. "=[^;]*", name .. "=" .. value)
      if n > 0 then
        current_cookie = new_cookie
        changed = true
      else
        current_cookie = current_cookie .. "; " .. name .. "=" .. value
        changed = true
      end
    end
  end

  if changed then
    self.settings:setCookie(current_cookie)
  end
end

function LivelibApiBeta:_is_session_expired(code, body)
  if code == 401 or code == 403 then return true end
  if body and (body:find('"status"%s*:%s*401') or body:find("/authentication")
      or body:find("Войти на сайт") or body:find('name="login"')) then
    return true
  end
  return false
end

--- HTTP request. Returns code_num, body, headers.
function LivelibApiBeta:_request(method, url, body, extra_headers)
  if not NetworkMgr:isConnected() then return nil, nil, nil end

  local sink = {}
  socketutil:set_timeout(15, 30)

  local headers = make_headers(self, extra_headers)
  if body then
    if not headers["Content-Type"] then
      headers["Content-Type"] = "application/json; charset=utf-8"
    end
    headers["Content-Length"] = tostring(#body)
  end

  local request_params = {
    url     = url,
    method  = method or "GET",
    headers = headers,
    sink    = ltn12.sink.table(sink),
    source  = body and ltn12.source.string(body) or nil,
  }

  logger.info("LiveLib Beta: " .. method .. " " .. url)
  local _, code, resp_headers, _ = http.request(request_params)
  socketutil:reset_timeout()

  local response_body = table.concat(sink)
  local code_num = tonumber(code)

  if resp_headers and resp_headers["set-cookie"] and self.settings then
    self:_update_cookies_from_response(resp_headers["set-cookie"])
  end

  return code_num, response_body, resp_headers
end

local function parse_envelope(body)
  if not body or body == "" then return nil end
  local ok, parsed = pcall(json.decode, body)
  if not ok or type(parsed) ~= "table" then return nil end
  return parsed
end

local function authors_to_string(authors)
  if type(authors) ~= "table" then return "" end
  local names = {}
  for _, a in ipairs(authors) do
    if type(a) == "table" and a.full_name and a.full_name ~= "" then
      table.insert(names, a.full_name)
    end
  end
  return table.concat(names, ", ")
end

--- Map beta search item → plugin book table (editions only).
local function map_edition(instance)
  if not instance or not instance.id then return nil end
  local path = instance.url or ("/book/" .. tostring(instance.id))
  local rating = ""
  if instance.stats and instance.stats.rating then
    rating = tostring(instance.stats.rating)
  end
  return {
    edition_id  = tostring(instance.id),
    book_id     = tostring(instance.id),
    title       = instance.title or "",
    authors     = authors_to_string(instance.authors),
    cover_url   = instance.cover_url,
    rating      = rating,
    livelib_url = SITE_ORIGIN .. path,
  }
end

function LivelibApiBeta:search(query)
  if not query or query == "" then return {} end

  local url = API_BASE .. "/search?query=" .. urlencode(query) .. "&limit=20"
  local code, response = self:_request("GET", url, nil)

  if not code then
    report_error(self, _("No network connection"))
    return nil
  end
  if self:_is_session_expired(code, response) then
    report_error(self, "session_expired")
    return nil
  end
  if code ~= 200 then
    report_error(self, T(_("Network error: %1"), tostring(code)))
    return nil
  end

  local parsed = parse_envelope(response)
  if not parsed then
    report_error(self, _("Unexpected server response during search"))
    return nil
  end

  if parsed.error then
    local msg = type(parsed.error) == "table" and (parsed.error.message or parsed.error.code)
      or tostring(parsed.error)
    report_error(self, msg ~= "" and msg or _("Search error"))
    return nil
  end

  local data = parsed.payload and parsed.payload.data
  if type(data) ~= "table" then
    return {}
  end

  local results = {}
  local seen = {}
  for _, item in ipairs(data) do
    if type(item) == "table" and item.type == "art_editions" then
      local book = map_edition(item.instance)
      if book and book.title ~= "" and not seen[book.edition_id] then
        seen[book.edition_id] = true
        table.insert(results, book)
      end
    end
  end

  logger.info("LiveLib Beta: search found " .. #results .. " editions")
  return results
end

local function today_read_date_json()
  local t = os.date("*t")
  return string.format('"read_date":{"day":%d,"month":%d,"year":%d}', t.day, t.month, t.year)
end

--- Set rating via dedicated endpoint (0–10). Returns ok bool.
function LivelibApiBeta:_set_rating(collection_id, rating)
  local rating_value = tonumber(rating) or 0
  if rating_value < 0 then rating_value = 0 end
  if rating_value > 10 then rating_value = 10 end
  rating_value = math.floor(rating_value + 0.5)

  local url = API_BASE .. "/users/me/collections/" .. tostring(collection_id) .. "/rating"
  local body = string.format('{"rating":%d}', rating_value)
  local code, response = self:_request("PATCH", url, body)

  if not code then
    return false, _("No network connection")
  end
  if self:_is_session_expired(code, response) then
    return false, "session_expired"
  end
  -- 204 No Content is success; also accept 200
  if code ~= 204 and code ~= 200 then
    return false, T(_("Network error: %1"), tostring(code))
  end
  return true, rating_value
end

--- Create collection (first add). Returns user_collection_art_id or nil, error.
function LivelibApiBeta:_create_collection(edition_id, art_status)
  local function post(status_value)
    local url = API_BASE .. "/users/me/collections"
    local body = string.format(
      '{"art_edition_id":%s,"art_status":"%s"}',
      tostring(edition_id),
      status_value
    )
    local code, response = self:_request("POST", url, body)

    if not code then
      return nil, _("No network connection"), nil
    end
    if self:_is_session_expired(code, response) then
      return nil, "session_expired", code
    end
    if code ~= 201 and code ~= 200 then
      local parsed = parse_envelope(response)
      local msg = parsed and parsed.error
      if type(msg) == "table" then msg = msg.message or msg.code end
      return nil, msg and tostring(msg) or T(_("Network error: %1"), tostring(code)), code
    end

    local parsed = parse_envelope(response)
    local id = parsed and parsed.payload and parsed.payload.data
      and parsed.payload.data.user_collection_art_id
    if not id then
      return nil, _("Unexpected server response"), code
    end
    return tonumber(id) or id, nil, code
  end

  local id, err, code = post(art_status)
  if id then return id, nil end

  -- Some beta builds only accept "wants" on create — add then PATCH
  if art_status ~= "wants" and code and code >= 400 and code < 500 and code ~= 401 and code ~= 403 then
    logger.info("LiveLib Beta: POST with " .. art_status
      .. " failed (" .. tostring(code) .. "); retry via wants + PATCH")
    local wants_id, wants_err = post("wants")
    if not wants_id then
      return nil, wants_err
    end
    local ok, patch_err = self:_patch_collection(wants_id, art_status)
    if not ok then
      return nil, patch_err
    end
    return wants_id, nil
  end

  return nil, err
end

local function is_missing_collection(code)
  return code == 404
end

--- Update existing collection status. Returns ok, error, http_code.
function LivelibApiBeta:_patch_collection(collection_id, art_status)
  local url = API_BASE .. "/users/me/collections/" .. tostring(collection_id)
  local body
  if art_status == "reads" then
    body = string.format(
      '{"art_status":"reads","notes":null,%s}',
      today_read_date_json()
    )
  else
    body = string.format('{"art_status":"%s","notes":null}', art_status)
  end

  local code, response = self:_request("PATCH", url, body)

  if not code then
    return false, _("No network connection"), nil
  end
  if self:_is_session_expired(code, response) then
    return false, "session_expired", code
  end
  if code ~= 204 and code ~= 200 then
    local parsed = parse_envelope(response)
    local msg = parsed and parsed.error
    if type(msg) == "table" then msg = msg.message or msg.code end
    return false, msg and tostring(msg) or T(_("Network error: %1"), tostring(code)), code
  end
  return true, nil, code
end

--- Set reading status (legacy codes 0/1/2/3). rating 0–10 applied after Finished.
function LivelibApiBeta:set_status(edition_id, status, userbook_id, rating)
  if not edition_id then return {ok = false, error_text = "edition_id is nil"} end

  local art_status = STATUS_TO_ART[tonumber(status) or status]
  if not art_status then
    return {ok = false, error_text = _("Unknown status")}
  end

  userbook_id = tonumber(userbook_id) or 0
  local collection_id = userbook_id

  if collection_id == 0 then
    local id, err = self:_create_collection(edition_id, art_status)
    if not id then
      report_error(self, err)
      return {ok = false, error_text = err}
    end
    collection_id = id
  else
    local ok, err, code = self:_patch_collection(collection_id, art_status)
    if not ok and is_missing_collection(code) then
      -- Sidecar id is stale (removed on the website) — create a new collection
      logger.info("LiveLib Beta: collection " .. tostring(collection_id)
        .. " missing (404); creating a new one")
      local id, create_err = self:_create_collection(edition_id, art_status)
      if not id then
        report_error(self, create_err)
        return {ok = false, error_text = create_err}
      end
      collection_id = id
    elseif not ok then
      report_error(self, err)
      return {ok = false, error_text = err}
    end
  end

  local rating_value = tonumber(rating) or 0
  if (tonumber(status) == 1) and rating_value > 0 then
    local ok_r, err_or_val = self:_set_rating(collection_id, rating_value)
    if not ok_r then
      report_error(self, err_or_val)
      -- Status already saved; still report partial success with collection id
      return {
        ok = true,
        userbook_id = collection_id,
        rating = 0,
        error_text = err_or_val,
      }
    end
    rating_value = err_or_val
  else
    rating_value = 0
  end

  return {
    ok = true,
    userbook_id = collection_id,
    rating = rating_value,
    error_text = nil,
  }
end

function LivelibApiBeta:remove_status(edition_id, userbook_id)
  userbook_id = tonumber(userbook_id) or 0
  if userbook_id == 0 then
    -- Nothing on server to delete
    return {ok = true, userbook_id = 0, error_text = nil}
  end

  local url = API_BASE .. "/users/me/collections/" .. tostring(userbook_id)
  local code, response = self:_request("DELETE", url, nil)

  if not code then
    local msg = _("No network connection")
    report_error(self, msg)
    return {ok = false, error_text = msg}
  end
  if self:_is_session_expired(code, response) then
    report_error(self, "session_expired")
    return {ok = false, error_text = "session_expired"}
  end
  if is_missing_collection(code) then
    -- Already gone on the server (e.g. removed on the website)
    logger.info("LiveLib Beta: collection " .. tostring(userbook_id)
      .. " already missing (404); treating delete as success")
    return {ok = true, userbook_id = 0, error_text = nil}
  end
  if code ~= 204 and code ~= 200 then
    local msg = T(_("Network error: %1"), tostring(code))
    report_error(self, msg)
    return {ok = false, error_text = msg}
  end

  return {ok = true, userbook_id = 0, error_text = nil}
end

return LivelibApiBeta
