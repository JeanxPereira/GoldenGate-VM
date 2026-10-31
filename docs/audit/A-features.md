# Family A: protocol version, APVFeatures, device info

Scope: how the 26A428 (macOS 27) guest negotiates its protocol rung and device-info reply, what Apple's
host does with each, what Orchard (`gg-macos27`) does instead, and which advertised values Orchard
should change.

Evidence: Apple host = `ParavirtualizedGraphics.c/` (PG) and `ParavirtualizedGraphicsGPUTask.c/` (GT).
Guest kext = `kc.c/` (KC). Guest Metal plugin = `AppleParavirtGPUMetalIOGPUFamily.c/` (MP). Orchard paths
are relative to `external/orchard/reims-vgpu/crates/reims-vgpu/src/`. steelbrain =
`steelbrain/reims-vgpu/crates/reims-vgpu-core/src/guest/abi/{features,device_info}.rs`. Field names
come from MP's `_features.*`/`_deviceInfo.*`, PG's `checkCapabilities` strings, and steelbrain.
Names marked *(ours)* are mine.

## A.0 Headline findings

1. **The guest and host use the same ladder.** KC `getAPVFeaturesForVersion` @0xFFFFFE00086A32F0 matches PG
   @0x222F58984 byte for byte (the diff is empty). The struct is 56 bytes; the guest keeps its copy at
   `AppleParavirtGPU+1400`. So a kext byte `+14NN` is feature byte `NN-00`: +1407 = byte 7
   displaySetProperties, +1442 = byte 42 guestICCProfile, +1453 = byte 53 (rung 251).
2. **The guest walks down the ladder itself** (KC `setupVersion` @0xFFFFFE00086A3188). It writes 252
   to `gfx+0x34` (PG mmio case 0xD), reads the register back, and builds its features from the value
   it reads. If that value is invalid or has bit 31 set, it steps down to the next valid rung and
   writes again. If the rung is ≤ 9, or no valid rung is left, it writes `0x800000FC` and the driver
   backs out. **Rungs 1–6 and 236 are "unsupported" in 26A428.** This is why `REIMS_VGPU_PROTOCOL_CAP=4`
   kills the driver (NOTES 29/10). The lowest viable cap is 10.
3. **Rung 62 is a rung Apple itself uses.** Apple reaches it with device feature level 1 ("2022")
   (`setBinaryVersion` @0x222F586E0 clamps: level 1→62, 2→113, 3→209, 4→245, 0 and 5→252, ≥6
   asserts). At 62 the guest gets bytes 2–10, maxFIFOCount 64, and s8ByteCountForD32S8 1. Every
   feature from rung 100 up is off. This is the simplest guest path that still has heaps,
   buffer-from-IOSurface, and two-plane textures.
4. **Orchard's device-info reply does not match a level-1 Apple host.** Apple at level 1 sends only
   keys 1–18, 40, 43, and 45 (key 18 = `0x20002`). Orchard sends keys 1–19, 21, 23–37, and 40–42 plus
   44, using level-0 values (key 18 = `0x20007`). Most extra keys do nothing, because the plugin
   ANDs them with a feature byte that is off at 62. **Some are not ANDed with anything (§A.3), and
   those are the lies.**
5. **Stale facts in Orchard.** `model/regs.rs:1050-1073` and `runtime/mmio.rs:165` say the guest
   writes 4, the top rung is 62, and higher values fall into the default arm. All three are false
   for 26A428: the guest writes 252, the ladder goes to 252, and the guest steps down. Separately,
   `DEVICE_INFO_DEAD_KEYS = [43]` (`regs.rs:1684`) is wrong. The 26A428 kext `parseDeviceInfo`
   @0xFFFFFE00086A4A74 has arms for keys 43 and 45, and the plugin reads both.
6. **steelbrain is one host generation behind** (`features.rs`). Its ladder tops out at 245. It still
   treats rungs 2–6 as valid with objectTables, efiDisplay, displayDoorbell, sharedTextures, and
   sunburst. Its rung 10 sets mapperIOSurfaces, syncAndDiscard, and displayMapperSurface, which
   26A428 dropped. It keeps the "7..100 / 7..104" post-switch clears. It allows feature levels 0..4,
   where 26A428 allows 0..5. Its device info has 44 keys, with no writer for 43 and none for 45.
   Use it for names only, not for thresholds.

## A.1 Negotiation and device-info commands

