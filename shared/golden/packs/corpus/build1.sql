-- Build 1: the upstream corpus the app's bundled core was cut from.
--
-- Hand-maintained input to tools/build_pack_goldens.py, applied on top of
-- schema.sql. Everything here is synthetic fixture text — no real author,
-- work or quotation — kept tiny so every row can be read in a diff.
--
-- Sources 1-2 stay in the bundled core. Source 3 (author "Golden Author
-- Alpha") goes to fragment f-alpha and source 4 ("Golden Author Beta") to
-- f-beta; build_packs.assign_sources decides that from the author name, as it
-- does for the real corpus.
--
-- Ids follow the real corpus's conventions: units are numbered in one
-- contiguous run per source, and a chunk id is its unit id * 1000 + sequence.

INSERT INTO branches VALUES (1, 'shared', 'The Undivided Church', 'Fixture branch.', NULL, 1);
INSERT INTO branches VALUES (2, 'protestant', 'Protestant', 'Fixture branch.', 1517, 6);

-- id, name, slug, description, created_at, branch_id, parent_id, full_name, sort_order
INSERT INTO traditions VALUES (1, 'Universal', 'universal', 'Fixture tradition held in common.', '2026-01-01 00:00:00', 1, NULL, NULL, 1);
INSERT INTO traditions VALUES (2, 'Reformed', 'reformed', 'Fixture description as first published.', '2026-01-01 00:00:00', 2, NULL, 'Reformed and Presbyterian', 2);

INSERT INTO source_types VALUES (1, 'Creed', 'creed', 'Fixture source type.');
INSERT INTO source_types VALUES (2, 'Treatise', 'treatise', 'Fixture source type.');

INSERT INTO tags VALUES (1, 'Trinity', 'trinity', 'doctrine', NULL);
INSERT INTO tags VALUES (2, 'Grace', 'grace', 'doctrine', 'Fixture tag.');

INSERT INTO authors VALUES (1, 'Golden Author Alpha', 'golden-author-alpha', 300, 380, 1, 'Synthetic author for the pack golden fixtures.', '2026-01-01 00:00:00');

INSERT INTO works VALUES (1, 1, 'Golden Work', 'golden-work', 'c. 350', 'la', NULL, 1, NULL, '2026-01-01 00:00:00');

-- id, source_type_id, tradition_id, title, slug, author, date_composed,
-- date_composed_approx, language_original, language_source, source_url,
-- license, public_domain, notes, created_at
INSERT INTO sources VALUES (1, 1, 1, 'Golden Core Creed', 'golden-core-creed', NULL, '325', 0, 'grc', 'en', 'https://example.invalid/core-creed', 'public domain', 1, 'Fixture: bundled core.', '2026-01-01 00:00:00');
INSERT INTO sources VALUES (2, 1, 2, 'Golden Core Confession', 'golden-core-confession', NULL, '1646', 0, 'en', 'en', NULL, 'public domain', 1, 'Fixture: bundled core.', '2026-01-01 00:00:00');
INSERT INTO sources VALUES (3, 2, 1, 'Golden Alpha Treatise', 'golden-alpha-treatise', 'Golden Author Alpha', 'c. 350', 1, 'la', 'en', 'https://example.invalid/alpha', 'public domain', 1, 'Fixture: fragment f-alpha.', '2026-01-01 00:00:00');
INSERT INTO sources VALUES (4, 2, 2, 'Golden Beta Sermons', 'golden-beta-sermons', 'Golden Author Beta', '1650', 0, 'en', 'en', NULL, 'public domain', 1, 'Fixture: fragment f-beta.', '2026-01-01 00:00:00');

-- id, source_id, unit_type, unit_number, title, content, parent_id, sequence,
-- created_at, provenance
INSERT INTO content_units VALUES (101, 1, 'article', 1, 'Article 1', 'Core creed text: one God in Trinity, maker of all things.', NULL, 1, '2026-01-01 00:00:00', 'primary_text');
INSERT INTO content_units VALUES (102, 1, 'article', 2, 'Article 2', 'Core creed text: the Son, begotten not made.', NULL, 2, '2026-01-01 00:00:00', 'primary_text');
INSERT INTO content_units VALUES (201, 2, 'chapter', 1, 'Chapter 1', 'Core confession text: of the holy Scripture.', NULL, 1, '2026-01-01 00:00:00', 'primary_text');
-- No title: the FTS index then holds nothing in the title column for this row.
INSERT INTO content_units VALUES (202, 2, 'chapter', 2, NULL, 'Core confession text: of grace and assurance.', NULL, 2, '2026-01-01 00:00:00', 'unknown');
INSERT INTO content_units VALUES (301, 3, 'book', 1, 'Book 1', 'Alpha treatise text: grace precedes every good will.', NULL, 1, '2026-01-01 00:00:00', 'primary_text');
INSERT INTO content_units VALUES (302, 3, 'chapter', 1, 'Book 1, Chapter 1', 'Alpha treatise text: the Trinity is one in essence. Alphaword marker.', 301, 2, '2026-01-01 00:00:00', 'primary_text');
INSERT INTO content_units VALUES (401, 4, 'sermon', 1, 'Sermon 1', 'Beta sermon text: grace and the covenant. Betaword marker.', NULL, 1, '2026-01-01 00:00:00', 'primary_text');
INSERT INTO content_units VALUES (402, 4, 'sermon', 2, 'Sermon 2', 'Beta sermon text: the sacraments as signs and seals.', NULL, 2, '2026-01-01 00:00:00', 'primary_text');

INSERT INTO content_tags VALUES (101, 1);
INSERT INTO content_tags VALUES (102, 1);
INSERT INTO content_tags VALUES (202, 2);
INSERT INTO content_tags VALUES (301, 2);
INSERT INTO content_tags VALUES (302, 1);
INSERT INTO content_tags VALUES (302, 2);
INSERT INTO content_tags VALUES (401, 2);

-- Unit 302 is split into two overlapping chunks; every other unit is one chunk.
INSERT INTO content_chunks VALUES (302001, 302, 1, 0, 40);
INSERT INTO content_chunks VALUES (302002, 302, 2, 30, 69);
INSERT INTO content_chunks
  SELECT id * 1000 + 1, id, 1, 0, length(content) FROM content_units
  WHERE id NOT IN (SELECT content_unit_id FROM content_chunks);

-- A 384-byte vector per chunk (the real model's width), made of the chunk id
-- as four big-endian bytes repeated 96 times. Any vector that lands on the
-- wrong chunk is visible at a glance in a hex dump.
INSERT INTO chunk_embeddings
  SELECT id, unhex(replace(printf('%96s', ''), ' ', printf('%08X', id)))
  FROM content_chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_embeddings);

INSERT INTO content_fts(content_fts) VALUES('rebuild');
