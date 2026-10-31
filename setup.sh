#!/usr/bin/env bash
# One-shot, idempotent host setup inside WSL2 (Ubuntu 24.04). Rerun it any time.
#
#   ./setup.sh             # everything below
#   ./setup.sh --no-apt    # skip the apt step (no sudo)
#   ./setup.sh --no-build  # skip building Orchard
#
# What it does:
#   1. apt packages for QEMU, the Rust GPU device, the shader toolchain and the image tools
#   2. checks rustup/cargo (prints how to install if missing)
#   3. checks out external/orchard and external/metal2vulkan (submodules, or a clone at the
#      commits in external/PINNED when the gitlinks are not recorded yet)
#   4. Python venv in $GG_HOME/venv (requests, lz4, capstone) and an SSH key in $GG_HOME/ssh
#   5. builds Orchard's QEMU (+ reims-vgpu, + metal2vulkan) with external/orchard/scripts/build.sh
#   6. checks for the private Mesa prefix and apfs-fuse, and prints what is left to do by hand
set -euo pipefail
REPO=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
GG=${GG_HOME:-$HOME/gg}
MESA=${GG_MESA:-$GG/opt/mesa-kisak}
APT=1 BUILD=1
for a in "$@"; do case $a in --no-apt) APT=0;; --no-build) BUILD=0;; *) echo "unknown option $a" >&2; exit 2;; esac; done
say() { printf '\n== %s\n' "$*"; }
todo=()

grep -qi microsoft /proc/version 2>/dev/null || echo "warning: this does not look like WSL2; only WSL2 + WSLg was tested"
case $REPO in /mnt/*) echo "warning: the repo is on a Windows drive ($REPO). Building there is very slow;"
  echo "         clone it inside the WSL filesystem (e.g. ~/GoldenGate-VM) instead.";; esac

if [ $APT = 1 ]; then
  say "1/6 apt packages"
  sudo apt-get update -q
  sudo apt-get install -y -q \
    git build-essential ninja-build meson pkg-config flex bison python3-venv python3-pip \
    libglib2.0-dev libpixman-1-dev libslirp-dev libfdt-dev zlib1g-dev \
    libgnutls28-dev nettle-dev \
    libvulkan-dev vulkan-tools libwayland-dev libxkbcommon-dev \
    spirv-tools glslc llvm \
    qemu-utils gdb-multiarch sshpass socat \
    cmake libfuse3-dev fuse3 libbz2-dev libattr1-dev
  # libgnutls28-dev: without a crypto backend QEMU's configure stays silent, the vmapple AES
  #   device fails ("Failed to create cipher object") and the guest idles forever before launchd.
  # spirv-tools glslc llvm: reims-vgpu's shader path calls spirv-val/spirv-as/glslc/llvm-dis;
  #   without them every shader fails quietly.
else
  say "1/6 apt step skipped (--no-apt)"
fi

say "2/6 Rust toolchain"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
if command -v cargo >/dev/null; then cargo --version
else
  echo "cargo not found. Install rustup, then rerun ./setup.sh:"
  echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal"
  todo+=("install Rust (rustup) and rerun ./setup.sh"); BUILD=0
fi

say "3/6 external/orchard and external/metal2vulkan"
cd "$REPO"
if git ls-files -s external/orchard | grep -q '^160000'; then
  git submodule update --init --recursive
else
  # gitlinks not recorded yet: clone each fork's branch and check out the pinned commit
  grep -v '^#' external/PINNED | while read -r path commit branch _; do
    [ -n "$path" ] || continue
    if [ ! -e "$path/.git" ]; then
      url=$(git config -f .gitmodules "submodule.$path.url")
      rmdir "$path" 2>/dev/null || true
      git clone -b "$branch" "$url" "$path"
    fi
    git -C "$path" checkout -q "$commit" || echo "warning: $path: cannot check out $commit"
    echo "$path @ $(git -C "$path" rev-parse --short HEAD)"
  done
fi
# reims-vgpu/Cargo.toml patches metal2vulkan to path "../../metal2vulkan", i.e. external/metal2vulkan
[ -f external/orchard/reims-vgpu/Cargo.toml ] && [ -f external/metal2vulkan/Cargo.toml ] ||
  { echo "external/ is incomplete; see external/PINNED" >&2; exit 1; }

say "4/6 Python venv and SSH key in $GG"
mkdir -p "$GG"/{img,run,cache,opt,ssh}
[ -x "$GG/venv/bin/python" ] || python3 -m venv "$GG/venv"
"$GG/venv/bin/pip" install -q requests lz4 capstone
[ -f "$GG/ssh/gg_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C gg-guest -f "$GG/ssh/gg_ed25519"
echo "venv: $GG/venv   key: $GG/ssh/gg_ed25519(.pub)"

if [ $BUILD = 1 ]; then
  say "5/6 build Orchard (QEMU + reims-vgpu); the first build takes a while"
  external/orchard/scripts/build.sh --enable-gnutls
  grep -q '^#define CONFIG_GNUTLS_CRYPTO' external/orchard/qemu/build/config-host.h ||
    echo "warning: QEMU built without a gnutls crypto backend; the guest will hang at boot"
else
  say "5/6 build skipped"
  [ -x external/orchard/qemu/build/qemu-system-aarch64 ] || todo+=("build Orchard: external/orchard/scripts/build.sh --enable-gnutls")
fi

say "6/6 checks"
if [ -e "$MESA/dzn_icd.json" ]; then echo "Mesa prefix: $MESA"
else
  echo "Mesa prefix missing ($MESA/dzn_icd.json)."
  todo+=("private Mesa: download the kisak-mesa 26.2.5 .debs (see tools/mesa-prefix.sh) and run tools/mesa-prefix.sh <dir>")
fi
if command -v apfs-fuse >/dev/null; then echo "apfs-fuse: $(command -v apfs-fuse)"
else
  todo+=("apfs-fuse (needed once, to extract AVPBooter): git clone --recursive https://github.com/sgan81/apfs-fuse && cd apfs-fuse && mkdir build && cd build && cmake .. && make && sudo make install")
fi
[ -S /mnt/wslg/runtime-dir/wayland-0 ] || echo "note: no WSLg socket; the reims window (GG_WINDOW=1) needs WSLg"

cat <<NEXT

== next steps
$(for t in "${todo[@]+"${todo[@]}"}"; do echo "  - $t"; done)
  1. tools/prepare-image.sh        fetch the macOS 27 image (~33 GB) and patch AVPBooter
  2. tools/gg provision            configure the guest once (single-user, ~3 min)
     tools/gg provision finish     rerun until it seals the layer (first boot converges in 6-10 min)
  3. GG_WINDOW=1 tools/gg verbose  boot (REIMS_VGPU_PROTOCOL_CAP defaults to 237); desktop in ~20-25 min
Add $REPO/tools to PATH to type plain 'gg'.
NEXT
