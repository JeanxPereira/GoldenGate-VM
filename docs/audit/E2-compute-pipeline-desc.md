# E2: compute pipeline descriptor (serializer object 0xB) and the 1522 `desc_decode` refusals

Sources: guest `AppleParavirtGPUMetalIOGPUFamily.c/` (x86_64 slice, small addresses), GPUTask
`ParavirtualizedGraphicsGPUTask.c/`, Orchard `external/orchard/reims-vgpu/crates/reims-vgpu/src/` on
`gg-macos27` (read at `3851d69`; the code involved is unchanged since `6fc0f4f`). Paths below are relative
to that `src/`. Logs: `/tmp/reims-vgpu-fail.log` is the 6fc0f4f run (there is no `.6fc0f4f` copy; it is
the 14:45 file with 1522 `desc_decode` lines). Every other `/tmp/reims-vgpu-fail.*.log` was compared.

## TL;DR

- **There is only one wire variant.** The lengths 48, 52, 56 and 60 are the same 4-property record with
  a different **label string length**. Every refused descriptor has the shape
  `tags=[02:4, 01:4, 0a:4, 00:4]`. Compute tag **0x0a** (value `0x2`) is unidentified, so
  `note_pipeline_tlv_fields` refuses the whole pipeline.
- **Wave 2 did not change the format.** The same refusal (`field_dropped kind=compute tag=0x0a
  first_value=0x2`) is in every macOS 27 log back to `before-probe`, which predates the key 27–35/18
  commits (`9e7331c`, `f38a4f2`). What changed is **volume**:
  - task 13, a second client, now builds labelled compute pipelines;
  - each refused ref is re-decoded on every submission by the Vulkan preflight. Failures are not
    cached.
- **Apple never parses these tags.** It hands the blob to Metal's
  `newComputePipelineDescriptorWithSerializedData:deserializationContext:`. Orchard must therefore
  name tag 0x0a itself. That needs a perturbation probe against the guest's Metal (see Fix 1).

## 1. Guest wire format

Emitter chain:
1. `-[AppleParavirtComputePipelineState initWithDevice:pipelineStateDescriptor:computeVariant:errorMessage:]`
   @0x1C728 copies the app's descriptor and replaces only `computeFunction`. It uses the variant's
   function, or the migrated one when `supportIndirectCommandBuffers` is set.
2. It then calls `-[device serializeComputePipelineDescriptor:]`. That is Metal.framework's serializer,
   **not** this plugin, and it returns `dispatch_data`.
3. It hands that to `-[PGSerializer newComputePipelineStateWithSerializedDescriptor:allocator:]` @0xCFC5.

The plugin applies no feature byte and no device-info key to the descriptor contents. Feature byte +21
(`supportsInfoEncoder`, v≥101) only selects how the guest asks for the pipeline info afterwards:
- v≥101: kext method 0x101, then `getComputePipelineStateInfo:` (op 450);
- below v101: kext method 0x10A, then `parseReply:` from a 48-byte descriptor buffer.

At v62 the second path runs. Orchard answers it as `get_compute_info`.

Record (CFC5):

| Off | Size | Field |
|---|---|---|
| 0 | u32 | `11` = serializer-object subtype compute PSO |
| 4 | u32 | total = 16 + round_up_4(payload) |
| 8 | u32 | new compute pipeline-state ref (`newComputePipelineStateRef`) |
| 12 | u32 | payload size, unrounded (asserts at PGSerializer.mm:639) |
| 16 | … | Metal compact property list: `u8 count`, then `count × {u8 tag, u8 len, value}`, then out-of-line data (strings, sub-objects) addressed by offsets relative to +16 |

Properties seen on 26A428. A property left at its default is omitted.

| Tag | Len | Property | Status in Orchard |
|---|---|---|---|
| 0x00 | 4 | `computeFunction` (function object ref) | consumed (`PIPELINE_TAG_KERNEL_FUNC`) |
| 0x01 | 4 | `threadGroupSizeIsMultipleOfThreadExecutionWidth` (BOOL) | benign |
| 0x02 | 4 | `label` (offset to a NUL-terminated string) | benign |
| 0x03 | 4 | `stageInputDescriptor` (offset) | consumed; not sent by this guest |
| **0x0a** | 4 | **unidentified**, first value `0x2` | **refused** (`!`) |

`maxTotalThreadsPerThreadgroup`, `buffers` mutability, `supportIndirectCommandBuffers`,
`linkedFunctions`, `binaryArchives`, `maxCallStackDepth` and `shaderValidation` have **not** been seen as
their own tags on this guest: there is no other compute shape in any log. Their ordinals are unknown.
Orchard's doc (resource/mod.rs:~3263) says `maxTotalThreadsPerThreadgroup` is a u16 with a different tag.

