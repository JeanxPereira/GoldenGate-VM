# Family D: render-encoder sub-opcodes 0–166

Apple: GPUTask `-[PGDeserializerRenderDecoder decodeWithHeader:withIterator:]` @0x100025C60, which
dispatches into the `decode…WithCursor:` methods at 0x10001BA84–0x100025934.
Guest emitter: `PGSerializerRenderCommandEncoder` (AppleParavirtGPUMetalIOGPUFamily.c, `getCommandBytes:forCommand:` size/opcode pairs).
Orchard (`gg-macos27` @ea4dfb5), paths relative to `external/orchard/reims-vgpu/crates/`:
- `exec` = `reims-vgpu/src/runtime/exec/mod.rs` (router `handle_render_record` :4031, fence :2862,
  barrier :2900, residency :2926, stream-state :3029, binds :3221, pass :3542, draws :3887,
  unsettled arms :4133–4407, indirect draw :5677)
- `pdec` = `reims-vgpu-protocol/src/decode/render.rs` (the 45 "settled" rows)
- `spi` = `reims-vgpu/src/runtime/decode/render_spi.rs` (the 31 "unsettled" rows)
- `wire` = `reims-vgpu-wire/src/ops/{render,render_pass,tile}.rs`

Logs: `/tmp/reims-vgpu-fail.5b042af.log` (newest full boot, 8.2 MB). The current `/tmp/reims-vgpu-fail.log`
is a short run that contains none of the target reasons. **Orchard keeps no per-opcode render
census** (`walk_records_render`=19 289 is the only total). The "Seen" column therefore uses proxy
counters from `store_routes` and fail lines. `render_unimplemented` (the unknown-opcode report,
`reims-vgpu/src/runtime/exec/report.rs:84`) appears in **no** log, so every opcode the guest sent
in these boots reached a known arm.

## Framing and encoder lifetime (applies to every row)

- Each record has a `u32 opcode` and a `u32 total_len` that includes the 8-byte header. The payload is
  `total_len-8`, read through a bounded sub-cursor. Apple ignores any bytes after the fields it reads.
- An opcode > 166, or one of 26 and 30–100 **in the main loop**, falls out of the switch and throws
  `UnrecognizedCommand`, which faults the whole command buffer. Orchard logs the record once and continues.
  That is more lenient than Apple and is harmless.
- **Pass descriptor**: the encoder is created only when segment header `var2==0`. `decodeRenderPassDescriptor:`
  @0x100025A44 reads records 30–36 and stops at **26**, which must come last. Records 30–36 are valid only
  in that prefix. 26 is not accepted mid-stream.
- **Continuation**: `decodeSegmentWithHeader` @0x1000292B0 reuses the previous decoder, including its
  live encoder and all bindings, when `var2!=0` and the segment type matches. `endEncoding` runs only
  when `var3==0`. Bindings therefore persist across chained segments. Orchard counter: `seg_chain_none`=604,
  `seg_chain_*` other = 0, so no chained render segment appeared in this boot.
- References: `getTextureForReference:`/`getBufferForReference:` (@0x100028B58/AD0 → `PGResourceManager::getObject`
  @0x10005A1AC → `sub_10005A27C`) map **ref 0 to nil** and look up the live object for each command,
  with no memo and no type or format gate (`PGResource::getTexture`). A non-zero ref that is unknown throws
  "Failed to create Texture".
- **Serializer version 8**: Orchard serves `DEVICE_INFO_SERIALIZER_VERSION = 8` (`reims-vgpu/src/model/regs.rs:1292`).
  The guest turns this into `supportsCorrectBaseVertex` (`PGSerializer initWithDevice…` @0xBEAA: `a5 >= 8`) and `supportsOpenGL` (>= 6). See rows 10/11/28/29 and 138–152.

## Table

Payload sizes are `total_len-8` (Apple `readBytes` size, or the guest `getCommandBytes` size).
"var" means `first:u32, count:u32` followed by entries.

