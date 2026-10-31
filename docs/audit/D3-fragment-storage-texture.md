# D3: fragment-stage storage texture (pipe 99, `inplace_copy_lph`)

Sources: host log `/tmp/reims-vgpu-fail.log` (Dozen run, Orchard `gg-macos27` @02c9b85), SPIR-V dump
`~/gg/run/gg27/spirv-dump-02c9b85/pipe99-fragment-593a8888c545f23f.{spv,air}`, Apple GPUTask pseudo-C
(`<RE corpus>/ParavirtualizedGraphicsGPUTask.c/`), Orchard `reims-vgpu/crates/reims-vgpu/src`, metal2vulkan @4bd73b0.
Read-only. Anything not proven by a log line or a code line is marked **inferred**.

## 1. What pipe 99 does

The log has one `linux_m2v_draw` line (it dedupes) and 39 `draws_skipped` lines, all for pipe 99 on task 1:

```
18858 OFF spirv_dump pipe=99 stage=fragment words=350 path=.../pipe99-fragment-593a8888c545f23f.spv valid=valid t=815559
18860 linux_m2v_draw reason=draw_prepare_texture_access_unsupported stage=fragment index=3 texture_ref=47 binding=483
      access=storage pipe=99 task=1 geom=1920x1080 vtx=24 ... colors=[s0:r73:mid3:...:1920x1080:fmt=0x73:l1:s1,
      s1:r15:mid0:...:1920x1080:fmt=0x73:l1:s0] ... ftex=[i3:r47,i5:r25,...]
18861 linux_clear_store draws_skipped ... refused_by=draw_prepare_texture_access_unsupported mid=3 1920x1080 load=0x1 store=0x1
18862 draw_encode_fail reason=draw_vk_nothing_stored class=no_metal pipe=99 task=1 di=3/11
```
35 skips are `model_pipeline=ready` and 4 are `retired`. They land on mid 3 and mid 26, both 1920x1080 RGBA16F.

Shader. The AIR strings name the function `inplace_copy_lph`, with `air.compile.framebuffer_fetch_enable`, a stage-in
`half4 color`, `float2 texcoord0_0`, and `texture2d<half, write> tex [[texture(3)]]` carrying `air.raster_order_group`.
The access is **`access::write`**, not read_write. `spirv-dis` shows:

| id | decl | meaning |
|---|---|---|
| %20 | `SubpassData`, set 0 binding 192, `InputAttachmentIndex 0` | framebuffer fetch of colour 0 |
| %23 | `Image 2D Rgba16f` (sampled=2 → storage), binding 483 (= texture base 480 + index 3) | `tex` |
| %17 | `v2float` Location 1 | `texcoord0_0` |

Body: `%40 = OpImageRead %20 (0,0)` (the current pixel of colour 0) → half → `OpImageWrite %23, uint2(u16(clamp(texcoord0, 0, 65535))), %40`.
The shader has **no colour output**. It is a gather: each covered pixel of the render target is copied to
`tex[texcoord]`. Coordinates come from a varying, not from `gl_FragCoord`, so the write is a scatter into a
different image. It is not programmable blending.

Is `tex` the same image as the target? **No** (at the ref level). The attachments are r73 (mid 3) and r15. `tex` is r47.
The next time task-1 r47 shows up in the log, 474 ms later, it is a **64x64 RGBA16F guest-backed texture at gva
0x27c000**. It has never been written (`lin_rung_guest_blank`), and pipe 2 then samples it into mid 3:
```
19001 OFF lin_rung_guest_blank task=1 ref=47 gva=0x27c000 64x64
19002 OFF lin_serve_fmt task=1 ref=47 gva=0x27c000 64x64 fmt=0x73 ... Rgba16Float
19004 OFF draw_trace ... pipe=2 mid=3 ref=73 ... smp=[...,b708:bytes:64x64,...] frefs=[...,4:47,...]
```
The same pattern appears for r100 (64x64, also blank). These are **inferred** to be pipe 99's destinations, because refs get
reused. The likely use is a 64x64 backdrop/luma sample for a glass or tint layer (**inferred**). A gather that is
dropped leaves those textures blank (zero), and the layer that samples them renders black or transparent.

