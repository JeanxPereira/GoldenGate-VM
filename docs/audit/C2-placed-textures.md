# C2: heap-placed textures (serializer cmd 0x15 / 0x38)

Follow-up to `C-objects-memory.md` (rows 8/9, 0xD, HeapTextureSizeAndAlign). Trigger: Orchard
`b02319b` started answering the heap size/align query. Apple sources are the 26A428 pseudo-C
dumps; Orchard paths are relative to `reims-vgpu/crates/reims-vgpu/src/` on `gg-macos27`
HEAD `6fc0f4f`. Log numbers come from `/tmp/reims-vgpu-fail.de0e7ed.log` (the run the brief
calls `/tmp/reims-vgpu-fail.log`; it has since been rotated) and from `/tmp/reims-vgpu-fail.ea4dfb5.log`.

| run | type-8 objects with cmd 0x15 (`rt_child_texture_base opcode=Some((21,…`) | `rt_wrong_type` | `heap_texture_query ok` | `heap_query_no_metal_device` | `heap_query_unknown_pixel_format` (0x226) |
|---|---|---|---|---|---|
| ea4dfb5 | 0 | 0 | 0 | 106 | 0 |
| de0e7ed | 414 lines (165 distinct refs, tasks 4/11/13) | 165 | 109 (108 × usage 0x5, options 0x20) | 0 | 40 |

## 1. Guest side: which path a non-zero size/align answer opens

- `-[AppleParavirtDevice heapTextureSizeAndAlignWithDescriptor:]` (plugin 0x2235F) caches one
  answer per descriptor. It gets the answer from the info encoder (`heapTextureDescriptorSizeAndAlign:sizeAndAlign:`
  0x32DD → host tag 22), or else from IOConnect 0x10C, and then rounds it with
  `heapBufferSizeAndAlignWithLength:options:`.
- `-[AppleParavirtHeap newTextureWithDescriptor:]` (0xEFFA) and `…:offset:` (0xF168) use that size and
  alignment to sub-allocate (`newSubResourceWithLength:alignment:options:offset:` /
  `newSubResourceAtOffset:…`). They then build `-[AppleParavirtTexture initWithHeap:resource:offset:length:descriptor:]`
  (0x91BA), which calls `-[PGSerializer newTextureWithDescriptor:heap:offset:useOffset:allocator:]`
  (0xC99C) with **useOffset = 1**.
- Before `b02319b` the reply was never written. The 16-byte answer was then stale or zero, so the sub-allocation
  failed and the client fell back to `device newTextureWithDescriptor:`, which is a type-2 normal texture
  (**inferred**: the fallback lives in the client framework, not in this plugin).
  After `b02319b` the same textures arrive as **MTLHeap placement textures**.
- Wire form (0xC99C): **object type 8** (the serializer/child texture). Its descriptor is one serializer op:

| off (record) | field | example (task 4 ref 20) |
|---|---|---|
| 0 | cmd = 0x15 (0x38 = wide/`TextureDescriptor2`, len 0x44) | `15000000` |
| 4 | len = 0x3C | `3c000000` |
| 8 | own object ref (`newTextureRef`) | `14000000` = 20 |
| 12 | **heap ref** (`-[AppleParavirtHeap heapRef]` 0xF2DE = an object-list ref) | `12000000` = 18 |
| 16 | `PGSerializedTextureDescriptor`, 32 B: `+0` u8 type\|0x10 fbOnly\|0x20 drawable\|0x40 gpuOptimized, `+1` usage, `+2` u16 pixelFormat, `+4` w, `+8` h, `+12` d, `+16` u16 mips, `+18` u16 samples, `+20` u16 array, `+22` u16 resourceOptions, `+24` u64 protection (`newTextureDescriptor` GPUTask @0x100045DA8) | `42 05 1900`, 56×90, R16Float, usage 5, opts 0x20 |
| 48 | u8 bit0 useOffset (the other bits are not written) | `01` |
| 52 | u64 offset in the heap | 0, 0x4000, 0x8000, 0xC000 seen |

  This is a **placed texture**: a full descriptor, a backing heap and an offset. It is **not** a view. A view
  (cmd 7/8/0x1B) carries a parent texture ref plus format/type/level/slice range/swizzle and no
  descriptor. A buffer texture (cmd 9/0x37) carries a buffer ref, an offset and bytesPerRow. Formats seen: 0x73
  RGBA16Float, 0x41 RG16Float, 0x50 BGRA8Unorm, 0x19 R16Float, all usage 0x5 (ShaderRead|RenderTarget),
  private storage, 1 mip, 1 sample, 2D. Many refs share one heap (for example heap 0x2E holds about 25 textures), and offsets
  are 16 KiB steps. Heap memory is reused over time.