| Op | Name (MTLRenderCommandEncoder call) | Payload | Apple host behaviour | Orchard handler | Status | Seen (proxy, 5b042af) | Pri |
|---|---|---|---|---|---|---|---|
| 0 | drawPrimitives:vertexStart:vertexCount: (64) | 0x14 | @0x10001BA84; throws on nil pipeline ("Attempting to draw with nil pipeline state"); validateMTLPrimitiveType | pdec:336 → exec:3887 | OK | draws: `stream_draws_*` total 556 streams (shape not split) | P2 |
| 1 | drawPrimitives (16-bit) | 8 | @0x10001BC54 | pdec:336 → exec:3887 | OK | in draw total | P2 |
| 2 | drawPrimitives…instanceCount: (64) | 0x1C | @0x10001BE28 | same | OK | — | P2 |
| 3 | drawPrimitives…instanceCount: (16) | 8 | @0x10001BFFC | same | OK | — | P2 |
| 4 | drawPrimitives…baseInstance: (64) | 0x24 | @0x10001C1D4 | same | OK | — | P2 |
| 5 | drawPrimitives…baseInstance: (16) | 0xC | @0x10001C3A8 | same | OK | — | P2 |
| 6 | drawIndexedPrimitives: (64) | 0x18 | @0x10001C588; also throws on nil index buffer | same | OK | `idx=1:ty0:n4` draws in fail lines | P2 |
| 7 | drawIndexedPrimitives: (16) | 0xC | @0x10001C7F4 | same | OK | yes | P2 |
| 8 | drawIndexed…instanceCount: (64) | 0x20 | @0x10001CA70 | same | OK | — | P2 |
| 9 | drawIndexed…instanceCount: (16) | 0x10 | @0x10001CCE0 | same | OK | — | P2 |
| 10 | drawIndexed…baseVertex:baseInstance: (64, legacy) | 0x30 | @0x10001CF5C | same (`wire` render.rs:423) | OK, but **dead at version 8**: the guest emits 28 instead | not seen | P3 |
| 11 | drawIndexed…baseVertex:baseInstance: (16, legacy) | 0x14 | @0x10001D1D8. baseVertex is read **unsigned** (`HIWORD`). The guest only selects this form when 0 ≤ baseVertex < 0x10000 | same (`wire` render.rs:379, `base_vertex: I16le`) | divergent: Orchard reads it **signed**, so 0x8000–0xFFFF become negative. Dead at version 8 | not seen | P3 |
| 12 | drawPatches (64) | 0x30 | @0x10001D954. Note: the guest's **wide drawIndexedPatches also emits opcode 12** with a 60-byte payload (`17603`). Apple reads 0x30 bytes and runs a *non-indexed* drawPatches | spi:266 (length-resolved) → exec:4312, declined | partial (nothing tessellates) | not seen | P2 |
| 13 | drawPatches (16) | 0x10 | @0x10001DACC | spi:266 → exec:4312 | partial | not seen | P2 |
| 14 | drawIndexedPatches (64) | 0x3C | @0x10001DC4C. The guest never emits it (see 12) | spi | partial | not seen | P3 |
| 15 | drawIndexedPatches (16) | 0x18 | @0x10001DDF8 | spi | partial | not seen | P2 |
| 16 | drawPrimitives:indirectBuffer: | 0x10 | @0x10001DFA4 | pdec:336 → exec:5677 | OK | — | P2 |
| 17 | drawIndexedPrimitives:indirectBuffer: | 0x1C | @0x10001E1A4 | pdec → exec:5677 | OK | — | P2 |
| 18 | drawPatches indirect | 0x1C | @0x10001E44C | spi:287 | partial | not seen | P2 |
| 19 | drawIndexedPatches indirect | 0x28 | @0x10001E5E0 | spi:290 | partial | not seen | P2 |
| 20 | executeCommandsInBuffer:indirectBuffer:offset: | 0x10 (icb u32, buf u32, off u64) | @0x10001E89C; throws on an unknown ICB or buffer | spi:244 → exec:4133 → `runtime/icb` | OK | `icb_ok/icb_fail`=0 | P2 |
| 21 | executeCommandsInBuffer:withRange: | 0x14 (icb u32, loc u64, len u64) | @0x10001E7B4; validates the range | spi:253 → exec:4133 | OK | 0 | P2 |
| 22 | memoryBarrierWithResources:count:after:before: | var | @0x10001E974 **always throws** "decodeRenderBarrierResourcesWithIterator unsupported", faulting the command buffer | exec:2900 (no-op, counts `render_noop_barrier`) | divergent (Orchard is more lenient; harmless) | `render_noop_barrier`=0 | P3 |
| 23 | memoryBarrierWithScope:after:before: | 4 (packed scope/stages) | @0x10001E9B8 → Metal | exec:2900, no-op | partial (relies on pass-granular submit) | 0 | P2 |
| 24 | updateFence:afterStages: | 8 | @0x10001EC1C `getFenceForReferenceNonNull` | exec:2862 → fence_exec | OK | `fence`=468 (all rails) | P2 |
| 25 | waitForFence:beforeStages: | 8 | @0x10001EDBC | exec:2862 | OK | same | P2 |
| 26 | *render pass descriptor* (renderCommandEncoderWithDescriptor:) | 0x248 | @0x100024650. Layout: depth @0 (tex, resolve, level/slice/plane/rlevel/rslice/rplane u16, load @0x14, store @0x16, opts @0x18, clearDepth f64 @0x1C, resolveFilter @0x24); stencil @0x28 (load @0x3C, store @0x3E, opts @0x40, clear u32 @0x44, filter @0x48); 8×colour @0x4C+60i (load +0x14, store +0x16, opts +0x18, clear 4×f64 +0x1C); visibility buf u32 @0x22C; rtArrayLength/width/height u64 @0x230/238/240. **Memoryless** (storageMode 3): store∉{DontCare,MSResolve,Unknown}→DontCare, load∉{DontCare,Clear}→**Clear**. **DontCare loads pass through to Metal unchanged** | pdec:446 → exec:3564 | partial: rtArrayLength>1 refused (exec:3571), rtWidth/Height not applied, memoryless coercion not seen in this arm, DontCare raised to Clear (see below) | `render_pass_target_extent_unapplied`=248; `passbegin_load`=1702; `color0_declared_dontcare` px 90 000; `load_action_dont_care_cleared` 44 | **P1** |
| 27 | useHeaps:count:stages: | var (4-byte refs) | @0x100021B7C → Metal | exec:2926 (counted, declined) | OK (residency hint) | `render_residency_*`=0 | P2 |
| 28 | drawIndexed…baseVertex:baseInstance: (64, "correct base vertex") | 0x30, same as 10 | @0x10001D458 → same Metal call as 10 | **none**: `spi::decode` → `ErrUnknownOpcode` → `render_unimplemented`, draw lost | **missing** | not seen | **P1** |
| 29 | drawIndexed…baseVertex:baseInstance: (16, "correct base vertex") | 0x14, same as 11 but baseVertex **signed** i16 (`SHIWORD`) | @0x10001D6D4. At version 8 the guest sends this, never 11, whenever every field fits in 16 bits (baseVertex+0x8000 ≤ 0xFFFF) | **none** | **missing** | not seen | **P1** |
| 30 | (desc) defaultRasterSampleCount | 4 | @0x10002523C, prefix only | spi:449 → exec:4338 (refused by contract) | partial | not seen | P2 |
| 31 | (desc) **defaultColorSampleCount** | 4 | @0x10002533C `setDefaultColorSampleCount:`. The guest emits it from `writeDescriptor` (`1536C` l.168) when `defaultColorSampleCount != 0` | **none**. `wire` render_pass.rs:518–535 calls 0x1f "a hole … not any property", which is wrong | **missing** | not seen | P2 |
| 32 | (desc) programmable sample positions | 4+8n (n ≤ 8) | @0x10002537C `setSamplePositions:count:`, throws if n ≥ 9 | spi:468 | partial (declined) | not seen | P2 |
| 33 | (desc) rasterizationRateMap | 4 (ref) | @0x100025624 | spi:444 | partial | not seen | P2 |
| 34 | (desc) imageblockSampleLength | 4 | @0x100025734 | spi:456 | partial | not seen | P2 |
| 35 | (desc) threadgroupMemoryLength | 4 | @0x100025834 | spi:456 | partial | not seen | P2 |
| 36 | (desc) tileWidth/Height | 4 (u16,u16) | @0x100025934 | spi:461 | partial | not seen | P2 |
| 101 | setBlendColorRed:green:blue:alpha: | 16 | @0x10001EF5C | pdec:506 → exec:3061 | OK | — | P2 |
| 102 | setColorStoreAction:atIndex: | 8 | @0x10001F05C; validateMTLStoreAction; throws if index > max | pdec:524 → exec:3759 | OK | — | P2 |
| 103 | setColorStoreActionOptions:atIndex: | 12 | @0x10001F230 | spi:321 → exec:4273 (refused, value logged) | partial | not seen | P2 |
| 104 | setDepthStencilState: | 4 | @0x10001F404; throws on a nil state | pdec:439 → exec:3059 | OK | `ds_state_held`=540 | P2 |
| 105 | setDepthStoreAction: | 8 | @0x10001F54C | pdec:537 → exec:3759 | OK | — | P2 |
| 106 | setDepthStoreActionOptions: | 8 | @0x10001F6C8 | spi:321 | partial | — | P2 |
| 107 | setCullMode: | 8 | @0x10001F784 | pdec:477 → exec:3069 | OK | — | P2 |
| 108 | setDepthBias:slopeScale:clamp: | 12 | @0x10001F840 | pdec:490 → exec:3073 | OK | — | P2 |
| 109 | setDepthClipMode (calls the SPI `setDepthClipModeSPI:`) | 8 | @0x10001F940 | pdec:482 → exec:3071 | OK | — | P2 |
| 110 | setFragmentBuffers:offsets:withRange: (also setFragmentBytes, guest `setBytes…withCommand:110`) | var, 12 B/entry (ref u32, off u64) | @0x10001F9FC; throws if first+count > maxFragmentBuffers | pdec:364 → exec:3242 | OK | `render_bind_reach_buffer_le16`=2659 | P2 |
| 111 | setFragmentBufferOffset:atIndex: | 12 | @0x10001FB84 | pdec:415 → exec:3403 | OK | — | P2 |
| 112 | setFragmentSamplerStates:withRange: | var, 4 B | @0x10001FC28; ref 0 → nil | pdec:396 → exec:3343 | OK | `render_bind_reach_sampler_le16`=597 | P2 |
| 113 | setFragmentSamplerStates:lodMin:lodMax:withRange: | var | @0x10001FD7C | pdec:406 → exec:3372 | OK | — | P2 |
| 114 | **setFragmentTextures:withRange:** | var, 4 B | @0x10001FF40. **ref 0 → nil bound**: no substitution and no draw refusal. Any object whose `PGResource::getTexture` is non-nil binds, whatever its type or format, and keeps its native format | pdec:390 → exec:3300; draw-time resolution in `runtime/draw/vulkan.rs` | **divergent** (see the four cases below) | `render_bind_reach_texture_le16`=1436; `frag_declared_descriptor_unbound` 68/78 lines, `frag_neutral_texture_substituted` 68, `settle_linear_texture_seed` 18, `draw_vk_nothing_stored` 23 | **P0** |
| 115 | setFrontFacingWinding: | 8 | @0x100020094 | pdec:479 → exec:3070 | OK | — | P2 |
| 116 | setRenderPipelineState: | 4 | @0x100020150; ref 0 throws "Invalid render pipeline state"; looks up the live object each time | pdec:432 → exec:3049; shader memo `runtime/m2v_cache.rs:1006` | **divergent**: the m2v pre-scan memo is keyed by ref/name | `pipeline_create_*`=297; `m2v_pipe_content_changed` 25 | **P0** |
| 117 | setScissorRect: | 32 (4×u64) | @0x1000201EC, unclamped | pdec:459 → exec:3105 | OK | `draw_scissor_partial`=1206, `_full`=505 | P2 |
| 118 | setScissorRects:count: | 4+32n | @0x1000202F8 | pdec:466 → exec:3105 | OK | — | P2 |
| 119 | setStencilFrontReferenceValue:backReferenceValue: | 8 | @0x1000205B0 | pdec:516 → exec:3060 | OK | — | P2 |
| 120 | setStencilStoreAction: | 8 | @0x1000206B4 | pdec:537 → exec:3759 | OK | — | P2 |
| 121 | setStencilStoreActionOptions: | 8 | @0x100020770 | spi:321 | partial | — | P2 |
| 122 | setTessellationFactorBuffer:offset:instanceStride: | 20 | @0x10002082C | spi:304 → exec:4331 (dropped) | partial | 0 | P2 |
| 123 | setTessellationFactorScale: | 4 | @0x100020944 | spi:314 → exec:4182 | partial | `render_tessellation_scale_dropped`=0 | P2 |
| 124 | setTriangleFillMode: | 8 | @0x100020A40 | pdec:484 → exec:3072 | OK | `fill_mode_non_solid`=0 | P2 |
| 125 | setVertexBuffers:offsets:withRange: (+setVertexBytes) | var, 12 B | @0x100020AFC | pdec:364 → exec:3242 | OK | in bind counters | P2 |
| 126 | setVertexBufferOffset:atIndex: | 12 | @0x100020F2C | pdec:415 → exec:3403 | OK | — | P2 |
| 127 | setVertexSamplerStates:withRange: | var | @0x100020FD0 | pdec:396 | OK | — | P2 |
| 128 | setVertexSamplerStates:lodMin:lodMax: | var | @0x100021124 | pdec:406 | OK | — | P2 |
| 129 | setVertexTextures:withRange: | var | @0x1000212E8; ref 0 → nil | pdec:390 → exec:3300 | OK (same resolution caveats as 114) | — | P2 |
| 130 | setViewport: | 48 (6×f64) | @0x10002143C | pdec:450 → exec:3091 | OK | `max_viewports`=16 | P2 |
| 131 | setViewports:count: | 4+48n | @0x100021554 | pdec:457 | OK | `multi_viewport`=0 | P2 |
| 132 | setVisibilityResultMode:offset: | 16 | @0x10002181C; the buffer comes from desc @0x22C | pdec:549 → exec:3122 | OK | — | P2 |
| 133 | textureBarrier | 0 | @0x1000219B8 → `memoryBarrierWithScope:4(RenderTargets) after:2(Fragment) before:1(Vertex)` | exec:2900, no-op | partial: a real barrier inside the pass matters for read-after-write of the render target (framebuffer-fetch pipelines) | `render_noop_barrier`=0 | P2 |
| 134 | useHeaps:count: (no stages) | var | @0x1000219CC | exec:2926 | OK. **This guest never emits it** (only 27) | 0 | P3 |
| 135 | useResources:count:usage: (no stages) | var | @0x100021DC4 | exec:2926 | OK. **Never emitted** (only 137) | 0 | P3 |
| 136 | setLineWidth: | 4 | @0x1000222C0 | pdec:499 → exec:3080 | OK | — | P2 |
| 137 | useResources:count:usage:stages: | var | @0x10002200C | exec:2926 (read and write halves counted) | OK | `render_residency_*`=0 | P2 |
| 138 | setAlphaTestReferenceValue: (GL) | 4 | @0x1000223BC. The guest emits it only if `supportsOpenGL` (version ≥ 6, which Orchard serves) | none → `render_unimplemented` | missing | not seen | P2 |
| 139 | setPointSize: (GL) | 4 | @0x1000224B8 | none | missing | — | P2 |
| 140 | setClipPlane:p2:p3:p4:atIndex: (GL) | 20 | @0x1000225B4; index ≥ 6 throws | none | missing | — | P2 |
| 141 | setVertexSamplerState:lodMin:lodMax:lodBias:atIndex: (GL) | 20 | @0x100022700 | none | missing | — | P2 |
| 142 | setFragmentSamplerState:…lodBias:atIndex: (GL) | 20 | @0x10002286C | none | missing | — | P2 |
| 143 | setViewportTransformEnabled: (GL) | 4 | @0x10002291C | none | missing | — | P2 |
| 144 | setProvokingVertexMode: (GL) | 4 | @0x100022A20 | none | missing | — | P2 |
| 145 | setPrimitiveRestartEnabled:index: (GL) | 8 | @0x100022BA0 | none | missing | — | P2 |
| 146 | setTriangleFrontFillMode:backFillMode: (GL) | 4 | @0x100022D04 | none | missing | — | P2 |
| 147 | setTransformFeedbackState: (GL) | 4 | @0x100022EFC | none | missing | — | P2 |
| 148 | setDepthCleared (GL) | 0 | @0x10002307C → `setDepthCleared` SPI | none | missing | — | P2 |
| 149 | setStencilCleared (GL) | 0 | @0x100023084 | none | missing | — | P2 |
| 150 | setColorResolveTexture:slice:depthPlane:level:yInvert:atIndex: (GL) | 16 | @0x10002308C | none | missing | — | P2 |
| 151 | setDepthResolveTexture… (GL) | 12 | @0x100023214 | none | missing | — | P2 |
| 152 | setStencilResolveTexture… (GL) | 12 | @0x100023354 | none | missing | — | P2 |
| 153 | setVertexAmplificationMode:value: | 8 (inferred) | @0x1000233D0 | spi:340 → exec:4199 (dropped) | partial | 0 | P2 |
| 154 | setVertexAmplificationCount:viewMappings: | 4+8n | @0x100023560 | spi:347 | partial | 0 | P2 |
| 155 | dispatchThreadsPerTile: | 24 | @0x100023814; throws without a pipeline | spi:421 → exec:4259 (dropped) | partial | 0 | P2 |
| 156 | setThreadgroupMemoryLength:offset:atIndex: | 20 | @0x100023968 | spi:363 | partial | — | P2 |
| 157 | setTileBuffers:offsets:withRange: | var | @0x100023AC0 | spi:378 → exec:4230 | partial | — | P2 |
| 158 | setTileBufferOffset:atIndex: | 12 | @0x100023C48 | spi:413 | partial | — | P2 |
| 159 | setTileSamplerStates:withRange: | var | @0x100023CEC | spi:378 | partial | — | P2 |
| 160 | setTileSamplerStates:lodMin:lodMax: | var | @0x100023E40 | spi:378 | partial | — | P2 |
| 161 | setTileTextures:withRange: | var | @0x100024004 | spi:378 | partial | — | P2 |
| 162 | dispatchThreadsPerTile:inRegion: | 76 | @0x100024158 | spi:429 | partial | — | P2 |
| 163 | dispatchThreadsPerTile:inRegion:withRenderTargetArrayIndex: | 76 | @0x1000242E4 | spi:429 | partial | — | P2 |
| 164 | getTileDimensions (host writes back) | 12 (buf u32, off u64) | @0x1000243B8 **writes `u16 tileWidth, u16 tileHeight`** into the guest buffer at the offset | spi:437 → exec:4389 (unanswered) | missing write-back | `render_tile_dimensions_unanswered`=0 | P2 |
| 165 | setVertexBuffers:offsets:attributeStrides:withRange: | var, 20 B (ref, off u64, stride u64) | @0x100020C84; **throws "Dynamic Attribute Stride not supported"** if the device lacks it | pdec:373 → exec:3271 | OK | — | P2 |
| 166 | setVertexBufferOffset:attributeStride:atIndex: | 20 (inferred) | @0x100020E68; same gate | pdec:425 → exec:3403 | OK | — | P2 |

