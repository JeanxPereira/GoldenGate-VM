# C19: Raising the protocol rung from 62 to 237: the porting map

Goal: get APVFeatures byte 50 (`supportsTextureDescriptor2`) on. It is set only from rung **237**
(C18-texture-usage.md, C18-host-format-caps.md). The ladder is cumulative and the guest builds its
features from the rung it reads back (A-features.md A.0 §2), so 237 also turns on every byte from
20 to 48. Byte 49 (rung 238, DisplayPort registers) stays off. 236 is "unsupported" and 234 is
not a rung, so the last steps are 235 → 237.

Sources and notation:
- **SB** = steelbrain `steelbrain/reims-vgpu/crates/reims-vgpu-core/src/` @ 12765ee.
- **OR** = Orchard `external/orchard/reims-vgpu/crates/` (`gg-macos27` @ 5a634ef). Paths start
  with the crate (`reims-vgpu/src/...`, `reims-vgpu-protocol/src/...`, `reims-vgpu-wire/src/...`).
- **KC** = guest kext `<RE corpus>/kc.c/`, **MP** = guest Metal plugin.
  Feature byte N is kext byte `+14NN` (A-features A.0 §1).
- "inferred" means not read in a binary.

## 0. What already exists and what does not

- **The negotiation is ready.** OR `reims-vgpu/src/model/regs.rs:1282` `APV_LADDER` is the full
  26A428 ladder up to 252. `negotiate_protocol_version_with_cap` (:1410) follows the Apple
  step-down. The one change needed is at `:1446`: `cap.min(PROTOCOL_VERSION_MAX)` silently caps
  the env value at 62. `PROTOCOL_VERSION_MAX = 62` (:1111) can stay as the default.
- **The host does not gate the wire on feature bytes.** SB gates only a few FIFO opcodes on
  features (SB `docs/testing.md:1436-1467`; `fifo/commands/exec.rs:44-52`,
  `fifo/commands/display.rs:239,261`, `fifo/commands/task.rs:298,312`). OR decodes whatever
  arrives. So each rung costs exactly what the **guest** starts sending.
- **The real lever is the device-info keys, not the rung.** Most MP features above 100 are
  `byte && key`: 20 && key 19, 25 && key 21, 27 && keys 23-27, 31 && key 28 bit 1, 36 && key 33 bit 2
  plus key 36, 37 && key 33 bit 4, 41 && key 33 bit 5, 45 && key 42 bit 0 (A-features A.2/A.3). The
  Apple `writeDeviceInfo` sends those keys only when the host can do the feature. OR
  `device_info_caps` (`regs.rs:1793`) withholds a key only when its byte is off
  (`device_info_key_feature_gate`, `:1726`). **At a raised rung OR would advertise tile shaders,
  imageblocks, ROG, programmable sample positions, shared textures, command-buffer jump and
  argument buffers**: the table at `:1926` has keys 19, 21, 23-26 and 36 set to 1, and key 33 =
  0xFFF minus bits 4, 7, 9 and 10 (`:2139`), which leaves bits 2, 5 and 11 set. Fixing that is
  Wave 0, and it has to come before any rung above 62.
- **Features gated on a byte alone** (the guest switches without asking a key) are the porting set:
  100 (kernel task size), 101 (info channel and info encoder), 108 (FIFO 11), 109 (ExecIndirect3),
  110 (descriptor2 for plain textures), 207 (FIFO 68 instead of 51), 208 (FIFO 12), 209 (XR10
  layout), 235 (InfoIndirect), 237 (descriptor2 everywhere).

## 1. Rung table, 63 → 237

The OR column says where OR handles the item today. "missing" means no decoder. "partial" means
the wire struct exists but the runtime path does not use it, or the item is decoded and then
dropped. M = mandatory: the guest switches format unconditionally. D = on demand. G = gated off by a
device-info key that Wave 0 withholds.

