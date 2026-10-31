# C18: Host format and usage capabilities: steelbrain vs Orchard

Symptom: the guest Metal plugin logs "Cannot create a texture with this usage on this host".
CoreAnimation then logs "Failed to allocate 1920x128 surface texture" (and once 192x128) about
every 60 s, so Liquid Glass backdrops are never captured.

Question: how does a correct host tell the guest which pixel formats and texture usages it
supports, and what does Orchard tell it instead?

Spec: `steelbrain/reims-vgpu` @ 12765ee (crate `reims-vgpu-core/src`, paths below are relative to it).
Target: `external/orchard/reims-vgpu/crates/reims-vgpu/src` @ 5a634ef (`gg-macos27`).

## 1. There is no format or usage capability table on the wire

steelbrain does not send the guest any per-pixel-format or per-usage table. The guest sees
exactly two capability channels:

1. **The binary-version rung.** The guest writes a version, reads it back, and derives its
   60-byte `APVFeatures` from the value it read, using its own `getAPVFeaturesForVersion`. The
   host cannot pick feature bytes one by one: it only chooses the rung.
   - The steelbrain cumulative switch is in `guest/abi/features.rs:30-93`.
   - The clamp by feature level is `binary_version_from_feature_level` at
     `guest/abi/features.rs:160`. Level 1 clamps to 62, 2 to 113, 3 to 209, and 0 or 4 to 245
     (`HIGHEST_BINARY_VERSION` 0xf5, `:23`).
   - The default level is 0 (`device/config.rs:69`). A 26A428 guest writes 252, so it reads
     back **245**. The table in `docs/testing.md:1410` is measured at level 0.
2. **Device-info key/value pairs** (opcode 58), written by `write_device_info` at
   `guest/abi/device_info.rs:135`. They are scalars and bitmasks only. None of them is per
   format or per usage.

`resources/texture/pixel_format.rs` (`GuestPixelFormatInfo`, 0x50 B) never goes on the wire. The
host builds it from `MTLPixelFormat` descriptions and uses it only for its own dimension
validation (`resources/texture/dimension.rs:282`).

## 2. The gate that fires is a rung gate, not a capability value

From `docs/audit/C6-heap-creation.md` section 2: the MP checks `usage >= 0x100 && !APVFeatures[50]`
and logs "Cannot create a texture with this usage on this host" (`sub_2CB18`). This check is in
`heapTextureSizeAndAlignWithDescriptor:` @0x2235F. guest RE should confirm that the same gate
sits on the `newTexture*` / IOSurface paths. Byte 50 is `supportsTextureDescriptor2`, which first
appears at rung **237**.

The reason is the descriptor format:
- **v1** `PGSerializedTextureDescriptor` (32 B) carries `usage : 8`, bits 8-15 of word 0
  (`deserializer/texture_descriptor.rs:12-31, 56-59`).
- **v2** `PGSerializedTextureDescriptor2` (packed, 0x27 B) carries `usage : u32` at +3, plus
  `writeSwizzleEnabled` and four swizzle bytes (`texture_descriptor.rs:67-94`).

A usage above 0xFF cannot be serialized in v1, so the guest refuses it locally. The host never
sees the request. In steelbrain the guest sits at rung 245, so byte 50 is on and the guest sends
the v2 commands:

| v1 cmd | v2 cmd | what | steelbrain |
|---|---|---|---|
| 1 | 52 | memoryless texture over a descriptor | `resources/manager/texture.rs:620-624, 917-918` |
| 48 | 53 | shared texture | `texture.rs:779-780` |
| 9 | 55 | texture over a buffer (0x38 vs 0x40 B) | `texture.rs:922-923, 1088-1100` |
| 21 | 56 | texture in a heap (0x34 vs 0x3c B) | `texture.rs:924-925, 1139-1150` |
| 47 | 57 | rotated IOSurface-plane texture (0x28 vs 0x30 B) | `texture.rs:1222-1224` |
| heap query | heap query 2 (0x2c vs 0x34 B) | `heapTextureSizeAndAlignWithDescriptor` | `deserializer/records.rs:650-666` |

`texture_desc2` (`texture.rs:400`) passes the full 32-bit usage straight to
`MTLTextureDescriptor setUsage:`. steelbrain has no usage filter of its own: Metal decides.

**Orchard:** `PROTOCOL_VERSION_MAX = 62` (`model/regs.rs:1111`). Its doc at `:1080-1110`
explicitly lists "237 texture descriptor 2" as a feature this host does not have. Byte 50 maps
to rung 237 at `regs.rs:1177, 1329`. As a result, every texture with usage >= 0x100 is refused
inside the guest. The wire structs for the wide forms already exist (`reims-vgpu-wire/src/ops/texture.rs:317`,
`backed_texture.rs:101-119`, `heap_texture.rs:99`, `info.rs:146,185`). The decode side has
consts for them (`runtime/decode/resource/mod.rs:1220-1225, 4876-4879`). None of them is
reachable at rung 62.

