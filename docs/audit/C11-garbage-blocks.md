# C11: rainbow/red garbage blocks at the menu bar and the Dock (regression in 89e87cc)

Orchard `gg-macos27` @ `89e87cc` (QEMU pid 102314, started 13:01:40). Evidence: live log
`/tmp/reims-vgpu-fail.log` (68k lines), `~/gg/run/gg27/logs/reims-vgpu-fail.6af5dfe-final.log`,
`shots/dzn-89e87cc-{1,3..15}.png`. Read-only diagnosis. The VM was not touched: the running QEMU
has no `REIMS_VGPU_*` dump env, so no texture dump was possible without a restart.

## Verdict

- **Culprit: `2e00fe4` (RGBA16Unorm). The XR10 commits (`ae97018`, `89e87cc`) are cleared.**
- **The garbage is made inside the menu-bar layer** by the pass that samples the 384×384 buffer
  texture (ref 233, converted on the CPU from 16 to 8 bits). The display composite then adds the
  128×128 native texture (ref 234) on top. The exact bad input inside that pass is not proven
  yet: three hypotheses, ranked below, and one boot can tell them apart.

## Timeline: when the garbage first appears

Each screenshot's file time is converted to the log's `t` (ms since QEMU start). For example,
13:18:21 is t ≈ 1 001 000.

| Shot | Wall | t (s) | Menu bar / Dock left |
|---|---|---|---|
| -3 | 13:16:18 | 878 | black, nothing drawn |
| — | — | **979.551** | `buftex_rgba16unorm_converted ref=233 buf=232 384x384 to=rgba8` |
| — | — | **979.559** | `sampled_rgba16unorm_native site=linear_memo 128x128` → `lin_serve_fmt task=1 ref=234 … Rgba16Unorm` |
| -4 | 13:18:21 | 1001 | **solid red box** under Apple/Finder/File; **red box** over the left of the Dock |
| -7 … -13 | 13:25 – 13:42 | — | red/magenta/orange smooth field with a blue/green/black faceted trapezoid, 146 px wide in both places |
| — | — | 2450.7 | first XR10 mapping RT/store (`xr10_2p_mapping_rt mid=243`) |
| -14, -15 | 13:45 – 13:47 | — | the same block, partly overdrawn (146×38) |

What this shows:

- **XR10 path is innocent.** The blocks exist 24 minutes before the first XR10 mapping RT
  (t = 2450 s). The `src=rgba8` on `xr10_2p_mapping_store` appears 2× in this run, only for the
  task-15 widget surfaces (mid 243/245), and those widgets render correctly.
- **Nothing refuses any more.** Compared with 6af5dfe, the slugs that disappeared are all the
  old refusals: `buftex`, `draws_skipped`, `linux_clear_store`, `draw_encode_fail`,
  `rt_resolve`, `scanout_paint_mapping`. No new failure slug appeared. So the garbage comes from
  draws that "succeed" but that never ran before, because C10's refusal skipped them.

## Where the garbage is made

```
33414 m2v_store_gva gva=0x1da4000 1920x128 pipe=2 tex_ref=76 load=1 ok=1 rgb_nz=131492 max_rgb=97  mean_rgb=21
33482 sampled_texture_narrowed reason=buftex_narrowed ref=233 fmt=0x6e 384x384 to=rgba8 lost=clamp_to_unit_and_256_levels
33483 buftex_rgba16unorm_converted ref=233 buf=232 384x384 to=rgba8
33486 color_input_mrt mask=0x03 pipe=2 colors=2 1920x128
33487 fetch_snapshot copy 0 1920x128 R16G16B16A16_SFLOAT op=clear
33487 m2v_store_gva gva=0x1da4000 1920x128 pipe=2 tex_ref=76 load=2 ok=1 rgb_nz=16888 max_rgb=255 mean_rgb=17
33489 lin_serve_fmt task=1 ref=234 gva=0x230c000 128x128 fmt=0x6e bytes=… Rgba16Unorm
```

- **The menu-bar layer (gva 0x1da4000, ref 76) is stored twice.**
  - The normal text pass (`load=1`) peaks at `max_rgb=97`.
  - The pass that samples ref 233 (`load=2`, Clear; a framebuffer-fetch MRT, `mask=0x03`) writes
    **16 888 saturated pixels** (`max_rgb=255`). That is ≈ 132×128, the Apple + app-name glass box.
  - So the red is already in the **layer** before any composite runs. It also sits **under** the
    menu text in the shots.
- **The second stage: the display composite.** The draw trail shows pipe 143 (`fw=238`, the
  generic two-texture layer shader) with `smp=[b:f91:128x128, t:f97:1920x128]`: ref 234 as
  `R16G16B16A16_UNORM` together with the menu-bar layer. The Dock block is the same width
  (146 px) and appeared at the same moment, so it is **inferred** to come from the same
  material.
- **The trapezoid looks like a data map, not an image.** It is a 4-facet pyramid on a hue-wheel
  background: a gradient or shape lookup (**inferred**: the glass shape or normal map) shown as
  colour. Also, saturated per-channel bands are what an over-range RGBA16Float colour looks like
  after display clamping (values > 1, inf or NaN).

## What is verified correct