| Op/type | Name | Payload (size, key fields) | Apple host behaviour | Orchard handler | Status | Seen in logs | Priority |
|---|---|---|---|---|---|---|---|
| MMIO gfx+0x34 (case 0xD) write | setBinaryVersion | u32 requested rung | PG `-[_PGDevice setBinaryVersion:]` @0x222F586E0. A write with bit 31 set is ignored (logged "Guest doesn't support host version"). Rungs 1–6 and 236 are stored with bit 31 set. An unknown rung above 252 becomes 252. An unknown rung ≤ 252 steps down to the next valid rung. Then the feature-level clamp applies, and the 56 B features are copied to `self+1252`. | `runtime/mmio.rs:165-188` → `model/regs.rs:1082` `negotiate_protocol_version` = `min(req, cap)`, cap = 62 or `REIMS_VGPU_PROTOCOL_CAP` (`regs.rs:1088`) | **partial**: same answer for 252 (→62). Two differences: (a) a bit-31 write (`0x800000FC`, the guest giving up) gets 62 back instead of being ignored; (b) an invalid rung below the cap is echoed, and the guest then has to step down itself. Harmless today. | `requested=252 negotiated=62` ×42; `negotiated=4` ×3 (cap-4 runs, driver absent) | P2 |
| MMIO gfx+0x34 read | binaryVersion | u32 | Returns the stored rung (with bit 31 if unsupported) | `runtime/mmio.rs:57` | OK | — | — |
| FIFO 0x3A | CmdGetDeviceInfo | 12 B: key bound (exclusive; guest sends **46**), pair capacity (guest: 0x4000>>3 = 2048), reply PFN (16 KiB page) | PG `CmdGetDeviceInfo` @0x222F71860 (payload < 12 B throws) → `getDeviceInfo:` @0x222F58650 maps 0x4000 B → `writeDeviceInfo` @0x222F41714 writes key k only if bound ≥ k+1 and a slot is free, gated by feature level and feature bytes (§A.3), then writes a {0,0} terminator. Stores the bound in `self+2168` for suspend | `runtime/drain/mod.rs:3310` `reply_device_info` (called :4052); values from `model/regs.rs:1352` `device_info_caps` / `:1453` `DEVICE_INFO_CAPS` | **partial**: the bound and terminator are handled correctly. The values diverge (§A.3). | `key_table_len=46` ×42, always `holes=[20,22,38,39] tail=1` | P1 |
| KC parse | parseDeviceInfo / fixupMetalShaderVersion | — | KC @0xFFFFFE00086A4A74 has arms for keys 1–45, including **43 and 45**. Key 18: if absent it becomes `0x20002`; if > `0x20007` it is clamped to `0x20007`; it is then split into major and minor halves (@0xFFFFFE00086A4A2C). The struct is returned to MP through user-client selector 0x109 together with the 56 B features (MP `setupDeviceInfo` @0x207BE) | — | n/a (guest) | — | — |
| XPC | GPUTask handshake | 56 B APVFeatures | GT `handshakeWithTaskRoot:…features:` @0x100029FB8 copies the features to `self+360`. It reads byte 41 (`+401`: object and placement list offsets from the task root) and byte 45 (ICB, passed to `PGResourceManager`). Resource creation reads bytes 6, 20, 33, 38, and 41. | Orchard runs in one process. It does not split by feature byte; it decodes whatever arrives. | n/a | — | — |

## A.2 The APVFeatures ladder (26A428, host = guest)

Valid rungs: 10, 11, 20, 21, 22, 30, 31, 40–43, 60–62, 100–113, 200–209, 230–233, 235, 237, 238, 245,
250, 251, 252 (49 rungs). The ladder is a cumulative fall-through: each rung sets its own byte and
every byte below it. Exceptions: rung 237 skips byte 49, and rung 40 clears byte 6. Defaults: valid=1,
maxFIFOCount 32, s8ByteCountForD32S8 4. Rungs 1–6 and 236 are unsupported (byte 1 set, valid 0). Any
other rung is invalid.
"At 62" = whether the guest has this feature at Orchard's rung.

