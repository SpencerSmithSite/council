#!/usr/bin/env python3
"""Ingest John Owen, clearing the rights question by corroboration.

Owen is the largest single gap this corpus has had. `ingest_reformation.py`
refused all thirty-one of his works, and it was right to on the evidence it
had: CCEL's exports carry no rights statement and name a Banner of Truth
printing of 1965-68 as their print basis, and a modern edition can carry modern
editorial matter. A header cannot tell a *new* edition from a *reprint* of an
old one, so that ingester declines rather than guess.

But the question is answerable — just not from the header. Banner of Truth's
Owen is a facsimile of the edition William H. Goold prepared in 1850-55, which
is unambiguously public domain and is on archive.org as page scans. So instead
of reasoning from a date, this script *measures*: it scores the text CCEL
transcribed against the OCR of Goold's volumes, and admits a work only where
the match says the two are the same document.

**The test, and why it can be trusted.** Containment of word *pairs* — the
fraction of a work's bigrams that also occur somewhere in the scan — the same
primitive `ingest_orthodox.py` uses, for the same reason: single words pass on
any two texts of the same period and subject, because English theological
vocabulary is small and shared. What matters is that the measure separates
"this is that printing" from "this is the same author", which is the confusion
that would actually let something through here. Measured on Goold's volume 10:

    Owen, Death of Death        — the work that volume contains      92.0%
    Owen, Mortification of Sin  — same author, same idiom, vol. 6    43.7%
    Calvin, Institutes          — unrelated Reformed treatise        18.2%

Fifty points of daylight between a true match and the hardest near-miss
available. `MIN_CONTAINMENT` sits in that gap, and `NEGATIVE_CONTROL` re-runs
the Calvin leg of that experiment against the assembled witness on every parse,
so the threshold is checked against this witness set rather than trusted from
this comment.

Scoring is against the units as they will be stored, not the file as
downloaded: what needs corroborating is what goes into the corpus, and that is
what survives segmentation.

Errors run one way. OCR of a Victorian octavo drops and mangles words, so the
witness is always missing some of what the transcription has, and containment
reads *low*. Noise in the scan — running heads, page numbers, marginal notes —
only adds bigrams to the witness, and adding to the witness can lift a score it
cannot fabricate one: an unrelated work has nothing to match against however
much junk is there, as the Calvin control shows. So a work that clears the
threshold has cleared it despite the measurement, not because of it.

    python3 tools/ingest_owen.py fetch
    python3 tools/ingest_owen.py parse
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ingest_reformation as reformation  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
WITNESS_CACHE = ROOT / ".cache" / "goold"
UNITS = ROOT / "tools" / "data" / "owen_units.json"

USER_AGENT = reformation.USER_AGENT
DELAY_SECONDS = 2.0

# The sixteen volumes of the *Works* proper, pinned by archive.org identifier
# rather than looked up, so a re-run scores against the same scans and not
# whichever copies search returns that day. Goold's edition continues to
# twenty-four with the *Exposition of Hebrews*, which is left out because CCEL
# has none of it — nothing here would ever be scored against those volumes.
#
# **These numbers are Goold's, not archive.org's.** archive.org's `volume`
# metadata is not reliable: the `worksofjohnowend00NNowen` scans are numbered
# straight through the twenty-four, so the item calling itself volume 12 is a
# Hebrews volume, and scoring against it left *Vindiciæ Evangelicæ* and the
# Grotius review with nowhere to match. They were refused as uncorroborated
# when the truth was that their volume had never been fetched. Every entry
# below was checked against the volume's own contents page instead, and
# `parse` reports the volume each work matched so that a bad pin shows up as a
# work with no home rather than as a rights problem.
GOOLD = {
    1: "worksofjohnowe185001owen",
    2: "worksofjohnowe185002owen",
    3: "worksofjohnowe185003owen",
    4: "worksofjohnowe185004owen",
    5: "worksofjohnowe185005owen",
    6: "worksofjohnowe185006owen",
    7: "worksofjohnowen07owenuoft",  # 1862 reissue; the 1850 scan has no text
    8: "worksofjohnowe185008owen",
    9: "worksofjohnowe185009owen",
    10: "worksofjohnowe185010owen",
    11: "worksofjohnowe185011owen",
    12: "worksofjohnowe185012owen",
    13: "worksofjohnowe185013owen",
    14: "worksofjohnowe185014owen",
    15: "worksofjohnowen185015owen",
    16: "worksofjohnowe185016owen",
}

# The CCEL work ids, and the genre each belongs to. Everything not named here is
# a treatise, which is most of Owen.
SERMONS = {"sermons", "discourses"}

WORK_IDS = [
    "apostasy", "catechisms", "churchlove", "communion", "conscience",
    "deathofdeath", "discourses", "display", "eshcol", "evangelicalchurches",
    "faith", "glory", "grotius", "indwellingsin", "just", "justice",
    "liturgies", "mort", "pastorspeople", "perseverance", "pneum", "psalm130",
    "schism", "sermons", "sin_grace", "spirituallyminded", "temptation",
    "trinity", "truthinnocence", "vindicevang", "worship",
]

# Set from the measurements in the docstring: far enough above the 43.7% that
# the *same author in a different volume* scores that a near-miss cannot reach
# it, far enough below the 92.0% of a true match to leave room for a volume
# whose scan is worse than average.
MIN_CONTAINMENT = 0.75

# The bar for a work that no single volume holds. Higher than `MIN_CONTAINMENT`
# rather than lower, because scoring against all sixteen volumes at once is a
# much easier test to pass — everything Owen ever wrote shares its idiom with
# the rest, so the whole edition matches loosely where one volume matches
# exactly. Raising the bar is what stops the fallback from being a way in for
# work the sharp test rejected.
MIN_SPANNING_CONTAINMENT = 0.90

# Calvin's Institutes, scored against Owen's collected works. It has no business
# matching, and if it ever does the measure has stopped discriminating and every
# other number in the run is worthless. Cached already by `ingest_reformation`.
NEGATIVE_CONTROL = reformation.CACHE / "calvin__institutes.txt"
CONTROL_KEY = "\0control"
MAX_CONTROL_CONTAINMENT = 0.60


def entry_for(work_id):
    """The 4-tuple `ingest_reformation.parse_work` expects."""
    kind = "Sermon" if work_id in SERMONS else "Treatise"
    return ("owen", work_id, "Reformed", kind)


# --- witness -----------------------------------------------------------------

WORDS = re.compile(r"[a-z']+")


def bigrams(text):
    """Adjacent word pairs, joined, so the witness set stays cheap to hold.

    Twenty-two volumes of OCR come to a couple of million distinct pairs. As
    tuples that is most of a gigabyte of interpreter overhead for no gain —
    nothing downstream looks at the halves.
    """
    tokens = WORDS.findall(text.lower())
    return {f"{a} {b}" for a, b in zip(tokens, tokens[1:])}


def containment(text, witness):
    pairs = bigrams(text)
    if not pairs:
        return 0.0
    return len(pairs & witness) / len(pairs)


def witness_path(volume):
    return WITNESS_CACHE / f"goold{volume:02d}.txt"


def score_against_edition(targets):
    """Score each target's bigrams against Goold, volume by volume.

    Returns `{name: (best_score, best_volume, whole_edition_score)}`.

    Both numbers are wanted, and they answer different questions. The
    single-volume score is the sharp one — a work sitting in the volume that
    contains it scores in the nineties while the same author's *other* works
    score in the forties, so a peak is evidence about this text and not merely
    about Owen's vocabulary. The whole-edition score is the forgiving one, for
    the handful of works that genuinely span volumes: Owen's collected sermons
    were gathered from several, and judging them by their best single volume
    would refuse them for how the edition was bound.

    Volumes are streamed one at a time rather than held together. Sixteen
    volumes of OCR is a couple of million pairs, and there is no reason to have
    them all resident when the targets are what needs to stay in memory.
    """
    missing = [v for v in GOOLD if not witness_path(v).exists()]
    if missing:
        sys.exit(f"volumes {missing} not fetched — run `fetch` first")

    best = {name: (0.0, None) for name in targets}
    union = set()

    for volume in sorted(GOOLD):
        text = witness_path(volume).read_bytes().decode("utf-8", errors="replace")
        pairs = bigrams(text)
        for name, target in targets.items():
            if not target:
                continue
            score = len(target & pairs) / len(target)
            if score > best[name][0]:
                best[name] = (score, volume)
        before = len(union)
        union |= pairs
        print(f"  vol {volume:>2}  {len(text):>10,} chars  "
              f"+{len(union) - before:>8,} pairs", flush=True)

    print(f"\n  {len(union):,} distinct word pairs across the edition\n")
    return {
        name: (best[name][0], best[name][1],
               len(target & union) / len(target) if target else 0.0)
        for name, target in targets.items()
    }


# --- commands ----------------------------------------------------------------


def fetch():
    WITNESS_CACHE.mkdir(parents=True, exist_ok=True)
    pending = [v for v in sorted(GOOLD) if not witness_path(v).exists()]
    print(f"{len(GOOLD)} Goold volumes, {len(pending)} to fetch "
          f"({len(GOOLD) - len(pending)} cached)\n")

    for i, volume in enumerate(pending, 1):
        identifier = GOOLD[volume]
        url = (f"https://archive.org/download/{identifier}/"
               f"{identifier}_djvu.txt")
        path = witness_path(volume)
        result = subprocess.run(
            ["curl", "-fsSL", "--max-time", "300", "-A", USER_AGENT, url,
             "-o", str(path)],
            capture_output=True,
        )
        if result.returncode != 0:
            path.unlink(missing_ok=True)
            print(f"  [{i}/{len(pending)}] FAILED  vol {volume} ({identifier}): "
                  f"curl exit {result.returncode}", file=sys.stderr)
        else:
            print(f"  [{i}/{len(pending)}] ok      vol {volume:<3} "
                  f"{identifier:<28} {path.stat().st_size:>10,} bytes",
                  flush=True)
        time.sleep(DELAY_SECONDS)

    # The CCEL side is already on disk from the reformation run, which fetched
    # every Owen export before refusing it. Say so rather than silently
    # depending on it.
    have = [w for w in WORK_IDS
            if reformation.path_for(entry_for(w)).exists()]
    print(f"\n{len(have)}/{len(WORK_IDS)} CCEL exports cached in "
          f"{reformation.CACHE}")
    if len(have) < len(WORK_IDS):
        print("  run `python3 tools/ingest_reformation.py fetch` for the rest "
              "— it fetches Owen even though it refuses him")


def parse():
    # Segment everything first, with the rights gate held open, so that what
    # gets scored is the text as it will be stored rather than the file as it
    # was downloaded. A refusal in this loop is a parsing refusal and has
    # nothing to do with rights.
    provisional, skipped = {}, []
    for work_id in WORK_IDS:
        entry = entry_for(work_id)
        path = reformation.path_for(entry)
        if not path.exists():
            skipped.append((work_id, "not fetched"))
            continue
        text = path.read_bytes().decode("utf-8", errors="replace")
        record, why = parse_work_provisionally(entry, text)
        if record is None:
            skipped.append((work_id, why))
            continue
        provisional[work_id] = record

    targets = {
        work_id: bigrams("\n".join(u["content"] for u in record["units"]))
        for work_id, record in provisional.items()
    }
    control_text = "".join(re.split(
        r"_{20,}",
        NEGATIVE_CONTROL.read_bytes().decode("utf-8", errors="replace"))[3:])
    targets[CONTROL_KEY] = bigrams(control_text)

    print(f"Scoring {len(provisional)} works against Goold's edition:")
    scores = score_against_edition(targets)

    control_best, control_volume, control_all = scores.pop(CONTROL_KEY)
    print(f"Negative control — Calvin's Institutes against Owen: "
          f"{control_best:.1%} at its best volume ({control_volume}), "
          f"{control_all:.1%} against the whole edition")
    if control_all >= MAX_CONTROL_CONTAINMENT:
        sys.exit(f"the control scores {control_all:.1%}, at or above "
                 f"{MAX_CONTROL_CONTAINMENT:.0%}. The measure is no longer "
                 f"telling Owen apart from any Reformed prose, so no result "
                 f"below it means anything. Refusing to ingest.")
    print(f"  below {MAX_CONTROL_CONTAINMENT:.0%} — the measure discriminates\n")

    records = []
    for work_id, record in provisional.items():
        best, volume, whole = scores[work_id]
        chars = sum(len(u["content"]) for u in record["units"])

        if best >= MIN_CONTAINMENT:
            basis = (f"{best:.0%} of its word pairs occur in volume {volume} "
                     f"of that edition")
            shown = f"vol {volume:>2} {best:>6.1%}"
        elif whole >= MIN_SPANNING_CONTAINMENT:
            # No single volume holds it, but the edition as a whole does — the
            # shape of a work the edition distributes across volumes.
            basis = (f"{whole:.0%} of its word pairs occur across the volumes "
                     f"of that edition, which is where this work is distributed")
            shown = f"spread {whole:>5.1%}"
        else:
            skipped.append((
                work_id,
                f"best volume {volume} holds {best:.1%} of its word pairs and "
                f"the whole edition {whole:.1%} — not corroborated"))
            print(f"  {'REFUSED':<8} {work_id:<22} vol {volume:>2} {best:>6.1%}  "
                  f"(edition {whole:.1%})  {record['title'][:36]}")
            continue

        record["rights"] = (
            f"Public domain in the US. Written in English by an author who died "
            f"in 1683, and the text is that of William H. Goold's edition of "
            f"1850-55: {basis}. CCEL's export states no rights and names a "
            f"1965-68 Banner of Truth printing, which is a facsimile of Goold"
        )
        record["collection"] = (
            f"{record['collection']} | Corroborated against The Works of John "
            f"Owen, ed. W. H. Goold, 1850-55 "
            f"(archive.org: {GOOLD[volume] if volume else GOOLD[1]})"
        )
        records.append(record)
        print(f"  {'ok':<8} {work_id:<22} {shown}  {len(record['units']):>5} units  "
              f"{chars/1e6:>5.2f} M  {record['title'][:36]}")

    total_units = sum(len(r["units"]) for r in records)
    total_chars = sum(len(u["content"]) for r in records for u in r["units"])
    print(f"\n  {len(records)} works  {total_units:,} units  "
          f"{total_chars/1e6:.2f} M chars")

    if skipped:
        print(f"\n{len(skipped)} works not ingested:")
        for work_id, why in skipped:
            print(f"    {work_id:<24} {why}")

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    UNITS.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print(f"\n-> {UNITS}")


def parse_work_provisionally(entry, text):
    """Segment a work with the rights question deferred to the score."""
    return reformation.parse_work(
        entry, text, rights_override="pending corroboration")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()
    {"fetch": fetch, "parse": parse}[args.command]()


if __name__ == "__main__":
    main()