| Rung | Byte | Feature | What changes on the wire | SB | OR status | M/D/G |
|---|---|---|---|---|---|---|
| 100 | 20 | sharedTextures | **KC `createKernelGPUTask` @0xFFFFFE00086A2AAC:8**: the kernel task VA size grows from 1 GiB to 16 GiB, or to 256 GiB when kext `+1288` bit 1 is set (inferred: key 33 bit 1, large kernel tasks, which OR sends). MP: object types 16/17/18 and FIFO 65 DeleteSharedTextureBacking, gated by key 19 | `resources/manager/texture.rs:747,779-780,1435`; `fifo/commands/task.rs:287`; key 33 `guest/abi/device_info.rs:254` | VA: probably OK. Depth 3 with 16 KiB pages covers 47 bits; `reims-vgpu-wire/src/page_table.rs:102` MAX_DEPTH 4. Types 16-18: missing. FIFO 0x41: unimplemented arm (`reims-vgpu/src/runtime/drain/mod.rs:6492`) | M (VA) / G (types) |
| 101 | 21 | infoEncoder | **KC `setupChannels` @0xFFFFFE00086A1950:169** opens a virtual channel "Info", **id 12**, with a 0x80000 B ring. MP sends queries as **segment type 4** records 450-469, with replies written into a buffer object at decode time and the guest waiting (`waitUntilCompleted`, C6 §4.2). At this rung execs still go through 0x37 | `deserializer/info.rs:133-157` (dispatch); 450 `:192`, 451 `:219`, 457 `:401`, 458/459 `:427/452`, 460 `:477`, 461-468 `:512-625`, 469 `:240`; layouts in SB `docs/testing.md:2661-2700` | **partial**: the type-4 segment is framed (`reims-vgpu-protocol/src/segment.rs:166`) and every record goes to `handle_info_record` (`reims-vgpu/src/runtime/exec/mod.rs:1795`), which answers nothing (`note_info_record_unanswered`). Wire structs: `reims-vgpu-wire/src/ops/info.rs:43-52,145,186,221,260`. Ledger: all Unresolved (`reims-vgpu-protocol/src/closure.rs:1664-1800`) | **M** |
| 102 | 22 | defaultRasterSampleCount | render pass prefix 0x1e/0x1f (`{u32 count}`) | `deserializer/render/pass.rs:217-218,346-372` | 0x1e: honoured at 1, other values refused (`closure.rs:770`). **0x1f: not a pass opcode in OR** (`reims-vgpu-wire/src/ops/render_pass.rs:536`, which says it was never captured), so a 0x1f in the prefix breaks the pass | D (inferred; RE Q4) |
| 103 | 23 | vertexAmplification | render 0x99/0x9a | `deserializer/render.rs:361-362` | Unresolved (`closure.rs:1100-1108`). Key 20 is absent, so the count is ≤ 1 (inferred) | G (key 20 absent) |
| 104 | 24 | sunburstDisplay | no reader in 26A428 | — | — | inert |
| 105 | 25 | programmableSamplePositions | pass prefix 0x20 | `render/pass.rs:219,374` | dropped with a count (`closure.rs:779`); **key 21 sent = 1** | G after Wave 0 |
| 106 | 26 | rasterizationRateMaps | FIFO 66; object type 7 cmd 0x32; pass 0x21; info 452-456 | `fifo/commands/task.rs:298`; `deserializer/rate_map.rs`; `info.rs:262-375` | FIFO 0x42: unimplemented arm (`drain/mod.rs:6495`); 0x32: Unresolved (`closure.rs:381`); key 22 absent | G (key 22 absent, inferred) |
| 107 | 27 | tileShadersImageBlocks | pass 0x22-0x24; render 0x9b-0xa4; pipeline cmd 51; compute 0xd8 | `render.rs:363-372`; `render/pass.rs:221-223`; `compute.rs:325,863` | tile ops Unresolved (`closure.rs:795-811,1116-1188`); **keys 23-26 sent = 1** | G after Wave 0 (pass-prefix records: RE Q4) |
| 108 | 28 | displayCompositorParameters | **FIFO 11**, 20 B: `u32 display@0, u16 x@4, u16 y@6, u64@8, u8@16`. Sent by KC `setParameter` @0xFFFFFE000869DB6C:20 | `fifo/commands/display.rs:239-258` (signals) | unimplemented arm (`drain/mod.rs:6486`) | M when WindowServer sets parameters (likely at boot, inferred) |
| 109 | 29 | cmdExecIndirect3 | **Every exec becomes FIFO 67 instead of 55** (KC `processSegmentKernelCommand` @0xFFFFFE00086B1928:568 tests `+1429`). The header is the same 12 B; resource records are **8 B `{u32 ref, u32 flags}`, with flag bits 0/1/2 = invalidateHost/invalidateGuest/synchronize**, instead of 24 B with one byte per flag | `fifo/commands/exec.rs:24-30,44-93,142-164`; `guest/records.rs:304-340`; `tasks/local.rs:594` | **missing**: unimplemented arm (`drain/mod.rs:6498`); the core layer refuses it (`reims-vgpu-core/src/control.rs:352`, `session.rs:1946`); the 24 B stride is hard-coded at `reims-vgpu-protocol/src/fifo.rs:895,1217-1248`, `reims-vgpu/src/runtime/exec/mod.rs:851`, `reims-vgpu-core/src/lifecycle.rs:4781`; arrival only reads 0x37 (`drain/mod.rs:2333`) | **M** |
| 110 | 30 | swizzledTextures | **MP `newTextureWithDescriptor:allocator:` @0xD29D always emits cmd 0x34 (52)** with descriptor2: packed 0x27 B, `bits[3]` (type, flags, pixelFormat u16 at +1), usage u32 at +3, …, swizzle[4] at +0x23. The op is 0x2c B. This covers object types 2/3/12 (paged) and 8/9 (memoryless) | `resources/manager/texture.rs:155-161,400-428,620-624,698-745,917-918`; `deserializer/texture_descriptor.rs:67-94` | types 8/9 with cmd 52: **OK** (`reims-vgpu/src/runtime/decode/resource/mod.rs:4879,4918`). Types 2/3/12: **missing**. The pixel format is read at fixed offset 86 (`:718`, `:2366-2372`); under v2 it is at 85, so every paged texture would misdecode. The wire struct exists (`reims-vgpu-wire/src/ops/texture.rs:311,485`) but is unused, even though the ledger says Implemented (`closure.rs:389`) | **M** |
| 111 | 31 | dynamicAttributeStride | compute 0xd9/0xda, render 0xa5/0xa6; key 28 bit 1 | `compute.rs:326-327,525,736`; `render/state.rs:602,629` | OK (`closure.rs:1196-1204,1350-1358`); key 28 bit 1 already follows the rung (`regs.rs:1746`) | D |
| 112 | 32 | blitEncoderSPI | blit 318-323 (fillTexture with bytes or colour, slices/levels copy, compressed invalidate) | `deserializer/blit.rs:207-212` | 318/319 OK; **320/321 Unresolved** (`closure.rs:1630,1638`); 322/323 no-op | D (RE Q5) |
| 113 | 33 | multiplaneMippedBlitTextures | type 12 with mips > 1; mipped two-plane shared backings | `resources/manager/texture.rs:678` (plane_count) | type 12 is decoded for XR10 only (`decode/resource/mod.rs:157`) | D |
| 200 | 34 | computePassDispatchType | compute 0xdb as the first record | `compute.rs` (first-record rule, SB `docs/testing.md:2457`) | OK (`closure.rs:1366`) | M (inferred), already handled |
| 201 | 35 | objectUniqueIdentifier | info 460 `{ref, objectType, replyBuf, u64 off}`, u64 reply | `info.rs:148,477` | missing (unanswered) | D |
| 202 | 36 | commandBufferJump | compute 0xdc-0xe2; key 36 | `compute.rs:328-334,874` | Unresolved (`closure.rs:1374-1422`); **key 33 bit 2 is set and key 36 = 16 at ≥ 202** | G after Wave 0 |
| 203 | 37 | sharedStorageHeaps | shared heaps | — | key 33 bit 4 already cleared (`regs.rs:2140`) | G |
| 204 | 38 | heapHazardTracking | KC `setupWithArgs`:135: heap args flags bit 1 = tracked (C6 §1) | SB `docs/testing.md:2177` (type 13 flags bit 1) | not checked; OR must accept the bit and ignore it | D |
| 205 | 39 | protectionOptionsEnvelope | segment type 5: `u64` options, then the real 8 B header | `deserializer/walk.rs:43` | framed (`segment.rs:167`, `SegmentRole::ProtectionEnvelope`) | D (RE Q7) |
| 206 | 40 | compressedTextureReinterpretationFlush | compute 0xe3 | `compute.rs:335` | proven no-op (`closure.rs:1430`) | D |
| 207 | 41 | argumentBuffers | **KC `AppleParavirtTask::setResourceHeap` @0xFFFFFE00086ABEB0:39-41 sends FIFO 68 instead of 51** for every task. 28 B: `u32 task@0, u64 objectListVA@4 (a byte offset, not a PFN), u64 placementListVA@12, u32 objectListBytes@20 (= 12·count), u32 placementBytes@24 (= 16·count)`. The host writes `{gpuAddress or resourceIndex, resourceID}` into placement entries (SB `docs/testing.md:2097-2108`). MP argument buffers and info 461-468 are gated by key 33 bit 5 | `fifo/commands/task.rs:312-329`; `tasks/object_lists.rs:307-380`; `guest/records.rs:366-375` (TaskRoot2 +0x1c/+0x24) | **missing**: unimplemented arm (`drain/mod.rs:6501`). The 0x33 handler `apply_set_object_list` (`drain/mod.rs:1062`) has the same semantics; `u32@8` of 0x33 is the same byte length (KC :101) | **M** (FIFO 68) / G (MP argument buffers, after Wave 0) |
| 208 | 42 | displaySetGuestICCProfile | **FIFO 12**, 24 B: `u32 display@0, u32 length@4, u64 VA@8, u64 mappedLength@16`, from KC swap path :86 | `fifo/commands/display.rs:261-287` (always signals) | unimplemented arm (`drain/mod.rs:6489`) | M when the display has a profile (likely, inferred) |
| 209 | 43 | correct2pXR10A8 | **No new opcode.** `-[AppleParavirtDevice supportsCorrectExtendedXR10Formats]` (MP @0x23506) returns this byte. The reader is Metal or QuartzCore (not MP), and it changes the 550/551 two-plane layout the guest writes | not used by SB | OR XR10 plane conversion (5b042af, `reims-vgpu/src/runtime/xr10_planes.rs`) was built on the "incorrect" layout | **M** (layout change, RE Q3) |
| 230 | 44 | cpuBuffers | object type 19, used only as an info reply target | SB `docs/testing.md:2165`; `info.rs:68` (writable cursor accepts types 1 and 19) | missing | D (RE Q9) |
| 231 | 45 | indirectCommandBuffers | MP ICB, gated by key 42 bit 0; object type 20; blit 305/312/313, compute 0xe4/0xe5, render 0x14/0x15, info 465 | `resources/manager/icb.rs`; `blit.rs:194,201-202` | type 20 and render 0x14/0x15 exist (`reims-vgpu/src/runtime/icb`); key 42 = 2, so bit 0 is off | G (already) |
| 232 | 46 | protectedTextureOptions | descriptor `protection_options` u64 | `texture_descriptor.rs:29,89` | ignored | D |
| 233 | 47 | dispatchThreadsIndirect | compute 0xe6 | `compute.rs:338` | OK (`closure.rs:1455`) | D |
| 235 | 48 | infoIndirect | **KC `processSegmentKernelCommand`:293: an info queue (`+1512`) with byte 48 sends FIFO 69** in place of the exec. Layout = FIFO 67 (12 B header, 8 B resources, 16 B command buffers); the command buffers hold type-4 segments | `fifo/commands/exec.rs:167-189`; `tasks/local.rs:641` | **missing**: unimplemented arm (`drain/mod.rs:6504`) | **M** |
| 237 | 50 | textureDescriptor2 | v2 forms of everything else: **0x39 (57)** IOSurface plane texture, 0x30 B with plane u16 and rotation u16 after the descriptor (object types 5 and 11); 0x37 (55) buffer texture, 0x40 B; 0x38 (56) heap texture, 0x3c B; 0x35 (53) shared backing; info **469** (0x1d5) heap size/align v2, 0x34 B. MP stops refusing usage ≥ 0x100 (bits 0x4000/0x8000/0x10000 are SPI) | `resources/manager/texture.rs:226-266,922-925,1207-1245,1300`; `deserializer/records.rs:649-666`; `info.rs:240` | 0x37 OK (`decode/resource/mod.rs:4805`); 0x38 OK (`:4584`); **0x39 missing on type 5** (`reims-vgpu-wire/src/device_desc.rs:228-282` reads a v1 record: "kind 0x2f observed", "tag" = v1 bits byte 0) **and on type 11** (`decode/resource/mod.rs:4955-4999`: fixed v1 offsets, pixel format at 0x16). The wire struct exists: `reims-vgpu-wire/src/ops/backed_texture.rs:114-168`. 469 missing (`reims-vgpu/src/runtime/exec/report.rs:835`). Heap-query FIFO 64 stays v1 in SB (`resources/manager/create.rs:512-542`) | **M** |