## What makes the logged Orchard cases well-defined on Apple's side

**`frag_declared_descriptor_unbound` (68 lines in 5b042af, 56 in 175aa0e) and `frag_neutral_texture_substituted` (68).**
The exact line is `pipe=61 unbound=[tex1:frag_declared_descriptor_unbound] violations=1/1 provided_tex={0} 128x160`.
The guest never sent fragment texture index 1 in that encoder. On Apple's host the slot keeps the state of
a fresh encoder, which is nil. Opcode 114 binds `getTextureForReference(0)`=nil (`sub_10005A27C`: ref 0 → 0),
and no host code substitutes anything. The AGX hardware reads (0,0,0,0) from a nil texture (**inferred**:
no host code is involved, so the value comes from the GPU or driver). Orchard's substitute is a 1×1
RGBA8 (0,0,0,0) (`runtime/draw/vulkan.rs:8280`, `solid_rgba8(1,1,&[0.0;4])`), so it matches. Both lines
are informational. They are worth keeping only as long as no array, cube or MSAA shape is declined
(`UnboundTextureShapeUnsupported`, vulkan.rs:8238). Bindings carry over only through segment
continuation (`var2`), and `seg_chain_none`=604 rules that out as the cause here.

**`load_action_dont_care_cleared` (44 latched lines; e.g. `pipe=12 geom=1920x60`, `pipe=39 1920x1080`).**
Apple passes `MTLLoadActionDontCare` to Metal unchanged (`validateMTLLoadAction` → `setLoadAction:`, @0x100024650).
The attachment's contents are then undefined, so clearing is conformant. Apple does force **Clear** only for
memoryless attachments, and only when the load action is neither DontCare nor Clear. The guest also never
sends DontCare on a split continuation: `-[PGSerializerRenderCommandEncoder setEncoderPosition:]` (guest 0x19ED4)
→ `forceLoadActions` (0x19E8D) writes `Load(1)` into every present attachment, and
`forceStoreActionsForPosition:` (0x19DDD) forces `Store`. A DontCare therefore always marks the **first**
encoder of a pass. Orchard's clear (vulkan.rs:14098) is correct. The one visible risk is a guest that
covers the target only partly (the 1920×60 strip) and expects the TBDR "whatever was there" behaviour,
which on AGX is usually the previous contents. The seed path `dontcare_seed_served` already handles that case.

