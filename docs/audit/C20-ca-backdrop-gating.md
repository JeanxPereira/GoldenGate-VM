# C20: what decides whether CoreAnimation re-captures a glass backdrop, and which device checks it makes

This is a read-only RE pass over the guest's QuartzCore, 26A428 arm64e.

- Sources:
  - `<RE corpus>/QuartzCore.i64` (18 919 functions, C++ names intact). It was built with
    `gq.py dsc ... /System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore --name QuartzCore`.
  - The cache it was built from is in `<RE corpus>/dsc/` (all subcaches, 8.4 GB). They were copied from the Preboot
    cryptex `os.dmg` (`disk.raw` p2 v1).
  - Metal is `Metal.i64`. The guest plugin is `AppleParavirtGPUMetalIOGPUFamily.c/` (MP).
- Debug-option layout: the 291 boolean CA_* options sit at `ca_debug_options` = 0x1E645EB54 + index. The index is
  the position in `debug_option_env_vars` @0x1E082DB50. Examples:
  - 27 `CA_PRINT_BACKDROPS` → 0x1E645EB6F
  - 72 `CA_DISABLE_BACKDROP_CACHE` → 0x1E645EB9C
  - 274 `CA_DISABLE_BACKDROP_COMPUTE` → 0x1E645EC66
  - 275 `CA_BACKDROP_COMPUTE_AND_RENDER_FALLBACK` → 0x1E645EC67

**Short answer.** Nothing in QuartzCore turns the glass into a flat material because of a Metal capability.
- The device probes (section 1) only pick shader variants, pixel formats and the compute-vs-render capture path.
  Both capture paths produce a real backdrop.
- Re-capture is driven by **damage**: WindowServer passes the dirty region into the render update, and
  `Update::invalidate_backdrops` intersects it with each backdrop's bounds.
- A backdrop buffer that already exists is **kept**. Only the invalidated shape is re-captured (section 2).
- The first invalidation after a capture is **deferred and throttled**.
- So "rendered once before the wallpaper, never again" means one of two things: no invalidation ever reached the
  Dock backdrop, or the deferred one was never honoured. It does not mean a capability fallback.
- The one switch that bypasses all of this is the `CA_DISABLE_BACKDROP_CACHE` environment variable. It is read
  with `getenv`, so it also works on customer builds.

## 1. Device probes: `CA::OGL::new_metal_context` @0x18B22F070

QuartzCore caches every answer in the Metal context:
- ctx+0xE8D is a u16 of family and format bits.
- ctx+0xE8F is a byte of shader-feature bits.

The line numbers are in that function's pseudo-C.

| Op/type (QC check) | Name (ctx bit) | Payload (how the guest answers) | Apple host behaviour | Orchard handler (host lever) | Status | Seen in logs | Priority |
|---|---|---|---|---|---|---|---|
| `supportsFamily:` 1001/1002/1003/1004/1005/1007/1009 (:739-765) | +0xE8D bits 0-6 = Apple1/2/3/4/5/7/9 | MP does not override `supportsFamily:`. `-[_MTLDevice supportsFamily:]` @0x18D549734 searches the device family vector at +0x288..+0x290. Metal fills that vector from its profile tables. **Inferred:** the input is `featureProfile` @0x210D1 (6 if key 28 bit 0, else 10001) | key 28 bit 0 means Apple5 (not sent at L1) | key 28 bit 0 | inferred | - | P2 |
| family bit uses | Apple1 gates the `supportsRasterOrderGroups` query (:816) and the 64-bit formats. Apple2/Apple3 gate XR10 format mapping (sub @0x18B03F700: 550/552/554 → 0 when absent). Apple3 or `fd0 > 3` decides `+0xE90 = 128` (:893) | - | - | - | no flat fallback found | - | P3 |
| `vendorName` contains "intel" (:785, :845) | +0xE8C = 4 or 1. +0xE8D bit 14 = !(intel or Apple1) | MP `vendorName` @0x210B6 = "Apple" | - | none | OK | - | P3 |
| `isFramebufferReadSupported` (:790) | bit 10 | MP @0x221D3 → **key 7** | - | key 7 = 1 | OK | - | P3 |
| Apple2 and not virtualized (:800-805) | bit 9 | `CADeviceIsVirtualized` (below) | - | none | - | - | P3 |
| `supportsRasterOrderGroups` (only if Apple1) | bit 11 | MP implements only `areRasterOrderGroupsSupported` @0x22CA4 (tile shaders and **key 25**). The `supportsRasterOrderGroups` selector is answered by the Metal base class (**inferred**) | - | keys 23-26 withheld | off | - | P3 |
| `supportsYCBCRFormats12` / `PackedFormats12` | bits 7/8 | Metal base | - | - | - | - | P3 |
| `requiredLinearTextureBytesPerRowForDescriptor:` (128x128 RGBA8, :861) | bit 15 = (result == 0) | Metal and MP | - | key 13/40 | - | - | P3 |
| `supportsNativeHardwareFP16` (:868) | +0xE8F bit 0 | MP @0x221F7 → **key 9** | - | key 9 | OK | - | P3 |
| `supportsTileShaders` (:873) | +0xE8F bit 1 | MP @0x22B9E = byte 27 and **key 23** | - | key 23 withheld → 0 | off. CA has `CA_DISABLE_TILE_SHADERS`, so this is an optional fast path | - | P3 |
| `supportsSIMDGroup` / `ShuffleAndFill` / `Reduction` (:878-892) | +0xE8F bits 2/3/4 (bit 6 always set) | Metal base and MP → **key 33 bits 6/8** | - | key 33 = 0xB → off | off | - | P3 |
| `supportsCorrectTextureUsageBits` (:895-916) | +0xE8F bit 5 | Asked **only when virtualized**; otherwise forced to 1. MP @0x23668 = **byte 50** | - | rung 237 → 1 | OK. The only reader is the purgeable-buffer recycler @0x18B24397C (`tbz #5`, `setPurgeableState:`). It is **not on the glass path** | - | P3 |
| `supportsMemorylessRenderTargets` (:332-349) | ctx+0x1080 bits 3/4 (memoryless offscreens on unless `CA_ENABLE_MEMORYLESS=0`) | MP @0x2341D **always 1** | - | not host-controlled | live. Memoryless offscreens are the transient targets Orchard has to emulate | - | P2 |
| `CADeviceIsVirtualized` block @0x18B2CA668 | global `is_virtualized` | `MGGetBoolAnswer("IsVirtualDevice")`. On ChipID 0x8103 only, `kern.hv_vmm_present` is used instead | Same on a real Apple VM | none | live (see section 2) | - | P3 |

