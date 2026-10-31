# C18: "Cannot create a texture with this usage on this host"

Read-only guest RE. Guest plugin = `<RE corpus>/AppleParavirtGPUMetalIOGPUFamily.c/` (MP,
x86_64 slice). Metal = `Metal.i64` (26A428 dyld cache, arm64e). Feature bytes as in `A-features.md` §A.2.

**Short answer.** The plugin refuses a texture when `descriptor.usage >= 0x100` and the host did not grant
APVFeatures **byte 50 `supportsTextureDescriptor2`**. That byte is on only from protocol **rung 237**. Orchard
negotiates rung 62, so the byte is off. The old descriptor (v1) packs `usage` into 8 bits. Only descriptor2
(ops 0x34/0x35/0x37/0x38/0x39) carries a 32-bit usage. Size, pixel format, storage mode and compression are
**not** part of the check. The 1920x128 size plays no role.

## Which usage bits are >= 0x100

Metal `__validateTextureUsage` @0x18D657244 accepts only `usage & ~0x1C03F`, i.e. it rejects anything outside
0x3F | 0x4000 | 0x8000 | 0x10000. `MTLTextureUsageString` @0x18D656EB8 names those three high bits:
0x4000 `NoConcurrentAccess`, 0x8000 `Video`, 0x10000 `BlockWritesOnly` (all SPI). So the CA surface texture carries
at least one of them. Which one was **not established**, because QuartzCore is not in the corpus.

## Refusal sites (every one tests the same condition)

| Op/type | Name | Payload (size, key fields) | Guest behaviour | Orchard handler | Status | Seen in logs | Priority |
|---|---|---|---|---|---|---|---|
| v1 0x0C / 0x2F, v2 0x39 | IOSurface texture | v1 48 B (usage u8 in word0 bits 8-15); v2 56 B (usage u32) | `-[PGSerializer newIOSurfaceTextureWithDescriptor:plane:allocator:]` @0xD0A3: `if (supportsTextureDescriptor2) op 0x39 … else if (usage < 0x100) op 0x0C/0x2F … else log (sub_2A520, call @0xD24A)`. Caller `-[AppleParavirtTexture initWithDevice:descriptor:iosurface:plane:field:]` @0x8CAD:79 | none: nothing is sent | divergent (refused in the guest) | WindowServer log every ~60 s | P0 |
| v1 0x01, v2 0x34 | plain texture | v1 44 B; v2 52 B | `-[PGSerializer newTextureWithDescriptor:allocator:]` @0xD29D: `if (supportsSwizzledTextures) op 0x34; else if (usage < 0x100 \|\| supportsTextureDescriptor2) op 0x01; else log (sub_2A57B @0xD39C)` | — | same | ? | P0 candidate |
| v1 0x15, v2 0x38 | heap texture | v1 60 B; v2 68 B | `newTextureWithDescriptor:heap:offset:useOffset:allocator:` @0xC99C (log @0xCB2F); `-[AppleParavirtHeap newTextureWithDescriptor:offset:]` @0xF168:20 reads `features+50` directly; `-[AppleParavirtHeap newTextureWithDescriptor:]` (log @0xF161) | — | same | ? | P1 |
| v1 0x09, v2 0x37 | buffer texture | v1 64 B; v2 72 B | `newTextureWithBuffer:descriptor:offset:bytesPerRow:allocator:` @0xCD55 (log @0xCE8B) | — | same | ? | P2 |
| v1 0x30, v2 0x35 | shared texture | 44/52 B | `newSharedTextureWithDescriptor:newTextureRef:allocator:` @0xDD4A (byte 20 required first; log @0xDE4A) | — | n/a at 62 | — | P3 |
| info | heap size and align | — | `-[AppleParavirtDevice heapTextureSizeAndAlignWithDescriptor:]` @0x2235F:39 `usage >= 0x100 && !_features.supportsTextureDescriptor2` (log @0x2270A) | — | same | ? | P1 |

Plumbing: `-[AppleParavirtDevice setupSerializerFeatures]` @0x20379 copies `_features.supportsTextureDescriptor2`
into `PGSerializer` (`setSupportsTextureDescriptor2:` @0xE757). `-[AppleParavirtDevice supportsCorrectTextureUsageBits]`
@0x23668 returns the same byte. Metal.framework has no selref to that selector (scan of `Metal:__objc_selrefs`),
so the caller is probably IOGPU or QuartzCore (**inferred**, not in the corpus).
Descriptor layouts: v1 `serializeTextureDescriptor:` @0xC31E stores `desc+104` (usage) as `(u8) << 8`, and an
overflow trips `sub_29FC4`. v2 `serializeTextureDescriptor2:` @0xC4B4 stores usage as a u32 at byte 3, plus a
4-byte swizzle.

## What the host would have to advertise

- **APVFeatures byte 50** (guest copy at kext `AppleParavirtGPU+1450`; plugin `features+50`). Rung 237 or higher is
  the only way to set it. The guest builds its features from the rung, not from per-bit host data (A.0 §2), and the
  ladder is cumulative. So granting byte 50 also grants bytes 20-48: shared textures, info encoder, tile shaders,
  ExecIndirect3, argument buffers, ICBs, and so on. No device-info key and no format table can do it alone.
- For the plain (non-IOSurface) path only, byte 30 `supportsSwizzledTextures` (rung 110) is enough: it sends op 0x34
  with descriptor2. It does **not** help the IOSurface path.

## Ranked fix list

1. Decide which path CA uses (QuartzCore). If it is the IOSurface path (**inferred** from "surface texture"), no host
   value below rung 237 helps. The only options are: (a) raise the rung to 237 and implement descriptor2 ops
   0x34/0x37/0x38/0x39 plus everything at rungs 100-235 (thousands of lines, high risk); or (b) a guest-side change
   (strip usage bits 0x4000/0x8000/0x10000 before serialising), which is out of this repo's host-only approach.
2. If it is the plain path, rung 110 is the smallest rung that helps (op 0x34, ~60 lines of decode). It still pulls
   in bytes 20-30 (high risk).

## Open questions

1. Which bit CA sets, and through which entry point. Next query: pull `QuartzCore` (and `IOGPU`) from the guest dyld
   cache, `gq.py dsc ... --name QuartzCore`, then grep for "surface texture" and `setUsage:`.
2. Who calls `supportsCorrectTextureUsageBits`, and whether a NO answer is meant to make the caller drop the high
   bits. If IOGPU/QuartzCore strips them in a path WindowServer skips, that path may be the real lever.