## 2. Apple's host

- `createSerializerTexture` @0x100049F54 switches on the serializer cmd: 1→`sub_10004A810`,
  7/8/0x1B→views, 9→`sub_10004B238`, 0x34→`sub_10004AD24`, 0x37→`sub_10004B9E8`, **0x15 (21)→`sub_10004C19C`**,
  **0x38→`sub_10004C894`**.
- `sub_10004C19C` @0x10004C19C reads 0x34 bytes (`sub_1000502F8`) and resolves the heap with
  `sub_10005A27C(HIDWORD(word0))`, which is a resource-table lookup and then `-getHeap` ("Failed to get base heap").
  It then calls `newTextureDescriptor` and `validateTextureDescriptorForDevice`, and **overrides the texture's options with the heap's**
  (`setResourceOptions: heap.resourceOptions`). It then calls `[heap newTextureWithDescriptor:offset:]` with the offset at +0x2C, **always**,
  ignoring the useOffset bit. If a placement exists it checks `gpuResourceID` ("Failed to correctly place texture").
  It then calls `[heapResource newChildTextureResourceWithTexture:]`.
- The result is an ordinary `MTLTexture`, used as a render target, sampled or blitted exactly like a type-2
  texture. No view constructor is involved. It answers `getTexture` and can be the parent of a 7/8/0x1B view.

## 3. What the heap is

- It is created by the kext: `AppleParavirtResource::setupWithArgs` (kc 0xFFFFFE00086AD5EC) case 9 →
  `allocateHeapHandle` (0xFFFFFE00086AE3CC) → `AppleParavirtResourceHeap::addObject(type **13 / 0xD**, ref,
  16 B)`. The descriptor is packed as **`{u32 virtualPage (task GVA >> 14) @0, u64 length @4, u8 flags @12}`**,
  where flag bit0 = storageMode ≠ shared and bit1 = hazard-tracked. The buffer descriptor (type 1) is ordered `{u64 len, u32 page, u8 flags}`,
  so **the two orders differ**. The guest plugin (`-[AppleParavirtHeap initWithDevice:descriptor:]` 0xE8C2)
  rounds the size up to `vm_page_size`. The pages are IOGPU resource memory in the task VA, the same allocator as buffers.
- The host side is `createHeap` @0x1000439A8 (16-byte read) → `+newHeapResourceWithTask…` (type 13 only).
  `PGDetachHeapResource` @0x10000C300 uses `MTLHeapTypePlacement` with storage shared. It runs `detachBacking`, and then
  `ensurePhysical` @0x10000C6E8 calls `replaceBackingWithRanges` with the **guest pages** (zero-copy).
  `PGLegacyHeapResource` @0x10000BCF8 uses a private host heap and copies from guest pages on `prepareInEncoder` @0x10000C0A8.
- So the backing is guest RAM at `page<<14 + offset`, but **in Metal's private GPU layout**. The guest
  marks these textures private (opts 0x20), so it never reads them by CPU. Metal leaves an aliased placed
  texture's contents undefined until it is written. **A host-only image per placed texture is therefore a faithful
  model.** Mapping it onto `heap GVA + offset` with a linear row pitch would invent a layout that
  Apple does not have, and it buys nothing. Orchard never needs the heap's extent to execute these textures.

## 4. Orchard

What exists today:
- `decode_heap_texture` resource/mod.rs:4454 (layout correct, pinned by `reims-vgpu-wire/src/ops/heap_texture.rs`).
- Compute only: compute_exec/mod.rs:1678-1890 keeps a host resident under
  `ComputeStorageResidencyKey::heap` (model/state.rs:2205).
- Draw sample path: `resolve_sampled_source` draw/vulkan.rs:1281 → the type-8 entry goes to the view chain →
  `decode_texture_view_hop_reasoned` → `res_texture_view_opcode opcode=0x15` (61 sample lines).
  `resolve_texture_view_reasoned` texture_view.rs:345-373 also hops through any type-8 parent.
- Render target: `resolve_render_target` render_target.rs:1299 tries transient (cmd 1/52) and then buffer
  texture (9/0x37), logs `rt_child_texture_base`, and falls to `WrongType` at :1338 (165).
