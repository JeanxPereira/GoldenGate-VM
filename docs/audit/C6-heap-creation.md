# C6: why `newHeapWithDescriptor:` returns nil (RenderBox "unable to create heap: 0")

Trigger: 57 × `[com.apple.renderbox:error] unable to create heap: 0` in `iconservicesagent`, then
`Central pixel is still transparent even with retry`. Other heaps exist: kext `allocateHeapHandle` adds
type-0xD objects, and placed textures from them render. Sources: plugin = `AppleParavirtGPUMetalIOGPUFamily.c`
(MP, x86_64 slice), kext = `kc.c` / `kc.i64` (KC), `Metal.i64`. RenderBox is not in the corpus.

## 1. The creation path and every nil branch

`-[AppleParavirtDevice newHeapWithDescriptor:]` MP @0x20CFF → `-[AppleParavirtHeap initWithDevice:descriptor:]` MP @0xE8C2
→ IOGPU.framework `-[IOGPUMetalHeap initWithDevice:size:options:args:argsSize:desc:]` (not in corpus) → KC
`AppleParavirtResource::setupWithArgs` @0xFFFFFE00086AD5EC case 9 → `allocateHeapHandle` @0xFFFFFE00086AE3CC.
MP builds the 112-byte args: +0x48 size, +0x58 type 9 (heap), +0x5C heap ref handle, +0x60 size,
+0x68 flags (bit0 = storageMode != Shared, bit1 = hazard-tracked, only if feature byte 38).
Size = `descriptor.size` rounded up to `vm_page_size` (16 KiB). There is **no max-size check, no type
(automatic/placement/sparse) check and no host round trip** for the heap itself.

| # | Where | Condition → nil | Guest log text | At rung 62 on Orchard |
|---|---|---|---|---|
| H1 | MP @0x20CFF → `supportsResourceHeaps` @0x222FE | key 14 == 0, or key 16 == 0, or feature byte 9 (metalHeaps, rung 43) off | none | passes: keys 14=1, 16=1, byte 9 on |
| H2 | MP @0xE8C2 head | `storageMode == 0` (Shared) and not `supportsSharedStorageHeapResources` @0x234A4 (= byte 37 (rung 203) **and** key 33 bit 4) | "Shared heap storage is not supported" (`sub_2ADA9`) | **fails for any shared heap.** Byte 37 is off at 62, so key 33 bit 4 (which Orchard sets) is inert. An Apple level-1 host gives the same result. The default `MTLHeapDescriptor` storageMode is 2 (Private): `-[MTLHeapDescriptorInternal init]` Metal @0x18D692454 copies `{size 0, storageMode 2}` from 0x18D79DA30, so a shared heap takes an explicit `setStorageMode:0` |
| H3 | MP @0xE8C2 | `newHeapRef` handle null | "Failed to create ref handle" (`sub_2AD71`) | not expected |
| H4 | IOGPU super init → KC `setupWithArgs` | args < 0x70 B; byte 9 (`+1409`) off ("Heaps are not supported"); vfunc +336/+384 backing allocation fails (the same path buffers take, and buffers work) | APVLog (kernel) | passes |
| H5 | KC `allocateHeapHandle` @0xFFFFFE00086AE3CC | heap GPU VA not 16 KiB aligned or >= 2^46 ("Invalid heap address"); `AppleParavirtResourceHeap::addObject(13, ...)` fails | APVLog | passes (same VA allocator as buffers) |
| H6 | MP `allocateCoverBuffer:options:` @0xED2E | the cover sub-resource over the whole heap fails (`newSubResourceAtOffset:0...` for placement, `newSubResourceWithLength:` for automatic). Its length comes from `heapBufferSizeAndAlignWithLength` @0x2232B (key 15 alignment, 256 if absent; computed locally, no host) | none | passes for size > 0 |
| H7 | IOGPU super init (**inferred**) | size 0: the descriptor size (default 0, Metal @0x18D692454) rounds to 0 | none from MP | **this is what "0" points at, see §2** |

## 2. Where a size of 0 comes from: the heap-texture query races the host

A client sizes a heap by summing `heapTextureSizeAndAlignWithDescriptor:` answers.
`-[AppleParavirtDevice heapTextureSizeAndAlignWithDescriptor:]` MP @0x2235F returns {0,0} when:
- `usage >= 0x100` and byte 50 (`supportsTextureDescriptor2`, rung 237) is off. It logs "Cannot create a texture with this usage on this host" (`sub_2CB18`).
- `preValidateTextureDescriptor:` @0x20D7D fails (protectionOptions without byte support; key 28 bit 0 skips the format check), or `validateWithDevice:` fails.
- **The reply has not arrived yet.** At rung 62, byte 21 (`supportsInfoEncoder`, rung 101) is off, so MP takes the kext path. It gets a 16-byte reply buffer from `newDescriptorBuffer:` @0x2112C (a sub-allocation of a reused descriptor heap, so it can hold stale bytes). It serializes cmd 0x16 (`PGSerializer heapTextureSizeAndAlignWithDescriptor:allocator:` @0xCCFF) and calls `IOConnectCallMethod(conn, 0x10C, ...)`. Then it **immediately** reads `*(_OWORD *)[buffer contents]`.