| Byte | Name | On from rung | Guest use (what it switches) | Apple host use | At 62 | Orchard behaviour at 62 | Status |
|---|---|---|---|---|---|---|---|
| 0 | valid | every valid rung | KC `setupVersion`: invalid → step down | `setBinaryVersion` step-down | 1 | — | OK |
| 1 | unsupported *(ours)* | 1–6, 236 | KC: bit 31 / step down | stored with bit 31 | 0 | — | OK |
| 2 | discardResources | 11, 20+ | KC `AppleParavirtResource::synchronizeAndDiscard` @0xFFFFFE00086AFA8C:37 sends CmdDiscardResources instead of the combined command | `CmdDiscardResources` @0x222F720FC refuses the command if this is off | on | implemented, `runtime/drain/mod.rs:6626` | OK |
| 3 | displaySleep | 21 | KC `do_power_state_change_gated` @0xFFFFFE000869C9D8:24 sends CmdDisplaySleepState | @0x222F6F560 gate | on | `drain/mod.rs:6242` no-op (`note_unimplemented`) | partial |
| 4 | supportsRGhAPresents | 22 | no KC/MP reader found | `_PGDisplayNub presentMappedSurface…` @0x222F5B9C8:95 (gamma path) | on | not audited (display family) | ? |
| 5 | synchronizeDiscardChildResources | 30 | KC `synchronizeAndDiscard`:41 (child resources) | — | on | 0x3e family implemented | OK |
| 6 | dualPlaneTextures | 31, 41+ (cleared at 40) | MP `supportsNonPrivateDepthStencilTextures` @0x22B69 = byte6 && key12. **This is the plugin's only use of the byte.** | key 12 value; GT `createNormalTexture` @0x1000468BC refuses object type 12 if off | on | two-plane XR10 as RGBA16F (5b042af); key 12 from `regs.rs:1324` | partial |
| 7 | displaySetProperties | 40, 41+ | KC `program_hardware_swap_gated` @0xFFFFFE000869BE10:205: when the colour matrix or remap is dirty (or headroom changed, rung 251), it sends **FIFO op 10** before swap op 8. Property id 0 = 48 B colour matrix; id 1 = 4 B headroom | — | on | `drain/mod.rs:6250` no-op: the colour matrix is never applied | partial |
| 8 | displayDimensionFloats | 42 | no reader found | no reader found | on | — | ? (inferred inert) |
| 9 | metalHeaps | 43 | KC `heapTextureSizeAndAlign` @0xFFFFFE00086A7714:30, `AppleParavirtResource::setupWithArgs` @0xFFFFFE00086AD5EC:122; MP `supportsResourceHeaps` @0x222FE = key14 && key16 && byte9 | keys 14–16 written only if on; `CmdHeapTextureSizeAndAlign` @0x222F72448 gate | on | `runtime/heap_query.rs`, heap objects 13/14 | partial (not seen in logs) |
| 10 | bufferFromIOSurface | 60 | KC `setupWithArgs`:103; MP `supportsBufferWithIOSurface` @0x2272E = key17 && byte10 | key 17 written only if on | on | mapper-ref buffer (object type 15, `decode/resource/mod.rs:98`) | partial |
| 12 (u32) | maxFIFOCount 32→64 | 61 | no KC reader found | `PGChildFIFO init` @0x222F7483C bound; `addWait` assert | 64 | `MAX_CHANNELS = 32` (`model/regs.rs:130`, u32 masks) | **divergent** (latent: see Q4) |
| 16 (u32) | s8ByteCountForD32S8 4→1 | 62 | MP (1 site): bytes per texel of the D32S8 stencil plane in guest memory | — | 1 | no guest-memory D32S8 layout found in Orchard | ? (P2, see fix 8) |
| 20 | supportsSharedTextures | 100 | KC `createKernelGPUTask` @0xFFFFFE00086A2AAC:8; MP `supportsSharedTextureHandles` @0x22787 (byte20 && key19 && serializer≥5) | key 19; GT `createSharedTexture` @0x10004ED7C refuses if off | off | — | n/a at 62 |
| 21 | supportsInfoEncoder | 101 | KC `setupChannels` @0xFFFFFE00086A1950:169, `setInfoChannelAndQueue` @0xFFFFFE00086B32C8; MP uses the info encoder (segments 450–469) instead of kext queries | — | off | — | n/a |
| 22 | supportsDefaultRasterSampleCount | 102 | MP serializer; `supportsRenderPassWithoutRenderTarget` | — | off | — | n/a |
| 23 | supportsVertexAmplification | 103 | MP | — | off | — | n/a |
| 24 | supportsSunburstDisplay | 104 | no reader found | — | off | — | n/a |
| 25 | supportsProgrammableSamplePositions | 105 | MP (and key 21) | key 21 only if on | off | — | n/a |
| 26 | supportsVariableRasterizationRateMaps | 106 | MP (and key 22) | — | off | — | n/a |
| 27 | supportsTileShadersImageBlocks | 107 | MP tile shaders, image blocks, memory-order atomics, ROG (and keys 23–26) | keys 23–27 only if on | off | — | n/a |
| 28 | supportsDisplayCompositorParameters | 108 | KC `setParameter` @0xFFFFFE000869DB6C:20 sends CmdDisplayCompositorParameters | @0x222F6F74C gate | off | — | n/a |
| 29 | supportsCmdExecIndirect3 | 109 | KC `processSegmentKernelCommand` @0xFFFFFE00086B1928:568 picks ExecIndirect3 | @0x222F72C18 gate | off | — | n/a |
| 30 | supportsSwizzledTextures | 110 | MP `supportsTextureSwizzle` | — | off | — | n/a |
| 31 | supportsDynamicAttributeStride | 111 | MP (and key 28 bit 1) | key 28 bit 1 only if on | off | — | n/a |
| 32 | supportsBlitEncoderSPI | 112 | MP blit SPI, fillTexture | — | off | — | n/a |
| 33 | supportsMultiplaneMippedBlitTextures | 113 | MP | `PGDualPlaneBlitTextureResource` @0x222F63E14 | off | — | n/a |
| 34 | supportsComputePassDescriptorDispatchType | 200 | MP serializer | — | off | — | n/a |
| 35 | supportsObjectUniqueIdentifier | 201 | no named reader | — | off | — | n/a |
| 36 | supportsCommandBufferJump | 202 | MP (and key 33 bit 2) | key 36 only if on | off | — | n/a |
| 37 | supportsSharedStorageHeaps | 203 | MP (and key 33 bit 4) | — | off | — | n/a |
| 38 | supportsHeapHazardTracking | 204 | KC `setupWithArgs`:135 | `PGLegacyHeapResource`/`PGDetachHeapResource` @0x222F61134/0x222F6173C | off | — | n/a |
| 39 | supportsProtectionOptionsEnvelope | 205 | MP serializer (segment type 5) | — | off | — | n/a |
| 40 | supportsInsertCompressedTextureReinterpretationFlush | 206 | MP serializer | — | off | — | n/a |
| 41 | supportsArgumentBuffers | 207 | KC `createComputePipeline` @0xFFFFFE00086A7294, `setResourceHeap`, `allocateTable`; MP (and key 33 bit 5) | `CmdSetObjectAndPlacementList` @0x222F72FBC gate; GT handshake | off | — | n/a |
| 42 | supportsDisplaySetGuestICCProfile | 208 | KC swap:86 `setGuestICCProfile` | — | off | — | n/a |
| 43 | supportsCorrect2pXR10A8 | 209 | MP `supportsCorrectExtendedXR10Formats` @0x23506. **Below 209 the guest uses the "incorrect" two-plane XR10 A8 layout.** | — | off | 5b042af targets the off layout | n/a |
| 44 | supportsCPUBuffers | 230 | MP | — | off | — | n/a |
| 45 | supportsIndirectCommandBuffers | 231 | MP (and key 42 bit 0) | GT `PGResourceManager` ctor | off | — | n/a |
| 46 | supportsProtectedTextureOptions | 232 | MP | — | off | — | n/a |
| 47 | supportsDispatchThreadsIndirect | 233 | MP | — | off | — | n/a |
| 48 | supportsInfoIndirect | 235 | KC `processSegmentKernelCommand`:293 | `CmdInfoIndirect` @0x222F73228 gate | off | — | n/a |
| 49 | supportsDisplayPortConnectionType | 238 (not 237) | KC `start`:80, `isDisplayPortExternal`, `configureDevice`:44 read reg +0x234 | `guestDisplayPortConnectionTypes` @0x222F591A4 | off | — | n/a |
| 50 | supportsTextureDescriptor2 | 237 | MP: op 0x39 descriptor, usage ≥ 0x100, `supportsCorrectTextureUsageBits` | — | off | — | n/a |
| 51 | supportsMultipleDisplays | 245 | — | `guestDisplayPortCount` @0x222F59128 | off | — | n/a |
| 52 | *unnamed* | 250 | **no reader in KC, MP, PG, or GT** | — | off | — | open Q1 |
| 53 | supportsGuestContentHeadroom *(ours)* | 251 | KC swap:91 reads `IOSurfaceContentHeadroom` and adds property id 1 to op 10 | "guestContentHeadroom" | off | — | n/a |
| 54 | supportsTaskCDHash *(ours)* | 252 | KC `AppleParavirtTask::init` @0xFFFFFE00086AB798:151 calls vtable+376 (inferred: `setupCDHash` @0xFFFFFE00086ABDA8), which writes a 20 B cdhash at task-root +40 | `PGRemoteTask calculateCachePathAndExtension` @0x222F6A000 keys the shader cache by it | off | — | n/a |

