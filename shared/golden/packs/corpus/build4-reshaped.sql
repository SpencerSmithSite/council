-- Build 4 (negative case "reshaped"): applied on top of build1 + build2.
--
-- content_units gains a column. No id moves and no text changes, so the only
-- thing that can catch it is the column list. build_packs.check_id_space does
-- (it reports `reshaped` and bumps the id space) when the ledger records table
-- shapes — but a ledger written before shapes were recorded cannot, and the
-- build then keeps the old id space. This case is published that way, so the
-- app's own idSpace gate lets it through and the positional merge meets it.

ALTER TABLE content_units ADD COLUMN reviewed_by TEXT;
UPDATE content_units SET reviewed_by = 'fixture' WHERE source_id = 3;
