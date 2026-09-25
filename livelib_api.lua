-- livelib_api.lua
-- API facade for Livelib. Routes calls to legacy or beta backend.

local _ = require("lib/livelib_i18n").gettext

local LivelibApiLegacy = require("livelib_api_legacy")
local LivelibApiBeta   = require("livelib_api_beta")

-- LiveLib status codes for UI (legacy numeric codes until beta mapping exists)
local STATUS_KEYS = {
  [0]  = "Want to read",
  [1]  = "Finished",
  [2]  = "Currently reading",
  [3]  = "Did not finish",
  [-2] = "Status removed",
}

local LivelibApi = {
  settings = nil,
  on_error = nil,
}

--- Human-readable label for a status code.
function LivelibApi:statusText(status_code)
  local key = STATUS_KEYS[status_code]
  return key and _(key) or _("Unknown status")
end

-- xgettext markers: STATUS_KEYS are translated via _(key) at runtime; list every
-- label here so scripts/update-pot.sh includes them in locale/livelib.pot.
if false then
  local _ignore = {
    _("Want to read"),
    _("Finished"),
    _("Currently reading"),
    _("Did not finish"),
    _("Status removed"),
  }
end

function LivelibApi:_get_backend()
  local backend_name = self.settings and self.settings:getBackend() or "legacy"
  local backend = backend_name == "beta" and LivelibApiBeta or LivelibApiLegacy

  backend.settings = self.settings
  backend.on_error = self.on_error

  return backend
end

function LivelibApi:search(query)
  return self:_get_backend():search(query)
end

function LivelibApi:set_status(edition_id, status, userbook_id, rating)
  return self:_get_backend():set_status(edition_id, status, userbook_id, rating)
end

--- KOReader rating (1–5★) → LiveLib (0–10, half-star steps).
function LivelibApi.koreaderToLivelibRating(koreader_rating)
  local n = tonumber(koreader_rating)
  if not n or n <= 0 then return 0 end
  if n > 5 then n = 5 end
  return math.floor(n * 2 + 0.5)
end

function LivelibApi:remove_status(edition_id, userbook_id)
  return self:_get_backend():remove_status(edition_id, userbook_id)
end

--- Publish a quote. Always uses the legacy backend — quote creation has only
--- been reverse-engineered against www.livelib.ru; the beta API's equivalent
--- (if any) is unconfirmed, so this ignores the user's beta/legacy toggle.
function LivelibApi:create_quote(edition_id, text, opts)
  LivelibApiLegacy.settings = self.settings
  LivelibApiLegacy.on_error = self.on_error
  return LivelibApiLegacy:create_quote(edition_id, text, opts)
end

return LivelibApi
