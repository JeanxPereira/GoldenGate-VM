# Status

Measured on a Ryzen 7 5700X (16 threads), 16 GB RAM, Radeon RX 6750 XT, Windows 11, WSL2 Ubuntu
24.04 (`.wslconfig`: `memory=11GB`, guest `RAM=6G`, 12 vCPUs), Dozen from kisak Mesa 26.2.5,
protocol rung 237. Guest: macOS 27.0 (26A428) from `cirruslabs/macos-golden-gate-vanilla:27.0`.
Last updated 2026-10-31.

## Works

- Full boot chain under TCG: patched AVPBooter → LLB → iBoot → XNU → launchd → WindowServer.
  Kernel log on the serial with `gg verbose`; single-user root shell with `gg single`.
- Data volume mounts without the "unencrypted data volume" panic (Apple vendor capability on the
  virtio-blk transport).
- SSH into the guest (`gg ssh`), with the key installed by `gg provision`. Slow to come up: from
  ~5 min with the GPU driver kept down (`REIMS_VGPU_PROTOCOL_CAP=4`) to ~30-35 min with the GPU
  path busy.
- The ParavirtualizedGraphics protocol at rung 237: version negotiation, device info, info channel
  (heap and compute-pipeline queries), texture descriptor v2, IOSurface textures, heaps.
- The desktop is drawn through Metal → AIR → SPIR-V → Vulkan → D3D12: menu bar, wallpaper (the
  Aerial still), Dock with icons, widgets (calendar, Photos), windows with text.
- Typical timings (window mode): Keyboard Setup Assistant at ~15 min, Dock ~21 min, wallpaper
  ~17-27 min, widgets ~30 min. The guest runs at load 300-900 throughout; this is an emulated
  12-core arm64 machine.

## Does not work yet / known issues

- **Liquid Glass.** Glass surfaces (Dock plate, widgets, alert and button backgrounds) draw as
  flat or smoothed backgrounds without blur or refraction. The blur pyramid stays empty; the
  latest cause found is the imageblock slice write in metal2vulkan storing one texel per tile
  (fixed in metal2vulkan `6b7ea34` / Orchard `6c2f813`, `5f8b985`). **The pinned submodule commits
  include that fix but it has not been booted yet;** the last booted state is Orchard `20d4616`.
  See `docs/audit/C13`-`C21` and `D2`.
- **Mouse not validated.** The guest side works (QEMU's USB tablet is the active handler; pointer
  injection moves `NSEvent.mouseLocation`), but moving the pointer through the WSLg window has not
  been measured end to end. The guest cursor is a hardware plane and does not show in captures.
  Keyboard: macOS shows "Keyboard Setup Assistant" for the QEMU keyboard. See `docs/audit/C12`.
- **WSLg window.** `GG_WINDOW=1` shows the screen live. WSLg sometimes stops mapping new windows
  (seen after plugging/unplugging a monitor); `gg winprobe` detects it, and only `wsl --shutdown`
  clears it. In window mode the HMP `screendump` comes out black; headless mode screendumps fine.
- **Freezes and panics, rare.** One `pmap_enter(): over-unwire` guest panic (the guest rebooted by
  itself) and one WindowServer freeze on `IOFence` timeouts at ~17 min were seen once each.
- **llvmpipe/lavapipe** abort with `LLVM ERROR: Cannot emit physreg copy instruction` ~3 min
  into a boot; use Dozen (`GG_VK=dzn-kisak`, the default).
- **Do not run** `gg hmp 'info virtio-status ...'`: it segfaults QEMU.

## Host log slugs worth knowing

The host GPU log is `/tmp/reims-vgpu-fail.log` (`gg up` copies earlier ones to
`$GG_HOME/run/<img>/logs/`). `tools/gpu-score.sh` summarises one or two logs.

| Slug | Meaning |
|---|---|
| `draws_ok` / `draws_fail` (in `exec_indirect*`) | draws executed vs refused per command buffer |
| `linux_m2v_draw reason=...` | a draw dropped while preparing it (missing texture, unsupported access, ...) |
| `m2v_store_gva ... rgb_nz=` | how many non-black texels a render pass wrote back to guest memory |
| `level_content` / `glass_sampler_census` | content of each mip level of a glass blur chain; sampler used by the glass shaders |
| `compute_imageblock_admitted` / `_dispatched` / `_region_write` | compute kernels with `[[imageblock]]` state (glass blur) |
| `packet_unadmitted` | a command the admission ledger has no decision for (protocol gap) |
| `spirv_debug_names_stripped` | long SPIR-V debug names removed (Dozen crashes on names of 256+ bytes; repro in `tools/shaderlab/names`) |
| `released_write_after_release` | the guest wrote memory after the host released it |
| `IOFence: blocking wait timed out` (guest serial) | the guest waited too long for a GPU stamp |
