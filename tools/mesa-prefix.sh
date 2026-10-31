#!/usr/bin/env bash
# Build the private Mesa prefix QEMU runs on, from .deb files you download yourself.
# The system Mesa and apt are left untouched; only `gg` points QEMU at this prefix
# (VK_DRIVER_FILES + LD_LIBRARY_PATH).
#
#   tools/mesa-prefix.sh <dir-with-debs> [prefix]      # prefix default: $GG_HOME/opt/mesa-kisak
#
# Tested with kisak-mesa 26.2.5 (LLVM 21.1.8) for Ubuntu 24.04 (noble), amd64, from the PPA
#   https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa
# Download these four packages (matching versions, "View package details" -> files) into <dir>:
#   mesa-vulkan-drivers   libllvm21   libdrm2 (2.4.134)   libdisplay-info1
# Older Mesa (24.x in noble) lacks the Dozen fixes this was measured on; llvmpipe/lavapipe
# aborts with "LLVM ERROR: Cannot emit physreg copy" a few minutes into the boot.
set -euo pipefail
D=${1:?usage: mesa-prefix.sh <dir-with-debs> [prefix]}
P=${2:-${GG_MESA:-${GG_HOME:-$HOME/gg}/opt/mesa-kisak}}
shopt -s nullglob
debs=("$D"/*.deb)
[ ${#debs[@]} -gt 0 ] || { echo "no .deb files in $D" >&2; exit 1; }
mkdir -p "$P"
for d in "${debs[@]}"; do echo "extract $(basename "$d")"; dpkg-deb -x "$d" "$P"; done
LIB=$P/usr/lib/x86_64-linux-gnu
for drv in dzn lvp; do
  src=$P/usr/share/vulkan/icd.d/${drv}_icd.json
  [ -e "$src" ] || src=$(ls "$P"/usr/share/vulkan/icd.d/${drv}_icd*.json 2>/dev/null | head -1)
  [ -n "$src" ] && [ -e "$src" ] || { echo "no ${drv} ICD manifest in the debs" >&2; continue; }
  python3 - "$src" "$LIB/libvulkan_${drv}.so" "$P/${drv}_icd.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["ICD"]["library_path"] = sys.argv[2]
json.dump(m, open(sys.argv[3], "w"), indent=4)
PY
  echo "wrote $P/${drv}_icd.json"
done
[ -e "$P/dzn_icd.json" ] || { echo "Dozen (dzn) driver missing: wrong mesa-vulkan-drivers build?" >&2; exit 1; }
echo "check: VK_DRIVER_FILES=$P/dzn_icd.json LD_LIBRARY_PATH=$LIB:/usr/lib/wsl/lib vulkaninfo --summary"
