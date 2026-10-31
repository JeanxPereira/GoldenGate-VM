#!/usr/bin/env bash
# Maintainer step, run once after the two forks are pushed: turn the entries of .gitmodules
# into real submodules pinned at the commits listed in external/PINNED, then commit.
#
#   scripts/add-submodules.sh && git commit -m "external: add orchard and metal2vulkan submodules"
#
# Orchard's reims-vgpu/Cargo.toml carries
#   [patch."https://github.com/steelbrain/metal2vulkan.git"]
#   metal2vulkan = { path = "../../metal2vulkan" }
# which, from external/orchard/reims-vgpu/, resolves to external/metal2vulkan: the two
# submodules must stay side by side under external/.
set -euo pipefail
cd "$(dirname "$0")/.."
grep -v '^#' external/PINNED | while read -r path commit branch _; do
  [ -n "$path" ] || continue
  url=$(git config -f .gitmodules "submodule.$path.url")
  if [ -e "$path/.git" ]; then
    echo "$path: already cloned"
  else
    rmdir "$path" 2>/dev/null || true
    git submodule add -b "$branch" "$url" "$path"
  fi
  git -C "$path" fetch -q origin "$branch"
  git -C "$path" checkout -q "$commit"
  git add "$path"
  echo "$path -> $(git -C "$path" rev-parse HEAD)"
done
git submodule status
