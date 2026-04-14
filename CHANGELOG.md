# Changelog

All notable changes to Council will be documented in this file.

## [0.5.0] - 2026-04-14

### Added
- Westminster Shorter Catechism added to database
- 19 key questions covering Reformed theology
- Source ID 32, Reformed tradition

## [0.4.0] - 2026-04-14

### Added
- Catechism of the Catholic Church added to database
- 13 key paragraphs covering core theology (Creed, Trinity, Creation, Incarnation, Christ's Passion, Resurrection, Holy Spirit, Church, Sacraments, Baptism, Eucharist, Human Dignity, Prayer)
- Source ID 31, Catholic tradition

## [0.3.0] - 2026-04-14

### Added
- Lumen Gentium (Vatican II document) added to database
- 3 chapters: Mystery of the Church, People of God, Hierarchical Structure
- Source ID 30, Catholic tradition

## [0.2.0] - 2026-04-14

### Added
- Real-time streaming responses in ChatScreen
- TODO.md for project tracking
- CHANGELOG.md for version history

### Changed
- ChatScreen now uses `generateStream()` for live response display
- Removed non-streaming `generateWithContext()` from ChatScreen flow

## [0.1.0] - 2026-04-13

### Added
- Initial Flutter app structure
- 5 screens: home, browse, search, chat, content detail
- Database service with SQLite + FTS5 full-text search
- Ollama service with generate, streaming, and RAG support
- RAG pipeline combining FTS5 + tag-based search
- 29 theological sources in database
- 341 content units (including Thirty-Nine Articles)
- 1,494 tag associations
- GitHub repository: https://github.com/SpencerSmithSite/Council

---

*Format based on [Keep a Changelog](https://keepachangelog.com/)*