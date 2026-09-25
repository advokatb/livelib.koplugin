-- livelib_api_legacy.lua
-- Legacy stable API implementation (www.livelib.ru HTML endpoints).

local _  = require("lib/livelib_i18n").gettext
local T  = require("ffi/util").template
local logger        = require("logger")
local http          = require("socket.http")
local ltn12         = require("ltn12")
local json          = require("json")
local NetworkMgr    = require("ui/network/manager")
local socketutil    = require("socketutil")

local LivelibParser = require("livelib_parser")

local BASE_URL = "https://www.livelib.ru"

local LivelibApiLegacy = {
  settings = nil,  -- injected by facade
  on_error = nil,  -- injected by facade
}

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function urlencode(str)
  if not str then return "" end
  str = tostring(str)
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return str
end

local function encode_form(data)
  local parts = {}
  for k, v in pairs(data) do
    table.insert(parts, urlencode(tostring(k)) .. "=" .. urlencode(tostring(v)))
  end
  return table.concat(parts, "&")
end

local function make_headers(self, extra)
  local cookie = self.settings and self.settings:getCookie() or ""
  local headers = {
    ["User-Agent"]       = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    ["Accept"]           = "application/json, text/javascript, */*; q=0.01",
    ["Accept-Language"]  = "ru-RU,ru;q=0.9,en;q=0.8",
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Origin"]           = BASE_URL,
    ["Referer"]          = BASE_URL .. "/",
    ["Cookie"]           = cookie,
  }
  if extra then
    for k, v in pairs(extra) do headers[k] = v end
  end
  return headers
end

local function report_error(self, err)
  logger.warn("LiveLib API Legacy error:", err)
  if self.on_error then self.on_error(err) end
end

function LivelibApiLegacy:_request(method, url, body, extra_headers, extra_req)
  if not NetworkMgr:isConnected() then return nil, nil, nil end

  local sink = {}
  socketutil:set_timeout(15, 30)

  local headers = make_headers(self, extra_headers)
  if method == "POST" and body then
    if not headers["Content-Type"] then
      headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
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
  if extra_req then
    for k, v in pairs(extra_req) do
      request_params[k] = v
    end
  end

  logger.info("LiveLib Legacy: " .. method .. " " .. url)
  local _, code, resp_headers, _ = http.request(request_params)
  socketutil:reset_timeout()

  local response_body = table.concat(sink)
  local code_num = tonumber(code)

  if resp_headers and resp_headers["set-cookie"] and self.settings then
    self:_update_cookies_from_response(resp_headers["set-cookie"])
  end

  return code_num, response_body, resp_headers
end

function LivelibApiLegacy:_update_cookies_from_response(set_cookie_header)
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

function LivelibApiLegacy:_is_session_expired(code, body)
  if code == 401 or code == 403 then return true end
  if body and (body:find('name="login"') or body:find("/login\"") or body:find("Войти на сайт")) then
    return true
  end
  return false
end

-- ─── API interface ───────────────────────────────────────────────────────────

function LivelibApiLegacy:search(query)
  if not query or query == "" then return {} end
  local url = BASE_URL .. "/main/search"
  local body = encode_form({
    text           = query,
    object_alias   = "booksauthors",
    result_element = "search-res-block",
    width          = "956px",
    start          = "",
    limit          = "",
    is_new_design  = "ll2024",
  })

  local code, response = self:_request("POST", url, body)
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

  local ok, parsed = pcall(json.decode, response)
  if not ok or not parsed then
    report_error(self, _("Unexpected server response during search"))
    return nil
  end

  if parsed.error_code and parsed.error_code ~= 0 then
    report_error(self, parsed.text or _("Search error"))
    return nil
  end

  return LivelibParser.parse_search_results(parsed.content or "")
end

