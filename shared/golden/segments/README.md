# Golden passage-segmentation fixture

`segments.json` records what the Flutter reader's
`lib/src/reader/passage_segments.dart` makes of a fixed set of passages: the
segments `segmentPassage` cuts, the passage's kind and nouns, and the
`referenceFor` and `quoteFor` output for several selections in each. The SwiftUI
app in `apple/` ports that file to
`CouncilCore/Reading/PassageSegments.swift` and has to reproduce this file
exactly (`SegmentsGoldenTests`). The Flutter side is held to it by
`test/segments_golden_test.dart`, which writes it and runs in the ordinary
`flutter test` suite.

Exactness matters more here than anywhere else. Highlights and notes are
stored in `council_user.db` as `start`/`end` offsets into the content unit,
written by the Flutter app as Dart string indices, which are UTF-16 code
units. The native app installs over the Flutter one and reads those same rows.
If it cut a passage one code unit differently, a saved highlight would cover
the wrong words or no segment at all.

Never edit `segments.json` by hand.

## Regenerating and verifying

```sh
flutter test test/segments_golden_test.dart                                   # verify
flutter test test/segments_golden_test.dart --dart-define=UPDATE_GOLDENS=true # rewrite outputs
python3 tools/build_segment_goldens.py                                        # rebuild inputs, then outputs
```

Use the CI-pinned Flutter (`~/development/flutter-3.44.8/bin/flutter`; the
Python script uses it unless `FLUTTER=` says otherwise). Its `pub get` rewrites
`pubspec.lock`. Restore that with `git checkout pubspec.lock` before committing.

- **Changed the segmenter on purpose?** Run the update test. It reads each
  case's inputs from `segments.json`, recomputes the outputs from the Dart code
  and rewrites the file. The Swift port then has to follow.
- **Changed the set of cases?** Edit `tools/build_segment_goldens.py` and run
  it. It reads the chosen chapters out of `assets/theology.db.gz`, writes the
  inputs into `segments.json` with no outputs, and then runs the update test.
  Running it twice leaves the file unchanged.

The verifying test needs only this JSON, never the corpus. It also checks
invariants of the Dart code that hold for every case. Every segment is
non-empty and trimmed, segments are in order and don't overlap, and
`content[start..<end]` is the text (prose) or ends with it (verses, whose span
includes the number). If an invariant fails, the segmenter is broken.
Regenerating would only record the breakage.

## Format

`cases` is a list. Each case lists its inputs first:

| Field | Meaning |
|---|---|
| `id`, `why` | Name and reason. `kjv-*` cases are chapters copied verbatim from the bundled corpus; the rest are hand-written. |
| `unitTitle` | What is passed to `referenceFor`. It can be `null`, `""` or padded with spaces. |
| `content` | The passage exactly as given to `segmentPassage`. Invisible characters are written as `\uXXXX` escapes so they show in a diff. |
| `extraSelections` | Optional selections the case asks for on top of the standard set. |

Then the outputs:

| Field | Meaning |
|---|---|
| `kind` | `verse`, `paragraph` or `sentence`. |
| `nouns` | `noun(0)`, `noun(1)`, `noun(2)`. |
| `segments` | One `[index, start, end, text, number]` per segment. `start` and `end` are UTF-16 offsets into `content`. `number` is `null` for prose and for a heading above verse 1. |
| `selections` | `{selected, reference, quote}`. `selected` lists segment indices in the order passed. `reference` is `referenceFor(unitTitle, [segments[i] for i in selected])`. `quote` is `quoteFor(passage, selected)`. |

The standard selections are `[]`, `[0]`, `[last]`, `[0, 1]`, `[1, 0]`,
`[0, 1, 2]`, `[0, 2]`, `[0, 2, 3, 5]`, `[last-1, last]`, `[1, 1]`,
`[0, last]`, and the first 10 indices, or all of them when there are 20 or
fewer. A selection is dropped when it doesn't fit the passage, and so is a
repeat of an earlier one.

The corpus chapters reflect what the corpus actually holds. Every KJV
chapter is one numbered verse per line, joined by `\n` with no trailing
newline. The only non-ASCII character in the core corpus is U+2019. There are no
headings, tabs, CRs, square brackets or double quotes, so everything else
is covered by hand-written cases.

## Tolerances

None. Everything must match exactly: offsets, counts, kinds and every string,
compared by UTF-16 code unit. Swift's `==` on `String` is canonical
equivalence, so it would accept the decomposed `é` in `prose-combining` as
equal to the precomposed one. The Swift test compares `utf16`.

## Swift implementation notes

These are the places where Dart semantics differ from what Swift or ICU would
do by default. Each one is pinned by at least one case.

