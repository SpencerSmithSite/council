# Changelog

All notable changes to Council will be documented in this file.

## [0.9.0] - 2026-04-14

### Added
- Small Catechism (Lutheran) content: 5 parts covering Commandments, Creed, Lord's Prayer, Baptism, Sacrament of the Altar

## [0.8.0] - 2026-04-14

### Added
- Heidelberg Catechism content: 10 key questions (comfort, sin, salvation, faith)
- Belgic Confession content: 7 articles (God, Trinity, Christ, justification, baptism)

## [0.7.0] - 2026-04-14

### Added
- Chalcedonian Definition added to database (Source ID 37)
- Athanasian Creed added to database
- Nicene Creed added to database
- 7 sections covering ecumenical Trinitarian theology

### Fixed
- Removed duplicate creed entries (sources 1-3 already contained Nicene, Apostles', Athanasian Creeds)

## [0.6.0] - 2026-04-14

### Added
- Augsburg Confession added to database
- 10 key articles covering Lutheran theology
- Source ID 33, Lutheran tradition

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