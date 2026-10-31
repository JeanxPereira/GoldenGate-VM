# D6: NaN in the icon shape mask (pipes 27/30/32, R16F 56×90)

Run: Orchard `e118d61`, fork `23f192a`, Dozen (kisak Mesa 26.2.5, RX 6750 XT). Host log
`~/gg/run/gg27/logs/reims-vgpu-fail.e118d61.log` (the shape pass is lines 8440–8476, task 3; the
probe latched at pass 160, so the first ref 20 reading is `stage=sampled` at line 8492).
Retranslations: `/tmp/d6/` in WSL (made with the release CLI, without `--storage-input-output16`).

## Result in one line

**The vertex shader is not the source.** The NaN comes from the accumulator s1 as pipe 32 reads
it back through framebuffer fetch. Orchard keeps every colour target in `GENERAL`. Dozen maps
that layout to D3D12 `(DIRECT_QUEUE_)COMMON`, and in pipe 32 it reads s1 through an SRV while the
same draw keeps s1 bound as an RTV and writes it. D3D12 does not define that combination.

## 1. Pipe 30 VS (`9e3b88c0`): translated faithfully, no out-of-bounds index

- On the current fork the translation is 7568 bytes (VS) and 2640 bytes (FS), the same sizes the
  runtime logged (`linux_m2v_async done pipe=30 … spv=7568` / `spv=2640`). The capabilities are
  `Shader Float16 Int16 Int64`. VariablePointers is gone, and so is the 16-bit IO: Location 3 is
  `float`, written with `OpFConvert`.
- The binary search compared against the AIR (`llvm-dis`): the AIR's `%37 = gep %seg, 1` becomes
  index phi `%116`, which starts at `ulong 1`. `mid = base + (n>>1)` uses a 64-bit add with an
  emulated carry, the select matches the AIR's `%55`, and the result is `%148`. P0 is
  `seg[%148 + u64max]`, that is `found − 1`. **`found ≥ 1` on every path** (it starts at 1 and
  only moves up), so the previous record is index ≥ 0. Index 0 is the header record, and reading
  its `p3` is the AIR's own behaviour (`gep %39, -1, 4`). No guard is dropped, the index never
  goes huge, and the u64 wrap `1 + 0xFFFF…F = 0` is exact. Orchard queries `shaderInt64`
  (`caps/device_features.rs:219`).
- The winding sign (`%280`, ±1 half) is computed only on the drawn path. The undef `%44` reaches
  the output only where `gl_Position = (−2,−2,0,1)`, which is off screen. Every corner of a piece
  shares one segment, so the four corners take the same branch.
- **Decisive:** the shape output is **byte-identical** before and after 543bb56/08c8f98.
  `shots/icons/00000-…-ref20-….ppm` (eadb240) and `placed-dump-e118d61/00000-…-ref20-….ppm` both
  have md5 `3f5c0f71…`, and both have `nz=4702/5040`. Rewriting the pointer phi and widening the
  IO changed nothing, so neither was the cause.

## 2. Where the NaN can and cannot come from

- Pipe 30 only rasterizes trapezoids from the curve to `maxX+0.5`, within each piece's y-range
  ±0.5. Even a fragment that produced NaN could not reach a texel outside that union.
- Pipe 32 (`fe0e63b4` / runtime `fd61e65a`) computes `s0 = a·sel(fract(|acc|))`, and NaN appears
  only if `acc` is NaN/±inf. `a` is a uniform and cannot be NaN, because 424 texels come out
  finite.
- The probe says `nan=4616`, 86 texels are non-zero and finite, and **338 are exactly 0**. If s1
  started at 0, every texel outside the trapezoid union would read `acc=0` and give s0=0. The
  right contour spans rows 15–73, so the union is at most about 64×56 ≈ 3600 texels. There are
  more NaN texels (4616) than the union can hold, so **NaN sits where pipe 30 never drew**. The
  starting value of the accumulator, or the way pipe 32 reads it, is wrong.
- A bad clear value cannot explain it. The clear uses `att.clear_color`
  (`runtime/draw/mod.rs:2726-2735`, load `2->2`, store always STORE in `caches.rs:2215`). A
  NaN/inf clear would make **every** texel NaN, and 424 are finite. The corruption varies across
  the image, which looks like block-wise compression or stale-memory content, not a single value.

