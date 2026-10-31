# Family E: ExecIndirect segment framing, compute 200–230, blit 300–323, info 450–469

Apple side: `ParavirtualizedGraphicsGPUTask` 26A428 (`.c` dumps, plus IDA disasm of 0x1000292B0 and
0x10000FDA8 for the header field offsets). Guest side: `AppleParavirtGPUMetalIOGPUFamily.c/`. That dump is
the x86_64 slice (its addresses are small). The serializer logic is shared, so the protocol is the same.
Orchard: `external/orchard/reims-vgpu/crates/` @ `ea4dfb5` (`gg-macos27`). Paths below are relative
to `reims-vgpu/src/runtime/` unless they name another crate. Logs: every `/tmp/reims-vgpu-fail*.log`
present on 2026-10-29. "all logs" means summed over the 25 boot logs. The latest full boot is `.5b042af`.

## 0. The context that decides most priorities

- The guest asks for **v252**. Orchard negotiates **v62** (`protocol_version requested=252 negotiated=62`).
  In Apple's `getAPVFeaturesForVersion` @0x222F58984, feature byte +21 is set only for v≥101 ('e') and
  +41 only for v≥207. In the guest, +21 is `supportsInfoEncoder`: the assert string
  `device.features->supportsInfoEncoder` is in `getComputePipelineStateInfo:`/`setupHostResourceInfo`.
  +41 gates host-resource-info, for example `-[AppleParavirtBuffer gpuAddress]` @0x13458.
  **So at v62 the guest never opens an info segment (type 4).** This matches the logs: `info_record`=0
  and `icb_backing`=0 in every log. It uses the FIFO/kext twins instead (§4).
- The guest's other serializer flags have their own feature bytes: ProtectionOptionsEnvelope,
  ComputePassDescriptorDispatchType, DispatchThreadsIndirect, InsertCompressedTextureReinterpretationFlush,
  BlitEncoderSPI, CommandBufferJump, DynamicAttributeStride and TextureDescriptor2
  (`-[AppleParavirtDevice setupSerializerFeatures]` @0x20379). Their offsets are **not mapped** here. They
  are **inferred** to be above the v62 cut, because v62 sets only bytes 0–10 plus the dwords at +12/+16.
  The ops these flags gate are therefore marked P2, "not sent at v62 (inferred)".
- Measured traffic, all logs: `walk_records_render`=189 608, `walk_records_compute`=3 491 (`computes`=3 393
  dispatches), `walk_records_blit`=14. The only blit kind seen is texture→buffer (302,
  `blit_kind_t2b`/`blitrec_copy_n`=14). Segment census: `seg_chain_none`=3 362/`exec_stream_framed`=3 362.
  No `seg_chain_next|prev|both` was ever counted, and `stream_frame_fail`/`framing_*`=0.
  `compute_ctrl_seen`, `compute_icb_seen`, `blit_icb`, `blit_fill_texture`, `blit_decode`, `blit_record` and
  `compute_decode` are all 0. Every compute refusal is on **DispatchThreadgroups (200)**:
  `compute_stage_tex_mapper_ref_texture_span` 56, `compute_view_format` 37, `compute_vk_engine_run` 26,
  `compute_vk_pipeline_load` 16, `compute_vk_translate` 9. `compute_noop_barrier` (215)=56.
  These are backend execution failures, not protocol failures.

## 1. Segment header and segment types

Apple: `-[_PGDeserializer decodeSegments:into:]` @0x100029764 reads **one** 8-byte header per chunk
cursor (`sub_10002962C`), truncates the cursor to `len`, then calls `decodeSegmentWithHeader` @0x1000292B0.
The decoder returned for a segment with +6≠0 is carried into the next chunk. The guest writes the header
in `-[PGSerializerCommandEncoder writeSegmentHeader:continuation:protectionOptions:]` @0x1BE82.
`-[AppleParavirtCommandBuffer endCurrentChunk]` @0x247D4 fills `len` **only at the chunk's first byte**.
`beginContinuation` @0x24F64 sets +6 of the previous chunk's header. So one chunk is one segment.