Not needed for 237: 238 (byte 49, register +0x234), 245 (byte 51, MMIO 0x122c/0x1234), 250-252.
maxFIFOCount and s8ByteCount do not change above 62.

## 2. What the boot will actually exercise

**Mandatory to decode** (the guest switches format with no key gate; WindowServer and CA hit every
one of these on the way to the desktop):
- 100: larger kernel task VA (KC, read).
- 101: Info channel 12 and type-4 queries 450 (compute pipeline info), 451 (heap texture size) and
  457 (render pipeline info). Which queries move off FIFO 0x3b/0x40 is inferred (RE Q1).
  An unanswered reply leaves stale bytes that the guest trusts.
- 109: ExecIndirect3 on every exec (KC, read).
- 110: cmd 52 for every plain texture (MP, read in C18).
- 207: FIFO 68 for every task object list (KC, read).
- 209: the two-plane XR10 layout (used by the compositor 550/551 intermediates, C5/C13).
- 235: InfoIndirect for every info submission (KC, read).
- 237: 0x39 on IOSurface textures (the Liquid Glass path), plus 0x37/0x38 and 469.

**Likely exercised, small:** 108 FIFO 11 and 208 FIFO 12. Both only need a decode, a log line and
stamp completion. 102 pass prefix 0x1e/0x1f, if MP writes the descriptor sample counts in every
pass (RE Q4).