--- Set reading status.
-- @param edition_id   edition ID
-- @param status       status code (0/1/2/3/-2)
-- @param userbook_id  user book record ID (0 on first add)
-- @param rating       LiveLib rating 0–10 (half stars; 5★ KOReader → 10). nil → 0
function LivelibApiLegacy:set_status(edition_id, status, userbook_id, rating)
  if not edition_id then return {ok = false, error_text = "edition_id is nil"} end
  userbook_id = userbook_id or 0
  local rating_value = tonumber(rating) or 0
  if rating_value < 0 then rating_value = 0 end
  if rating_value > 10 then rating_value = 10 end
  rating_value = math.floor(rating_value + 0.5)

  local url = BASE_URL .. "/user/bookstatussave"
  local body = encode_form({
    edition_id     = tostring(edition_id),
    userbook_id    = tostring(userbook_id),
    strict         = "0",
    status         = tostring(status),
    rating         = tostring(rating_value),
    rand_id        = "0",
    is_new_design  = "ll2024",
    ub_read_again  = "0",
    viewmode       = "",
  })

  local code, response = self:_request("POST", url, body)
  if not code then
    local msg = _("No network connection")
    report_error(self, msg)
    return {ok = false, error_text = msg}
  end
  if self:_is_session_expired(code, response) then
    report_error(self, "session_expired")
    return {ok = false, error_text = "session_expired"}
  end
  if code ~= 200 then
    local msg = T(_("Network error: %1"), tostring(code))
    report_error(self, msg)
    return {ok = false, error_text = msg}
  end

  local ok, parsed = pcall(json.decode, response)
  if not ok or not parsed then
    if self:_is_session_expired(code, response) then
      report_error(self, "session_expired")
      return {ok = false, error_text = "session_expired"}
    end
    local msg = _("Unexpected server response")
    report_error(self, msg)
    return {ok = false, error_text = msg}
  end

  if parsed.error_code and parsed.error_code ~= 0 then
    local msg = parsed.text or _("Error updating status")
    report_error(self, msg)
    return {ok = false, error_text = msg}
  end

  return {
    ok = true,
    userbook_id = parsed.userbook_id or userbook_id,
    rating = rating_value,
    error_text = parsed.text
  }
end

function LivelibApiLegacy:remove_status(edition_id, userbook_id)
  -- In legacy API, removing status is status_code = -2
  local result = self:set_status(edition_id, -2, userbook_id, 0)
  return {ok = result.ok, error_text = result.error_text}
end

-- ─── Quotes ──────────────────────────────────────────────────────────────────
-- /quote/save/{edition_id} expects multipart/form-data. With X-Requested-With
-- (all our legacy calls) the server returns JSON 200
-- {"error_code":0,"message":"Цитата успешно добавлена","userquote_id":…}.
-- A non-AJAX form POST may still 302 to /quote/editmy/{id}.
-- quote[guid] is not validated server-side; we generate it locally.

local function random_hex32()
  local chars = "0123456789abcdef"
  local t = {}
  for i = 1, 32 do
    local idx = math.random(1, 16)
    t[i] = chars:sub(idx, idx)
  end
  return table.concat(t)
end

-- multipart/form-data body from an ordered array of {name=, value=} fields.
-- Text fields only (no file uploads) — good enough for this form.
local function encode_multipart(fields, boundary)
  local parts = {}
  for _, field in ipairs(fields) do
    table.insert(parts, "--" .. boundary .. "\r\n")
    table.insert(parts, 'Content-Disposition: form-data; name="' .. field.name .. '"\r\n\r\n')
    table.insert(parts, tostring(field.value or "") .. "\r\n")
  end
  table.insert(parts, "--" .. boundary .. "--\r\n")
  return table.concat(parts)
end