There are no `isLowPower` / `isRemovable` reads in the context path: the two call sites @0x18AFE096C/0x18B2A74E8 are
outside the backdrop code and were not traced. QC references neither `readWriteTextureSupport` nor any
argument-buffer, lossless-compression or threadgroup-memory selector.

## 2. The backdrop path

| Op/type | Name | Payload | Behaviour (pseudo-C) | Lever | Status | Seen | Priority |
|---|---|---|---|---|---|---|---|
| dirty region | `CARenderUpdateSetRegionAndInvalidateBackdropsWithForceOption` @0x18B1C63DC | WindowServer passes a CGSRegion | `set_shape(region)`, then `invalidate_backdrops(update, shape, 0, 0, force)`, then `add_backdrop_invalidations` | WindowServer only | - | - | P1 |
| invalidate | `Update::invalidate_backdrops` @0x18B1BAD08 | shape ∩ `state+112` (the backdrop bounds) | Empty intersection → nothing happens. If `state+152 != update seed (+240)`: set `state+156 = 1` (pending) and schedule the next update at `min(update+72, state+160 + backdrop+124)`. That is a **throttled, deferred** refresh. Otherwise the shape is unioned into the group shape (`group+16`), followed by `invalidate_rasterized_backdrops` | `CA_DISABLE_THROTTLE` / `CA_BACKDROP_THROTTLE_CONSTANT` (**inferred** link) | - | - | P1 |
| deferred refresh | `Update::add_backdrop_invalidations` @0x18B060B88 | - | Acts only if `state+156 == 1 && state+152 == update+240`. It then re-invalidates the full `group+648` shape and adds it to the update dirty shape | - | - | - | P1 |
| WindowServer clip | `CARenderUpdateClipBackdropInvalidations2` @0x18B1C3808 | WindowServer region | Invalidations outside the clip are **parked** in `group+696` and replayed on a later update | - | - | - | P2 |
| cache knob | `Update::invalidate_backdrop_shapes` @0x18B1BB664:434 | - | `if (BYTE8(xmmword_1E645EB94) == 1)` (= `CA_DISABLE_BACKDROP_CACHE`) → union the backdrop full shape into the update dirty region **on every update** | env | lever | - | **P0** |
| capture | `CA::OGL::capture_backdrop` @0x18B0753A8:1404-1500 | BackdropBuffer `group+32` | `v188 = CA_DISABLE_BACKDROP_CACHE`. The surface is released if its size, format (the `0x38000` bits) or context changed. A new `image-capture-backdrop` surface sets `v188 = 1` (full capture). Otherwise only the damaged shape is re-captured into the **kept** buffer | env | - | - | P1 |
| compute vs render | `MetalContext::capture_backdrop_surface_compute` @0x18B24BAD4 | src Surface | Returns 0 (render path) if the source is not a simple single-image blend or if the destination is protected, and **`if ((src+0x12C & 0x200) && is_virtualized) return 0`** | `CA_DISABLE_BACKDROP_COMPUTE`, `CA_BACKDROP_COMPUTE_AND_RENDER_FALLBACK` | render path on this VM for flagged surfaces | C17: no 1920x128 compute | P3 |
| surface alloc | `MetalContext::create_surface_with_properties` @0x18B243CA4 | - | usage = 5, plus 2 (unless memoryless/flag), plus **0x10000** (prop bit 23), plus **0x4000** (prop bit 25). Calls `setCompressionType:1`. On nil it logs "Failed to allocate %dx%d surface texture" (@0x18B244DA8) | byte 50 (C18) | fixed at 237 (usage 0x10005 decoded) | 0 at 206/237 | done |
| process kill-switch | `+[CABackdropLayer initialize]` @0x18AFEA7B8 | - | `disable_backdrops = [NSUserDefaults boolForKey:@"CADisableBackdrops"]` | defaults | should be unset | - | check |