Measured shapes (`serializer_object_pipeline_shape`, latched per (tag, len) sequence; identical in
`.log`, `.de0e7ed`, `.5b042af`, `.ea4dfb5`, …):
- `kind=compute nfields=1 tags=[00:4]`: an unlabelled pipeline. It decodes and works.
- `kind=compute nfields=4 tags=[02:4*,01:4*,0a:4*!,00:4] unknown=1`: every refused pipeline.

### The lengths are label lengths

The property list is 1 + 4×6 = 25 bytes. The label string follows it, and the whole is rounded up to 4:

| desc_len | label length (chars, excluding NUL) | Refs (6fc0f4f) | Count |
|---|---|---|---|
| 48 | ≤ 6 | task 13: 204, 241, 380, 384, 462, 488 | 111/111/81/81/81/81 |
| 52 | 7–10 | task 13: 339, 400 | 81/81 |
| 56 | 11–14 | task 1: 98 | 407 |
| 60 | 15–18 | task 1: 95 | 407 |

Task 1's pair had the same lengths at de0e7ed (refs 89/92, 2× each). The label-length reading is
**inferred** from the arithmetic and from the single logged shape. A raw dump of one 48-byte descriptor
would confirm it.

### Which key "selects" a variant

None. 0x0a is present at v62 with or without the wave-2 keys. Wave 2 plausibly let more clients reach
compute: task 13 is new, and its refs ask `get_compute_info` repeatedly (pipe 204 twice). That part is
**inferred**. Not one compute descriptor byte depends on keys 18/29/30/31/33.

## 2. What Apple's host does

Lookup and creation:
1. `sub_10005F9CC` is the compute get-or-create. It calls
   `PGResourceManager::createObject<MTLComputePipelineState>` @0x10003DAB8, which:
   - requires object tag 7 and serializer subtype 11 (otherwise "Invalid serializer command type ({})");
   - calls `newComputePipelineStateWithDescriptor(...)` @0x10003D0A0.
2. `newComputePipelineStateWithDescriptor` reads the payload and calls
   `-[MTLDevice newComputePipelineDescriptorWithSerializedData:deserializationContext:]`. Metal
   deserializes the property list itself, including tag 0x0a and the label, and resolves the function ref
   through the deserialization context.
3. If an object placement exists, it sets `setResourceIndex:` and `setForceResourceIndex:YES`.
4. It calls `newComputePipelineStateWithDescriptor:options:0 reflection:nil error:`, writes the
   placement back (`resourceIndex`, `gpuResourceID`), then `registerPipeline(uniqueIdentifier)`.

Failure strings (as `expected<…, string>`): "Insufficient data in command", "Failed to read
descriptor: {}", "Function lookup failed during pipeline deserialization: {}", "Compute pipeline
descriptor has nil computeFunction", "Failed to create compute pipeline: {}", and in the caller
"Failed to register object".

The error goes back up to the ref lookup. Op 208 then throws "Invalid compute pipeline state" (see E
§compute), so the command buffer fails decode and the guest sees an errored command buffer. Apple also
has to build the pipeline to answer the 0x10A info query; there a failure would give the guest a nil
pipeline at creation (**inferred**). Apple has no partial or "dropped field" path: unknown Metal
properties are Metal's own business.

## 3. Orchard

Call path:
1. `load_compute_pipeline` runtime/compute_exec/mod.rs:951 → `decode_serializer_object_descriptor`
   runtime/decode/resource/mod.rs:5601.
2. → `decode_compute_pipeline_descriptor` :5203 → `decode_compact_tlv_record` :2669.
3. → `note_pipeline_tlv_fields` :3434 → `report_tlv_shape` :3515.
4. Tag 0x0a is neither in `COMPUTE_PIPELINE_TAGS_CONSUMED` :3037 nor in `COMPUTE_PIPELINE_TAGS_BENIGN`
   :3185, so it returns `ErrUnsupported("res_pipeline_field_unread")`.
5. The caller flattens that to `desc_decode` (compute_exec/mod.rs:983). **The sub-slug is lost** in the
   rung line.

The cause is the same for all four lengths: tag 0x0a. There is no length-dependent bug. The header
check, the TLV walk and the label offsets are all fine.

Why there are 1522 lines:
- `preflight_compute_translations` runtime/exec/vulkan.rs:207 calls `load_compute_pipeline` for every
  dispatch of every submission.
- The dispatch paths (compute_exec/vulkan.rs:499 and others) call it again. Nothing caches a negative
  result.
- Only 10 `compute_record … compute_vk_pipeline_load class=missing_pipeline` were recorded (8 task 13,
  2 task 1), so most of the lines are preflight re-decodes.

