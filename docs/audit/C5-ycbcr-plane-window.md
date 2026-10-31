# C5: `ycbcr_2p_plane_window plane=1` on the 444f wallpaper tiles (run 83e3b84)

Question: in 3abd014 the Aerial still staged (`ycbcr_2p_staged` ×39, no refusals). In 83e3b84 it
was black, with 17× `compute_stage_tex view_fail reason=ycbcr_2p_plane_window plane=1 ref=8
base_fmt=0x21e 512x512`. What did plane 1 look like in each run, and what does Apple do?
Orchard is the same at both commits for this path: `git diff --stat 3abd014 83e3b84` touches no
mapper, mapping_write, ycbcr or compute_exec file. Read-only audit, 30/10.

## 0. The evidence is gone

Both host logs are lost. `/tmp/reims-vgpu-fail.log` and `/tmp/reims-vgpu-fail.3abd014.log` no
longer exist. WSL was shut down: `qemu.out` ends with `terminating on signal 15 from pid 1
(/usr/lib/systemd/systemd-shutdown)`, `uptime` read 0 min at 02:31, and `/tmp` came back empty.
No copy exists in the repo, in `~/gg/run`, or on the data disk. `qemu.log` has no reims
lines. So none of the per-tile offset, pitch, page or alloc numbers can be read back. What
follows is what the code allows, and which field decides between the options.
**Process fix (no code):** the always-on sink is hard-wired to `/tmp`
(`reims-vgpu-observe/src/emit.rs:27`). The tester must copy the log to `~/gg/run/gg27/` before
any `gg stop` or `wsl --shutdown`. Better, `tools/gg` should do that copy on stop.

Known 444f geometry, from b3e58a4 (C4 §B): `mapper_desc_path mapping=233 512x512 bpr=512
fmt='444f' alloc=786432`. That is 48 pages of 16 KiB: plane 0 is Y 512×512 at 0 (256 KiB),
plane 1 is CbCr 512×512×2 at 262144 with bpr 1024 (512 KiB). Plane 1 therefore ends
**exactly at alloc** (262144 + 511·1024 + 1024 = 786432), with no slack at all.

## 1. Two different checks print the same `plane=1`

| # | Site | Fires when | Label |
|---|---|---|---|
| A | `runtime/ycbcr_planes.rs:265-269` (closure `window`, called for plane 1 at :278) | `sample_window_from_device_plane` returns None (`reims-vgpu-protocol/src/iosurface_pages.rs:456-483`: plane bpr < 1024, or `plane_size` < 524288, or plane w/h < 512), **or** plane-1 `span_end > surf.alloc_size` | honest plane 1 |
| B | `runtime/compute_exec/mod.rs:2288-2294` | `page_entries.len() << page_shift < planes.span_end()`, the mapping's resolved page list is shorter than 786432 bytes, **including an empty list** | **hard-coded** `PlaneWindow { plane: 1 }` whatever the cause |

Plane 0 passed in both cases: a plane-0 record or extent failure would print `plane=0`, or
`ycbcr_2p_plane_extent`. So the descriptor existed, had ≥2 planes, and plane 0 was 512×512.

Why B is the likelier one:
- A depends only on the guest's plane records. The same guest image, decoder and tile size
  produced records that passed 39/39 in 3abd014, and plane records are not timing-dependent.
- B depends on the mapping's **page list at bind time**, which is timing-dependent:
  - `condemn_surface_backing` (`model/state.rs:5420-5440`) moves `page_entries` into
    `condemned_entries` on a trailing `DeleteIOSurfaceBacking2`, which leaves the list
    **empty** until the next resolve.
  - `invalidate…` (`state.rs:5395-5398`) clears it on unmap or reattach.
  - `ensure_resolved_for_scanout` (`compute_exec/mod.rs:2153`) has its result **discarded**.
    When the re-resolve fails (`mapper_desc_fail`, for example a released backing), the stage
    carries on with an empty or short list.
  - Its coverage test, `pages_cover_geom` (`runtime/mapper/mod.rs:1152-1176`), sizes the span
    from the mapping's single-plane `m.format`. For '444f' that is 0, because
    `iosurface_pixel_format_to_mtl` returns 0 for biplanar formats, so it falls back to BGRA8.
    It never uses the two-plane span.
  - 83e3b84 ran under heavier guest churn ("Too many corpses" crash storms, then a panic at
    ~26 min), which is exactly when surface ids recycle and trailing deletes land between a
    tile's encode and its execution on the host.
- B also preempts the read. `read_rect_raw_at` (`mapping_write/mod.rs:2085`) would itself
  refuse an empty list (as `ycbcr_2p_read plane=0`). B fires first and mislabels it.

What would distinguish them in a log: B leaves no `mapper_desc_path`/footprint line for that
mapping near the refusal, and `mapper_desc_fail` / `revalidate_*` / `condemn` lines for that
mapping id show up instead. A would show the same mapping staged in one dispatch and refused in
another with an identical page count. The 17 lines carry `mapping=`; the next run must log the
numbers themselves (fix step 1).

Partial or sub-range mappings, and plane 1 "placed elsewhere": `walk_descriptor_pages`
(`iosurface_pages.rs:1190-1240`) always walks `span_page_count_shift(alloc_size)` pages, so a
resolved list is never a sub-range. Plane offsets are surface-relative, which is what
`sample_window_from_device_plane` uses (`plane_offset`, falling back to `plane_base` when 0), and
the mapping view starts at the surface base. No base is missing. "Different layout" would be
case A, and nothing points to it.