## A.3 Device-info keys (26A428 writer vs Orchard)

Apple gates: "L≥2" means written only when the feature level is 0 or ≥ 2 (likewise for ≥3 and ≥4).
A level-1 host is the Apple equivalent of rung 62. "Ungated" means the guest uses the value without
ANDing it with a feature byte; at rung 62 that is the column that matters.

| Key | Name | Apple value / gate | Guest consumer (MP unless noted) | Orchard value (`regs.rs:1453`) | Matches Apple at the rung? | Orchard implements it? | Status |
|---|---|---|---|---|---|---|---|
| 1 | MSAASamples | highest n in {1,2,4,8} the host supports | `supportsSampleCount:` (ungated) | 8, reduced to host (1 on lvp/dzn per log) | yes, as a host value | yes (honest 1) | OK (Q5) |
| 2 | D24S8Supported | host | `isDepth24Stencil8PixelFormatSupported` | 1, reduced | yes | yes | OK |
| 3–5 | MaxThreadsPerThreadgroupW/H/D | host | `maxThreadsPerThreadgroup` | 1024/1024/64, reduced | yes | yes | OK |
| 6 | MaxThreadgroupMemoryLength | host | ungated | 32768, reduced | yes | yes | OK |
| 7 | IsFramebufferReadSupported | host | ungated (byte) | 1 | yes | yes (subpass input) | OK |
| 8 | IsRGB10A2GammaSupported | host | ungated (byte) | 1 | yes | unverified | ? P2 |
| 9 | SupportsNativeHardwareFP16 | host | ungated | 1, reduced | yes | yes | OK |
| 10 | DeserializerVersion | fixed 8 | serializer rungs (GL ≥ 6, base vertex ≥ 8) | 8 | yes | GL ops 0x8a–0x98 not decoded (Orchard doc) | partial |
| 11 | PrimtiveTypeSupport | host bitmask of types 0–9 | `supportsPrimitiveType:` | `EXECUTABLE_PRIMITIVE_TYPES` (narrower) | yes (narrowed) | yes | OK |
| 12 | SupportsMultiplaneTextures | = byte 6 | `supportsNonPrivateDepthStencilTextures` (with byte 6) | `protocol_dual_plane_textures(v)` = {31,41,42,43,60,61,62} | yes at ≤62; **wrong at ≥100** | see byte 16 | OK at 62 / P1 if the rung rises |
| 13 | LinearTextureAlignment | host `linearTextureAlignmentBytes` | ungated (default 16) | 256 | value unknown (inferred plausible) | yes | OK |
| 14 | HeapBuffers | 1 if byte 9 | `supportsResourceHeaps` | 1 | yes | partial | OK |
| 15 | HeapBufferAlignment | host heap align (if byte 9) | `heapBufferSizeAndAlign…` | 32 | Apple value not derived (Q6) | partial | ? |
| 16 | HeapTextures | 1 if byte 9 | `supportsResourceHeaps`, heap textures | 1 | yes | partial | OK |
| 17 | BufferFromIOSurface | 1 if PG supports && byte 10 | `supportsBufferWithIOSurface` | 1 | yes | partial | OK |
| 18 | MaxMetalShaderVersion | L1 `0x20002`, L2 `0x20006`, L0/≥3 `0x20007` | compiler target; **`supportsShaderBarycentricCoordinates` = ≥0x20004 (ungated)** | `0x20007` | matches level 0, not level 1 | barycentrics unverified in M2V | divergent (Q3) |
| 19 | SupportsSharedTextures | L≥2, PG && byte 20 | gated by byte 20 | 1 | Apple at L1 omits it | no shared textures | divergent, **inert at 62** |
| 20 | MaxVertexAmplificationCount | L≥2 | gated | absent | — | no | OK (correctly absent) |
| 21 | SupportsProgrammableSamplePositions | L≥2 && byte 25 | gated by byte 25 | 1 | omitted at 62 | no | divergent, inert |
| 22 | RasterizationRateLayerCount | L≥2, if nonzero | gated by byte 26 | absent | — | no | OK |
| 23 | TileShaders | L≥2 && byte 27 | gated by byte 27 | 1 | omitted | no | divergent, inert |
| 24 | ImageBlocks | L≥2 && byte 27 | gated | 1 | omitted | no | divergent, inert |
| 25 | RasterOrderGroups | L≥2 && byte 27 | gated through tile shaders | 1 | omitted | no | divergent, inert |
| 26 | MemoryOrderAtomics | L≥2 && byte 27 | gated by byte 27 | 1 | omitted | ? | divergent, inert |
| 27 | LargeMRT | L≥2 && byte 27 | **`isLargeMRTSupported` ungated** | 1 | Apple at L1 → guest reads false | yes if Vulkan maxColorAttachments ≥ 8 | **divergent, live** P2 |
| 28 | SupportFlags2023 | L≥2: bit0 Apple5 family, bit1 dynAttrStride (byte 31), bit2 MSAA 2D array | bit0 `featureProfile` (6 vs 10001) and skips the pixel-format check in `preValidateTextureDescriptor` (ungated); bit1 gated by byte 31; **bit2 `supportsTexture2DMultisampleArray` ungated** | 7 | Apple at L1 omits it; bit1 at 62 would be 0 | **no MSAA (key 1 = 1)** | **lie (bit 2)** P1 |
| 29 | MaxTotalComputeThreadsPerThreadgroup | L≥3, host | ungated | 1024, **not reduced** | — | host 128 per log (key 3) | **lie** P1 |
| 30 | MaxComputeLocalMemorySizes | L≥3, host | ungated | 32768, not reduced | — | ? | P1 |
| 31 | MaxComputeThreadgroupMemory | L≥3, host | ungated | 32768, **not reduced** | — | host 16384 per log (key 6) | **lie** P1 |
| 32 | MaxComputeThreadgroupMemoryAlignmentBytes | L≥3, host | ungated | 16 | — | yes | OK |
| 33 | SupportFlags2024 | L≥3: bits 0,1 always; 2 cmdBufJump; 3 rangeBuffer; 4 sharedMemHeap; 5 argBuffers; 6 SIMDReduction; 7 F16 bicubic; 8 SIMDShuffleAndFill; 9 condLoadStore; 10 computeCompressedTextureWrite; 11 sharedTextures | bits 2/4/5 gated by bytes 36/37/41; **bits 6–10 ungated** | 4095 | Apple at L1 omits it | bits 7 and 10: no; 6/8/9 depend on subgroup ops in M2V | **lie (7, 10), unverified (6, 8, 9)** P1 |
| 34 | GpuCoreCount | L≥3, host | `gpuCoreCount` (SPI) | 8 | — | informational | OK |
| 35 | MaxTextureLayers | L≥3, host | ungated | 2048, not reduced | — | ≤ Vulkan `maxImageArrayLayers`? | P2 |
| 36 | MaxPredicatedNestingDepth | L≥3 && byte 36 | gated through cmdBufJump | 16 | omitted | no | divergent, inert |
| 37 | HostGPUFamilyClamped | L≥3, highest Apple5..9 | no named guest reader | 1009 | — | — | inert (Q7) |
| 38, 39 | ArgumentBuffersTier / MaxSamplerCount | **never written** by 26A428 | no reader | absent | yes | — | OK |
| 40 | MinimumLinearTextureAlignment | always, host | `minimumTextureBufferAlignmentForPixelFormat:` | 256 | yes (value plausible) | yes | OK |
| 41 | SupportedTextureWriteRoundingModes | L≥3: 1 \| RTZ?2 \| RNE?4 | **`supportsTextureWriteRoundingMode:` ungated** (default 7 when absent) | 7 | Apple at L1 omits it → guest default is 7 too | Vulkan has no per-write rounding control | same as absent → OK |
| 42 | SupportFlags2025 | L≥4: argBuf ? 3 : 0 | bit0 ICB gated by byte 45; bit1 no reader found | 2 | omitted at L1; bit pattern differs (Q8) | no ICB | divergent, inert |
| 43 | SupportsNonPageAlignedIOSurfaces | **always 3** | KC arm 43; MP `supportsNonPageAlignedIOSurfaces` (bit0) / `…SpanningPages` (bit1) | **absent**; listed as DEAD (`regs.rs:1684`) | no (Apple 3) | absence keeps IOSurfaces page-aligned = simpler | divergent, **keep absent, fix the label** |
| 44 | HostGPUFamilies | L≥4, bits Apple5..11 | no named guest reader | 0x1F | — | — | inert (Q7) |
| 45 | HostChipID | always, `MGGetSInt64Answer("ChipID")` | MP `hostChipID` (SPI; 0 if absent) | absent (`tail=1` in every log) | no | — | missing, harmless P3 |