- **Ref 234's layout.** `declared_extent_is_a_sub_window task=1 ref=234 extent_length=174592`
  equals 131072 + 32768 + 8192 + 2048 + 512: five tight mips, with level 0 at offset 0 and pitch
  1024. The native rail (`texture_view.rs:1029-1040`, `load_tight_linear_rgba_with` `:1300+`)
  returns level 0 verbatim as `Rgba16Unorm`. The Vulkan side maps that to
  `R16G16B16A16_UNORM`, 8 bytes per texel (`reims-vgpu-vulkan/src/pixel.rs:446,1017`). Draw
  sampled images have 1 mip (`pools/*:mip_levels(1)`), so no uninitialised mip levels can be
  sampled. Byte order: little-endian u16 R,G,B,A, which is Metal's order.
- **The CPU arm.** `RowToRgba8::Rgba16Unorm` (`pixel_format.rs:3752`) and
  `unorm16_to_unorm8` are correct, and bpr 3072 = tight.

## Hypotheses (ranked)

1. **The 8-bit narrowing of ref 233 breaks a precision lookup** (`buftex_narrowed
   lost=…256_levels`).
   - The 384×384 RGBA16Unorm is almost certainly a glass refraction or shape LUT, and Apple
     binds it natively at 16 bits.
   - A shader that rescales a LUT delta (for example `(v-0.5)*k`, or a division by a
     near-zero channel) amplifies the 1/255 steps into over-range output. That fits "smooth
     shape + saturated hue bands".
   - This is the only lossy step that 2e00fe4 introduced into this pass.
2. **The pass's framebuffer-fetch inputs are wrong.**
   - Pipe 2 / 243 is an MRT with a memoryless `s1` (ref 75) read back through `color_input_mrt`.
   - Its first `fetch_snapshot` is `op=clear`, and `frag_color_unwritten mask=0x02` shows that
     some draws never write `s1`.
   - This pass had never executed before 2e00fe4, so the fetch emulation of a memoryless second
     attachment is untested here. Zero alpha read back then becomes a divide-by-zero, giving
     inf/NaN, which shows up saturated.
3. **Stale buffer bytes for buf 232** (read from guest RAM while a host resident is newer).
   - Least likely: the content is structured, not zero.
   - The buffer has no producer line in the log.

Ref 234 is unlikely to be the root cause: its upload is exact. It would only *display* a wrong
input if hypothesis 1 or 2 holds upstream.

## Fix spec

1. **Native RGBA16Unorm on the buffer-texture rail** (fixes hypothesis 1; it is what Apple does,
   `newTextureWithDescriptor:offset:bytesPerRow:`).
   - In `runtime/draw/mod.rs:1620` `load_buffer_texture_rgba`, when
     `fmt == MTL_FORMAT_RGBA16_UNORM` and `native_uploads_asking_host().unorm16`, copy the rows
     straight through (`tight` = w×8). Return them with
     `SampledByteFormat::from_source(TexelLayout::Rgba16Unorm, 0x6e)` instead of RGBA8.
   - Callers: `vulkan.rs:1636` and `vulkan.rs:1690` (`resolve_sampled_source`), plus
     `mod.rs:4157`. They must carry the layout instead of assuming RGBA8. That is the same
     contract as `load_linear_texture_host`.
   - Keep the `RowToRgba8` arm only as the fallback for hosts without the filter.
   - About 40–60 lines. Risk **medium**: the buffer-texture return type is RGBA8-only today, so
     every caller has to learn the layout. The cache keys must include the layout.
2. **If hypothesis 2 holds after fix 1:** make a memoryless colour attachment that is read
   through `color_input_mrt` snapshot after each draw that writes it (not only at the
   pass-start `op=clear`). The place is `backend/vulkan/engine/exec.rs:6375`
   (`fetch_snapshot_format`) and the copy at `:6577`. About 20–40 lines. Risk **medium-high**:
   this is the hot path.
3. **Interim guard (optional):** gate the new buffer-texture arm behind
   `REIMS_VGPU_BUFTEX_RGBA16UNORM` (default on) so a boot can toggle it. About 5 lines, low risk.

## Discriminating test (one boot, with a tester)

- **Boot A: hypothesis 1.** Boot with fix 1 alone and run `tools/gpu-score.sh`.
  - Look for `m2v_store_gva gva=<menu layer> … load=2` with `max_rgb` < 255, or no saturated
    run.
  - Expect no red box at the next screendump.
- **Boot B: hypothesis 2.** If the red box persists, boot with `REIMS_VGPU_PLACED_DUMP=<dir>`,
  `REIMS_VGPU_PLACED_PROBE_TASK=1`, and `REIMS_VGPU_PLACED_PROBE_SIZE=2048`.
  - Read the `.nan.pgm` of the 1920×128 store. NaN/inf pixels confirm hypothesis 2.

## Open questions

- What ref 233 and ref 234 are semantically (glass shape LUT vs normal map). Answering that
  needs `guest RE` on WindowServer / QuartzCore's glass material.
- Why the Dock block sits over Finder + Launchpad (146 px). The **inferred** answer is that it is
  the frontmost app's (Finder) glass lens, the same material as the menu bar's.
