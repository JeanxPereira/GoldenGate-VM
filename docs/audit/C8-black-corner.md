# C8 — black 192×256 block at the top-left corner

Orchard `gg-macos27` @ `a61708e`. The evidence comes from the live VM on 30/10, with the host log
`/tmp/reims-vgpu-fail.log` (64 970 lines) and a screendump taken at 14:1x guest time.

## Verdict

**This is not the cursor or an overlay plane.** It is the **wallpaper**. The still Golden
Gate image is decoded in 512×512 HEIC tiles, and a compute kernel converts each tile into one
4096×2160 BGRA IOSurface (mapping 176). Orchard **dropped the dispatch for tile (0,0)**:
its kernel was still being translated (`compute_vk_translate_pending`). That tile stays zero in
guest memory. The wallpaper layer is opaque, so it composites as (0,0,0,1).

The geometry matches exactly. The 4096×2160 image is scaled to cover 1920×1080 (factor 0.5,
crop 64 px per side). Tile (0,0), texels 0..512 × 0..512, then lands at screen x −64..192,
y 0..256. The visible part is **192×256**.

## Evidence

| Check | Result |
|---|---|
| QMP screendump | Pure black at exactly x<192, y<256. Alpha cannot be seen there. |
| Guest framebuffer pages (`xp` on mid 3 / mid 74, first page) | Bytes 0x000–0x5FF (192 px × 8 B RGBA16F) are `0000 0000 0000 3c00` = (0,0,0,1.0). From 0x600 on, wallpaper. **The black is in the guest-visible FB, not in the QEMU console.** |
| QEMU HW cursor | `qemu_console_set_cursor` (`qemu/hw/display/reims-vgpu-mmio.c:819`) is a console cursor and never enters the screendump. The guest has `CursorPlane=1`. The cursor window (`kCGCursorWindowLevel`, 28×40 at 5,5) is offscreen. **Hypothesis refuted.** |
| op8 swap | `CmdDisplaySwapMapping` names one mapping and carries no plane list (`runtime/drain/mod.rs:1205-1235`). No layer can land at (0,0). |
| CGWindowList (guest, JXA) | No window or layer of 192×256 at the origin. |
| Wallpaper decode | `mapping=176 4096x2160 fmt=BGRA`. Each tile is a `ycbcr_2p_staged fmt=0x21e 512x512` source, then compute (`task=10`, `bind=481`, viewed as `1024x2160 RGBA32Uint`), then `mapping_write full_tight_direct mid=176`. **39 writes = 40 tiles (8×5) minus 1.** |
| The lost tile | `t=1066989 linux_m2v_async queued pipe=10 stage=Kernel tg=[32,32,1]`, then `compute_vk_translation_wait waited_us=2009 outcome=still_pending`, then `compute_linux_m2v reason=m2v_translation_pending_at_sync_boundary pipe=10 model_pipeline=retired`, then `compute_record reason=compute_vk_translate_pending task=10 pipe=10 kind=DispatchThreadgroups`. The translation finished at `t=1067031` (**39 ms late**). |
| Earlier boots | `shots/dzn-e118d61-6.png` has the same 192×256. In `-7` the wallpaper was black, so the block was hidden. |

## Rows

| Op/type | Name | Payload | Apple host behaviour | Orchard handler `file:line` | Status | Seen in logs | Priority |
|---|---|---|---|---|---|---|---|
| ExecIndirect compute 200–230 | DispatchThreadgroups on a cold kernel | kernel AIR, tg 32×32×1, dst IOSurface BGRA | `PGResourceManager::createObject<MTLComputePipelineState>` @0x10003DAB8, via `newComputePipelineStateWithDescriptor` @0x10003D0A0, compiles **synchronously** when the pipeline object is created. A dispatch never finds a pipeline still being built and is never dropped. | `runtime/compute_exec/vulkan.rs:485` (`PENDING_TRANSLATION_WAIT` = 2 ms), `:497-528` (wait), `:643-670` (returns `TranslationPending`, dispatch lost) | **divergent**: drops guest work | 5× `compute_vk_translate_pending` (task 5 ×4, task 10 ×1) | **P0** |
| Admission / park | Lease of a pipeline the guest already deleted | — | n/a (synchronous) | `runtime/drain/mod.rs:2495-2512` (withdraw/ready by `translating`), `:2797-2840` (`pump_translations`) | **partial**: the lease was `retired` (the guest sent DeleteObject after it encoded the dispatch), so the packet ran without waiting for the translation (**inferred** from `model_pipeline=retired`) | idem | P0 |
| Cursor glyph / show | op 0x04 / 0x05 | — | `-[PGFIFO CmdDisplayCursorGlyph…]` @0x222F6EC28 hands the glyph to `cursorGlyphHandler`. It never touches the framebuffer. | `runtime/drain/mod.rs:6529-6546` | OK (not involved) | 0 | — |

## Fix (ranked)

1. **Never drop a dispatch for `TranslationPending`. Wait for the translation, as Apple does at
   creation.** In `runtime/compute_exec/vulkan.rs:643`, when `translate_kernel_waiting_briefly`
   still returns `TranslationPending` after 2 ms, either:
   - poll for a second, longer budget (≈250 ms, logged as `compute_vk_translation_wait_long`)
     until `linux_m2v_async done`, or
   - translate inline: call the synchronous path that the async worker uses, keyed on the same
     `(air, local_size)`, so the cache is shared.

   Only after that fails return `MetalFailed`. Size: ~20 lines. Risk: **low–medium**. The wait
   holds the BQL (a cold kernel took 40 ms here, once per kernel). Hard boot TCG already
   tolerates that. Keep a ceiling, so a translation that hangs cannot freeze the VM.
2. **The same treatment on the render path** (`runtime/draw/vulkan.rs:811`,
   `draw_prepare_{fragment,vertex}_translate`). It is the same race, with 4 draws lost in this
   log, among them pipe 223 at `t=1432500`: the **menu bar** draw onto the 1920×128 target. That
   is a candidate for "the menu bar disappears after login". After that, pipe 223 also falls into
   `draw_prepare_texture_resolve_missing` (buftex 384×384 RGBA16Unorm, `texture_ref=215`), which
   is a second problem. ~15 lines, same risk.
3. **(Structural, optional.)** In `drain/mod.rs:2495-2512`, a lease that is `retired` but whose
   ref is in `translating` should park the packet like a live lease does. Then item 1 becomes a
   safety net only. ~10 lines. Risk: medium (the retire/park interaction in `reims-vgpu-core`).

Expected test: the Golden Gate wallpaper with no block in the corner, 40 (not 39)
`mapping_write full_tight_direct mid=<wallpaper>`, and `compute_vk_translate_pending` = 0.

## Open questions

- Does the menu bar come back with item 2 alone, or does the `buftex_load` 384×384 also need a
  fix? It needs its own audit.
- Why 2 ms was enough in the measured case (44 µs) but not here (39 ms): the translator queue
  was congested by the HEIC kernels arriving together. A larger budget only partly solves it;
  item 1 should not depend on timing.