| Field/type | Name | Payload | Apple host behaviour | Orchard `file:line` | Status | Logs | Prio |
|---|---|---|---|---|---|---|---|
| +0 u32 | length | whole chunk incl. header | Truncates the chunk cursor. A segment whose remaining bytes are <8 is not walked. | `reims-vgpu-protocol/src/segment.rs:392` (`step`), `reims-vgpu-wire/src/ops/segment.rs:108` | OK | 3 362 framed, 0 refused | — |
| +4 u8 | type | 0 render, 1 compute, 2 blit, 4 info, 5 envelope | `ldrb [x2,#4]`. Types 0/1/2 get `initWithDeserializer:commandBuffer:` and 4 gets `PGDeserializerInfoDecoder`. **3 and ≥6 throw `InvalidEncoder` "Invalid encoder type"** @0x1000293AC–0x10002949C. | `segment.rs:160` `segment_role`; `:71` `SEGMENT_TYPE_EVENT = 3` | **divergent**: Orchard accepts 3 as an Event segment. Its doc claims that "the deserializer constructs 0..=3", which is false for 26A428. This is a harmless superset only if the guest never writes 3. | 0 | P3 |
| +5 u8 | continuation (`begin_flag`) | `beginSegment:` BOOL | `ldrb [x19,#5]`≠0: **reuse the previous decoder**, meaning the same `MTL*CommandEncoder` with its pipeline and bindings. It throws `InvalidContinuation` if there is no previous decoder and `InvalidEncoder` if the type differs. For compute, it skips `decodeComputePassDescriptor` and encoder creation (@0x10000FDCC). | Parsed at `segment.rs:428`. It is used **only** for the `seg_chain_*` census (`exec/mod.rs:1788`). `begin_segment` (`exec/mod.rs:1567`) always creates a fresh `ComputeSegment::default()`. | **divergent**: a continuation compute segment loses pipeline, binds and dispatch type. The guest does not re-emit them; `handleSplits` @0x1D79D only re-adds residency refs. Its dispatches then fail as `pipeline_ref=0`. | 0 nonzero | P2 |
| +6 u8 | continues-into-next (`unidentified_u8`) | set afterwards by `beginContinuation` | `ldrb [x19,#6]`/`[x20,#6]`≠0: **no `endEncoding`**. The compute pipeline is not cleared, and the decoder is returned for the next chunk. | `segment.rs:429` only feeds the census. `end_segment` (`exec/mod.rs:1639`) commits the compute session after every segment. | **divergent** (same fix as +5) | 0 | P2 |
| +7 | — | never written by the guest | unread | not a field (`wire/src/ops/segment.rs:141`) | OK | — | — |
| type 5 | protection-options envelope | `[hdr t=5, len=chunk][u64 options][inner hdr: len **0**, type, cont][records…]` | Reads the u64 and calls `-[MTLCommandBuffer setProtectionOptions:]`. It then **reads the next 8-byte header inline from the same truncated cursor** (`sub_10002962C`), replaces `*a3`, and decodes that segment up to the end of the outer length. The inner `len` is ignored. | `segment.rs:438-451` requires the type-5 window to be exactly 8 bytes, then expects the inner header as its own segment with its own length. `exec/mod.rs:1738` skips the options. | **divergent**: a real envelope chunk has outer len = whole chunk, so it becomes `EnvelopeWindowNotItsPayload`. The whole rest of the stream is dropped (`exec/mod.rs:1712`). The inner header (len 0) would also fail `LengthBelowHeader`. Orchard's fixtures captured headers before `endCurrentChunk`, so they never saw a filled length. | 0 (flag not advertised at v62, inferred) | P2 |

Record framing inside a segment is `u32 opcode, u32 size (incl. 8)` (`sub_1000037A8`). A size <8 throws
"Underflow". Orchard: `exec/mod.rs:1392` `walk_segment_records` / `reims_vgpu_wire::op::OpStream`. **OK**.

## 2. Compute segment: `-[PGDeserializerComputeDecoder decodeWithHeader:withIterator:]` @0x10000FDA8

Encoder: on a non-continuation segment, `decodeComputePassDescriptor` @0x10000FBCC peeks at the first record.
If it is 219, it consumes it as `setDispatchType:`. Then `computeCommandEncoderWithDescriptor:`.
An unknown opcode throws `UnrecognizedCommand`. That includes **219 anywhere other than the first record**.
At segment end with +6==0, it calls `endEncoding` and drops the pipeline. Sizes are total record bytes
including the 8-byte header. They come from Orchard's wire fixtures (`reims-vgpu-wire/src/ops/compute.rs`)
and were checked against Apple's readers for 200, 203 and 219.
Orchard routing goes `exec/mod.rs:1916` `handle_compute_record` → `compute_exec/mod.rs:821`
`apply_record_inner`, or `exec/mod.rs:2035-2085` for the records whose ledger row is not settled.