Collateral damage, which is the bigger cost: the dropped draw is `no_metal`, so the GPU-resident chain of the
full-screen target is abandoned and recovered through the CPU:
```
18863 writeback_chain_rgba reason=resident_chain_abandoned_cpu_recovery cause=no_metal mid=3 1920x1080 fmt=0x73 t=815611
18864 OFF render_flush_lease_declined reason=read_target_texel_not_four_bytes format=R16G16B16A16_SFLOAT mapping=3
      ... next pass: ld=mapping_host_cache_bytes (instead of surface_resident)
```
Totals: 24 abandonments on mid 3, 20 on mid 26, 1 on mid 2, which roughly matches the 39 pipe-99 refusals. This is the
"fragment read-write texture" cause the earlier audit recorded (D-render.md:185).

## 2. Apple's host

`-[PGDeserializerRenderDecoder decodeSetFragmentTexturesWithCursor:]` @0x10001FF40 reads (first, count), checks that
`first+count ≤ maxFragmentTextures` (otherwise it throws "Invalid texture count"), resolves each ref with
`-[_PGDeserializer getTextureForReference:]` @0x100028B58 (a plain delegate lookup with no usage or access check), and
calls `-[MTLRenderCommandEncoder setFragmentTextures:withRange:]`. Access is a property of the shader argument and
not of the bind. The texture's usage is the guest's value, passed through as-is:
`newTextureDescriptor(PGSerializedTextureDescriptor2)` @0x1000460D4 → `validateMTLTextureUsage` @0x100065C84 (it
rejects only unknown bits, mask `~0x1C037`) → `setUsage:`. The guest therefore creates r47 with ShaderWrite.
Metal on AGX honours `raster_order_group`. Nothing else is special.

## 3. Orchard

Refused before any resource is resolved, in two places:
- `runtime/draw/vulkan.rs:7531-7559`, a pre-check loop calling `spirv_bind::first_non_sampled_texture_descriptor`
  (`runtime/spirv_bind.rs:2492`). This is the site that fired (binding=483 is the raw reflected binding).
- `runtime/draw/vulkan.rs:8104-8128`, the same refusal inside `push_tex`.
- Slug: `backend/vulkan/engine/draw_preparation.rs:135,306`. Its doc says "the render engine currently exposes guest
  textures as sampled images".

The render descriptor layout knows only STORAGE_BUFFER, SAMPLED_IMAGE, SAMPLER and INPUT_ATTACHMENT
(`backend/vulkan/engine/exec.rs:2950-2985`). The pool already has STORAGE_IMAGE (`desc_arena.rs:162`).

The pieces needed for a fix already exist on the compute side:
- `stage_texture_raw::<VulkanStage>(…, is_storage)` (`runtime/compute_exec/vulkan.rs:922`)
- `spirv_bind::storage_image_access` (spirv_bind.rs:713) returns WriteOnly/ReadWrite
- `ComputeStorageImageResource` (`engine/types.rs:1674`), with seed bytes, `destination`, and `residency`
- storage-image pools and descriptor writes (`engine/exec_compute.rs:415-447, 891`)
- Rgba16Float storage already runs on Dozen (`compute_linux storage_format_specialize ... engine=Rgba16Float`).

Framebuffer fetch (binding 192 = `COLOR_INPUT_BINDING`+0) is already supported (`color_input_mrt` lines, exec.rs:2976).