**Become possible but on demand:** 112 fills (320/321), 113 mipped two-plane, 201 info 460,
204 tracked heaps, 205 envelope, 206 0xe3, 230 type 19, 232, 233.

**Kept off by device info (Wave 0):** 100 shared textures (key 19), 105 (key 21), 107 tile
(keys 23-26), 202 jump (key 33 bit 2, key 36), 203 (key 33 bit 4), 207 MP argument buffers
(key 33 bit 5), 231 ICB (key 42 bit 0). 103 and 106 are off because keys 20 and 22 are absent.

## 3. Wave plan

Every valid rung is a possible stop: 100-113, 200-209, 230-233, 235, 237. The infrastructure in
Wave 0 lets `REIMS_VGPU_PROTOCOL_CAP=N` select any of them. The rungs that cannot be split are
listed after the table.

| Wave | Stop rung | Work (OR function → change) | Size | Risk | Boot check |
|---|---|---|---|---|---|
| W0 | 62 (unchanged default) | `protocol_version_cap` (`regs.rs:1439`): accept up to `APV_LADDER_TOP` and log the env rung. `device_info_caps` (`:1793`): a second gate, "host can do it": always withhold keys 19, 21, 23-26 and 36; clear key 33 bits 2, 5 and 11 (and bit 3 rangeBuffer unless verified). Make sure the seven `note_unimplemented` arms (`drain/mod.rs:6486-6506`) complete their stamps | 40 + 60 tests | low | Boot at 62: identical; device-info log shows only key 33 changed. Boot at cap 100: `negotiated=100`, desktop, no new fails |
| W1 | 100 | Check that no OR structure is sized by the kernel task length (task-length checks, `guest_ram_map`, GVA spans) | 0-40 | low | cap 100: desktop; DefineTask2 for task 0 logs the new length; no `depth-too-deep` |
| W2 | 101 | Info encoder: `handle_info_record` (`exec/mod.rs:1795`) answers 450/451/457 using the GetComputeInfo (`drain/mod.rs:6511`) and `heap_query.rs` computations. Reply writer into the reply buffer object guest pages (types 1 and 19) at `reply_offset`. 458/459/460-468 log and refuse. Channel 12 accepted | 350-450 | med-high | cap 101: fail log has `info_answered`, no `info_record_unanswered` for 450/451/457; C6 "unable to create heap: 0" gone (the guest now waits) |
| W3 | 108 | `is_render_pass_opcode` + prefix: accept 0x1f (record and ignore, honour 1). 0x99/0x9a: accept count 1. FIFO 11: decode 20 B, log, complete | 60-90 | low | cap 108: no `render_pass_*` refusals beyond W2; FIFO 11 counted |
| W4 | 109 | ExecIndirect3: a resource-record variant in `decode_exec_resource_table` (stride 8, flags from bits 0-2 into `InvalidateValidityOps`); admit 0x43 in core `control.rs`/`session.rs`; arrival (`drain/mod.rs:2333`) and execution (`:6547`) arms for 0x43; `exec/mod.rs:851` and `lifecycle.rs:4781` use the stride; census | 200-300 | **high** (every frame) | cap 109: desktop renders as at 101; exec count unchanged; zero `UnsupportedExec`/`exec_retained_inputs_missing` |
| W5 | 110 | Descriptor2 on paged textures: in the type 2/3/12 decoder (`decode_texture_dimension_block`, `decode/resource/mod.rs:2219`) branch on the op header commandType 1 vs 52. Under 52: format at +1, usage u32 at +3, extent at +7, swizzle at +0x23, mapped onto the Vulkan component mapping (identity when 0/default) | 150-250 | **high** (all textures) | cap 110: no `texture_desc_trailer_disagrees`; icons, wallpaper and windows as at 109 |
| W6 | 113 | 320/321 FillTexture (bytes/colour) on the blit rail; type 12 with mips > 1 refused by name | 120-160 | med | cap 113: no blit `unknown_opcode`; fills counted |
| W7 | 206 | Info 460 (u64 id per object); accept heap flag bit 1; envelope through exec, with a unit test of a real type-5 segment | 60-100 | low | cap 206: desktop; no `framing_*` fails |
| W8 | 209 | FIFO 68 → `apply_set_object_list` (offset = byte VA, length = bytes); zero the placement list or leave it untouched (MP argument buffers are off); FIFO 12: decode 24 B, log, complete. **XR10 correct layout:** re-derive `xr10_planes` from RE Q3 | 80 + XR10 (unknown, 100-300) | **high** at 209 | cap 208 first (68 + ICC only): desktop. Then cap 209: XR10 surfaces (Dock, menu bar) render correctly |
| W9 | 235 | Type 19 as a reply target; FIFO 69 routed to the W2 info walker with the W4 record parse | 80-120 | med | cap 235: info answers continue (they now arrive through 0x45) |
| W10 | 237 | 0x39 on type 5 (`device_desc.rs` record: branch on kind 47 vs 57, v2 offsets, plane and rotation after the descriptor) and on type 11 (`decode_iosurface_texture_descriptor`); info 469; a usage → Vulkan usage map that ignores 0x4000/0x8000/0x10000; check 0x37/0x38 against live bytes | 150-250 | med | cap 237: no "Cannot create a texture with this usage" in WindowServer; "Failed to allocate 1920x128 surface texture" gone; glass backdrop captured (C17) |