| Op | Name (Metal call replayed) | Payload | Apple host behaviour | Orchard `file:line` | Status | Logs | Prio |
|---|---|---|---|---|---|---|---|
| 200 | `dispatchThreadgroups:threadsPerThreadgroup:` | 56: 6×u64 groups, tpg | Throws "Attempting to dispatch without pipeline set" if no 208 was seen (@0x10000C948). | `compute_exec/mod.rs:892` → backend `execute_dispatch` | decode OK. Execution **partial** (Vulkan rail refusals). | 3 393 dispatches. Refusals: 56 stage_tex span, 37 `compute_view_format`, 26 `compute_vk_engine_run`, 16 pipeline_load, 9 translate | P0 (execution; owned by the backend, not this family) |
| 201 | `dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:` | 44: 3×u64 tpg, u64 off, u32 buf | Same pipeline check. | `compute_exec/mod.rs:892` (guest args read → direct encode, `:12`) | OK (inferred, not seen) | 0 seen | P2 |
| 202 | `dispatchThreads:threadsPerThreadgroup:` | 56 | Same check. | `compute_exec/mod.rs:892` | OK | not separated | P2 |
| 203 | `setBuffers:offsets:withRange:` (also covers setBuffer and setBytes) | 16 + n×12 {u32 ref, u64 off}; head {u32 start, u32 count} | Throws "Invalid buffer count" if start+count > `maxComputeBuffers`. | `compute_exec/mod.rs:837` | OK | not separated | — |
| 204 | `setSamplerStates:withRange:` | 16 + n×4 refs | Throws "Invalid sampler count". | `:856` | OK | | — |
| 205 | `setSamplerStates:lodMinClamps:lodMaxClamps:withRange:` | 16 + n×12 {ref, f32, f32} | Same check. | `:860` | OK | | — |
| 206 | `setTextures:withRange:` | 16 + n×4 refs | Throws "Invalid texture count". | `:852` | OK | | — |
| 207 | `setBufferOffset:atIndex:` | 20: u64 off, u32 idx | Throws "Invalid buffer index". | `:848` | OK | | — |
| 208 | `setComputePipelineState:` | 12: u32 ref | Throws "Invalid compute pipeline state" on a bad ref. | `:830` (decodes lazily at dispatch, `compute_load_pipeline`) | OK. The 66 `compute_load_pipeline desc_decode` lines are object-side. | | — |
| 209 | `setStageInRegion:` | 56: MTLRegion 6×u64 | Replays the call. | `:868` | OK | 0 | P2 |
| 210 | `setStageInRegionWithIndirectBuffer:indirectBufferOffset:` | 20: u32 buf, u64 off | Throws "Invalid indirect buffer offset". | `:879` | OK | 0 | P2 |
| 211 | `setThreadgroupMemoryLength:atIndex:` | 20: u64 len, u32 idx | Throws "Invalid threadgroup memory size index". | `:884` | OK | | — |
| 212 | `updateFence:` | 12: u32 fence | Replays the call. | `exec/mod.rs:2035` → `fence_exec` | OK | | — |
| 213 | `waitForFence:` | 12 | Replays the call. | `exec/mod.rs:2035` | OK | | — |
| 214 | `memoryBarrierWithResources:count:` | 12 + n×4 | Throws "Too many resources specified". | `exec/mod.rs:2158` (proven no-op) | OK | 0 | — |
| 215 | `memoryBarrierWithScope:` | 12: u16 scope | Replays the call. The serial pass emits one after each dispatch. | `exec/mod.rs:2158` | OK | `compute_noop_barrier` 56 | — |
| 216 | `setImageblockWidth:height:` | 16: u32 w, u32 h | Throws "ImageBlocks not supported" if the device lacks them. | `compute_exec/mod.rs:888` | OK | 0 | P2 |
| 217 | `setBuffers:offsets:attributeStrides:withRange:` | 16 + n×20 | Needs `supportsDynamicAttributeStride`. | `:841` | OK | | P2 |
| 218 | `setBufferOffset:attributeStride:atIndex:` | 28 | Same requirement. | `:848` | OK | | P2 |
| 219 | `MTLComputePassDescriptor.dispatchType` | 12: u32 type (validated by `validateMTLDispatchType`) | **Only as the first record of a new segment.** Anywhere else it throws. | `compute_exec/mod.rs:864` (accepted at any position) | divergent (more lenient). Not sent at v62 (inferred). | 0 | P3 |
| 220 | `encodeStartDoWhile` | 8 | Needs `supportsCommandBufferJump`. | `exec/mod.rs:2049` → `compute_session::apply_sequencing` | OK (not seen) | 0 | P2 |
| 221 | `encodeEndDoWhile:offset:comparison:referenceValue:` | 28: u32 buf, u64 off, u32 cmp, u32 ref | Same requirement. | `exec/mod.rs:2049` | OK (not seen) | 0 | P2 |
| 222 | `encodeStartWhile:offset:comparison:referenceValue:` | 28 | Same requirement. | same | OK (not seen) | 0 | P2 |
| 223 | `encodeEndWhile` | 8 | Same requirement. | same | OK (not seen) | 0 | P2 |
| 224 | `encodeStartIf:offset:comparison:referenceValue:` | 28 | Same requirement. | same | OK (not seen) | 0 | P2 |
| 225 | `encodeStartElse` | 8 | Same requirement. | same | OK (not seen) | 0 | P2 |
| 226 | `encodeEndIf` | 8 | Same requirement. | same | OK (not seen) | 0 | P2 |
| 227 | `insertCompressedTextureReinterpretationFlush` | 8 | Replays the call. | `exec/mod.rs:2186` (no-op) | OK | 0 | P3 |
| 228 | `executeCommandsInBuffer:withRange:` | 28: u32 icb, u64 loc, u64 len | Throws "Invalid indirect command buffer range". | `exec/mod.rs:2071` (ICB materialised on the Metal arm only, per the `compute_exec/mod.rs:17` doc) | partial | `compute_icb_fail` 0, seen 0 | P2 |
| 229 | `executeCommandsInBuffer:indirectBuffer:indirectBufferOffset:` | 24: u32 icb, u32 buf, u64 off | Same as 228. | `exec/mod.rs:2071` | partial | 0 | P2 |
| 230 | `dispatchThreadsWithIndirectBuffer:indirectBufferOffset:` | 20: u64 off, u32 buf | Pipeline check. Needs DispatchThreadsIndirect. | `compute_exec/mod.rs:892` | OK | 0 | P2 |
| 134/135 | `useHeaps:count:` / `useResources:count:usage:` (accepted inside a compute segment) | variable | Replays the residency call. Throws "Too many resources specified". | `exec/mod.rs:2259` (declined; residency no-op) | OK on a unified-memory host | not split | — |

