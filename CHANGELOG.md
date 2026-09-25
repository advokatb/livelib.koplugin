# Changelog

## [0.6.0] - 2026-09-24

### Added
- Send a highlight to Livelib as a quote: **Send to Livelib** in the highlight dialog (linked books only). Uses the classic `/quote/save/{edition_id}` multipart endpoint (even if Beta API is on).

## [0.5.0] - 2026-09-24

### Added
- Autolink by Calibre/OPF identifiers `livelib` (`{id}-{slug}`) and `livelib-edition` (`{id}`): on open and from **Link book…** (on by default, same UX as Goodreads).
- Setting **Autolink by LIVELIB identifier**.

### Fixed
- Search results no longer crash on first paint: cover placeholders used an empty `CenterContainer` (`paintTo` on nil).

## [0.4.0] - 2026-09-19

### Added
- Search results show covers in a left slot; they load in the background after the list is shown (Hardcover-style, via Trapper subprocess so the UI stays usable).
- Author names in search results are **bold**.

### Changed
- Search results keep KOReader `Menu` chrome (title bar, back, paging, search icon) with custom rows for covers and author styling.
- Search results are a centered dialog (not fullscreen), with table-style separator lines between rows.

### Fixed
- Auto-track sets **Currently reading** as soon as the book is linked (and on the first pages). It no longer waits for 1% progress. Opening an unlinked book no longer burns the 2s ensure before search/link finishes.

## [0.3.4] - 2026-08-25

### Fixed
- Auto-track sets **Currently reading** as soon as the book is linked (and on the first pages). It no longer waits for 1% progress.
  Opening an unlinked book no longer burns the 2s ensure before search/link finishes.

## [0.3.3] - 2026-08-25

First public release: sync reading status and ratings with livelib.ru
(classic site or Beta API), auto-tracking, English / Russian / Ukrainian UI.

### Fixed
- Stale collection id after the book is removed on the website (beta `PATCH`/`DELETE` 404 → recreate or treat delete as success).
- Sidecar rating stores the value accepted by the server; a failed rating PATCH can be retried.
- Opening a book no longer double-sends «Currently reading».

### Removed
- Unused Livelib username setting (never used to build profile links).

## [0.3.2] - 2026-08-25

### Fixed
- Sidecar rating now stores the value accepted by the server (`result.rating`). If the status update succeeds but the rating PATCH fails, local state stays at `0` so the next sync can retry.
- Opening a book no longer sends «Currently reading» twice: a successful auto-track request cancels the pending open-book ensure.

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
- Search on beta lists **art_editions** only (skips works/authors).

## [0.2.0] - 2026-08-23

### Added
- Sync KOReader Book Status rating (1–5★) to LiveLib (`rating` 0–10 on `bookstatussave`).
- Auto-tracking: **Currently reading** while reading, **Finished** at ~100% / Book Status / end of book.
- Settings: auto-tracking for new books, sync rating, Wi-Fi on demand, per-book sync toggle.
- Dispatcher actions: enable/disable auto-tracking, send rating.

## [0.1.0] - 2026-08-23

### Added
- Initial MVP: book search/link, reading status sync, session cookies, DDoS-Guard cookie rotation.
- Legacy API facade with beta API stub.