**`draw_vk_nothing_stored` (23).** Every occurrence follows a `draws_skipped_after_engine_refusal`.
`refused_by` breaks down as `texture_resolve_missing` 63, `texture_access_unsupported` 26, `fragment_translate` 5.
Apple refuses none of these draws, because texture binding (114/129) is just `getTexture` on whatever object the ref names:
- `memo_wrong_type … want=[8] memo_ot=2` → `reason=linear_sample` (`pipe=59`, ref 57, fmt 0x19): Orchard
  asked one object type and refused another. Apple's `PGResource::getTexture` is polymorphic.
- `buftex convert_unsupported fmt=0x5a` (pipe 78): the texture is backed by a buffer. Apple binds the
  native `MTLTexture` with no conversion.
- `res_texture_view_opcode opcode=0x9 class=unsupported` (pipe 182, 13 others): the texture is a view object. Apple binds the view.
- `texture_access_unsupported access=storage` (pipe 93, 1920×1080, MRT): a fragment shader uses a read_write
  texture. Apple binds it through the same `setFragmentTextures:` call, because access is a property of the
  shader and not of the bind.

**`settle_linear_texture_seed` (18), e.g. `fmt=0x41 128x160 to=rgba8 lost=clamp_to_unit_and_256_levels`.**
0x41 = `MTLPixelFormatRG16Float`. Apple samples the native texture. Orchard's CPU-origin loader narrows it to
unorm8, which loses data if the texels are LUTs or coordinates. This is not an opcode bug but it degrades
row 114.