## 3. Blit segment: `-[PGDeserializerBlitDecoder decodeWithHeader:withIterator:]` @0x1000033D8

The encoder is created in `initWithDeserializer:commandBuffer:` @0x10000131C (`blitCommandEncoder`).
`endEncoding` runs only when +6==0. 134/135 are **not** accepted here (`UnrecognizedCommand`).
Orchard: `exec/mod.rs:2366` `handle_blit_record` classifies through the closure ledger, then goes to
`blit_exec/mod.rs:4234`.

| Op | Name (`MTLBlitCommandEncoder` call) | Payload | Apple host behaviour | Orchard `file:line` | Status | Logs | Prio |
|---|---|---|---|---|---|---|---|
| 300 | `copyFromBuffer:…toTexture:…options:` | 96 | Replays the call. | `blit_exec/mod.rs:2526` | OK | 0 | P2 |
| 301 | `copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:` | 40 | Replays the call. | `blit_exec/mod.rs:2037` | OK | 0 | P2 |
| 302 | `copyFromTexture:…toBuffer:…options:` | 96 | Replays the call. | `blit_exec/mod.rs:2785` | OK | **14** (`blit_kind_t2b`), 0 refused | — |
| 303 | `copyFromTexture:…toTexture:…destinationOrigin:` | 96 | Replays the call. | `blit_exec/mod.rs:3029` | OK | 0 | P2 |
| 304 | same as 303, `…options:` | 100 | Replays the call. | `blit_exec/mod.rs:3029` (options carried in the record; **inferred** ignored) | OK | 0 | P2 |
| 305 | `copyIndirectCommandBuffer:sourceRange:destination:destinationIndex:` | 40 | Range and index checks. | `exec/mod.rs:2767` (dropped, `blit_icb`) | **missing** | 0 | P2 |
| 306 | `fillBuffer:range:value:` | 32 | Throws "Invalid buffer range". | `blit_exec/mod.rs:1951` | OK | 0 | P2 |
| 307 | `generateMipmapsForTexture:` | 12 | Replays the call. | `exec/mod.rs:2654` → `runtime::mipmap` (linear) | OK | 0 | P2 |
| 308/309 | `optimizeContentsForCPUAccess:` / `…GPUAccess:` | 12 | Replays the call (a performance hint). | `exec/mod.rs:~2392` (no-op route) | OK | 0 | — |
| 310/311 | `optimizeContentsFor{CPU,GPU}Access:slice:level:` | 16 | Same. | same | OK | 0 | — |
| 312 | `optimizeIndirectCommandBuffer:withRange:` | 28 | Range check. | `exec/mod.rs:2603` (no-op) | OK | 0 | — |
| 313 | `resetCommandsInBuffer:withRange:` | 28 | Range check. | `exec/mod.rs:2767` (dropped) | **missing** | 0 | P2 |
| 314 | `synchronizeResource:` | 12 | Replays the call (managed storage → CPU). | no-op route | OK (shared guest memory) | 0 | — |
| 315 | `synchronizeTexture:slice:level:` | 16 | Same. | no-op route | OK (inferred) | 0 | — |
| 316 | `updateFence:` | 12 | Replays the call. | `blit_exec/mod.rs:4150` | OK | 0 | — |
| 317 | `waitForFence:` | 12 | Replays the call. | `blit_exec/mod.rs:4150` | OK | 0 | — |
| 318 | `copyFromTexture:sourceSlice:sourceLevel:toTexture:…sliceCount:levelCount:` (also `copyFromTexture:toTexture:`) | 28 | Replays the call. | `blit_exec/mod.rs:3834` | OK | 0 | P2 |
| 319 | `fillBuffer:range:pattern4:` (BlitEncoderSPI) | 32 | Throws "Invalid buffer range". | `blit_exec/mod.rs:2006` | OK | 0 | P2 |
| 320 | `fillTexture:level:slice:region:bytes:length:` (SPI) | 84 | Source buffer must be shared storage and at least minLength for the format. | `exec/mod.rs:2793` (dropped, `blit_fill_texture`) | **missing** | 0 | P2 |
| 321 | `fillTexture:level:slice:region:color:pixelFormat:` (SPI) | 100: 4×f64 colour, u16 pf | Replays the call. | `exec/mod.rs:2793` (dropped) | **missing** | 0 | P2 |
| 322 | `invalidateCompressedTexture:` (SPI) | 12 | Replays the call. | no-op route | OK | 0 | P3 |
| 323 | `invalidateCompressedTexture:slice:level:` (SPI) | 16 | Replays the call. | no-op route | OK | 0 | P3 |

