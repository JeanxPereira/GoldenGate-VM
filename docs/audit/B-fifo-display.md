# Family B: top-level FIFO commands and the display/scanout path

Apple side: `ParavirtualizedGraphics.framework` 26A428, `-[PGFIFO processFifo:]` @0x222F735D4 and
the `-[PGFIFO Cmd*]` handlers 0x222F6E6DC–0x222F73228 (pseudo-C in
`<RE corpus>/ParavirtualizedGraphics.c/`). Guest builders were checked in
`kc.c/` (`AppleParavirtDisplay::*`). Orchard: `external/orchard/reims-vgpu/crates/`, branch
`gg-macos27` @ `ea4dfb5`. Paths below are relative to `crates/`, and `drain` means
`reims-vgpu/src/runtime/drain/mod.rs`.

Log counts come from the newest full boot, `/tmp/reims-vgpu-fail.5b042af.log` (about 870 s, desktop
reached). They are the sums of the `drain_ops … op0xNN_n=` counters plus the named slugs. Where an
older log says something different, it is given in brackets: `[m8]` is
`reims-vgpu-fail.before-mapper-op8.log`. `above_max=0` in every log, so no opcode above 0x40 has
ever arrived.

## Wire frame (`processFifo`)

The header is 12 bytes: `u16 opcode @0, u16 barrierCount @2, u32 totalLen @4, u32 stampValue @8`.
Then come `barrierCount × 8` bytes of barriers, then the payload. Apple rejects these cases:
- `totalLen < 12` or `totalLen > commandLength`: log, then stop.
- `barrierCount ≥ 0x41`: fault.
- barriers longer than `totalLen`: fault.

Apple then calls `barrierWait`, `advance` and `pushStamp`, and dispatches on `opcode ≤ 0x45` (69).
Opcodes 13–29 and anything above 69 log "Invalid FIFO command", then `faultAtStampValue`. Every
handler that completes calls `signalStampValue:` itself, inline or from its task completion block
(the block faults when the error code is not 1). One table serves every FIFO; only Define/Delete
ChildFIFO check `isRootFifo`.

