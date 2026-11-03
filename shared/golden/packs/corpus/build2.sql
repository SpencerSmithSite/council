-- Build 2: an append-only rebuild. The published packs (../manifest.json) are
-- cut from build1.sql + this file.
--
-- Everything build 1 already numbered keeps its id and its text, so
-- build_packs.check_id_space leaves the id space where it was and these packs
-- install into an app whose bundled core came from build 1.
--
-- Two reference-table changes ride along, to pin how the app merges them:
--   * tradition 3 and tag 3 are new, so INSERT OR IGNORE adds them;
--   * tradition 2's description is revised, and INSERT OR IGNORE keeps the
--     app's existing row — the revision never reaches an installed app.

UPDATE traditions SET description = 'Fixture description as REVISED in build 2.' WHERE id = 2;
INSERT INTO traditions VALUES (3, 'Lutheran', 'lutheran', 'Fixture tradition added in build 2.', '2026-02-01 00:00:00', 2, NULL, NULL, 3);
INSERT INTO tags VALUES (3, 'Sacraments', 'sacraments', 'doctrine', NULL);

-- Appended above build 1's high-water mark (unit 402), so it cannot collide.
INSERT INTO sources VALUES (5, 2, 3, 'Golden Beta Catechism', 'golden-beta-catechism', 'Golden Author Beta', '1660', 0, 'de', 'en', NULL, 'public domain', 1, 'Fixture: fragment f-beta, appended in build 2.', '2026-02-01 00:00:00');
INSERT INTO content_units VALUES (501, 5, 'question', 1, 'Question 1', 'Beta catechism text: what is a sacrament? Appendedword marker.', NULL, 1, '2026-02-01 00:00:00', 'primary_text');
INSERT INTO content_units VALUES (502, 5, 'question', 2, 'Question 2', 'Beta catechism text: how many sacraments are there?', NULL, 2, '2026-02-01 00:00:00', 'primary_text');

INSERT INTO content_tags VALUES (501, 3);
INSERT INTO content_tags VALUES (502, 3);

INSERT INTO content_chunks
  SELECT id * 1000 + 1, id, 1, 0, length(content) FROM content_units
  WHERE id NOT IN (SELECT content_unit_id FROM content_chunks);
INSERT INTO chunk_embeddings
  SELECT id, unhex(replace(printf('%96s', ''), ' ', printf('%08X', id)))
  FROM content_chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_embeddings);

INSERT INTO content_fts(content_fts) VALUES('rebuild');