## 4. Info segment: `-[PGDeserializerInfoDecoder decodeWithHeader:withIterator:]` @0x100006BDC

Every query names a **reply buffer and offset**. Apple resolves them with `newMemoryCursorForBuffer:` plus
`advance` and writes the answer there. The guest **blocks on every one of them**: each caller does
`infoCommandEncoder`, then query, `endEncoding`, `commit`, `waitUntilCompleted`, checks `status == 4`, and
reads the reply. Callers checked: 13458, 14972, 14B82, 14CD5, 1C49F, 1CE78, 1D1EE, 1D341, 2235F, 26E8,
2E57, 548E, 56D6, 68A4, AF84, F306. Orchard answers **none** of them. `handle_info_record`
(`exec/mod.rs:1792`) logs every info record through `note_info_record_unanswered` (`exec/report.rs:869`)
and leaves the reply buffer untouched. 465 also has a decode-only arm (`icb/mod.rs:1416`). At v62 none of
these is sent (§0), so all are P2 today. **Each one becomes a guest-visible wrong answer the moment the
negotiated version is raised to ≥101.**

| Op | Query | Payload | Apple reply (bytes) | Guest caller (blocks) | Orchard | Status | Logs | Prio |
|---|---|---|---|---|---|---|---|---|
| 450 | computePipelineStateInfo | 24 Query {u32 obj, u32 reply_buf, u64 reply_off} | 28: maxTotalThreadsPerThreadgroup, threadExecutionWidth, staticThreadgroupMemoryLength, supportIndirectCommandBuffers | `getComputePipelineStateInfo:` 0x1CE78 | unanswered | **missing** | 0 | P2 (blocker for v≥101) |
| 451 | heapTextureDescriptorSizeAndAlign | 52: TextureDescriptor body, reply buf/off | 16: {size, align} from `heapTextureSizeAndAlignWithDescriptor:` | `heapTextureSizeAndAlignWithDescriptor:` 0x2235F (cached in a dictionary) | unanswered | **missing** | 0 | P2 |
| 452 | getRasterizationRateMapInfo | 32 | 20 + 4×layers | 0x548E | unanswered | missing | 0 | P3 (VRR not advertised) |
| 453 | copyRasterizationRateParameterBuffer | 24 | `copyParameterDataToBuffer:offset:` into a guest buffer | 0x68A4 | unanswered | missing | 0 | P3 |
| 454/455 | mapScreenToPhysical / mapPhysicalToScreen | 36 | 8 (float2) | via `mapCoordinateInternal` 0x3839 | unanswered | missing | 0 | P3 |
| 456 | mapPhysicalToScreenCoordinates (multiple) | variable | n×8 | 0x56D6 | wire marks it `Excluded`; unanswered | missing | 0 | P3 |
| 457 | renderPipelineStateInfo | 24 Query | 12: imageblockSampleLength, maxTotalThreads, threadgroupSizeMatchesTileSize, supportICB | 0x14972 | unanswered | **missing** | 0 | P2 |
| 458/459 | render/compute pipeline imageblockMemoryLengthForDimensions | 48 | 4 | 0x14B82 / 0x1D1EE | unanswered | missing | 0 | P3 (imageblocks) |
| 460 | objectUniqueIdentifier (obj type 1 texture, 5 ICB, 9 RPS, 10 CPS) | 28: u32 obj, u32 type, u32 reply_buf, u64 off | 8 | **none found in the guest** (`uniqueIdentifier` is local) | not in wire | n/a | 0 | P3 |
| 461 | bufferHostResourceInfo | 24 Query | 8: `gpuAddress` | `-[AppleParavirtBuffer gpuAddress]` 0x13458 (gated on +41, v≥207) | unanswered | missing | 0 | P2 |
| 462 | textureHostResourceInfo | 24 | 16: gpuResourceID, resourceIndex | 0xAF84 (+41 and deviceInfo+164 bit 1) | unanswered | missing | 0 | P2 |
| 463 | heapHostResourceInfo | 24 | 8: gpuAddress | 0xF306 | unanswered | missing | 0 | P2 |
| 464 | samplerStateHostResourceInfo | 24 | 16 | 0x1C49F | unanswered | missing | 0 | P2 |
| 465 | icbHostResourceInfo | 24 | 16 | 0x26E8 | decoded, refused, unanswered (`icb/mod.rs:1416`) | missing | `icb_backing` 0 | P2 |
| 466 | renderPipelineHostResourceInfo | 24 | 16 | 0x14CD5 | unanswered | missing | 0 | P2 |
| 467 | computePipelineHostResourceInfo | 24 | 16 | 0x1D341 | unanswered | missing | 0 | P2 |
| 468 | depthStencilHostResourceInfo | 24 | 16 | 0x2E57 | unanswered | missing | 0 | P2 |
| 469 | heapTextureDescriptorSizeAndAlign2 (TextureDescriptor2) | 60 | 16 | 0x2235F (usage ≥0x100 path) | unanswered | missing | 0 | P2 |

