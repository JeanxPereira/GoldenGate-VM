# Protocol audit: Apple's host vs Orchard

Goal: for every guest→host GPU command, object type and feature the macOS 27 (26A428) guest
uses, say what Apple's own host does and whether Orchard's reims-vgpu does the same. The result
drives the porting waves instead of chasing one host-log decline at a time.

## Sources

| Side | Where |
|---|---|
| Apple host, FIFO/MMIO/features (`ParavirtualizedGraphics.framework`) | IDA database / decompiler dump of the 26A428 binary (the *RE corpus*, local only) |
| Apple host, Metal command decoder (`com.apple.gpusw.ParavirtualizedGraphicsGPUTask`, `PGDeserializer`) | RE corpus |
| Guest user side (Metal plugin, `PGSerializer`) | RE corpus (`AppleParavirtGPUMetalIOGPUFamily`) |
| Guest kernel side (kext) | RE corpus (kernelcache, `kc`) |
| Orchard (target) | `external/orchard/reims-vgpu/crates/reims-vgpu/src/` (branch `gg-macos27`): `model/regs.rs`, `runtime/{decode,draw,objects,drain,mmio,compute_exec}` |
| steelbrain (second opinion) | [steelbrain/reims-vgpu](https://github.com/steelbrain/reims-vgpu) `crates/reims-vgpu-core/src/` |
| Measured traffic | host log `/tmp/reims-vgpu-fail*.log` (copied to `$GG_HOME/run/<img>/logs/` by `gg`); `tools/gpu-score.sh` |

The RE corpus (`<RE corpus>/...` below) is the analyst's local set of IDA databases and decompiler
dumps of Apple binaries from the 26A428 image. It is not distributed: these documents keep only
function names, addresses and descriptions of behaviour. Log paths, AIR/SPIR-V dump names,
screenshot names and short commit hashes refer to artefacts of the original runs and are kept as
provenance; the commits are on the `gg-macos27` branches of the two forks. `gq.py` is the
author's local headless-IDA query helper (not included); its commands are quoted as how a
finding was made.

Landmarks (from the extraction):
- FIFO dispatch `-[PGFIFO processFifo:]` @0x222F735D4; `Cmd*` handlers 0x222F6E6DC–0x222F73228.
- ExecIndirect segments: GPUTask `-[_PGDeserializer decodeSegmentWithHeader:…]` @0x1000292B0 →
  render 0–166 @0x100025C60, compute 200–230 @0x10000FDA8, blit 300–323 @0x1000033D8,
  info 450–469 @0x100006BDC (segment types 0/1/2/4, 5 = protection options).
- Objects: GPUTask `PGResourceManager::createObject<PGResource*>` @0x1000427EC.
- Version/features: `-[_PGDevice mmioWriteAtOffset:value:]` @0x222F56D6C (case 0xD → `setBinaryVersion:`),
  `getAPVFeaturesForVersion` @0x222F58984, `getDeviceInfoStructs` @0x222F4C770,
  `checkCapabilities` @0x222F42374, `writeDeviceInfo` @0x222F41714,
  GPUTask `handshakeWithTaskRoot:…features:` @0x100029FB8.

## Rules

- Evidence for every row: Apple function + address; Orchard `file:line`. Mark guesses **inferred**.

## Row format (one table per family)

| Op/type | Name | Payload (size, key fields) | Apple host behaviour (1–2 lines) | Orchard handler `file:line` | Status | Seen in logs (count) | Priority |

Status: **OK** · **partial** (say what's missing) · **divergent** (say how) · **missing** · **n/a**
(deprecated / never sent by this guest). Priority: P0 seen in logs and failing, P1 sent by this
guest and wrong, P2 not seen yet, P3 deprecated.

End each file with: a ranked fix list (each item sized in lines, with risk) and the open questions.