Total: about 1300-2000 lines plus tests.

**Stops that are impossible:**
- Byte 50 cannot be had without bytes 20-48 (cumulative, A.0 §2).
- 110 needs 109, and both need 101. W4 is a single rung and its ExecIndirect3 port is atomic:
  once 109 is negotiated there is no "half" path.
- 236 and 234 are not stops (236 unsupported, 234 absent).
- W2 must also handle info routing from W4 and W9 onward: execs become 67 and info becomes 69, so
  the info walker has to be reachable from all three FIFO opcodes.
- **W0 is a precondition for every rung ≥ 105.** Without it the guest is told tile shaders are
  available (105/107) and command-buffer jump and argument buffers (202/207). It would then send
  Unresolved tile ops and pipelines (cmd 51), which OR cannot execute.

## 4. Open questions for guest RE

1. At byte 21, which MP/KC queries move to the info encoder (450, 451, 457; does 459 appear
   without tiles?), and does KC still send FIFO 0x3b GetComputeInfo and 0x40 at ≥ 101? Do replies
   go to a type-1 buffer or a type-19 CPU buffer?
2. Is kext `+1288` bit 1 key 33 bit 1 (large kernel tasks)? This decides 16 GiB vs 256 GiB.
3. Byte 43: which framework reads `supportsCorrectExtendedXR10Formats` (Metal or QuartzCore), and
   what exactly changes in the 550/551 plane-1 (A8) layout or size?
4. Byte 22/27: does MP `writeDescriptor` emit 0x1e/0x1f/0x22-0x24 for every render pass once the
   byte is on, or only for non-default values? Is 0x1f the color-sample-count SPI?