### What the guest blocks on today (v62, no info encoder)

These are the FIFO/kext twins of the same questions:
- **Heap texture size/align** (the twin of 451/469). `heapTextureSizeAndAlignWithDescriptor:` without the
  info encoder calls `IOConnectCallMethod(…, 0x10C, …)` synchronously, then reads 16 bytes from a
  descriptor buffer (0x2235F). Orchard: `drain/mod.rs:~3686` `reply_heap_texture_size_and_align` →
  `backend/heap_placement.rs:64/105`. That path only has a Metal implementation. On the Vulkan rail it
  **always refuses `heap_query_no_metal_device` and writes nothing**: **349** refusals across all logs, 83
  in `.5b042af`. The guest reads whatever the descriptor buffer held (presumably 0). It caches that
  answer per descriptor and rounds it up to the buffer alignment. **P0.**
- **Compute pipeline info** (the twin of 450): `get_compute_info ok` **511** across all logs. It is
  answered. **OK.**
- gpuAddress and the other host-resource-info queries (461–468) are gated on +41 (v≥207), so the guest
  does not ask them at v62. **n/a.**

## Ranked fix list

1. **Answer the heap-texture size/align query on the Vulkan rail** (`backend/heap_placement.rs`). Use
   `vkGetDeviceImageMemoryRequirements`, or the same layout arithmetic the image pool uses, so the answer
   matches where Orchard later places the texture. Size: ~80–150 lines plus tests. Risk: medium. The
   guest caches the answer per descriptor, so a wrong size is sticky for the whole boot. P0, 349 refusals.