Orchard (`drain:2005-2040`) parses the same 12-byte header ("stamps" are Apple's barriers). It does
not enforce the 64-barrier cap. It splits dispatch into a root table (`drain:4043-4141`) and a child
table (`drain:6072-6745`), and it caps opcodes at `CHILD_OP_MAX = 0x40`
(`reims-vgpu/src/model/regs.rs:383`, `reims-vgpu-protocol/src/packets.rs:58`). Apple's cap is
**0x45**. Ledger rows whose closure is `Unresolved` are refused at ingress as
`packet_unadmitted reason=ingress_row_unresolved` (`reims-vgpu/src/runtime/ingress.rs:181`), and
their completion word is written out of band.

## Opcode table

| Op/type | Name (Apple handler) | Payload (size, key fields) | Apple host behaviour | Orchard handler `file:line` | Status | Seen in logs (count) | Priority |
|---|---|---|---|---|---|---|---|
| 0 | CmdDebug @0x222F6FB64 | ≥1 B, a string | Writes NUL into the last payload byte (`a5[a6-1]=0`), signals. No other effect | `drain:6235`; ledger `packets.rs:186` = Unresolved, so refused at ingress | partial: refused at ingress instead of signalled in order; Apple proves it a no-op | 0 | P2 |
| 1 | CmdDisplaySetSharedStatePage @0x222F6E8B4 | 8 B `{u32 port @0, u32 page @4}` | `setSharedDisplayStatePage:page forPort:port` (@0x222F57D0C): creates `_PGDisplayNub`; port must be below the port count, and "already in use" faults | `drain:6116` → `apply_setup_shared_state` `drain:749`; decode `reims-vgpu-protocol/src/fifo.rs:1270` | OK | 1 (`display_shared_state_setup`) | — |
| 2 | CmdDisplayAck @0x222F6EA54 | 8 B `{u32 port, u32 token}` | `nub ack:` (@0x222F5B240) faults unless the pending byte at shared+0xFA9 is set **and** `token == shared u32 @0x200`. Writes the token to shared+0xFAC, clears 0xFA9, runs the nub state machine | `drain:6119`: sets `online_acked` and logs w0/w1 | partial: no validation, and shared+0xFA9/0xFAC are never written | 1 (`display_online_ack`) | P3 |
| 3, 6, 7, 31, 33, 35, 36, 38, 39, 41–47, 50, 54, 57, 60 | CmdDeprecated @0x222F6E6DC | any | Logs, `dumpPayload`, **`faultAtStampValue`**: the FIFO faults | retired slots `packets.rs:460-544` + `drain:6710` (accept and retire); **but 6, 7, 0x2d, 0x36, 0x39, 0x3c are live handlers** (rows below) | divergent: Orchard accepts what 26A428's host faults on. The `RETIRED` ledger evidence ("accepts the packet … retires the stamps", `packets.rs:101`) is false for 26A428 | 0 | P3 |
| 6 / 7 | (Apple: deprecated) | Orchard: Transaction2 12 B / Transaction3 36 B | Fault (see the deprecated row) | `drain:6161`, `reims-vgpu-protocol/src/present.rs:92` | divergent but harmless: kept for x86 Ventura/Tahoe guests | 0 | P3 |
| 4 | CmdDisplayCursorGlyph @0x222F6EC28 | 44 B `{u32 port @0, u32 task @4 (must be 0), u64 va @8, u64 mappedLen @16, u64 stride @24, u16 w @32, u16 h @34, u16 hotX @36, u16 hotY @38, u32 sum @40}` | Faults when task≠0. `_cursorGlyph…` (@0x222F5C850): w,h within 1..256, then `copy_GuestBGRA_ToHostBGRA` from the **kernel task** VA, **checksum verified**, then the `cursorGlyphHandler2` block | `drain:6295` → `load_cursor_glyph` `drain:4506`; decode `fifo.rs:1329` | partial: reads through the task id rather than asserting kernel task 0; `sum` is not verified | 754 (`op0x04_n`), 0 `cursor_glyph_fail` | P3 |
| 5 | CmdDisplayCursorShow @0x222F6EE50 | 8 B `{u32 port, u8 show @4}` | `nub cursorShow:` → `cursorShowHandler` | `drain:6287` | OK | 0 | — |
| 8 | CmdDisplaySwapMapping @0x222F6F024 | **40 B** `{u32 port @0, u32 task @4 (must be 0, else fault "may only reference a kernel task"), u64 mappingID @8, u64 gammaVA @16, u64 gammaMappedLen @24, u32 gammaEntryCount @32, u32 gammaSum @36}` | `nub presentMappedSurface:…` (@0x222F5B9C8). See the display path section. Fault on a short payload, a nonzero task, an unknown mappingID, a bad pixel format or BPP, or a gamma table that is bad or fails its checksum | `drain:6161` → `present_named_mapping` `drain:4777`; decode `present.rs:279` / `SwapMappingLong::decode` `present.rs:214`; log `note_display_swap_long` `drain:1223` | partial: (a) **gamma is decoded and never applied**; (b) `+0x20` is misnamed `flags = 0x101` (`present.rs:175-179`); it is `entryCount = 257`, written by the guest at `program_hardware_swap_gated` @0xFFFFFE000869BE10 `*(u32*)(cmd+32)=257`; (c) `+0x04` is documented as "GPU task id" but is the kernel task, always 0; (d) mappingID is truncated to 32 bits (a first-sight log exists); (e) none of the shared-page present bookkeeping happens | 201 (`op0x08_n`); `display_swap_long_form` 1, `display_swap_gamma` 1 (`len=0x4000 flags=0x101 checksum=0x48400000`) | P1 |
| 9 | CmdDisplaySleepState @0x222F6F560 | 8 B `{u32 port, u8 state @4}`; gated on `features[3]` | `nub sleepState:` → client `sleepHandler` | `drain:6242`; ledger `packets.rs:255` Unresolved | missing (refused at ingress) | 0. Guest sends it from `do_power_state_change_gated` only when GPU+1403 (`features[3]`) is set | P2 |
| 10 | CmdDisplaySetProperties @0x222F6F1C8 | 8 B `{u32 port, u32 count}` + `count × {u32 prop, u32 wordCount, u32 words[]}`; gated on `features[7]` | For each record, `nub setProperty:value:wordCount:` (@0x222F5BE30). Prop 0 is the colour matrix and must have wordCount 12 (48 B): it goes into the shared page double buffer at 0xA10/0xA40, index byte 0xA72, dirty 0xA73, and is picked up by `getDirtyColorMatrix` at the next present. Prop 1 is a content-headroom f32 that marks the headroom dirty. Any other prop faults | `drain:6250` (`note_unimplemented`); ledger `packets.rs:265` Unresolved | **missing: refused at ingress** (`packet_unadmitted ch=4 opcode=0xa reason=ingress_row_unresolved`). The guest builds it in `program_hardware_swap_gated` (prop 0 = `0xC00000000` + 48 B matrix, prop 1 = `0x100000001` + 1 word) right before an op8 | 1 per boot, in every log since `[m8]` | P0 |
| 11 | CmdDisplayCompositorParameters @0x222F6F74C | 20 B `{u32 port @0, u16 originX @4, u16 originY @6, u64 configEpoch @8, u8 scaleFactor @16}`; gated on `features[28]` | `nub compositorParametersConfigEpoch:origin:scale:` dispatches the descriptor's `compositorParametersHandler` asynchronously | none (no constant, no ledger row) | missing; would log as an "unassigned slot" | 0. Guest sender `setParameter` @0xFFFFFE000869DB6C, gated on GPU+1428 | P2 |
| 12 | CmdDisplaySetGuestICCProfile @0x222F6F944 | 24 B `{u32 port, u32 length @4, u64 va @8, u64 mappedLen @16}`; `mappedLen ≥ length`; gated on `features[42]` | `nub setGuestICCProfileLength:virtualOffset:` writes shared+0xFC8 (va) and +0xFD0 (len). `updateGuestColorSpace` reads the bytes from the kernel task, then `CGColorSpaceCreateWithICCData`, marks the colour space dirty, and the next presentFrame applies it | none | missing | 0. When GPU+1442 is set, the guest calls it **before every swap** | P2 |
| 13–29 | (no handler) | — | "Invalid FIFO command" + fault | default arm `drain:6720` (`UnknownChildOpcode`) | OK (refused in both) | 0 | — |
| 30 (0x1e) | CmdNOP @0x222F6FCF4 | any | signal | `drain:6684` | OK | 0 | — |
| 32 (0x20) | CmdDeleteTask @0x222F6FCFC | 4 B `{u32 task}` | `deleteTaskID:`; fault on failure | `drain:6113` / root `drain:4137` → `apply_delete_task` `drain:792` | OK | 6 | — |
| 34 (0x22) | CmdUnmapMemory @0x222F6FECC | 20 B `{u32 task, u64 offset @4, u64 len @12}` | `task unmapMemoryAtOffset:length:` with a completion block | `drain:6584`; decode `fifo.rs:346` | OK (layout) | 7 | — |
| 37 (0x25) | CmdDeleteResource @0x222F70118 | 8 B `{u32 task, u32 resource}` | `task deleteResource:` | `drain:6081`; `fifo.rs:1408` | OK | 994 | — |
| 40 (0x28) | CmdDeleteObject @0x222F70360 | ≥12 B `{u32 task @0 (≠0: "may not reference a kernel task"), serialized record @4 with u32 len @8, len+4 ≤ size}` | `getUserTaskID` → `deleteObjectWithSerializedData:size-4` (GPUTask destroys the serializer object) | `drain:6220` → `apply_delete_object` `drain:298`; decode `fifo.rs:283` | **divergent: decoded and declined** (`fail_event reason=cmd_delete_object_unimplemented`). Semantics belong to the objects family | 333 (`op0x28_n`); 6+ `cmd_delete_object_unimplemented` in `store_routes` | P0 (cross-ref objects audit) |
| 48 (0x30) | CmdDefineChildFIFO @0x222F70698 | 4 B `{u32 fifo}`; root FIFO only | `createFIFO:`; fault on failure or when not on the root FIFO | root `drain:4062` | OK | (root, not in drain_ops) | — |
| 49 (0x31) | CmdDeleteChildFIFO @0x222F7087C | 4 B | `deleteFIFO:` | root `drain:4062` | OK | — | — |
| 51 (0x33) | CmdSetObjectList @0x222F70A60 | 12 B `{u32 task, u32 pageNo @4, u32 len @8}` | `setObjectListOffset:(pageNo<<14) objectListLength:len placementListOffset:0 placementListLength:0` (16 KiB pages) | `drain:6078` / root `drain:4136` → `apply_set_object_list` `drain:925`; decode `fifo.rs:162` (calls `+8` "count") | OK (layout). Whether `+8` is bytes or entries is **inferred**; objects family | 19 | P2 |
| 52 (0x34) | CmdInvalidateResources @0x222F70CB4 | `{u32 task, u32 n}` + n × 8 B | `invalidateResources:count:` | `drain:6590`; `fifo.rs:1085` | OK | 0 | — |
| 53 (0x35) | CmdSynchronizeResources @0x222F70FEC | `{u32 task, u32 n}` + n × 4 B | `synchronizeResources:count:discard:0` | `drain:6599`; `fifo.rs:1425` | OK | 0 `[m8: 0]` | — |
| 54 (0x36) | (Apple: deprecated) | Orchard: DeleteIOSurfaceBacking2 `{obj, task}` | Fault | `drain:6617`, `fifo.rs:204` | divergent, legacy | 0 | P3 |
| 55 (0x37) | CmdExecIndirect2 @0x222F71324 | `{u32 task≠0, u32 resCount @4, u32 cbCount @8}` + resCount × **24 B** + cbCount × 16 B | `execIndirect2…` (@0x222F6C328) repacks each 24 B resource into the 8 B EI3 form `{u32 id, u8 flags(bit0..2)}` and runs the shared exec | `drain:6305`; `fifo.rs:1188` / `decode_exec_resource_table` | OK (frame). Segment semantics belong to other families | 604 | — |
| 56 (0x38) | CmdDefineTask2 @0x222F716B4 | 16 B `{u32 id<<1|kernelBit @0, u64 length @4, u32 taskRootPage @12}` | `createTaskID:(w0>>1) taskRoot:@12 length:@4` | `drain:6072` / root `drain:4135`; `fifo.rs:99` | OK | 19 | — |
| 57 (0x39) | (Apple: deprecated) | Orchard: MapMemory2 | Fault | `drain:6587` | divergent, legacy | 0 | P3 |
| 58 (0x3a) | CmdGetDeviceInfo @0x222F71860 | 12 B `{u32 keyLimit, u32 length, u32 dstPage}` | `getDeviceInfo:length:dst:`, handled on **any** FIFO | root only `drain:4043`; `fifo.rs:489` (`WithKeyLimit`) | partial: a child-FIFO 0x3a would be an unknown opcode | 1 (`device_info`, root) | P3 |
| 59 (0x3b) | CmdGetComputeInfo @0x222F71A00 | 24 B `{u32 task, u32 a @4, u32 maxKey @8, u32 count @12, u64 offset @16}` | `getComputeInfo:maxKey:count:offset:` on the user task | `drain:6269`; `fifo.rs:552` | OK (layout) | 50 | — |
| 60 (0x3c) | (Apple: deprecated) | Orchard: ReplacePhysical | Fault | `drain:6463` | divergent, legacy | 0 | P3 |
| 61 (0x3d) | CmdDelay @0x222F71C50 | ≥8 B | **Does nothing**: after the length check it returns without even `signalStampValue`. Disassembly confirmed: `CMP X5,#7; B.LS fault; RETAB`. The stamp is covered by the next command's signal | `drain:6262`; ledger `packets.rs:417` Unresolved, so refused at ingress | partial: Apple proves it a no-op; close it as ProvenNoOp | 0 `[m8: 0]` | P2 |
| 62 (0x3e) | CmdSynchronizeAndDiscardResources @0x222F71DC4 | as 53 | `synchronizeResources:count:discard:1` | `drain:6608` | OK | 6 `[m8: 49]` | — |
| 63 (0x3f) | CmdDiscardResources @0x222F720FC | as 53; gated on `features[2]` | `discardResources:count:` | `drain:6635` | OK | 13 `[m8: 184]` | — |
| 64 (0x40) | CmdHeapTextureSizeAndAlign @0x222F72448 | `{u32 task, u64 replyVA @4, u64 replyLen @12, u32 serLen @20}` + serialized payload @24; gated on `features[9]` | `heapTextureSizeAndAlign:serializerPayloadLength:replyVirtualOffset:replyLength:` | `drain:6449`; `fifo.rs:696` | OK (layout) | 83 (`heap_texture_query` 83) | — |
| 65 (0x41) | CmdDeleteSharedTextureBacking @0x222F72770 | 4 B `{u32 backingId}`, kernel task | `getKernelTask deleteSharedTextureBacking:` | none: above `CHILD_OP_MAX`, logged as `child_opcode_out_of_range` ("malformed header … desynced ring") | **missing**, and mislabelled if it ever arrives | 0 | P2 |
| 66 (0x42) | CmdResetRasterizationRateMap @0x222F729B4 | 8 B `{u32 task, u32 rrmId}`; gated on `features[26]` | `resetRasterizationRateMap:` on the user task | none (ceiling) | missing | 0 | P2 |
| 67 (0x43) | CmdExecIndirect3 @0x222F72C18 | `{u32 task≠0, u32 resCount, u32 cbCount}` + resCount × **8 B** + cbCount × 16 B; gated on `features[29]` | `execIndirect3…`, the native form that EI2 is converted into | none (ceiling) | missing. The guest uses EI2 because the advertised version lacks `features[29]` (**inferred**) | 0 | P2 (P0 if the version is raised) |
| 68 (0x44) | CmdSetObjectAndPlacementList @0x222F72FBC | 28 B `{u32 task, u64 objOffset @4, u64 placementOffset @12, u32 objLen @20, u32 placementLen @24}`; gated on `features[41]` | `setObjectListOffset:objectListLength:placementListOffset:placementListLength:` | none (ceiling) | missing | 0 | P2 |
| 69 (0x45) | CmdInfoIndirect @0x222F73228 | as 67; gated on `features[48]` | `infoIndirect…` (the info segment 450–469 path) | none (ceiling) | missing | 0 | P2 |

`features[n]` is the byte at `[_PGDevice features] + n`. The guest reads the same bytes at
`AppleParavirtGPU + 1400 + n` (GPU+1403 → op9, +1407 → op10, +1428 → op11, +1442 → op12), so this
family's gating can be checked straight against the version and feature audit.

## Display / scanout path

**Apple** (`_PGDisplayNub _presentMappedSurface:…` @0x222F5B9C8, under the nub mutex):
1. Resolve `mappingID` (a full u64) with `[mapperService retainSurfaceWithMappingID:]` to an
   **IOSurface**. No surface means a fault, "Invalid mappingID". The surface *is* the backing: there
   are no guest pages to capture and no staleness concept.
2. Pixel format allowlist: `'BGRA'` → MTL 80 (BGRA8Unorm, 4 B), `'RGBA'` → 70 (4 B), `'RGhA'` → 115
   (RGBA16Float, 8 B). `'RGhA'` without `features[4]` is only logged, once. Anything else, or a wrong
   `bytesPerElement`, faults.
3. `newTextureWithDescriptor:iosurface:plane:0`.
4. If `gammaEntryCount ≠ 0`, run `setGammaTableVirtualOffset:…` (@0x222F5B7C4). It requires
   `1 ≤ count ≤ 1024` and `mappedLen ≥ 12·count`, and writes shared+0xF80 (va), 0xF88 (len),
   0xF90 (count) and 0xF94 (sum).
5. Call `_PGDisplay presentFrame:…` (@0x222F76E04):
   - `waitForPendingFrames`.
   - A mode change when width, height, format, protection or colour space changed.
   - `updateGammaTable` (@0x222F7662C): read `12·N` bytes from the kernel task; the checksum is
     `Σ u32 bit patterns` over R[N], G[N] and B[N] (each ramp contiguous, f32); require `N ≥ 2`;
     upload a 1D-array R32Float texture (pf 55, width N, 3 slices); compute the end slopes.
   - Apply the dirty colour matrix.
   - **Retain the texture as the current frame** (`self+0x2D0`). It is re-encoded on every host
     refresh by `encodeCurrentFrameToCommandBuffer`.
6. Completion block: an atomic OR of **bit 1 into shared+0x100, always**. The IRQ
   (`displayPokePort`) fires only if shared+0x104 & 2.
7. Shared-page bookkeeping: `u64 @0xF98 ++` (guest present count), `u64 @0xFB0 = mappingID`,
   `u32 @0xFA4 = 0`.

The FIFO stamp is signalled right after the call returns. Presentation does not hold the stamp,
because the retained IOSurface keeps the pixels alive.

**Orchard** (`present_named_mapping` `drain:4777`):
1. Drain the other child FIFOs, and the main FIFO when needed. Hold the packet
   (`present_order_hold`) while an earlier EXEC is translation-deferred.
2. Look up the **low 32 bits** of the mappingID in `state.mappings`. Mapping 0 completes silently,
   where Apple faults.
3. `ensure_surface_for_present`, then `resolve_mapping_backing`.
4. `note_present_backing` (`reims-vgpu/src/model/state.rs:3821`) flags
   `present_backing_restaled` / `present_backing_never_stored` (`state.rs:2247`).
5. `capture_present_frame` copies guest pages or a resident into `frame_bgra`. Paint failures log
   `scanout_paint_mapping` (`reims-vgpu/src/runtime/scanout/mod.rs:936`).
6. `signal_display_present_complete` (`drain:7073`) writes pending bit 1 **only when the enable
   mask has bit 1**.
7. No gamma, no colour matrix, no ICC, no pixel-format allowlist, and no shared-page bookkeeping.

| Aspect | Apple | Orchard | Status | Logs (5b042af) | Priority |
|---|---|---|---|---|---|
| Backing lifetime | The IOSurface is retained at present and stays valid however the guest recycles it | Freezes guest pages at the present boundary and gates on `dense_frame_seq` | divergent by design; works now | `present_backing_restaled` 1 `[m8: 376]`, `never_stored` 0 `[m8: 3]`, `present capture fail` 0 `[m8: 379]`, `scanout_paint_mapping` 0 | — (fixed by the mapper-op8 work) |
| Black frames | n/a | `present_black_retain` | open (early-boot mid 2, gen 0/1) | 19 | P2: render-path families |
| Gamma | 257-entry, 3-ramp LUT applied in the display pipeline | decoded, logged, not applied | partial | 1 per boot | P1 |
| Colour matrix (op10 prop 0) and headroom (prop 1) | applied at the next present | refused at ingress | missing | 1 per boot | P0 |
| ICC profile (op12) | guest colour space applied | none | missing | 0 | P2 |
| Pending bit 1 | always ORed; IRQ gated | write gated on the enable mask | divergent, inert: the guest's mask is `0xc`, so neither raises an IRQ; Apple leaves bit 1 set | `display_present_signal not_enabled=192` | P3 |
| Shared page 0xF80–0xFB0 | written on every present | never written | missing; no guest reader found by grepping `kc.c` (**inferred**: host or restore bookkeeping) | — | P2 |
| Display port | `getDisplayNubAtPort(port)` | single display; port decoded, not routed | partial | — | P3 |

## Ranked fix list

1. **op10 SetProperties: admit and implement.** Add a ledger row → Implemented, a decoder in
   `fifo.rs` (header + `{prop, wordCount, words}` loop with Apple's bounds), and store the matrix and
   headroom in `DeviceState.display`. Apply the matrix in the scanout colour pass, or treat it as an
   identity no-op once a dump shows identity.
   - Size: about 60 lines plus tests.
   - Risk: low. The packet stops being the one `packet_unadmitted` per boot and completes in order.
2. **op8 gamma: rename and apply.**
   - In `present.rs`, rename `flags` to `entry_count` and `0x101` to 257, and rename the task word to
     "kernel task (0)". About 15 lines; risk: none.
   - Validate as Apple does (count 2..1024, `len ≥ 12N`, checksum).
   - Read the 3N f32 once from the kernel-task VA and apply a per-channel LUT in the present or
     scanout shader. About 80 lines on the CPU path, about 150 on the Vulkan path; risk: medium
     (whole-screen colour shift if it is wrong).
   - First dump the table on one boot. If it is identity, the apply can wait.
3. **op0x28 DeleteObject (P0, 333 per boot):** owned by the objects audit. Listed here only because
   its FIFO frame is this family's.
4. **Raise the dispatch ceiling to 0x45 and add ledger rows** for 0x0b, 0x0c, 0x41–0x45 as
   Unresolved with Apple payload floors. A feature or version bump would then log them as
   "unimplemented command" and not as "desynced ring".
   - Size: about 40 lines. Risk: none.
   - Then port EI3 (0x43) and InfoIndirect (0x45) with the exec family. EI3 is EI2 with 8-byte
     resource records.
5. **Close CmdDelay (0x3d) and CmdDebug (0x00) as `ProvenNoOp`** citing @0x222F71C50 and
   @0x222F6FB64, so they pass ingress in order. About 10 lines; risk: none.
6. **Shared-page present bookkeeping** (0xF98++, 0xFB0, 0xFA4, gamma words 0xF80–0xF94), only if
   some guest reader turns up. About 20 lines; risk: low.
7. **Correct the `RETIRED` ledger evidence** (`packets.rs:101`): in 26A428 those slots fault. Keep
   Orchard's accept behaviour for older guests, but say so. Docs only.
8. P3 hygiene, each about 10 lines:
   - Enforce the 64-barrier cap.
   - Accept 0x3a on child FIFOs.
   - Check the CursorGlyph `sum` and require task 0.
   - Validate the op2 ack against shared+0x200.
   - Treat mapping 0 / an unknown mapping as a guest error, not a silent complete.

## Open questions

- Is the 257-entry gamma table the guest sends identity? (`checksum=0x48400000`, VA 0x104000 in the
  kernel task.) Dump it once to decide whether fix 2 is cosmetic.
- Which `features[]` bytes does Orchard's advertised binary version set? 3, 28 and 42 decide whether
  ops 9, 11 and 12 ever arrive. 29, 41 and 48 decide whether the guest would switch to EI3,
  SetObjectAndPlacementList and InfoIndirect. This is for the version/features audit.
- SetObjectList `+8`: bytes or entry count? `PGObjectListManager::setObjectList` was not followed.
  This is for the objects audit.
- Does anything in the guest read shared+0xF98, 0xFB0 or 0xFA4? A grep of `kc.c` found no literal
  use. A pointer-based read would need IDA xrefs on `AppleParavirtDisplay` shared-state accessors.
- CursorShow (op5) never appears in any log while CursorGlyph runs at about 750 per boot. Is
  visibility carried only in shared+0xE04, or is the guest's show path gated?
- Ingress-refused packets get their completion word "out of band". Is that ordering-safe against
  later stamps on ch4, given that Apple signals strictly in FIFO order?
