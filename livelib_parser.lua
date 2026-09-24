-- livelib_parser.lua
-- Parse HTML fragments from livelib.ru API responses.
--
-- LiveLib returns HTML inside the JSON "content" field.
-- Markup based on DevTools reconnaissance:
--
-- /main/search → <li class="book-card book-card_state_row-full" id="quicksearchrow-N">
-- Per card:
--   edition_id  — data-edition_id on .ll-btnbuy-bind OR numeric prefix of /book/{id}-{slug}
--   book_id     — href /book/{book_id}/editions ("N editions")
--   title       — .book-card__book-title-link text
--   authors     — all .book-card__book-author-link text
--   cover_url   — .book-card__book-cover-image src
--   rating      — .book-card__book-rating text

local logger = require("logger")

local LivelibParser = {}

local function decode_entities(s)
  if not s then return "" end
  return s
    :gsub("&amp;",  "&")
    :gsub("&lt;",   "<")
    :gsub("&gt;",   ">")
    :gsub("&quot;", '"')
    :gsub("&#39;",  "'")
    :gsub("&apos;", "'")
    :gsub("&nbsp;", " ")
    :gsub("&#(%d+);", function(n)
      local code = tonumber(n)
      if code and code < 128 then
        return string.char(code)
      end
      return ""
    end)
end

local function strip_tags(s)
  if not s then return "" end
  return s:gsub("<[^>]+>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

local function get_attr(tag_str, attr)
  local v = tag_str:match(attr .. '="([^"]*)"')
  if not v then
    v = tag_str:match(attr .. "='([^']*)'")
  end
  return v and decode_entities(v) or nil
end

local function find_class_content(html, class_name)
  local tag_start, tag_end = html:find('<[^>]+class="[^"]*' .. class_name:gsub("%-", "%%-") .. '[^"]*"[^>]*>')
  if not tag_start then
    tag_start, tag_end = html:find("<[^>]+class='[^']*" .. class_name:gsub("%-", "%%-") .. "[^']*'[^>]*>")
  end
  if not tag_start then return nil end

  local after = html:sub(tag_end + 1)
  local content = after:match("^([^<]*)")
  return content and content:match("^%s*(.-)%s*$") or ""
end

local function find_all_class_content(html, class_name)
  local results = {}
  local pattern = '<[^>]+class="[^"]*' .. class_name:gsub("%-", "%%-") .. '[^"]*"[^>]*>([^<]*)'
  for content in html:gmatch(pattern) do
    local trimmed = decode_entities(content):match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(results, trimmed)
    end
  end
  if #results == 0 then
    pattern = "<[^>]+class='[^']*" .. class_name:gsub("%-", "%%-") .. "[^']*'[^>]*>([^<]*)"
    for content in html:gmatch(pattern) do
      local trimmed = decode_entities(content):match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        table.insert(results, trimmed)
      end
    end
  end
  return results
end

--- Parse HTML from the "content" field of /main/search response.
--
-- @param html  HTML fragment string
-- @return      array of { edition_id, book_id, title, authors, cover_url, rating, livelib_url }
function LivelibParser.parse_search_results(html)
  if not html or html == "" then
    return {}
  end

  local results = {}
  local seen = {}

  for card_html in html:gmatch('<li[^>]+id="quicksearchrow%-[^"]*"[^>]*>(.-)</li>') do

    local edition_id = card_html:match('data%-edition_id="(%d+)"')

    if not edition_id then
      edition_id = card_html:match('/book/(%d+)[%-%_]')
    end

    if not edition_id or edition_id == "" then
      logger.dbg("LiveLib parser: skipping card without edition_id")
      goto continue
    end

    if seen[edition_id] then
      goto continue
    end
    seen[edition_id] = true

    local book_id = card_html:match('/book/(%d+)/editions')
    if not book_id then
      book_id = edition_id
    end

    local title = ""
    do
      local title_tag = card_html:match('<a[^>]+class="[^"]*book%-card__book%-title%-link[^"]*"[^>]*>(.-)</a>')
      if title_tag then
        title = strip_tags(decode_entities(title_tag))
      end
      if title == "" then
        title_tag = card_html:match('<a[^>]+href="/book/[^"]*"[^>]*>(.-)</a>')
        if title_tag then
          title = strip_tags(decode_entities(title_tag))
        end
      end
    end

    if title == "" then
      logger.dbg("LiveLib parser: skipping card without title, edition_id=" .. edition_id)
      goto continue
    end

    local authors_list = {}
    for author_tag in card_html:gmatch('<a[^>]+class="[^"]*book%-card__book%-author%-link[^"]*"[^>]*>(.-)</a>') do
      local author = strip_tags(decode_entities(author_tag))
      if author ~= "" then
        table.insert(authors_list, author)
      end
    end
    local authors = table.concat(authors_list, ", ")

    local cover_url = nil
    do
      local img_tag = card_html:match('<img[^>]+class="[^"]*book%-card__book%-cover%-image[^"]*"[^>]*>')
      if img_tag then
        -- Lazy-load: real image is usually data-src; src may be a 1×1 placeholder
        cover_url = get_attr(img_tag, "data%-src") or get_attr(img_tag, "src")
      end
    end

    local rating = ""
    do
      local rating_content = find_class_content(card_html, "book%-card__book%-rating")
      if rating_content then
        rating = decode_entities(rating_content):match("^%s*(.-)%s*$")
      end
    end

    local livelib_url = nil
    do
      local slug = card_html:match('href="(/book/%d+[^"]*)"')
      if slug then
        livelib_url = "https://www.livelib.ru" .. slug
      end
    end

    table.insert(results, {
      edition_id  = edition_id,
      book_id     = book_id,
      title       = title,
      authors     = authors,
      cover_url   = cover_url,
      rating      = rating,
      livelib_url = livelib_url,
      contributions = { { author = { name = authors } } },
      cached_image  = cover_url and { url = cover_url } or nil,
      book_series   = {},
    })

    ::continue::
  end

  logger.info("LiveLib parser: found " .. #results .. " books in search results")
  return results
end

return LivelibParser