5. Byte 32: which `PGSerializerBlitCommandEncoder` calls change from a fallback to 318-323?
6. Byte 30: does MP also send cmd 52 for type 3 (generate-mipmaps) and type 12, and which swizzle
   bytes does it write by default?
7. Byte 39: is the type-5 envelope emitted for every command buffer, or only when
   `protectionOptions != 0`?
8. Byte 41: does MP or KC read the placement list back when key 33 bit 5 is 0 (that is, does the
   host have to write it)? Is the kernel task `setResourceHeap` @0xFFFFFE00086ACCCC also 68?
9. Byte 44: when does MP create type-19 objects?
10. Byte 35: does anything at boot call `uniqueIdentifier` (info 460)?
11. Does the Info channel (id 12) need any host-side handshake beyond DefineFifo, for example a
    reserved ring size?

## §4 answers (guest RE, 26A428)

MP = `AppleParavirtGPUMetalIOGPUFamily.c/`, KC = `kc.c/`. The kext keeps the device-info struct at `AppleParavirtGPU+1160`
(`setupDeviceInfo` @0xFFFFFE00086A2074:96 `parseDeviceInfo(..., this+1160)`). Key k is a u32 at struct `+4k-4`
(`parseDeviceInfo` @0xFFFFFE00086A4A74:155 `case 33: *(a3+128) = v`). So kext `+1288` = key 33 and MP `deviceInfo+164`
= key 42.

### Q3. XR10 two-plane (byte 43, rung 209): no layout change, no reader

- MP reads byte 43 in exactly one place: the getter `-[AppleParavirtDevice supportsCorrectExtendedXR10Formats]` @0x23506
  (`return _features.supportsCorrect2pXR10A8`). The 550/551 plane layout comes from `sub_106F2` @0x106F2:52-70
  (2 planes, plane 0 bpp 4, plane 1 bpp 4 with `+56 = 0x0401`, alignment = `linearTextureAlignmentBytes`). That code
  is gated only on Metal `supportsExtendedXR10Formats`. It never tests byte 43. The callers (`initWithDevice:descriptor:`
  @0x73AA:131, `AppleParavirtTextureLayout` @0x1366C, `getSharedTextureAllocSize:` @0x2290A, ...) do not test it either.
- KC: no test of `+1443`. The full list of `+14NN & 1` tests in kc.c has no 1443.
- Apple host (`ParavirtualizedGraphics.c`, the same 26A428 cryptex): `APVPixelFormatGetInfoForDevice` @0x222F50DA0
  returns the same 550/551 info as MP. `-[PGDualPlaneComputeTextureResource setupFormatSpecific]` @0x222F647E4 always
  uses plane formats 554/555 + 84 and the `BlitIn/OutRGB_2P_XR10_A8` kernels. There is no version or feature branch.
- **Nobody calls the selector.** A selref scan of the whole 26A428 `dyld_shared_cache_arm64e` (all 10 subcaches,
  every image `__objc_selrefs`) found **no copy of the string `supportsCorrectExtendedXR10Formats`**, so QuartzCore,
  SkyLight, CoreImage, IOSurface, Metal and IOGPU do not reference it. The same scan matched
  `supportsExtendedXR10Formats` in 35 images, which validates the method. A `grep -F` over the on-disk Mach-Os under
  System/Library/{Extensions,CoreServices,Frameworks,PrivateFrameworks}, usr/libexec and usr/sbin (WindowServer
  included) found it only in the MP bundle itself.
- **Conclusion: byte 43 is inert in 26A428.** Turning on rung 209 changes no wire record and no 550/551 memory layout.
  OR `xr10_planes` stays valid as it is. Side finding for C18: QuartzCore **does** reference
  `supportsCorrectTextureUsageBits` (selref @0x1E0835AD0). It is the caller of the byte-50 getter.

### Q1. Info encoder (byte 21, rung 101)

| Query | Record (cmd bytes) | Sender | Trigger | Boot traffic |
|---|---|---|---|---|
| compute pipeline info | 450, 16 B `{u32 pipelineRef, u32 replyBufRef, u64 replyOff}`, reply 28 B | `getComputePipelineStateInfo:` @0x1CE78 | **every compute pipeline creation**, synchronous. `initWithDevice:pipelineStateDescriptor:computeVariant:errorMessage:` @0x1C728:107-182: with byte 21 it uses kext selector 0x101 (plain create), then 450; without it, 0x10A | yes |
| heap texture size/align | 451 (v1, 44 B) / 469 (v2, 52 B, byte 50) | `heapTextureSizeAndAlignWithDescriptor:` @0x2235F:65-80 | every uncached descriptor, synchronous | yes (C6) |
| render pipeline info | 457, 16 B, reply 12 B | `getRenderPipelineStateInfo:` @0x14972 | lazy, from `maxTotalThreadsPerThreadgroup` @0x14AD1, `threadgroupSizeMatchesTileSize` @0x14B0B and `imageblockSampleLength` @0x14B47 only | unlikely (inferred) |
| imageblock length | 458/459, 40 B, reply 4 B | @0x14B82 / @0x1D1EE | imageblock API (keys 23-26) | no; **459 does not appear without tiles** |
| RRM | 452-456 | @0x5054 | key 22 absent | no |
| host resource info | 461 buffer, 462 texture, 463 heap, 464 sampler, 465 ICB, 466 render PSO, 467 compute PSO, 468 depth-stencil; 16 B each; reply 8 B (461, 463, 465) or 16 B | @0x4255 .. @0x4E92 | **byte 41**, see Q8 | 463 yes at >= 207 |