**`m2v_pipe_content_changed` (25), e.g. `pipe=12 stage=Vertex air=6952 was=… now=…`.**
Apple resolves `setRenderPipelineState:` with `getRenderPipelineStateForReference:` (@0x100028A48) for each
command. A ref is a slot: `deleteRenderPipelineStateForReference` (@0x100028AC8) frees it, and the guest reuses
the number for a different pipeline (`child_delete_object_render_pipeline_state`=73 in this boot). The new AIR
is therefore the correct answer. Any memo keyed by ref or name has to be invalidated on delete, or keyed by the AIR digest.

## Ranked fix list

1. **Decode 0x1c/0x1d** (rows 28/29). They reuse the 0x0a/0x0b layouts, with base_vertex **signed i16** in 0x1d.
   Fix 0x0b to read base_vertex **unsigned** in the same change. About 40 lines in `wire`/`pdec` plus a
   RenderKind entry. Low risk. Without it, every `drawIndexedPrimitives:…baseVertex:baseInstance:` from a
   version-8 guest is dropped (WebKit/ANGLE and SceneKit use it).
2. **Texture resolution parity for 114/129** (draw_vk_nothing_stored): accept any texture-bearing object type,
   bind texture-view objects (opcode 0x9 view type) and buffer-backed textures natively, and support
   fragment read_write textures. About 150–400 lines across `objects`, `draw/texture_view.rs` and the
   engine's storage-image path. Medium risk. This fixes 23 lost draws per boot plus the 94 skipped lines.