Divergence from Apple: Orchard answers `get_compute_info ok` for exactly these refs (task 1 pipes 95/98,
task 13 pipes 204/241). The guest is told the pipeline exists, and then every dispatch on it is silently
dropped.

| Op/type | Name | Payload | Apple host behaviour | Orchard handler | Status | Seen | Prio |
|---|---|---|---|---|---|---|---|
| obj 7 / sub 0xB | compute PSO descriptor | 16 B header + Metal property list (48–60 B seen) | Metal deserializes every property, then builds the pipeline; failure throws at op 208 | resource/mod.rs:5203, refused at :3434 | **divergent**: tag 0x0a refused, so labelled pipelines are lost (unlabelled ones work) | 1522 (10 refs) | **P0** |
| 0x10A info | compute pipeline info | 48 B reply | needs the built pipeline (inferred) | `get_compute_info ok` | divergent: answers OK for a pipeline it will refuse | 164 | P1 |

## 4. `compute_vk_translate class=metal_failed task=10 pipe=10`

This is a timing race, not a shader failure:

| t (µs) | Line |
|---|---|
| 852472 | `linux_m2v_async queued pipe=10 stage=Kernel tg=[32,32,1]` |
| 852473 | `compute_linux_m2v reason=m2v_translation_pending_at_sync_boundary` (runtime/m2v_cache.rs:186) |
| 852473 | the dispatch is recorded as `compute_vk_translate`; its class falls into the `MetalFailed` bucket (compute_exec/mod.rs:655) |
| 852517 | `linux_m2v_async done pipe=10 … ok spv=7904` |

The translation finished 44 µs later. One dispatch was dropped, and the class name is misleading.

## Ranked fix list (for the port)

1. **Identify compute tag 0x0a** (blocker for 2). Size: ~40-line JXA script plus one `gg ssh` run.
   Risk: none, read-only in the guest.
   - Use the same method as the render sweep documented at resource/mod.rs:~3300. In the guest, run
     `osascript -l JavaScript` with `ObjC.import('Metal')`. No compiler is needed.
   - Build `MTLComputePipelineDescriptor.new`, set exactly one property per probe, and call
     `dev.serializeComputePipelineDescriptor(d)`. Print the tags.
   - Probe at least: `maxTotalThreadsPerThreadgroup`, `supportIndirectCommandBuffers`,
     `maxCallStackDepth`, `shaderValidation` (2 = Disabled), `textureWriteRoundingMode` (render
     0x1e), `supportAddingBinaryFunctions`, `requiredThreadsPerThreadgroup`, and the
     `MTLComputePipelineDescriptorInternal` scalar setters.
   - Candidates for value 2 (**unverified**): `shaderValidation=Disabled`, `maxCallStackDepth=2`, a
     rounding-mode SPI.
2. **Name 0x0a in the compute tag lists.** Size: ~10–25 lines plus a test with a 4-field fixture
   (`[02,01,0a,00]` and a label, lengths 48 and 60). Risk: low. Unblocks all 10 refs.
   - If it is validation, call depth or rounding mode: add it to `COMPUTE_PIPELINE_TAGS_BENIGN` :3185
     with the written argument the file requires.
   - If it is a threadgroup cap: consume it and clamp the value in `get_compute_info` and at dispatch.
3. **Cache the negative decode** per (task, pipe_ref, object generation) in `load_compute_pipeline`.
   Clear it on the ref-forget hook from `8ee1678`. Size: ~15–25 lines. Risk: low. This stops about 1500
   identical re-decodes per boot.
4. **Carry the sub-slug into the rung line**, e.g. `desc_decode sub=res_pipeline_field_unread tag=0x0a`.
   Size: ~5 lines. Risk: none. The cause was only visible from a separately latched OFF line.
5. **Parity: do not answer `get_compute_info ok` for a descriptor Orchard cannot decode.** Fail the
   reply so the guest's `parseReply:` returns nil, as Apple's would. Size: ~20 lines. Risk: medium, since
   apps get a nil pipeline instead of silent no-op dispatches. Do this only after 2.
6. **m2v pending at the sync boundary:** wait for or re-queue the pending translation (or classify it
   as `pending`) instead of dropping the dispatch as `metal_failed`. Size: ~20–40 lines in the
   compute_exec/vulkan sync path. Risk: low to medium (latency at the boundary).

## Open questions

- What is tag 0x0a? Fix 1 answers it. Without Metal.framework in the RE corpus there is no static
  answer: the PG binaries never parse it.
- Confirm that the 48/52 vs 56/60 split is label length only. Dump the bytes of one refused
  descriptor; the OFF shape line could also print `desc_len`.