- The type 0xD heap itself is never decoded. That is fine and not needed.

### Change list for the port (in order)

| # | Change | Where | Size | Risk |
|---|---|---|---|---|
| 1 | `heap_texture_render_target` rung: type 8 + `descriptor_is_heap_placement` → decode → `ResolvedRenderTarget{mapping_id 0, gva 0, w,h, format = transient_host_format(fmt), sample_count, transient:false, placed:true}`. Refuse mips>1, samples>1, array>1, non-2D, zero extent, and level≠0 with named causes. Insert before `buffer_texture_render_target` at :1310. | render_target.rs | ~70 | low |
| 2 | Add `placed: bool` to `ResolvedRenderTarget` (:378) and `ColorRtRequest` (draw/mod.rs:525). In the attachment builder (draw/mod.rs ~2646) a placed attachment gets **no** `memoryless_actions` and **no** CPU seed (Load with no resident = clear to 0). At the writeback (draw/mod.rs:2222) it returns "not landed, by design" as a route, **not** `lost`. | draw/mod.rs | ~40 | med |
| 3 | `TargetIdentity::Placed{task_id, texture_ref, w, h, format}` (types.rs:1886 and its match arms :2041-2219, draw_execution.rs:366). `is_transient()` stays false, so `set_sole_copy` (images_and_registry.rs:2052) pins it, because it is the only copy. `render_chain_identity`/`transient_identity` (vulkan.rs:10155/10182) and the `c0_transient` chain rail (vulkan.rs:9044) take `placed` like transient (no guest Store, no readback), and the secondary-MRT arm (vulkan.rs:6822) does the same. | backend/vulkan, draw/vulkan.rs | ~80 | med |
| 4 | Sample rung at the top of `resolve_sampled_source` (beside the buffer-texture check, vulkan.rs:~1293): a placed ref → `SampledSourceRequest::Target(Placed{…}, translate(fmt).vk)` if the registry holds it, else zero bytes (undefined contents, as in Metal). XR10 0x226 → RGBA16Float as in item 1. | draw/vulkan.rs | ~50 | low |
| 5 | View chain: in `resolve_texture_view_reasoned` (texture_view.rs:359), stop when the type-8 parent's opcode is not 7/8/0x1B and return it as the base, so a view over a placed (or 9/0x37, or 1/0x34) texture resolves through items 1/4 with the view's format/swizzle. This also fixes the opcode-9 parents from C §4. | texture_view.rs | ~25 | med (chain-cap tests) |
| 6 | Retire `Placed` on delete of the type-8 ref and on task teardown, next to `retire_linear_resident` model/state.rs:4021/4038 (refs are recycled; w/h/format in the key covers a different shape). | model/state.rs, engine | ~40 | low |
| 7 | Unify with compute: compute_exec/mod.rs:1795 should look up/serve the same `Placed` resident instead of a separate `ComputeStorageResidencyKey::heap`, or else draw→compute and compute→draw content is lost. | compute_exec | ~80 | med-high |
| 8 | 0x226/0x227 in the Linux size rule (`heap_texture_size_and_align` backend/heap_placement.rs:149, `block_geometry` has no 2P entry). Plane 0 has 4 B/px. Plane 1 is the 1 B/px alpha, but `xr10_planes.rs:60` records that the guest sizes plane-1 rows with plane 0's bpp. Use `p = align256(w·4)`, `size = align16K(align16K(p·h) + p·h)`, `align = 16 KiB`. Over-sizing is harmless, because Orchard does not alias. The exact Metal answer is **unverifiable here (inferred)**. | heap_placement.rs | ~20 + test | low |

Items 1-4 together clear the 165 `rt_wrong_type` and the 61 `res_texture_view_opcode` (0x15) lines.
Check in the porter: `render_target_bpp(0x19)` admits R16Float, because the transient rung already admits 0x41 and 0x73.

## Open questions
1. Do any placed textures get written by compute and then sampled by draw in this boot? There are 0 `compute_stage_tex heap` lines in de0e7ed, so item 7 can wait.
2. Is the client fallback to type 2 on a zero size real (§1)? This needs the CoreAnimation/Metal client frame.
3. If the guest places a 0x226 texture after item 8, it arrives as cmd 0x15 with fmt 0x226. Items 1/4 must host it as RGBA16Float, as `transient_host_format` does. Nothing samples its planes separately.