## A.4 Ranked fix list

1. **P1. Clear or reduce the ungated lies in the device-info table** (≈25 lines, `regs.rs:1453` +
   `device_info_caps`; low risk, because each change is a reduction).
   - Key 28: clear bit 2, since there is no MSAA rasterization (key 1 is reduced to 1 on lvp and dzn).
   - Key 29 → host `maxComputeWorkGroupInvocations`; key 31 → host `maxComputeSharedMemorySize`;
     key 30 → the same; key 35 → `maxImageArrayLayers`. Add them to `DeviceInfoLimits` next to
     keys 3–6. The log shows the host at 16384 B while key 31 promises 32768.
   - Key 33: clear bits 7 (F16 bicubic) and 10 (compute compressed texture write). Keep bits 6/8/9
     only if M2V emits subgroup ops and the host has `VK_KHR_shader_subgroup` arithmetic, ballot, and
     shuffle; otherwise clear them. That check is a porter task.
2. **P1. Port the full 26A428 ladder into Orchard as a table** (≈90 lines: one `features_for_version`
   like steelbrain's, with 26A428 rungs and the 56 B layout; low risk). Derive key 12 and the
   byte-gated keys (14/16/17/19/21/23–27/36/42) from it the way `writeDeviceInfo` does.
   `protocol_dual_plane_textures` is wrong for every rung ≥ 100, so raising the cap (e.g.
   `REIMS_VGPU_PROTOCOL_CAP=101`) would contradict key 12. Also make the version write follow Apple:
   ignore bit-31 writes and step an invalid rung down to a valid one.
3. **P1. Stay at rung 62. It is an Apple-legal configuration (feature level 1) and the simplest guest
   path.** Correct the stale docs (≈30 lines of comments, no code): `regs.rs:1050-1073` and
   `mmio.rs:165`. The guest writes 252, not 4; the ladder goes to 252; the guest steps down itself;
   rungs 1–6 are unsupported; the minimum viable cap is 10. Make `REIMS_VGPU_PROTOCOL_CAP` reject
   values below 10, or warn on them, so it cannot silently disable the driver. Each step up costs a
   host feature: 100 shared textures, 101 info-encoder segments 450–469, 107 tile shaders,
   109 ExecIndirect3, 207 argument buffers and placement lists, 237 descriptor2 (op 0x39),
   238 DisplayPort registers. None of them simplifies the guest.
4. **P2. Key 27 LargeMRT** (≈3 lines): this is the one byte-27 key the guest reads ungated. Derive it
   from Vulkan `maxColorAttachments ≥ 8`; Apple at rung 62 would not send it at all.
5. **P2. Key 43** (≈5 lines, docs): remove 43 from `DEVICE_INFO_DEAD_KEYS`. The 26A428 kext has an arm
   for it and the plugin reads bits 0 and 1. Move it to `DEVICE_INFO_UNANSWERED_KEYS` with the
   reason: absence makes the guest page-align IOSurfaces, which is the simpler path. Add key 45
   there too (HostChipID, 0 is harmless). Only send 43 = 3 if Orchard maps sub-page IOSurfaces.
6. **P2. Key 18 vs barycentrics.** `0x20007` makes `supportsShaderBarycentricCoordinates` true. Either
   verify that M2V translates `[[barycentric_coord]]` (and that the host has
   `VK_KHR_fragment_shader_barycentric`), or accept the risk. Do not lower the key blindly: the guest
   forces AIR 2.7 (Orchard doc), and a level-1 Apple host would send `0x20002`. Changing it needs a
   measured boot.
7. **P2. Display features on at 62** (≈40 lines, display family): CmdDisplaySetProperties (byte 7) is
   sent before a swap whenever the colour matrix or remap changes. Orchard drops it
   (`drain/mod.rs:6250`), so Night Shift and colour filters never apply. Decode property id 0
   (48 B matrix) at least into a log line. CmdDisplaySleepState (byte 3) may stay a no-op.
8. **P2. byte 16 s8ByteCountForD32S8 = 1 together with byte 6 && key 12.** Together these give
   `supportsNonPrivateDepthStencilTextures`, so the guest may build guest-memory D32S8 textures with
   a 1-byte stencil plane. No such layout exists in Orchard. If those textures show up, there are
   two levers: (a) implement the layout; (b) send key 12 = 0. That turns off only the non-private
   depth/stencil path in the plugin, because the host-side two-plane gate reads byte 6, not key 12.
   Option (b) departs from Apple; measure before choosing it.
9. **P3. maxFIFOCount 64 vs MAX_CHANNELS 32.** At rung ≥ 61 Apple accepts child FIFO index < 64,
   while Orchard's masks are u32. No guest reader of the count was found, so the guest's real
   channel ceiling is unknown (Q4). If a refused channel ≥ 32 ever appears, rung 60 is the fallback:
   it differs from 62 only in maxFIFOCount 32 and s8ByteCount 4.

## A.5 Open questions

1. Rung 250 / byte 52: no reader in KC, MP, PG, or GT. It may be a feature of a binary not in the
   corpus (WindowServer, a display daemon) or a placeholder. It does not matter at rung 62.
2. Bytes 8 (displayDimensionFloats) and 24 (sunburst): no readers found in 26A428. They are probably
   dead in this release.
3. Does M2V handle barycentric coordinates, and are the SIMD-group ops (key 33 bits 6/8/9) translated
   to Vulkan subgroup ops? This decides fixes 1 and 6 and needs a host-spec review or the port.
4. Which channel ids does the 26A428 kext actually open? Its `maxFIFOCount` copy (`+1412`) has no
   reader. The answer decides whether fix 9 is ever needed.
5. Key 1 = 1: Metal guarantees 4 samples on every device. A guest that asks for 4 anyway will hit
   Orchard's resolve refusal. That is a known trade-off (Orchard doc); I am not changing it here.
6. Key 15: the value Apple derives (`heapBufferSizeAndAlignWithLength:vm_page_size options:0x20`
   alignment) was not computed. Orchard's 32 is below the guest default of 256. The porter should
   confirm that the host honours 32-byte heap placement.
7. Keys 37 and 44: no named reader in KC or MP. They may be read by struct offset or by Metal.framework
   SPI. `supportsExtendedXR10Formats` is likewise an MTLDevice base-class answer, not an APV field;
   the guest's rung-209 analogue is `supportsCorrectExtendedXR10Formats` (byte 43).
8. Key 42: the dump computes both bits from `-[_PGDevice supportsArgumentBuffers]` (value 3 or 0).
   One of the two calls may be a different selector that the decompiler merged. Verify in IDA
   (@0x222F41714, the `v167`/`v144` lines) before relying on the meaning of bit 1.
9. Vtable+376 = `setupCDHash` is inferred from the vtable order (`setupCDHash`, then 384
   `defineHostTask`, then 392 `setResourceHeap`) and from the kernel-task override returning 1.
   This is irrelevant below rung 252.

## A.6 Linear texture alignment (key 13)

Measured: iconservicesagent crash-loops after `(Metal) _mtlValidateStrideTextureParameters, line 1938`
(`shots/ics-7190627-log.txt:89,196,268`). Metal = `Metal.i64` (26A428 dyld cache, arm64e).

**What line 1938 means.** `_mtlValidateStrideTextureParameters(device, desc, width, offset, bytesPerRow, isIOSurface)`
@0x18D557EA8 opens one message context with `line 1938` (`_MTLMessageContextBegin_(…, 1938, …)`), so every
check in it logs the same line. The log alone does not say which check failed. The checks are:
1. `bytesPerRow < bytesPerPixel*width` → "bytesPerRow must be greater or equal".
2. `((A-1) & bytesPerRow) != 0` → "bytesPerRow must be aligned to A"; `((A-1) & offset)` → "offset must be aligned".
3. Compressed/depth/stencil format, mip count ≠ 1, depth ≠ 1, or a type other than 2D.

Where A comes from (normal branch, TLS+288 ≠ 7085):
| Caller | isIOSurface | A |
|---|---|---|
| `-[MTLIOAccelTexture initWithBuffer:descriptor:offset:bytesPerRow:]` @0x18D65C6F8; `…isStrideTexture:` @0x18D65C27C | 0 | `[device linearTextureAlignmentBytes]` |
| `-[MTLIOAccelTexture initWithDevice:descriptor:iosurface:…]` @0x18D557AA0 (single-plane surfaces only; offset = `IOSurfaceGetBaseAddress`) | 1 | `iosurfaceTextureAlignmentBytes` = `_limits[41]` (or `[42]` for read-only usage) |

The guest plugin overrides only one of these getters:
- `-[AppleParavirtDevice linearTextureAlignmentBytes]` @0x222DC returns **key 13**, or 16 when key 13 is absent.
- Metal's public `minimumLinearTextureAlignmentForPixelFormat:` @0x18D64E9DC → `minLinearTextureAlignmentForPixelFormat:` @0x18D64EAAC →
  `deviceLinearTextureAlignmentBytes` = `_limits[43]`. The plugin does not override these, so they ignore key 13.
  (The IOGPU.framework superclass is not in the corpus, so an override there is not excluded.) This is the value apps and frameworks use to align `bytesPerRow`.
- `-[_MTLDevice initLimits]` @0x18D5448FC sets `deviceLinear…` = `linear…` = `deviceLinearReadOnly…` = v303, which is chosen by
  `featureProfile`: profiles 0/1 → 64, profiles 4–13 → 16, and profiles 10000/10001/10002 → 256. One value per device; there is **no per-pixel-format table**
  (the format only feeds the "unsupported, compressed, depth" failures).
- `-[AppleParavirtDevice featureProfile]` @0x210D1 returns 6 when key 28 has bit 0 set, and 10001 otherwise.
- `minimumTextureBufferAlignmentForPixelFormat:` @0x20A6D returns max(super, **key 40**). Texture buffers (type 9) skip the alignment check entirely.

Apple host, `writeDeviceInfo` @0x222F41714: key 13 = host `[MTLDevice linearTextureAlignmentBytes]` (line 301),
key 40 = host `deviceLinearTextureAlignmentBytes` (line 689). At level 1, key 28 is not sent, so the guest's profile is 10001 and Metal reports 256.
On an Apple-silicon host, key 13 is 16 (**inferred**: the base table gives 16 for profiles 4–13; the AGX override was not checked). The guest therefore validates
against 16 or less and reports 256, so any stride an app derives from the reported value passes.

**Orchard is inverted.** It sends key 28 = 3 (bit 0 set → profile 6), so Metal reports 16, and key 13 = 256, so Metal validates against 256.
A `bytesPerRow` that is a multiple of 16 but not of 256 is rejected. This is the probable cause of the crash, **inferred**: the failing check is hidden by `<private>`.
**Fix: key 13 = 16. Key 40 = max(16, Vulkan `minTexelBufferOffsetAlignment`).** The alternative, clearing key 28 bit 0, changes the
feature profile wholesale. Host-spec must confirm that Orchard accepts buffer-backed linear textures with a 16-byte row pitch.
The IOSurface branch does not depend on key 13; its `_limits[41]` value for profile 6 was not resolved (vectorised `initLimits`, v540).

**air64_v22 is benign and comes from key 18 = 0x20002.** `setupDeviceArchInfo` @0x22E06: subType = (MSV − 0x20001) + 5
→ 6, and `air_macho_get_public_arch_name_from_id` @0x18D5EA258 (table `off_1E0AA6B58[subType-1]`) names it `air64_v22`.
`-[_MTLBinaryArchive loadFromURL:error:]` @0x18D5E96A0 logs the miss and still returns 1, so the functions are compiled
normally instead of loaded from the archive. The cost is compile time.