## 3. Dozen's framebuffer-fetch path (Mesa `src/microsoft/vulkan`, current main)

- `unified_color_layout()` is on by default (`caches.rs:1427-1449`), so every colour attachment
  rests in `GENERAL`. A fetched attachment is `GENERAL` too (`color_layout`, `caches.rs:654`).
- `dzn_image.c` `dzn_vk_layout_to_d3d_layout`: `GENERAL` → `D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_COMMON`.
  The legacy path maps it to `RESOURCE_STATE_COMMON`, with the comment `/* YOLO! */`.
  `dzn_rendering_attachment_initial_transition` moves the attachment into that layout. Then
  `dzn_CmdBeginRendering` calls `OMSetRenderTargets` on it.
- In the MS enhanced-barriers spec, `COMMON`/`DIRECT_QUEUE_COMMON` admit `SHADER_RESOURCE`,
  `COPY_*` and `UNORDERED_ACCESS`. `RENDER_TARGET` is allowed only for simultaneous-access
  textures, and Dozen sets `ALLOW_SIMULTANEOUS_ACCESS` only for `VK_SHARING_MODE_CONCURRENT`
  (`dzn_image.c:263-266`). Dozen lowers the subpass input with `nir_lower_input_attachments` to a
  texel load from an SRV of the **same** resource. Pipe 32 reads s1 that way while writing s1.G
  (mask 0x4) and s0. The record-1 clear goes through `ClearRenderTargetView` in `RENDER_TARGET`
  and then transitions back to `COMMON`.
- On RDNA2 with DCC/fast-clear, RTV writes and clears in a layout the driver treats as
  "common/decompressed", read back through an SRV, can return metadata-dependent garbage block
  by block. That matches what we see: finite values only along the right edge, NaN almost
  everywhere else. **Inferred, not measured.**
- Pipe 30's blend is not a suspect: R16G16_FLOAT blending is mandatory in D3D12 and the blend tags
  were verified in D4.

## Most likely cause

The pass uses a framebuffer-fetch feedback loop (s1 is a colour attachment and an input attachment
in pipe 32, and every target rests in `GENERAL`). Dozen cannot express that legally in D3D12, so
the accumulator s1 reads back as garbage/NaN outside the texels it wrote uncompressed. This is a
host/driver-path fault, not a translator fault.

## Fix (sized)

0. **Measure first, one boot, no code:** `REIMS_VGPU_COLOR_GENERAL=off`, which takes non-fetch
   passes out of `COMMON`. If `nan=` drops, the layout is confirmed. Optionally add a NaN-mask
   PGM to `placed_probe.rs` (~10 lines) to show the NaN outside the trapezoid union directly.
1. **Orchard, ~100–150 lines, medium risk (recommended):** on a device without a real feedback
   loop (Dozen; gate on the driver, or on `attachmentFeedbackLoopLayout == false`), break the
   loop. Each draw is already its own render-pass record (`exec/mod.rs:5235-5290`). Before a
   record that fetches attachment N, `vkCmdCopyImage` that attachment into a scratch twin (56×90,
   cheap). Add the twin to the pass as an **input-only** attachment in
   `SHADER_READ_ONLY_OPTIMAL`, and point the `COLOR_INPUT_BINDING+N` descriptor at it
   (`exec.rs:4403`). Keep the colour attachments in `COLOR_ATTACHMENT_OPTIMAL` for that pass. Each
   fragment reads only its own pixel and pipe 32 runs once per pixel, so the snapshot gives the
   same result as Metal's fetch.
2. **Alternative in the fork plus Orchard, ~60 + ~60 lines:** emit `[[color(n)]]` reads as
   `texelFetch(sampled, ivec2(FragCoord))` when a flag is set, and have Orchard bind the same
   snapshot as a sampled image. This touches more code than option 1.
3. **Check:** ref 20 `nan=0`, with the interior ≈1 (even-odd). Pass 160's ref 35 RGB `nan` (4505)
   should also go to 0. It is downstream of this mask.
