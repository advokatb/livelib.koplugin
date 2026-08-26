# Changelog

## [0.3.3] - 2026-08-25

First public release: sync reading status and ratings with livelib.ru
(classic site or Beta API), auto-tracking, English / Russian / Ukrainian UI.

### Fixed
- Stale collection id after the book is removed on the website (beta `PATCH`/`DELETE` 404 → recreate or treat delete as success).
- Sidecar rating stores the value accepted by the server; a failed rating PATCH can be retried.
- Opening a book no longer double-sends «Currently reading».

### Changed
- GitHub Release zip includes `livelib_config.example.lua` and `README.md`. The `docs/` folder and maintainer tooling stay out of the zip.

### Removed
- Unused Livelib username setting (never used to build profile links).
- Dead code: unused sidecar helpers, unread `last_page` state, unused `ngettext` / `getLang` exports.

## [0.3.2] - 2026-08-25

### Fixed
- Sidecar rating now stores the value accepted by the server (`result.rating`). If the status update succeeds but the rating PATCH fails, local state stays at `0` so the next sync can retry.
- Opening a book no longer sends «Currently reading» twice: a successful auto-track request cancels the pending open-book ensure.

### Removed
- Unused `LivelibParser.looks_like_valid_response`.

## [0.3.1] - 2026-08-24

### Fixed
- Beta: `DELETE`/`PATCH` **404** when sidecar `userbook_id` is stale (book removed on the website) — delete treated as success; patch recreates the collection via `POST`.
- Auto-tracking no longer skips when local status is already «Currently reading»; on book open it re-pushes status to LiveLib (so the book reappears after a website delete).
- Clearer auto-track logs; retry ensure when Wi‑Fi comes up.

## [0.3.0] - 2026-08-23

### Added
- **Beta API** (`beta.api.livelib.ru/trisolaris/api/`): search, create/update/delete collection, separate rating endpoint.
- Status mapping: wants / readings / reads / unreads; `user_collection_art_id` stored as sidecar `userbook_id`.
- Finished status sends `read_date` (today); rating via `PATCH …/collections/{id}/rating`.

### Changed
- Settings toggle renamed to **Use Beta API** (no longer “in development”).
- Search on beta lists **art_editions** only (skips works/authors).

## [0.2.0] - 2026-08-23

### Added
- Sync KOReader Book Status rating (1–5★) to LiveLib (`rating` 0–10 on `bookstatussave`).
- Auto-tracking: **Currently reading** while reading, **Finished** at ~100% / Book Status / end of book.
- Settings: auto-tracking for new books, sync rating, Wi-Fi on demand, per-book sync toggle.
- Dispatcher actions: enable/disable auto-tracking, send rating.
- Localization (`lib/livelib_i18n.lua`, `locale/ru.po`); default UI language is English.
- GitHub Actions release workflow (tag `v*` → zip + GitHub Release).

### Changed
- User-facing strings and code comments are English by default; Russian via `locale/ru.po`.
- README is English; Russian UI via `locale/ru.po`.

## [0.1.0] - 2026-08-23

### Added
- Initial MVP: book search/link, reading status sync, session cookies, DDoS-Guard cookie rotation.
- Legacy API facade with beta API stub.