--- Publish a quote for edition_id.
-- @param edition_id  edition ID (same id used for set_status)
-- @param text        quote text (required)
-- @param opts        optional: { author, work, tags, lang_id (default "119" = Russian),
--                     access (default "0" = everyone) }
-- @return { ok, quote_id, quote_url, error_text }
function LivelibApiLegacy:create_quote(edition_id, text, opts)
  if not edition_id then return {ok = false, error_text = "edition_id is nil"} end
  if not text or text == "" then return {ok = false, error_text = _("Quote text is empty")} end
  opts = opts or {}

  local boundary = "----LivelibKOReaderBoundary" .. random_hex32()
  local body = encode_multipart({
    { name = "page_referer",             value = BASE_URL .. "/my/quotes" },
    { name = "is_new",                   value = "yes" },
    { name = "edition_id",               value = tostring(edition_id) },
    { name = "quote[author]",            value = opts.author or "" },
    { name = "quote[work]",              value = opts.work or "" },
    { name = "quote[tags]",              value = opts.tags or "" },
    { name = "quote[lang_id]",           value = opts.lang_id or "119" },
    { name = "quote[data]",              value = text },
    { name = "quote[character_id]",      value = "" },
    { name = "quote[access]",            value = opts.access or "0" },
    { name = "soc_settings[vkontakte]",  value = "0" },
    { name = "soc_settings[twitter]",    value = "0" },
    { name = "quote[guid]",              value = random_hex32() },
    { name = "submitted-status",         value = "0" },
    { name = "is_new_design",            value = "group" },
  }, boundary)

  local url = BASE_URL .. "/quote/save/" .. tostring(edition_id)
  local code, response, headers = self:_request("POST", url, body, {
    ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
    ["Referer"]       = BASE_URL .. "/quote/create/" .. tostring(edition_id),
  }, { redirect = false })

  if not code then
    local msg = _("No network connection")
    report_error(self, msg)
    return {ok = false, error_text = msg}
  end

  local location = headers and (headers["location"] or headers["Location"])
  logger.info("LiveLib quote: HTTP " .. tostring(code)
    .. " loc=" .. tostring(location))

  -- A 302 to /authentication means the session cookie is dead, not success.
  if (code == 302 or code == 303) and location
      and location:find("/authentication", 1, true) then
    report_error(self, "session_expired")
    return {ok = false, error_text = "session_expired"}
  end

  -- AJAX (X-Requested-With) gets JSON 200:
  -- {"error_code":0,"message":"Цитата успешно добавлена","userquote_id":...}
  -- A browser form POST may still 302 to /quote/editmy/{id}.
  if type(response) == "string" and response:match("^%s*{") then
    local ok_json, parsed = pcall(json.decode, response)
    if ok_json and type(parsed) == "table" then
      if parsed.error_code and tonumber(parsed.error_code) ~= 0 then
        local msg = parsed.message or parsed.text or _("Error updating status")
        report_error(self, msg)
        return {ok = false, error_text = msg}
      end
      local qid = parsed.userquote_id or parsed.quote_id
      if tonumber(parsed.error_code) == 0 or qid then
        qid = qid and tostring(qid) or nil
        return {
          ok = true,
          quote_id = qid,
          quote_url = qid and (BASE_URL .. "/quote/" .. qid) or nil,
          error_text = nil,
        }
      end
    end
  end

  if (code == 302 or code == 303) and location then
    local quote_id = location:match("/quote/editmy/(%d+)") or location:match("/quote/(%d+)")
    return {
      ok = true,
      quote_id = quote_id,
      quote_url = location,
      error_text = nil,
    }
  end

  if self:_is_session_expired(code, response) then
    report_error(self, "session_expired")
    return {ok = false, error_text = "session_expired"}
  end

  local html_id = type(response) == "string"
    and (response:match("/quote/editmy/(%d+)") or response:match("/quote/(%d+)"))
  if code == 200 and html_id then
    return {
      ok = true,
      quote_id = html_id,
      quote_url = BASE_URL .. "/quote/" .. html_id,
      error_text = nil,
    }
  end

  local msg = T(_("Network error: %1"), tostring(code))
  report_error(self, msg)
  return {ok = false, error_text = msg}
end

return LivelibApiLegacy