- Does Apple really build the pipeline when it answers 0x10A (making Fix 5 exact parity)? Its
  FIFO/kext info handler is not traced here.

## Tag table from Metal

Source: `Metal.framework` from the 26A428 OS cryptex dyld cache (arm64e), IDA database
`<RE corpus>/Metal.i64` (`gq.py dsc`). Static answer, no guest probe needed.

**Tag 0x0a = `textureWriteRoundingMode`, and value 2 = `MTLRoundingModeRTNE`.** The `shaderValidation`
hypothesis is refuted: the compute serializer does not emit `shaderValidation` at all.

Chain (both directions are the same compact property list):
- Guest: `-[_MTLDevice serializeComputePipelineDescriptor:]` @0x18D649EBC → block @0x18D649F88 →
  `PipelineDescriptorSerializerPrivate::serializeComputePipelineDescriptor` @0x18D58B2F8 →
  `PipelineLibraryBinarySerializer::serializeComputePipelineDescriptor` @0x18D588378 →
  `PipelineLibrarySerializer::serializeComputePipelineDescriptorInternal` @0x18D584E88.
- Host (what PG's GPUTask calls): `-[_MTLDevice newComputePipelineDescriptorWithSerializedData:deserializationContext:]`
  @0x18D64A008 → `PipelineDescriptorDeserializer::newComputePipelineDescriptor` @0x18D58B470 →
  `PipelineDescriptorBinaryDeserializer::newComputePipelineDescriptor(SerializedCompactPropertyList&)` @0x18D58913C.

The serializer writes each scalar as `(tag, value, default)`, where the default is a fresh
`MTLComputePipelineDescriptor`. A property equal to its default is omitted (**inferred** from the
3-argument call and from the observed omissions). Emission order is 2, 3, 1, 8, 7, 10, 12, 6, then 0.
Tag 0 is appended last by @0x18D588378 with default `-1`. This matches the refused shape
`[02,01,0a,00]`.

| Tag | Property (deserializer setter @0x18D58913C) | Wire value | Source field / default |
|---|---|---|---|
| 0x00 | `computeFunction`: `setComputeFunction:` via the context vtable +16 (function ref) | u32 function ref | `functionRef`, default -1 |
| 0x01 | `threadGroupSizeIsMultipleOfThreadExecutionWidth` | u32, `!= 0` → BOOL | u8 |
| 0x02 | `label`: `initWithUTF8String:` | offset to a NUL-terminated string (object) | written when label != nil |
| 0x03 | `stageInputDescriptor`: `deserializeStageInputDescriptor`, or nil | object | when != default |
| 0x06 | `buffers`: object list → `deserializeBuffers` per entry | object (u32 count + objects) | when != default |
| 0x07 | `supportIndirectCommandBuffers` | u32, `!= 0` → BOOL | u8 |
| 0x08 | `maxTotalThreadsPerThreadgroup` | u32 (source field is u16) | u16 |
| **0x0a** | **`textureWriteRoundingMode`** (`setTextureWriteRoundingMode:`) | u32 `MTLRoundingMode` | NSInteger `_private.textureWriteRoundingMode` |
| 0x0c | `needsCustomBorderColorSamplers` | u32, `!= 0` → BOOL | u8 |

Tags 4, 5, 9, 0x0b and anything above 0x0c are ignored by the compute deserializer (`default: break`).

`MTLRoundingMode` comes from `_MTLRoundingModeString` @0x18D643D38, which indexes the table at
0x1E0AA6D68 (values > 2 → "Unknown"): 0 = `MTLRoundingModeDefault`, 1 = `MTLRoundingModeRTZ`,
**2 = `MTLRoundingModeRTNE`**. `-[_MTLDevice defaultTextureWriteRoundingMode]` @0x18D64B678 returns 0.

Not serialized for compute: `shaderValidation` (the getter exists at @0x18D6EAB1C but is never written),
`textureWriteFPRoundingMode`, `maxCallStackDepth`, linked or binary functions.

The guest gates the mode with `-[AppleParavirtDevice supportsTextureWriteRoundingMode:]` @0x22DD0 on device-info
`SupportedTextureWriteRoundingModes` (bit `1<<mode`) when that key is defined. Which client sets RTNE is not
established. It is probably the app or CoreAnimation, since the plugin only replaces `computeFunction`.

Implication for Fix 2: 0x0a is a texture-write rounding hint (RTNE = round to nearest even). It is
benign for Orchard: Vulkan storage-image writes of float to unorm/fp16 already round to nearest. Add it
to `COMPUTE_PIPELINE_TAGS_BENIGN` with that argument. The same Metal serializer probably also writes a
render tag for `textureWriteRoundingMode`; the render sweep's 0x1e is consistent with that (**inferred**,
not traced here).
