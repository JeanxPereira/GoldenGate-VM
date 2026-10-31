#!/usr/bin/env bash
# Fetch the macOS 27 (26A428) image published by Cirrus Labs for `tart` and lay it out for `gg`.
# You download it yourself, from ghcr.io, under the licence terms that apply to it; nothing
# from Apple is shipped in this repository.
#
#   tools/prepare-image.sh            # every step; each one is skipped when its output exists
#
# Steps (outputs in $GG_HOME/img/$GG_IMG, default ~/gg/img/gg27):
#   1. Orchard's scripts/fetch-tart-image.py pulls disk, NVRAM (aux) and config (~33 GB,
#      resumable; 8 parallel jobs, since ghcr throttles per connection).
#   2. The macOS 27 disk is an ASIF container ("diskFormat":"asif"); tools/asif2raw.py turns it
#      into a sparse 50 GB raw image, freeing the input as it goes (--consume).
#   3. aux.img and config.json are copied as published (aux.pristine.img is a spare copy).
#      Boot-args are NOT written to NVRAM: iBoot filters them under full security; `gg`
#      injects them at the iBoot->XNU handoff instead.
#   4. Orchard's scripts/extract-avpbooter.py copies AVPBooter.vmapple2.bin out of the image
#      (needs apfs-fuse).
#   5. tools/find_avpbooter_patch.py --write stubs the routine NyanSatan's Virtual-iBoot-Fun
#      identified (0x2370 on this build) -> AVPBooter.patched.bin.
#
# Env: GG_HOME, GG_IMG, GG_TART_REPO (cirruslabs/macos-golden-gate-vanilla), GG_TART_TAG (27.0),
#      GG_JOBS (8), GG_ORCHARD (<repo>/external/orchard), GG_PY ($GG_HOME/venv/bin/python).
set -euo pipefail
T=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
REPO=$(cd "$T/.." && pwd)
GG=${GG_HOME:-$HOME/gg}
NAME=${GG_IMG:-gg27}
I=$GG/img/$NAME
C=$GG/cache/$NAME-fetch
ORCH=${GG_ORCHARD:-$REPO/external/orchard}
PY=${GG_PY:-$GG/venv/bin/python}
[ -x "$PY" ] || { echo "no venv at $PY: run setup.sh first" >&2; exit 1; }
[ -f "$ORCH/scripts/fetch-tart-image.py" ] || { echo "Orchard not found at $ORCH: run setup.sh first" >&2; exit 1; }
mkdir -p "$I" "$C"

if [ ! -e "$I/disk.raw" ]; then
  echo "== 1/5 fetch ${GG_TART_REPO:-cirruslabs/macos-golden-gate-vanilla}:${GG_TART_TAG:-27.0} into $C"
  "$PY" "$ORCH/scripts/fetch-tart-image.py" --repo "${GG_TART_REPO:-cirruslabs/macos-golden-gate-vanilla}" \
    --tag "${GG_TART_TAG:-27.0}" --jobs "${GG_JOBS:-8}" --out-dir "$C"
  if [ "$(head -c4 "$C/disk.raw")" = shdw ]; then
    echo "== 2/5 ASIF -> raw ($I/disk.raw)"
    "$PY" "$T/asif2raw.py" convert "$C/disk.raw" "$I/disk.raw.part" --consume
    mv "$I/disk.raw.part" "$I/disk.raw"; rm -f "$C/disk.raw"
  else
    echo "== 2/5 disk is already raw"; mv "$C/disk.raw" "$I/disk.raw"
  fi
else
  echo "== 1-2/5 $I/disk.raw exists, skipping fetch"
fi

echo "== 3/5 aux.img / config.json"
for f in aux.img config.json; do
  [ -e "$I/$f" ] || cp "$C/$f" "$I/$f"
done
[ -e "$I/aux.pristine.img" ] || cp "$I/aux.img" "$I/aux.pristine.img"

if [ ! -e "$I/AVPBooter.vmapple2.bin" ]; then
  echo "== 4/5 extract AVPBooter (apfs-fuse)"
  "$PY" "$ORCH/scripts/extract-avpbooter.py" "$I/disk.raw" -o "$I/AVPBooter.vmapple2.bin"
fi
if [ ! -e "$I/AVPBooter.patched.bin" ]; then
  echo "== 5/5 patch AVPBooter"
  "$PY" "$T/find_avpbooter_patch.py" "$I/AVPBooter.vmapple2.bin" --write "$I/AVPBooter.patched.bin"
fi
ls -la "$I"
echo "next: gg provision   (then gg provision finish, rerun until it seals the layer)"