1. **Offsets and lengths are UTF-16.** Work on `Array(content.utf16)`, not on
   `Character`s or scalars. This applies to the thresholds too. In
   `prose-astral-over-700`, about 690 scalars come to more than 700 code units,
   so Dart splits it into sentences. In `median-astral`, runs of about 395
   scalars are 405 units, so they are prose.
2. **Don't use NSRegularExpression.** ICU disagrees with Dart on every
   class these patterns use. The port uses a hand-written scanner for each
   pattern instead (all three are simple). The differences:
   - `\d` in Dart is ASCII `0-9`. ICU's is `\p{Nd}`, so it matches `١` and
     `１`. See `arabic-indic-digits`, `other-script-digits` and
     `mixed-digit-scripts`. Swift's `Int("١٢")` is nil, so an ICU match would
     produce a verse with no number.
   - `\s` in Dart is the ECMAScript set: `\t \n \v \f \r`, space, U+00A0,
     U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF.
     ICU's `\s` adds U+0085 and drops U+FEFF. See `prose-long-sentences`.
     These sets were checked by running every BMP code point through Dart.
   - Multiline `^` in Dart matches after `\n`, `\r`, U+2028 and U+2029. ICU's
     also matches after U+0085, `\v` and `\f`. See `nel-verses`,
     `formfeed-vt-verses`, `cr-verses` and `line-separator-verses`.
3. **`trim()` is its own set:** the `\s` set plus U+0085. It doesn't
   include U+200B (`zwsp-only` is one segment). Foundation's
   `trimmingCharacters(in: .whitespacesAndNewlines)` gets both wrong: it trims
   U+200B and keeps U+FEFF. `Character.isWhitespace` also excludes U+FEFF. Use
   `DartText.isTrimWhitespace`. `trimLeft` and `trimRight` use the same set.
4. **The verse marker is `^[ \t]*(\d{1,3})\.[ \t]+`.** Only spaces and tabs
   count on either side of the number. `1.\u00a0First` is no marker
   (`nbsp-after-stop`), and neither is a line starting with a BOM
   (`bom-first-line`, `bom-then-verses`). Four digits are no marker at all
   (`four-digit-numbers`). `int.tryParse` ignores leading zeros, so `007` is 7
   and `0` is 0 (`leading-zeros`).
5. **What a verse span covers.** `start` is the marker's line start, including
   the indentation and the number. `end` is where the trimmed text ends. A
   heading above verse 1 starts at 0, not where its text starts. A marker with
   no text after it makes no segment, and later indices close up
   (`empty-verse-texts`). If no marker has text, the passage is prose
   (`all-verse-texts-empty`).
6. **The median run is the upper median** (`runs[runs.length ~/ 2]`), and
   the test is `> 400`. See `median-run-400` (verses), `median-run-401` and
   `median-upper-of-two` (prose). A run is measured from the end of a marker to
   the start of the next one, untrimmed, newline included.
7. **Only `\n` separates paragraphs.** A CRLF blank line is `\n\r\n`, which
   `\n[ \t]*\n+` doesn't match, so CRLF prose always falls back to one
   paragraph per line (`prose-crlf`). A bare `\r`, U+2028 and U+2029 separate
   nothing (`prose-cr-only`, `prose-line-separators`). Blocks are split by
   blank lines only when that gives more than one block; otherwise by every
   run of `\n` (`prose-single-newlines`).
8. **The sentence regex is `(?<=[.!?][")\]]?)\s+(?=[A-Z"“(\[])`, applied to
   the block's substring,** so neither lookaround can see outside the
   block. The lookbehind takes one straight `"`, `)` or `]` after the stop,
   but not a curly `”`. The lookahead does take an opening `“`. Capitals are
   ASCII only, so a sentence starting with `É` or a Greek capital never
   splits (`prose-long-sentences`, `prose-greek-long`). As
   `prose-long-sentences` shows, `St. Paul` and `Mr. Smith` do split, while
   `Gen. 1` and `e.g. the` don't.
9. **Kind `sentence`** means at least one paragraph was over 700 code units
   after trimming. The other paragraphs in that passage stay whole
   (`prose-long-wrapped-among-short`). A long paragraph with no boundary in it
   is still `sentence`, with a single segment (`prose-long-no-boundary`).
10. **References** sort and de-duplicate the numbers
    (`unordered-duplicate-numbers`). Two adjacent verses are written `4, 5`.
    Three or more consecutive ones use an en dash (`4–6`). If the selection
    includes any unnumbered segment, the reference is just the trimmed title.
    An empty title gives the bare numbers. The title separator is `:`.
11. **Quotes** sort the indices. A repeated index counts as a gap, so
    `[1, 1]` quotes the segment twice with `… ` between the copies. Verses
    are joined with a space, prose with a blank line.
