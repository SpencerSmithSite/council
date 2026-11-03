-- Build 3 (negative case "wrong-idspace"): applied on top of build1 + build2.
--
-- Core source 2 is removed upstream and its unit ids (201, 202) are reused for
-- a new f-beta source. build_packs.check_id_space reports that as `occupied`
-- and bumps the id space, because an app holding build 1's core still has the
-- old text under those ids: merging this f-beta would hit a primary-key
-- collision on content_units.id.

DELETE FROM chunk_embeddings WHERE chunk_id IN
  (SELECT id FROM content_chunks WHERE content_unit_id IN
    (SELECT id FROM content_units WHERE source_id = 2));
DELETE FROM content_chunks WHERE content_unit_id IN
  (SELECT id FROM content_units WHERE source_id = 2);
DELETE FROM content_tags WHERE content_unit_id IN
  (SELECT id FROM content_units WHERE source_id = 2);
DELETE FROM content_units WHERE source_id = 2;
DELETE FROM sources WHERE id = 2;

INSERT INTO sources VALUES (6, 2, 2, 'Golden Beta Letters', 'golden-beta-letters', 'Golden Author Beta', '1655', 0, 'en', 'en', NULL, 'public domain', 1, 'Fixture: f-beta, written onto ids build 1 gave the core.', '2026-03-01 00:00:00');
INSERT INTO content_units VALUES (201, 6, 'letter', 1, 'Letter 1', 'Beta letter text: reusing an id the core already holds.', NULL, 1, '2026-03-01 00:00:00', 'primary_text');
INSERT INTO content_units VALUES (202, 6, 'letter', 2, 'Letter 2', 'Beta letter text: a second reused id.', NULL, 2, '2026-03-01 00:00:00', 'primary_text');

INSERT INTO content_chunks
  SELECT id * 1000 + 1, id, 1, 0, length(content) FROM content_units
  WHERE id NOT IN (SELECT content_unit_id FROM content_chunks);
INSERT INTO chunk_embeddings
  SELECT id, unhex(replace(printf('%96s', ''), ' ', printf('%08X', id)))
  FROM content_chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_embeddings);

INSERT INTO content_fts(content_fts) VALUES('rebuild');
