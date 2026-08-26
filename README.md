# livelib.koplugin

![GitHub release (latest by date)](https://img.shields.io/github/v/release/advokatb/livelib.koplugin?style=for-the-badge&color=orange) ![GitHub all releases](https://img.shields.io/github/downloads/advokatb/livelib.koplugin/total?style=for-the-badge&color=yellow) ![Platform](https://img.shields.io/badge/Platform-KOReader-success?style=for-the-badge&logo=koreader)

A [KOReader](https://github.com/koreader/koreader) plugin that syncs reading status and ratings from the reader to your [livelib.ru](https://www.livelib.ru) account.

## Features

- Search for books on Livelib by title and author (from document metadata or manual query)
- Link a Livelib edition to the open book (stored in the sidecar file)
- Set status: **Want to read** / **Currently reading** / **Finished** / **Did not finish** / **Remove status**
- Sync rating from KOReader Book Status (1–5★ → Livelib scale 0–10)
- Auto-tracking: sets **Currently reading** while reading and **Finished** at ~100% / book completion (+ rating)
- Optional **Beta API** (`beta.api.livelib.ru`) — enable in **Settings → Use Beta API**
- Automatic DDoS-Guard cookie rotation (`__ddg*` on each response)

> **Note:** Livelib has no page/percent progress API. Auto-tracking updates **status** (and rating) only, not a reading progress bar on the site.

## Installation

1. Copy the `livelib.koplugin` folder to your KOReader plugins directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Android: `/sdcard/koreader/plugins/`
   - Linux: `~/.config/koreader/plugins/`

2. Copy `livelib_config.example.lua` → `livelib_config.lua`:
   ```
   cp livelib_config.example.lua livelib_config.lua
   ```

3. Get your livelib.ru session cookies:
   - Log in at [livelib.ru](https://www.livelib.ru) in a browser
   - Open DevTools (F12) → Application → Cookies → `livelib.ru`
   - Copy **all** domain cookies (~10–15) as one line: `name1=value1; name2=value2; ...`

4. Paste the cookie string into `livelib_config.lua`:
   ```lua
   return {
     session_cookie = 'LiveLibId=xxx; llsid=yyy; __ddg1_=zzz; ...',
   }
   ```

5. Restart KOReader. **Livelib** appears in the top menu.

### Alternative: enter cookies from the menu

**Menu → Livelib → Settings → Session cookies**

## Usage

### Link a book

1. Open a book in KOReader
2. **Menu → Livelib → Link book…**
3. The plugin auto-searches by metadata and shows results
4. Tap the edition you want
5. Tap **↩ New search** to search again

Hold-tap **Book: …** to unlink.

### Change status

1. **Menu → Livelib → Change status**
2. Pick a status (radio buttons)

The current status is cached in the sidecar and restored when you reopen the book.

### Rating (★)

1. Set stars in KOReader **Book Status** (long-press status icon / book widget)
2. When setting **Finished**, the rating is sent automatically (if enabled in settings)
3. Or manually: **Menu → Livelib → Send rating (N★)**

Scale: 1★ KOReader = 2 on Livelib, 5★ = 10 (half-star steps on the site).

### Auto-tracking

1. Link the book
2. Enable **Auto-track progress** in the Livelib menu (or globally: **Settings → Auto-tracking for new books**)
3. At ≥1% progress → **Currently reading**
4. At ~100%, EndOfBook, or Book Status = complete → **Finished** (+ rating)

Requests are throttled (max once per minute). **Enable Wi-Fi on demand** helps on devices that can restore Wi-Fi automatically.

### Gestures / hardware keys

In **Menu → Settings → Gestures**, you can assign:

- **Livelib: Link book**
- **Livelib: Status — Currently reading**
- **Livelib: Status — Finished**
- **Livelib: Enable / Disable auto-tracking**
- **Livelib: Send rating**

## Data storage

| Data | Location |
|------|----------|
| Session cookies, plugin settings | `<koreader_dir>/settings/livelib_settings.lua` |
| Book link (edition_id, userbook_id, status, rating, sync) | Sidecar (`*.sdr/metadata.*.lua`, key `livelib`) |
| KOReader rating / status | Sidecar `summary.rating` / `summary.status` |
| Secret cookies (manual config) | `livelib_config.lua` (gitignored) |

## Updating cookies

Livelib cookies expire periodically. The plugin auto-updates `__ddg*` (DDoS-Guard) from response headers. Main session cookies (`LiveLibId`, `llsid`) must be refreshed manually when the session expires.

**Signs of expired cookies:**
- Message: “Livelib: session expired”
- Empty search results or network errors

## Technical details

- **Auth:** browser session cookies (no official API)
- **HTTP:** `socket.http` + `ltn12`
- **JSON:** built-in `json` module
- **HTML parsing:** Lua regex (no external deps)
- **Anti-bot:** DDoS-Guard; plain HTTP with cookies works without browser emulation

## License

MIT

## Credits

Architecture inspired by:

- [storygraph.koplugin](https://github.com/burneracc0112/storygraph.koplugin) — session cookie auth
- [hardcoverapp.koplugin](https://github.com/billiam/hardcoverapp.koplugin) — menu UX and structure