## 2. Apple's host

`createMapperRefTexture` @0x10004D788 does three things. It calls `retainIOSurfaceWithMappingID:`
(@0x10002E718, an XPC to the PG host process holding a **real host IOSurface** for that mapping
id). For type 0xC it calls `newIOSurfaceTexture` @0x10004CF90, which runs
`validateIOSurfaceDescriptor` (returns early for planar surfaces) and then
`newTextureWithDescriptor:iosurface:plane:` with the wire plane index (`v39`). There is no plane
arithmetic in GPUTask. The plane geometry lives in the host IOSurface, built once in
`-[PGIOSurfaceHostDevice createPlaneDictionary:]` @0x222F4EA60 from the guest's
`IOSurfaceDevicePlaneDescriptor2`: `var1` goes to kIOSurfacePlaneOffset, `var2` to PlaneBase,
`var3` to PlaneSize, `var4`/`var5` to Width/Height, `var6` to BytesPerRow, and `var7` to
BytesPerElement. The surface keeps its whole allocation for as long as the mapping id is
retained (the retain/release pair brackets the texture). There is no "page list shorter than
the plane" state on Apple's side. A surface is either retained in full or it is gone. When it is
gone, `retainIOSurfaceWithMappingID:` returns nil and the object fails to create. Nothing is
sampled empty.

## 3. The kernel panic (serial.txt:2655-2780)

- Panicked task pid 551 CampoRemoteService, cpu 1, at uptime ≈ 0x6ae40da3−0x6ae4076d = 1590 s
  (26.5 min). The primary exception (`esr 0x96000045`, a write translation fault, `far
  0xfffffffffffffff0`) has **sp=0, fp=0, lr=0x3c00000020043c00, x22=x23=0x22060000**. The
  nested one is an SP1 data abort at far 0xfffffe00000f0020. This is a thread resumed from a
  **corrupted saved context**, not a fault in driver code.
- The backtrace frames all sit in the kernelcache text near 0xfffffe0020c3…–0xfffffe00215a…, and
  no AppleParavirtGPU frame is named. That is not symbolicated. guest RE can resolve
  0xfffffe00215ac92c / 0xfffffe0020c8e918 (slide 0x16d84000) if needed.
- Just before it there is a crash storm (airportd, mobileassetd, fontworker, calaccessd,
  managedappdistributiond: "Too many corpses"). Many unrelated processes failing at once
  points to memory corruption, not to one bad process.
- Host side: the GPU-timeout and host-log correlation **cannot be checked**, because the log is
  lost. The plausible host link is the same lifetime class as §1B. A host writeback (Store,
  `mapping_write`, compute `mapping_write full_tight_direct`) into guest pages the guest has
  already recycled would corrupt kernel memory, and Orchard's own comments call this the
  "boot-16 PTE-corruption rule". A TCG fault is the alternative. **Unproven either way.** On the
  next run, grep the last 120 s before the panic for `mapping_write`, `m2v_store_gva`,
  `revalidate_`, `condemn` and `stale` on mapping ids that have a trailing delete.

## 4. One more caveat

17 refused tiles out of 39 would leave 17 black tiles in an 8×5 canvas, not a fully black
desktop. Unless the other ~22 also failed or were never dispatched, the full black needs a
second cause, such as no canvas copy or a WallpaperAgent fallback. The lost log would have
answered this through the `ycbcr_2p_staged` count in 83e3b84. Treat "black" as possibly more
than this refusal.

## 5. Fix (porter), sized

1. **Split and enrich the refusal** (~25 lines, no risk).
   - `compute_exec/mod.rs:2288-2294`: replace the hard-coded `PlaneWindow{plane:1}` with
     `CodePlaneRefusal::PagesShort { pages, span_end }` (slug `ycbcr_2p_pages_short`), and log
     `pages= page_bytes= span_end= luma_off/bpr chroma_off/bpr alloc= map_gen= condemned=0|1
     mapped=`.
   - `ycbcr_planes.rs:257-276`: make `PlaneWindow` carry the plane record (`off base size w h
     bpr alloc span_end`) and print it.
2. **Re-resolve before refusing** (~20 lines, low risk). In that branch, if the pages are short,
   call `mapper::resolve_mapping_backing(state, host, mapping_id)` once and recheck. In
   `mapper/mod.rs:1152-1176`, for a mapping whose descriptor has `plane_count ≥ 2`, cover
   `alloc_size`, not the single-plane BGRA8 estimate. Use the return value of
   `ensure_resolved_for_scanout` at :2153 for logging.
3. If, after 2, refusals remain with `condemned=1` or a failed resolve, the tile surface really
   was released before the host ran the dispatch. That is the lifetime race to chase. Do not
   relax the bound, because reading recycled pages would put foreign bytes on screen. If
   instead `PlaneWindow` shows a record past `alloc`, that is case A: compare the record with
   what Apple's host IOSurface would accept (it keeps offset and base separately, §2) before
   changing the arithmetic.
4. Tester: one boot (~25 min). Copy the log off `/tmp` before stopping. Count
   `ycbcr_2p_staged` against `ycbcr_2p_pages_short` and `ycbcr_2p_plane_window`, take a
   screenshot of the wallpaper, and grep the pre-panic window as in §3.

Total: about 45–60 lines in `compute_exec/mod.rs`, `ycbcr_planes.rs` and `mapper/mod.rs`, plus
tests for the split slug and the biplanar coverage. Medium-low risk.