KC `AppleParavirtDevice::heapTextureSizeAndAlign` @0xFFFFFE00086A7714 does not wait for the host:
- @0xFFFFFE00086A7968..78 it calls `addCommandLocked(queue, desc, device->task + 0x1D8)`. The command is tied to the event of the **task**.
- @0xFFFFFE00086A7984..90 it calls `finishEvent(machine, &local)` on the **local** event (SP+0x10). That event only went through `initEvent` @0xFFFFFE00086A7884 and is never attached to anything.
- `IOGPUEventMachine::finishEvent` @0xFFFFFE000932D278 waits only for the stamps in the event mask. A fresh mask is 0 (`v2 = 0|0x8000` gives `v3 == 15`), so it returns at once.
- Compare `createComputePipeline` @0xFFFFFE00086A7294 (line 130) and `resetRasterizationRateMap` @0xFFFFFE00086A7A00 (line 74). Both pass the local event to `addCommandLocked`, and so they do block.

MP then caches the answer in `_textureSizeAndAlign`, keyed by descriptor, for the life of the process. A lost race therefore becomes a permanent {0,0}: `heapBufferSizeAndAlign(0)` keeps the size at 0, and the alignment rounds to 0 too. A stale buffer gives a wrong non-zero size instead, which means a heap that is too small and placements that overlap (**inferred**; this fits the C3 aliasing at `heap=33 off=0`). Orchard answers late (QEMU/TCG, the drain thread), so whether a real size is read depends on timing. That matches what we measured: some heaps are created and 57 are not. Before `b02319b`, when there was no reply at all, there were 0 heap creations.

The "0" in the RenderBox message is the requested heap size: **inferred**, because RenderBox is not loaded. Host log `/tmp/reims-vgpu-fail.log`: 369 × `heap_texture_query ok` (362 × `usage=0x5 options=0x20`, task 4), with no failures and no usage >= 0x100. So the host does answer every query. It answers too late.

## 3. Orchard against these conditions

| Condition | Orchard (rung 62) | Verdict |
|---|---|---|
| H1 keys 14/16, byte 9 | 1 / 1 / on | OK |
| H2 shared heaps | byte 37 off (set by the rung); key 33 bit 4 set | Shared heaps are impossible below rung 203, as on an Apple level-1 host. Key 33 bit 4 is an inert lie |
| key 15 heap-buffer alignment | 32 | below the guest default of 256 (A-features Q6); not a cause of nil |
| heap-texture query reply | correct values, written asynchronously by the drain | **breaks the timing the kext assumes**: the reply has to land before the kick MMIO write returns to the guest |

## 4. Fix (sized)

1. **Synchronous heap-query reply (P0, about 60-100 lines, medium risk).** In the doorbell / FIFO-kick MMIO handler, on the vCPU thread and before it returns, scan the newly published object-queue commands for `CmdHeapTextureSizeAndAlign` and write the 16-byte reply inline. The drain then skips commands already answered (mark them by FIFO offset). The answer depends only on the descriptor, so answering ahead of the task barrier is safe. Owner: host-spec and porter, to find the kick path.
2. Alternative: a rung >= 101 turns on the info encoder (`waitUntilCompleted`, MP @0x2235F). That is too broad, because it switches bytes 11-21 on at once.
3. H2 has no host fix below rung 203. Clear key 33 bit 4 so it stops lying (1 line).

## 5. Open questions / next queries

- Guest: run `log show --last boot` with a predicate on process iconservicesagent, and grep for "Shared heap storage", "Cannot create a texture with this usage", "Kernel call failed" and "unable to create heap". H2 and the usage gate would each print their own line; the race prints nothing.
- Host: log the time of the kick and of the reply for every `heap_texture_query`. A reply that comes after the next FIFO activity from the same task proves the race.
- RenderBox: mount the image read-only (`losetup -r -P` + `apfs-fuse`), take `dyld_shared_cache_arm64e` from the Preboot cryptex `os.dmg`, then run `gq.py dsc <cache> /System/Library/PrivateFrameworks/RenderBox.framework/Versions/A/RenderBox --name RenderBox`, then `strings RenderBox "unable to create heap"` and `xrefs`. That shows which value is printed and how the size is summed.
