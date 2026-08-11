#!/usr/bin/env bash
# Every 64-bit native library in the APK must load on a 16 KB page-size device.
#
# Android's page size moved from 4 KB to 16 KB. A library whose LOAD segments
# are aligned to less than that cannot be mapped directly, so the OS falls back
# to page-size compatible mode and shows the reader a "This app isn't 16 KB
# compatible" dialog naming every library it could not check — which is most of
# them, because the checker reports "Unknown error" for libraries it simply
# could not read. That dialog is therefore useless for deciding what is wrong:
# on 2026-08-11 it named twenty libraries and five were actually misaligned.
#
# This measures instead of guessing, and fails on anything new. The alignment is
# set at link time by whoever compiled the binary, so for a prebuilt third-party
# library the only fixes are a newer upstream or dropping the dependency — which
# means the useful guarantee is not "everything is aligned" but "nothing is
# misaligned that we have not already decided about".
#
#   tools/check_alignment.sh [path/to.apk]
#
# Defaults to the release APK. A debug APK works equally well for the libraries
# that matter: the third-party binaries are the same files in both.
set -euo pipefail

APK="${1:-build/app/outputs/flutter-apk/app-release.apk}"

# Known and accepted, each with the reason it is not simply fixed.
#
#   libonnxruntime.so     the embedding runtime, pub release 1.4.1 (2024-03-27)
#                         and unmaintained. PLAN.md holds the exit: flutter_gemma
#                         is the destination, gated on re-embedding the corpus.
# The four Qualcomm Hexagon DSP skeletons used to be here and are now excluded
# from the APK entirely (see android/app/build.gradle.kts). They are deliberately
# *not* listed below: if a change puts them back, this should fail rather than
# wave through 42 MB and four misaligned libraries that were already decided
# about once.
ALLOWED=(
  libonnxruntime.so
)

# 16 KB. A library aligned to more (the Flutter engine uses 64 KB) is fine.
readonly REQUIRED=16384

find_readelf() {
  if [[ -n "${ANDROID_NDK_HOME:-}" && -x "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt"/*/bin/llvm-readelf ]]; then
    echo "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt"/*/bin/llvm-readelf
    return
  fi
  local candidate
  for candidate in "$HOME/Library/Android/sdk/ndk"/*/toolchains/llvm/prebuilt/*/bin/llvm-readelf \
                   "$HOME/Android/Sdk/ndk"/*/toolchains/llvm/prebuilt/*/bin/llvm-readelf; do
    [[ -x "$candidate" ]] && { echo "$candidate"; return; }
  done
  command -v llvm-readelf || command -v readelf || return 1
}

READELF="$(find_readelf)" || {
  echo "No readelf found. Install the Android NDK, or set ANDROID_NDK_HOME." >&2
  exit 2
}

[[ -f "$APK" ]] || { echo "No APK at $APK — build one first." >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q -o "$APK" 'lib/*' -d "$WORK"

allowed() {
  local name="$1" entry
  for entry in "${ALLOWED[@]}"; do [[ "$entry" == "$name" ]] && return 0; done
  return 1
}

failures=0
stale=0

# 64-bit ABIs only. A 32-bit Android has 4 KB pages and always will.
for abi in arm64-v8a x86_64; do
  dir="$WORK/lib/$abi"
  [[ -d "$dir" ]] || continue
  checked=0
  aligned=0
  echo "== $abi"

  for so in "$dir"/*.so; do
    name="$(basename "$so")"
    hex="$($READELF -lW "$so" 2>/dev/null | awk '$1=="LOAD"{print $NF; exit}')"
    [[ -n "$hex" ]] || { printf '  %-44s unreadable\n' "$name"; continue; }
    align=$((hex))
    checked=$((checked + 1))

    if (( align >= REQUIRED )); then
      aligned=$((aligned + 1))
      if allowed "$name"; then
        printf '  %-44s %8s  now aligned — drop it from ALLOWED\n' "$name" "$hex"
        stale=1
      fi
    elif allowed "$name"; then
      printf '  %-44s %8s  known\n' "$name" "$hex"
    else
      printf '  %-44s %8s  NOT 16 KB ALIGNED\n' "$name" "$hex"
      failures=$((failures + 1))
    fi
  done

  # Printed even when nothing is wrong: a checker whose silence could mean
  # "all good" or "looked at nothing" is not worth having in a build.
  printf '  %d checked, %d aligned\n' "$checked" "$aligned"
done

echo
if (( failures > 0 )); then
  echo "$failures librar$([[ $failures -eq 1 ]] && echo y || echo ies) newly misaligned."
  echo "Either the dependency that ships it moved, or a new one arrived. Find out"
  echo "which before adding it to ALLOWED — the list is for things already decided"
  echo "about, not a place to put whatever is failing today."
  exit 1
fi

(( stale == 1 )) && echo "Nothing new. Some ALLOWED entries are no longer needed (above)."
(( stale == 0 )) && echo "Nothing new: every 64-bit library is 16 KB aligned or already accounted for."
exit 0