- **FIFO 0x3B and 0x40 stop at >= 101.** KC emits 59 only in `AppleParavirtDevice::createComputePipeline`
  @0xFFFFFE00086A7294:76, and 64 only in `heapTextureSizeAndAlign` @0xFFFFFE00086A7714:60. MP reaches them only on the
  byte-21-off branches (@0x1C728:186-224, @0x2235F:82-104). From byte 41 the kext also refuses 0x10A ("Cannot use when
  argument buffers are supported, use info encoder instead", @0xFFFFFE00086A7294:32). The selector numbers are
  **inferred** from the `s_*` order in AppleParavirtDeviceUserClient: 0x10A createComputePipeline, 0x10C
  heapTextureSizeAndAlign, 0x10F commandQueueSetInfoChannelAndQueue.
- **Reply buffer type.** 450, 457-459 and 461-468 request `poolType:2`. `getBufferBytes:alignment:poolType:buffer:offset:`
  @0x24902:22 picks pool `features[44]+1` for poolType 2 and pool 1 otherwise. Pool 1 is resource args type 1, a
  type-1 buffer. Pool 2 is args type 13; `setupResourcePools` @0x2053A creates it only when byte 44 is on. KC
  turns args type 13 into **object type 19** (`setupWithArgs` @0xFFFFFE00086AD5EC:180-197, which needs `+1444`;
  `allocateCPUBufferHandle` @0xFFFFFE00086AE830 calls `addObject(19, ref, 12 B {u64 residentSize, u32 VA>>14})`).
  451/469 always use pool 1 (@0x248D7 passes poolType 1). So rungs 101-209 reply into type 1 only. From 230 on,
  450/457/461-468 reply into type 19.
- MP copies a reply only when the command buffer status is 4, completed (`sub_34AF` @0x34AF). On any other status
  `getComputePipelineStateInfo:` returns NO and **the compute pipeline creation fails** (@0x1C728:178). Info
  submissions must be stamped completed, never faulted.

### Q4. Render-pass prefix: only for non-default values

`-[PGSerializerRenderCommandEncoder writeDescriptor]` @0x1536C:
- 0x1E (30) `{u32}` is written only when `defaultRasterSampleCount != 0` (:137-158). With byte 22 off, such a pass
  **fails in the guest**: it logs and returns 0.
- 0x1F (31) `{u32}` is written only when `defaultColorSampleCount != 0`, under the same byte. 0x1F is the
  color-sample-count SPI.
- 0x21 (33) is written only with a rate map.
- 0x20 (32) `{u32 n, u64 positions[n]}` is written only with sample positions and encoder flag +5195.
- 0x22, 0x23 and 0x24 (imageblockSampleLength, threadgroupMemoryLength, tileWidth/tileHeight u16x2) are written only
  with encoder flag +5198 (tile support), and each only when its value is non-zero (:186-206).
- Then 0x1A (26, 584 B) always follows.

### Q8. Placement list (byte 41)

- **No guest code reads the placement list.** `AppleParavirtResourceHeap::allocateTable` @0xFFFFFE00086B468C:69-121
  allocates `16*count` B of sysmem when byte 41 is on, and keeps only the sysmem (`+80`) and its GPU mapping in the
  task (`+88`). It keeps no CPU pointer; the object list does keep one, at `+96`. `resize` @0xFFFFFE00086B4D64 copies
  the object list only, and MP has no reader. With key 33 bit 5 off, the host may leave the placement list untouched
  (**inferred**: nothing guest-side could observe it).
- `AppleParavirtKernelTask::setResourceHeap` @0xFFFFFE00086ACCCC:23 **always sends 51**. Only the user-task version
  (@0xFFFFFE00086ABEB0:39) switches to 68.
- **Byte 41 alone (no key) turns on host-resource-info queries.** `-[AppleParavirtHeap gpuAddress]` @0xF306 and
  `-[AppleParavirtBuffer gpuAddress]` @0x13458 test only `features+41 == 1`, then send 463/461 and wait.
  `-[AppleParavirtBuffer initWithHeapSubAllocated:...]` @0x12759:51 calls the heap `gpuAddress` for **every buffer
  sub-allocated from a heap**. MP caches the result only when it is non-zero, so a host that answers 0 is asked again
  on every sub-allocation. Texture and sampler `setupHostResourceInfo` (@0xAF84, @0x1C49F) test byte 41 only. Render
  PSO, compute PSO and depth-stencil (@0x14CD5, @0x1D341, @0x2E57) also need key 42 bit 1, **which OR sends (key 42 = 2)**.
  All of these run lazily from `resourceIndex`/`gpuResourceID`, that is from the argument encoder (@0x2633D ...) and
  the ICB.

### Q2. Kernel task size (byte 20, rung 100)

`createKernelGPUTask` @0xFFFFFE00086A2AAC:8-15 gives the kernel task 1 GiB with byte 20 off. With byte 20 on it gets
**0x4000000000 (256 GiB)** when `+1288 & 2` (key 33 bit 1, read above) and 16 GiB otherwise. OR sends key 33 bit 1,
so the task gets 256 GiB.

### Q5. Blit SPI (byte 32)

With byte 32 off **no fallback exists: MP drops the call silently**. Each of these wraps its emit in
`if (_supportsBlitEncoderSPI)`: `fillBuffer:range:pattern4:` @0x27DF2 (319, 24 B), `fillTexture:...bytes:length:`
@0x27EE2 (320, 76 B), `fillTexture:...color:pixelFormat:` @0x280B0 (321, 92 B), `invalidateCompressedTexture:` @0x281E3
(322, 4 B) and `...slice:level:` @0x282A4 (323, 8 B). 318 (@0x28388:41) is ungated.

### Q6. Descriptor2 on paged textures (byte 30)

`newTextureWithDescriptor:allocator:` @0xD29D emits op 52 whenever byte 30 is on. It is called from @0x73AA:90/228,
`initTiledWithBuffer:` @0x8740:84 and `initWithBytesNoCopy:` @0xA432. The kext maps the args type to the object type
(`allocateTextureHandle` @0xFFFFFE00086ADFD4:64-80): args 2 gives type 2, args 3 gives **type 12**, args 4 gives
**type 3**. MP passes args 3 for two-plane formats (@0x73AA:134: XR10 550/551, or D32S8 with a separate stencil) and
args 4 for a tiled texture on a buffer (@0x8740:194). **Types 2, 3 and 12 therefore all switch to op 52.** The swizzle
is `descriptor.swizzle`, packed as 4 bytes R,G,B,A (`serializeTextureDescriptor2:` @0xC4B4, last 4 stores). The Metal
default is R=2, G=3, B=4, A=5 (**inferred** from the MTLTextureSwizzle enum). 0 means Zero, not identity.

### Q7. Protection envelope (byte 39)

`writeSegmentHeader:continuation:protectionOptions:` @0x1BE82 writes the type-5 envelope (`u32 0, u8 5, u8 0, u8 0`,
then `u64 options`, then the real header) **only when protectionOptions != 0 and the segment is not a continuation**.
The options are 0 unless a resource carries protection options (@0x13458, @0xAF84 copy them onto info command
buffers). The envelope is on-demand traffic.

### Q9. Type-19 CPU buffers (byte 44, rung 230)

MP creates them only as command-buffer pool 2 (`setupResourcePools` @0x2053A, 0x4000 B chunks), the reply target of
every `poolType:2` info query (Q1). No other creator exists. At rung >= 230 the first compute pipeline creates one.

### Q10. Info 460 / byte 35

Byte 35 is inert. MP has no 460 encoder. `uniqueIdentifier` returns a local handle field (@0xAF70, @0x14CC1, @0x1D32D)
or `gpuResourceID` (ICB @0x2889). Neither MP (`_features` uses) nor KC (no `+1435` test) reads byte 35.

### Q11. Info channel setup

`setupChannels` @0xFFFFFE00086A1950:170-200 opens it through **the same `AppleParavirtVirtualChannel::init`** as the
`Display[n]` channels (@0xFFFFFE000869FD2C): id 12, ring 0x80000 B (32 pages, PFNs listed in one 16 KiB page). It
writes a 20 B channel record at shared page `+1024 + 20*(id-1)` = `+1244`: `u32 head = 0, u32 tail = 0,
u32 0xFFFFFFFF, u16 id, u16 0, u32 rootPFN`. Then it sends **root FIFO 48 (0x30) `{u32 channelId}`**. No other
handshake follows. The host must accept id 12 and a 32-page ring; Display rings are 0x4000 B. Binding a queue to the
channel (selector 0x10F, `AppleParavirtCommandQueue::setInfoChannelAndQueue` @0xFFFFFE00086B32C8, which sets `+1512`)
happens in the kernel and puts nothing on the wire.

### Effect on §2/§3

- 209 leaves the mandatory list. W8 shrinks to FIFO 68 + FIFO 12 (about 80 lines); the "XR10 unknown 100-300" goes.
- W2 must answer 450 (every compute pipeline; a fault kills the pipeline) and 451, and always stamp info
  submissions completed. 457 and 458/459 can stay refused. W2 can drop the FIFO 0x3B/0x40 paths at >= 101.
- New in W8 (207): answer 461/463 with a non-zero `u64` GPU address (463 is boot traffic through heap
  sub-allocation), and 462/464 lazily. Placement list: leave it untouched.
- W5 covers types 2, 3 and 12 together. The swizzle default is 2,3,4,5.
- W3: 0x1E/0x1F/0x22-0x24 are on demand. W7: the envelope is on demand and 460 never arrives, so drop info 460.
- W6: fills now arrive where they used to be dropped. W9: type 19 is the reply target for most queries from 230 on.