How options are read: `init_debug` @0x18AFEEF48 calls `CADefaultsGetFloat` @0x18B338040 for each option:
- **`getenv(name)` first.**
- The `com.apple.coreanimation` defaults dictionary is used only when `CADeviceHasInternalBuild`.

So on this guest only **environment variables** work, and they must be in **WindowServer's** environment, because
WindowServer is the render server. `CA_PRINT_BACKDROPS` (byte 0x1E645EB6F) turns on the backdrop logging in
`capture_backdrop`, including "Backdrop compute not supported, falling back to render path".

## Ranked: what most likely keeps the glass flat, and what to change

1. **No invalidation reaches the Dock backdrop, or the deferred one is never honoured** (section 2 rows 1-3). This
   matches C14/C17: the one 1920x128 capture happened before the wallpaper, and the Dock is only composited afterwards.
   - Guest debug lever (no host change): put `CA_DISABLE_BACKDROP_CACHE=1` and `CA_PRINT_BACKDROPS=1` into
     WindowServer's environment.
   - If the glass then picks up the wallpaper, the bug is upstream, in the damage path. Candidates:
     - the WindowServer region;
     - IOSurface seeds or completion events that tell WindowServer the wallpaper surface changed (**inferred**);
     - the deadline in `update+72` (see C15) never firing.
   - How to set the variable, **inferred, unverified**: a `gg provision` LaunchDaemon (RunAtLoad) that runs
     `launchctl setenv CA_DISABLE_BACKDROP_CACHE 1` in the system domain before WindowServer starts, or before it is
     restarted. The WindowServer plist is on the sealed volume.
   - Size: ~10 lines of provisioning. Risk: low. Costs GPU time every frame.
2. **Memoryless offscreens** (MP always reports support). They are live in CA's offscreen and vibrancy paths.
   - `CA_ENABLE_MEMORYLESS=0` in the same environment rules out Orchard's transient-target emulation as the reason a
     capture lands nowhere.
   - Size: one line. Risk: low.
3. **The virtualized compute gate**. It forces the render capture path. It is not a flat fallback, and the host
   cannot change it. `CA_DISABLE_BACKDROP_COMPUTE=1` makes that the path for every surface, which makes runs comparable.
4. **Capability bits** (key 7, 9, 23-26, 33, 28 bit 0, byte 50). No reader found on the glass path, except shader
   variant choice. Changing host keys for glass is **not** recommended.
5. `CADisableBackdrops`: read `defaults read -g CADisableBackdrops` (and the `com.apple.WindowServer` /
   `com.apple.dock` domains). It should be unset.

## Open questions

1. Which family list does Metal build for `featureProfile` 6? Next query: decompile `-[_MTLDevice initLimits]`
   @0x18D5448FC and find where +0x288 is filled. Or ask the guest with `osascript -l JavaScript`
   (`$.MTLCreateSystemDefaultDevice().supportsFamily(1005)`).
2. What sets `state+152`? That is the seed a deferred backdrop waits for. Next query: xrefs to the BackdropState
   writes at +152/+160 (candidates: `BackdropLayer::update` @0x18B20D828, `finalize_backdrop_invalidations` @0x18B1BC278).
3. Does WindowServer (SkyLight) call `CARenderUpdateSetRegionAndInvalidateBackdrops*` with the wallpaper damage?
   Next query: `gq.py dsc ... SkyLight` and xrefs to that import. Strings already seen in SkyLight:
   "Has WindowServer-Aware Backdrops?", `menubar.desktop.capture.backdrop`, `kSLSMenuBarReduceTransparency`.
4. What is surface flag `+0x12C & 0x200` (the virtualized compute veto)? It is not established.
