# Changelog

All notable changes to Council will be documented in this file.

## [1.7.0] - 2026-04-14

### Added
- Small Catechism expanded: Confession, Office of the Keys
- Lumen Gentium expanded: People of God, Hierarchical Structure continued
- Database: 34 sources, 484 content units, 1,815 tag associations

## [1.6.0] - 2026-04-14

### Added
- Confessions (Augustine) expanded: books 1-3, 7 (Infancy, Childhood, Adolescence, Philosophy)
- Great Catechism (Gregory of Nyssa) expanded: chapters 6, 7, 9 (Holy Spirit, Church, Baptism)
- Database: 34 sources, 480 content units, 1,809 tag associations

## [1.5.0] - 2026-04-14

### Added
- Heidelberg Catechism expanded: 4 questions (Christian life, law, good works, prayer)
- Belgic Confession expanded: 3 articles (Justification, Sanctification, Holy Supper)
- Database milestone: 34 sources, 473 content units, 1,800 tag associations

## [1.4.0] - 2026-04-14

### Added
- Articles of Religion (Methodist): 5 articles on Trinity, Son of God, Resurrection, Holy Ghost, Scripture
- Catechism of the Catholic Church expanded: 5 more paragraphs (Man/Woman, Incarnation, Ascension, Church, Hell)
- Database: 34 sources, 466 content units, 1,800+ tag associations

## [1.3.0] - 2026-04-14

### Added
- Against Heresies (Irenaeus): 4 books on Gnosticism, Unity of God, Incarnation, Tradition
- Dei Verbum (Vatican II): 6 chapters on Divine Revelation and Scripture
- Chalcedonian Definition expanded: historical context, four adverbs, ecumenical significance
- Database milestone: 34 sources, 456 content units, 1,765 tag associations

## [1.2.0] - 2026-04-14

### Added
- Expositions on the Psalms (Augustine): 3 expositions (Psalm 1, 23, 51)
- Ecumenical creeds expanded: Nicene, Apostles', Athanasian with historical context
- Database milestone: 34 sources, 443 content units, 1,702 tag associations

## [1.1.0] - 2026-04-14

### Added
- Augsburg Confession expanded: articles 13-18 (Vows, Church Government, Customs, Civil Government, Return of Christ, Free Will)
- Contra Celsum (Origen): 3 sections on truth, incarnation, resurrection
- Confessions (Augustine): 5 books covering infancy, conversion, memory, time, creation
- Great Catechism (Gregory of Nyssa): 3 chapters on purpose, incarnation, resurrection

### Fixed
- Westminster Shorter Catechism tradition corrected to Reformed (was Eastern Orthodox)

## [1.0.0] - 2026-04-14

### Added
- Expanded Lumen Gentium: chapters 4-8 (Laity, Holiness, Religious, Eschatology, Mary)
- Database milestone: 34 sources, 415 content units, 1,645 tag associations

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