What Dozen needs (from vulkaninfo on kisak dzn, and the run's own `vk_features`):

| Need | Dozen (RX 6750 XT) |
|---|---|
| `fragmentStoresAndAtomics` | **true** (log: `fragment_stores_and_atomics=true`) |
| storage RGBA16F, declared format | true (`shaderStorageImageExtendedFormats`; compute already uses it) |
| `rasterizationOrderColorAttachmentAccess` / `fragmentShaderPixelInterlock` | **absent** (lavapipe has both) |
| `attachmentFeedbackLoopLayout` | false |

On Vulkan, the storage image must be a separate VkImage with STORAGE (and TRANSFER_SRC/DST) usage, in layout GENERAL
for the whole pass. It must be transitioned **before** `vkCmdBeginRenderPass`, since it is not an attachment and needs no
self-dependency. After the pass it needs a barrier `FRAGMENT_SHADER/SHADER_WRITE → TRANSFER/TRANSFER_READ` (or
→ FRAGMENT_SHADER/SHADER_READ when the next sampler reads the resident).

Ordering: for pipe 99 the raster-order group only orders overlapping fragments that scatter to the same `tex` texel.
Dozen has no interlock, so the last write wins in an undefined order. That is acceptable, because both values come from
the same frame. There is no feedback loop: the read of colour 0 goes through the existing input-attachment path and the
write goes to another image.

If a future pipe aliases the storage texture with a bound attachment, which the log has not shown so far, Dozen
cannot do it in place. Either copy the target to a scratch storage image before the pass and bind the scratch, or end
the pass, bind the target as storage only, and restart. Until such a pipe is seen, refuse it by name.

## Fix list for the porter

1. **Allow fragment storage textures in draw preparation** (~60–90 lines, low risk). In `vulkan.rs:7531` and
   `:8104`, stop refusing `Storage` in the fragment stage when `fragment_stores_and_atomics` is true. Keep refusing
   `Unknown` and the vertex stage. Stage the bind with `stage_texture_raw(..., is_storage=true)` and record its access
   via `storage_image_access`. Add `storage_images: Vec<…StorageImageResource>` to `DrawRequest` (reuse
   `ComputeStorageImageResource`). Seed from guest bytes even for write-only access: the scatter covers only part of
   the image.
2. **Engine support** (~150–220 lines, medium risk). In `exec.rs:2950`, add a STORAGE_IMAGE `BindingSig` with stage
   FRAGMENT. Acquire the image from the existing storage pool, upload the seed, and transition it UNDEFINED/
   TRANSFER_DST→GENERAL before BeginRenderPass. Write the descriptor, and after EndRenderPass add the barrier above.
   Read back and write back to the guest gva (0x27c000-style, 64x64 = 32 KiB) through the compute
   `ComputeImageDestination`/residency rail, so that pipe 2's `route=bytes` sampling sees the data.
3. **Colour write mask for an output-less fragment** (~15–25 lines, low risk). `inplace_copy_lph` writes no Location
   0/1 output. In Vulkan, the attachment values are then undefined, and Dozen could clobber mid 3. Mask each slot for
   which the fragment SPIR-V declares no Output location, next to the `FragmentStage::Absent` rule at exec.rs:3400.
   On AGX the tile keeps its contents (**inferred**). Also confirm that `first_unsupported_vulkan_interface` accepts a
   fragment shader with zero outputs.
4. **Alias guard** (~15 lines, low risk). If the storage ref resolves to the same resource or mapping as a bound colour
   attachment, refuse with a new slug `fragment_storage_aliases_attachment` instead of creating a feedback loop.

Expected result: 39 skipped draws become drawn, the about 45 `resident_chain_abandoned_cpu_recovery` lines on mid
2/3/26 go away, and r47/r100 stop being `lin_rung_guest_blank`.

## Open questions
- Is r47 at t=815559 the same object as the 64x64 r47 at t=816033? To confirm, add `texture_ref` dims and format to the
  refusal line, or log the storage bind once fix 1 lands.
- Does the 64x64 destination explain the black wallpaper, or only a glass tint? Compare a screendump after the fix.
- Pipe 99's second incarnation (`fhea3ja…`, task 15, t=1139090) is a different shader with `EarlyFragmentTests`.
  It is not refused, so it is outside this scope.
