# Architecture

macOS 27 arm64 runs on an x86-64 PC by emulating Apple's *virtual* Mac (the `vmapple` machine
that Virtualization.framework exposes), not a physical Mac. Every guest instruction is
translated by QEMU's TCG; the GPU is paravirtual, so the guest never needs an Apple GPU.

```
 Windows 11 host                         WSL2 (Ubuntu 24.04)                       macOS 27 guest
 ───────────────                         ───────────────────                       ──────────────
                                         QEMU (external/orchard/qemu)
                                           -M apple-vm  (vmapple, TCG, 12 vCPUs)
                                           AVPBooter (patched) → LLB → iBoot → XNU  ◄── boot chain
                                           vmapple-virtio-blk (root, aux)            ◄── APFS volumes
                                           virtio-net (slirp, :2222 → :22)           ◄── sshd
                                           reims-vgpu PCI device  ◄──── MMIO / FIFO / shared pages ────  AppleParavirtGPU kext
                                             │                                                          ▲
                                             │  ParavirtualizedGraphics (PG) protocol, rung 237         │ IOGPU user client
                                             ▼                                                          │
                                         reims-vgpu (Rust, external/orchard/reims-vgpu)          AppleParavirtGPUMetalIOGPUFamily
                                           decodes FIFO commands, ExecIndirect segments            (Metal plugin: PGSerializer)
                                           (render / compute / blit / info), objects, IOSurfaces    ▲
                                             │ AIR (Metal shader IR) from the guest                 │ Metal API
                                             ▼                                                      │
                                         metal2vulkan (external/metal2vulkan)               WindowServer, CoreAnimation,
                                           AIR → SPIR-V                                         apps
                                             │
                                             ▼
                                         Vulkan  ──  Mesa "Dozen" (dzn) from a private
                                                     kisak Mesa 26.2.5 prefix
                                             │
 D3D12 driver (AMD/NVIDIA)  ◄──────────── /usr/lib/wsl/lib (dxcore / d3d12 passthrough)
 GPU (tested: RX 6750 XT)
 WSLg window (optional)     ◄──────────── reims window (winit, Wayland/X11 via WSLg)
```

## Pieces

| Layer | What it is | Where |
|---|---|---|
| Guest driver | `AppleParavirtGPU` kext (kernelcache) + `AppleParavirtGPUMetalIOGPUFamily` Metal plugin. The plugin serialises Metal objects and command buffers; the kext moves them through a FIFO and shared memory. | inside macOS 27 (26A428) |
| PG protocol | Apple's ParavirtualizedGraphics host/guest protocol. The guest asks for protocol rung 252; Orchard upstream speaks 62, this fork 237 (`REIMS_VGPU_PROTOCOL_CAP`). | [`docs/audit/`](audit/README.md) documents it command by command |
| reims-vgpu | Host side of the protocol (steelbrain's reims-vgpu, as vendored by Orchard, with the macOS 27 work on top): FIFO and ExecIndirect decoding, object/resource tracking, IOSurface mapping, display, and a Vulkan renderer. Built as a static library and linked into QEMU. | `external/orchard/reims-vgpu` |
| metal2vulkan | Translates the guest's AIR shaders (LLVM bitcode) into SPIR-V. Wired in through a Cargo `[patch]` to `../../metal2vulkan`, i.e. `external/metal2vulkan`. | `external/metal2vulkan` |
| QEMU | Upstream QEMU with Orchard's `vmapple` changes and the macOS 27 fixes (1 MiB config region, unimplemented MMIO at 0x30240000, ascending PCI capability list, Apple vendor capability on the virtio-blk transport so the Data volume mounts "unencrypted"). | `external/orchard/qemu` |
| Vulkan driver | Mesa's Dozen (Vulkan on D3D12), from a private prefix so the system Mesa stays untouched. llvmpipe/lavapipe abort a few minutes into the boot. | `$GG_HOME/opt/mesa-kisak` |
| Tooling | `tools/gg` boots, provisions and drives the VM; boot-args are injected at the iBoot→XNU handoff (0xE0A00000) through QEMU's gdbstub, because iBoot filters NVRAM boot-args under full security. | `tools/` |

## Disk layout

`img/gg27/disk.raw` (converted from the published ASIF image, read-only) ←
`img/gg27/configured.qcow2` (built once by `gg provision`: Spotlight and triald disabled, SSH key,
telemetry daemon; then made read-only) ← `run/gg27/overlay.qcow2` (throwaway, recreated on every
boot). A crash costs only the overlay.