3. **m2v memo invalidation on pipeline delete or AIR digest** (row 116). About 20 lines in
   `runtime/m2v_cache.rs`. Low risk.
4. **Per-opcode render census** (one `note_store_route("render_op_0x..")` in `handle_render_record`).
   About 10 lines, no risk. Without it the "Seen" column cannot be filled.
5. **Pass descriptor gaps** (row 26): apply rtWidth/Height when the pass has no attachments (248 unapplied),
   support rtArrayLength > 1, and mirror Apple's memoryless coercion (load→Clear, store→DontCare). About
   60 lines. Medium risk.
6. **Native RG16Float (and other float) sampled upload** instead of RGBA8 narrowing. About 80 lines. Medium risk.
7. **0x1f defaultColorSampleCount**: add a RenderPassProperty arm in `spi` and correct the `render_pass.rs:518`
   doc. About 15 lines. No risk.
8. **getTileDimensions write-back** (u16 w, u16 h): about 20 lines. Low risk.
9. **textureBarrier (0x85)**: split or barrier the pass when a framebuffer-fetch pipeline follows. About 40 lines.
   Medium risk. Not seen yet.
10. GL rung opcodes 0x8a–0x98: either decode them or serve serializer version 8 with GL off. The version and
    the GL rung are coupled in the guest, so this needs a decision, not code.

## Open questions

- Which value does AGX return for a nil fragment texture: (0,0,0,0), or (0,0,0,1) for some formats? This decides
  whether Orchard's zero substitute is bit-exact.
- Does the vmapple sysbus plugin's `supportsOpenGL` return true? If it does, opcodes 138–152 can arrive from
  any OpenGL client. Run a GL app with the census from fix 4 to find out.
- Does pipe 61's fragment shader read tex1 on a path that executes (the M2V reflection marks it `Used`), or is it dead code?
- The guest emits opcode 12 for the wide drawIndexedPatches. Confirm that Apple then really draws non-indexed
  (this looks like a guest bug), and choose whether Orchard should copy that or reject it.
