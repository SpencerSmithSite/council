#!/usr/bin/env python3
"""Rekey the id ledger from source_url to source id — once.

The ledger `build_packs.py` compares each build against was keyed by
`source_url`, and the query that fills it groups by `s.id`. Where several
sources share a url — the five parts of the Summa, three of Brannan's
confessions, three of Schaff's *Creeds* — each row overwrote the last and only
one survived. Eight of 653 sources were therefore outside the check that decides
whether a rebuild reassigned ids that readers already hold. Nothing reported it:
a dict that collapses keys does not raise, it just returns fewer entries than it
was given.

This script is the one-time repair, and it exists as a script rather than as a
line in a commit because the repair has a precondition worth stating and
checking. Rekeying is only safe if it is *lossless* — if the new ledger asserts
exactly what the old one asserted, plus the eight it could not hold. So:

  * Every url in the old ledger must be reproduced exactly. The old entry for a
    url is whichever of that url's sources has the highest id, because that is
    the row `GROUP BY s.id` wrote last. Range, count and text hash must all
    match, or this refuses to write.
  * The corpus must not have moved since the ledger was written — same
    high-water mark — or this is not a rekey of a baseline but the invention of
    a new one, which is a different and far more dangerous act.

What it cannot check is the eight sources themselves, since the old ledger never
recorded them: writing them in asserts that their ids are where they have always
been, on no evidence from this file. That evidence was gathered separately and
directly, from the packs readers actually hold — `f-aquinas.db.gz` and
`f-reformed.db.gz` of release corpus-v17 — and all six of the eight that could
be on a reader's device matched the live corpus exactly, range for range and
hash for hash. (The other two are Schaff's, ingested above corpus-v17's
high-water mark of 178840, so no published pack has ever carried those ids.
They read as "settled" below because the ledger they are measured against is
today's, which already stands above them.) It is recorded here because a check
run once and written down is worth more than a check nobody thought to run.

After this, `build_packs.py` refuses any ledger that is not format 2, and counts
its own entries against the corpus on every build, so the blindness cannot
return quietly.

    python3 tools/migrate_id_ledger.py            # check, report, write nothing
    python3 tools/migrate_id_ledger.py --write    # rekey in place
"""

import argparse
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_packs import DB_PATH, LEDGER_PATH, LEDGER_FORMAT, current_ledger


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true",
                        help="rewrite the ledger in place")
    args = parser.parse_args()

    if not LEDGER_PATH.exists():
        sys.exit(f"No ledger at {LEDGER_PATH} — nothing to migrate.")
    if not DB_PATH.exists():
        sys.exit(f"No corpus at {DB_PATH}. The rekey is proved against it.")

    before = json.loads(LEDGER_PATH.read_text(encoding="utf-8"))
    if before.get("format") == LEDGER_FORMAT:
        print(f"Already format {LEDGER_FORMAT}, {len(before['sources'])} sources. "
              "Nothing to do.")
        return

    conn = sqlite3.connect(DB_PATH)
    after = current_ledger(conn)  # counts itself against the corpus

    if after["maxUnitId"] != before["maxUnitId"]:
        sys.exit(
            f"The corpus has moved since the ledger was written: high-water mark "
            f"{before['maxUnitId']} in the ledger, {after['maxUnitId']} in the "
            f"corpus.\nThis migration rekeys an existing baseline; it will not "
            f"invent one. Rebuild the packs first, then migrate.")

    by_url = {}
    for key, entry in after["sources"].items():
        by_url.setdefault(entry["url"], []).append((int(key), entry))

    facts = ("min", "max", "count", "hash")
    missing, mismatched, reproduced = [], [], 0
    for url, old in before["sources"].items():
        candidates = by_url.get(url)
        if not candidates:
            missing.append(url)
            continue
        _, entry = max(candidates, key=lambda pair: pair[0])
        if all(entry[fact] == old[fact] for fact in facts):
            reproduced += 1
        else:
            mismatched.append((url, old, entry))

    print(f"old ledger   {len(before['sources'])} entries, keyed by url")
    print(f"rekeyed      {len(after['sources'])} entries, keyed by source id")
    print(f"reproduced   {reproduced}/{len(before['sources'])} exactly")

    if missing or mismatched:
        for url in missing[:6]:
            print(f"    missing     {url}")
        for url, old, new in mismatched[:6]:
            print(f"    mismatched  {url}\n"
                  f"        was {old['min']}-{old['max']} n={old['count']} {old['hash']}\n"
                  f"        now {new['min']}-{new['max']} n={new['count']} {new['hash']}")
        sys.exit("\nThis is not a lossless rekey. Refusing to write: the ledger "
                 "disagrees with the corpus about ids that are already published, "
                 "which is the fault it exists to catch, not one to migrate past.")

    gained = sorted(
        (int(key), entry) for url, group in by_url.items() if len(group) > 1
        for key, entry in sorted(group)[:-1])
    print(f"newly covered {len(gained)} sources the url key could not hold:")
    for key, entry in gained:
        ground = "settled" if entry["min"] <= before["maxUnitId"] else "new ground"
        print(f"    source {key:<5} units {entry['min']}-{entry['max']:<7} "
              f"{ground:11} {entry['title'][:48]}")

    # Carried across unchanged. The ledger describes what was published, and a
    # rekey publishes nothing: the same build, the same ids, filed under names
    # that do not collide.
    after["idSpace"] = before.get("idSpace", 1)

    if not args.write:
        print("\nDry run. Pass --write to rekey the ledger in place.")
        return

    LEDGER_PATH.write_text(json.dumps(after, indent=1) + "\n", encoding="utf-8")
    print(f"\nWrote {LEDGER_PATH.name}  format {LEDGER_FORMAT}, "
          f"{len(after['sources'])} sources, id space {after['idSpace']}.")
    print("The next build compares against this. It should report id space "
          f"{after['idSpace']} unchanged — anything else means something moved.")


if __name__ == "__main__":
    main()