2. **Carry the compute (and blit) encoder across continuation segments.** In `exec/mod.rs:1567/1639`:
   - when `continues_previous`, keep `self.compute` instead of replacing it;
   - when `continues_into_next`, skip `finish_session`;
   - refuse like Apple (`InvalidContinuation`/type mismatch) when a continuation has no open segment of
     the same kind.

   Size: ~40–60 lines. Risk: low. It only changes behaviour on headers with +5/+6 set, of which 0 have been
   seen so far. It becomes live as soon as a compute pass outgrows one chunk. P2, high impact.
3. **Frame the protection-options envelope the way Apple does** (`reims-vgpu-protocol/src/segment.rs:438`).
   A type-5 segment is `[u64 options][inner 8-byte header whose len is ignored][records to the outer
   len]`, and it should yield the inner kind and lifetime. Fix the fixtures, which captured a pre-fill
   length. Size: ~40 lines plus fixture updates. Risk: low. Prerequisite for advertising
   `supportsProtectionOptionsEnvelope`. P2.
4. **Implement the info encoder answers before raising the negotiated version past 100.** Order:
   451/469 (share code with item 1), 450, 457, then 461–468 (only needed at v≥207, and they need a
   stable per-object gpuAddress/resourceID scheme), then 458/459. Rate maps (452–456) can stay refused if
   VRR stays unadvertised. Write the reply through the task-GVA writer that `get_compute_info` uses.
   Size: ~300–500 lines. Risk: medium-high, because wrong answers are cached by the guest.
5. **Blit ICB copy/reset (305, 313) and fillTexture bytes/colour (320, 321).** These are dropped today.
   Size: ~150–250 lines. Risk: medium. 320/321 need the format-encode path. P2, nothing seen.
6. **Refuse segment type 3**, or confirm a guest emitter and document it. Apple 26A428 throws on it.
   Size: ~5 lines plus the doc in `segment.rs:1-45`. Risk: none. P3.
7. **Refuse 219 when it is not the first record of a fresh compute segment**, matching Apple. Size:
   ~10 lines. P3.

## Open questions

- Feature-byte offsets for ProtectionOptionsEnvelope, ComputePassDescriptorDispatchType,
  DispatchThreadsIndirect, BlitEncoderSPI and CommandBufferJump are unmapped. That they are above v62 is
  **inferred**. It needs the guest `_features` struct offsets, either from the IDA local types or from
  `initWithAcceleratorPort:` 0x1FEBB.
- Can a guest chunk ever hold more than one segment? Apple's `decodeSegments` reads exactly one header
  per chunk, and `endCurrentChunk` fills only the first. Orchard's `SegmentStream` loops over several,
  which is harmless but would hide a guest that packs two.
- How large does a compute pass get before the guest splits it (`hadSplit`)? This decides whether item 2
  is P1 for real workloads (WindowServer blur and Core Image kernels).
- What happens to a guest command buffer whose host decode throws on Apple? It becomes status ≠ 4 and the
  guest logs a FAULT. Orchard never fails the command buffer for a refused record. Is that silence ever
  worse than failing it?