## 3. Device-info diff (steelbrain at level 0 on an Apple-silicon Mac vs Orchard at rung 62)

Steelbrain lines are in `guest/abi/device_info.rs`. Orchard values come from `DEVICE_INFO_CAPS`
at `regs.rs:1926-1975`, filtered by `device_info_caps` (`regs.rs:1793`), which withholds a key
whose feature byte is off at the rung (`regs.rs:1726`).

| key | name | steelbrain | Orchard | matters for usage/format? |
|---|---|---|---|---|
| 8 | RGB10A2Gamma | Metal `isRGB10A2GammaSupported` (:170) | 1 | no (same on M-series) |
| 12 | MultiplaneTextures | features byte 6 (:181) | rung byte 6 (`regs.rs:1825`) | same |
| 13 | LinearTextureAlignment | Metal `linearTextureAlignmentBytes` (:182) | 16 | no |
| 15 | HeapBufferAlignment | heap buffer align, page, Private = 16 KiB (:186) | 32 | no (C6) |
| 18 | MaxMetalShaderVersion | level 0: 0x20007 (:198) | 0x20002, on purpose (`regs.rs:2189`, barycentrics) | no |
| 19 | SharedTextures | 1 if rung byte 20 and host (:210) | withheld at 62 | no |
| 20 | MaxVertexAmplification | Metal count, level >= 1 (:212) | never sent (hole) | no |
| 22 | RasterRateLayers | only if nonzero (:221) | never sent | no |
| 28 | SupportFlags2023 | bit0 Apple5 family, bit1 dyn stride (rung 111 and host), bit2 MSAA 2D array (:246) | 0b011, bit1 cleared below 111, so **1** (`regs.rs:2083,1834`) | bit2 (MSAA 2D-array textures) differs. bit0 skips the MP format pre-check on both |
| 33 | SupportFlags2024 | host bits; bit10 computeCompressedTextureWrite, bit11 = supports_shared_textures (:254-266) | 0x96F (bits 4, 7, 9, 10 cleared; 6 and 8 reduced) (`regs.rs:2139`) | bit10 (compressed texture shader-write) is off in Orchard. bit11 is set without rung 100 |
| 37 | HostGPUFamilyClamped | highest of Apple9..6, else Apple5 (:301) | 1009 | no |
| 40 | MinLinearTextureAlignment | deviceLinearTextureAlignmentBytes (:338) | max(16, minTexelBufferOffsetAlignment) | no |
| 41 | WriteRoundingModes | 1, or 2/4 per Metal (:298) | 7 | no |
| 42 | SupportFlags2025 | **0 or 3** (argument buffers) (:333) | **2** | no (but 2 never comes from steelbrain) |
| 43 / 45 | NonPageAlignedIOSurfaces / ChipID | not written | not written | same |
| 44 | HostGPUFamilies | Metal supportsFamily set, bit5 = family -1009, bit6 Apple10 (:336) | 0x1F | no |

There is no key for RGBA16Float, BGRA8, BGR10A2 or XR10 render-target or shader-write support,
and none for pixel-format views or lossless compression. Their behaviour is all keyed to rung
bytes:
- XR10: byte supports_correct_2p_xr10_a8, rung 209 (`features.rs:42`).
- Swizzled textures: rung 110.
- Compressed reinterpretation flush: rung 206.
- Protected texture options: rung 232.
- 32-bit usage: rung 237.

## 4. Change candidates for Orchard

1. **No device-info edit can lift the gate.** It is guest-side, on byte 50, and the guest
   computes byte 50 from the rung. Do not tweak keys 28, 33 or 42 for this symptom.
2. **Raise the rung to >= 237** (`regs.rs:1111`). This is the only host-side fix. It also turns
   on every byte from rung 100 to 237: shared textures, info encoder (which would also fix the
   C6 heap-query race), tile shaders, ExecIndirect3, swizzled textures, command buffer jump,
   shared-storage heaps, argument buffers 207, CPU buffers, ICBs, protected options, and info
   indirect. Each one changes wire formats Orchard does not decode today. Size: thousands of
   lines, very high risk; a project, not a patch. A diagnostic run with a cap above 62 is not
   possible today, because protocol_version_cap can only lower the rung (`regs.rs:1446`).
3. **Cheap tidy-ups (low risk, unrelated to the symptom).**
   - Key 42: send 0 instead of 2 (1 line), which is the value steelbrain sends without
     argument buffers.
   - Key 33 bit 11: clear it below rung 100 (about 3 lines in device_info_caps).
4. **Guest-side alternative (outside these two trees):** patch the MP usage >= 0x100 gate, or
   strip the high usage bits that CoreAnimation asks for, if the guest RE findings show they
   are advisory. Those findings should decide this.
