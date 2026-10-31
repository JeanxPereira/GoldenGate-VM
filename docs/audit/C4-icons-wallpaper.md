# C4: Dock icons and wallpaper (run b3e58a4, 29/10 ~23:13–00:05)

Screen: `shots/dzn-b3e58a4-8.png`. Dock has Safari and Downloads; every other tile is the dashed
placeholder, and the desktop is black. Sources: host log `/tmp/reims-vgpu-fail.log` (74k lines,
`REIMS_VGPU_DRAW_TRACE=1`), guest `log show` over SSH (load ~714), `ps`. Orchard @b3e58a4.
Host `t=` is milliseconds since QEMU start.

## Who is who (tasks to processes)

| Task | What it draws | Process | Basis |
|---|---|---|---|
| 1 | 1920×1080 display mids 1/2/3, menu bar, Dock backdrop | WindowServer (pid 156) | geometry |
| 4 | 11.5k draws, 14–1024 px, multisize outputs 16/18/20/22/…/208/210/412/824 | iconservicesagent pid 439 (10 min CPU) | **inferred**: sizes plus its own log (below) |
| 16 | same pipes and sizes as task 4, 2k lines | 2nd icon renderer (iconservicesagent pid 280, or Dock) | **inferred** |
| 9 | compute only: 444f tiles to 512×512 BGRA tile to a 4096×2160 BGRA canvas | wallpaper still (WallpaperAgent/WallpaperAerialsExtension) | **inferred**: the canvas is what WindowServer samples full-screen |
| 21 | compute only, from t≈2.85M: 4096×2160 `x420` frames to 4096×2160 RGhA | aerial video frames | **inferred** |

## (A) Dock icons: iconservicesagent flattens every icon to a transparent image

Guest log (iconservicesagent 439), 12 times between 23:27:01 and 23:31:10 and again at 23:51:36:
```
F Flattened representation is seemingly a fully transparent image
E Central pixel is still transparent even with retry.
Df Failed to generate flatten representation for icon stack … asset type: NaturalStack / MultisizeImageCompositeStack
```
IconServices then hands the Dock its placeholder. The guest *does* ask for the icons, and
renders them. The result just comes back empty.

Host side: each icon is about 10–20 render passes over heap-placed RGBA16F/RG16F textures
(`rt_placed … heap=99 opts=0x20` (private), 318 in task 4). Shape passes have no sampler
(pipes 145/183/24). Then a blur ping-pong (pipes 116/127/119/122, which bind only tex0; the
`frag_neutral_texture_substituted` ×613 is that optional tex1, benign). The **final flatten pass**
(pipes 149/144, later 24/191/105/102/239/255) writes a *texture over a guest buffer*
(`rt_buffer_texture … fmt=0x5a|0xa|0x50|0x73 gva=…`), which the CPU then reads. Every one of
these stores is zero:

```
m2v_store_gva gva=0x119000 16x16  pipe=149 tex_ref=151 load=2 ok=1 rgb_nz=0 max_rgb=0  t=831688
m2v_store_gva gva=0x108000 106x106 pipe=149 tex_ref=3  load=2 ok=1 rgb_nz=0 max_rgb=0  t=863242
m2v_store_gva gva=0x4a0000 104x104 pipe=255 tex_ref=121 load=2 ok=1 rgb_nz=0          t=2842273
```
Of the icon-sized `m2v_store_gva` stores, every one (≈130, 14..826 px) has `rgb_nz=0`. Only
WindowServer's stores are non-zero (192×128, 360×180, 352×128, 1920×128). The store itself
works (`ok=1`, `Store never deferred`), so the zeros come from **upstream, from the placed chain**.
For example, the 16×16 icon: `p4:117g2` (pipe 183, `ld=none`, Clear) → `p4:190g2` → blur via
`p4:211g2/p4:210g2` → pipe 149 → gva 0x119000, all zero.

What the listed failure classes contribute (all in task 4):
- `draw_prepare_vertex_translate` ×3 / `draw_prepare_fragment_translate` ×4,
  `m2v_reason=m2v_translation_pending_at_sync_boundary` (pipes 181, 126, 93, 397; 14×14, 118×118,
  104×104, 57×72, 295×114) → `draws_skipped_after_engine_refusal`, `draw_vk_nothing_stored`. Each
  one drops a whole icon layer pass. For example, mid 28 (14×14) is never drawn, and the next
  16×16 icon samples its 14×14 input `bytes:14x14` (ref 186). Real, but too few to explain *every*
  icon being empty.
- `compute_view_format`, `mapper_ref_texture_sample`, `rt_mapper_ref_texture_format`,
  `buftex_load`, `linear_sample`: **none in tasks 4/16**. They belong to WindowServer
  (task 1) and the wallpaper (tasks 9/21).
- Compute writes into icon IOSurfaces (`compute_dst_mapper_ref_texture … mid=25/26/27 …
  GuestRefRefused{NoBackendImport}`, 128 in total, R16G16B16A16/R8G8B8A8) take the Host route.
  Only 13 of them (all on the wallpaper mid 138) log a `mapping_write`. Whether the other 115
  reach guest pages is **unverified**.

Root cause: **not pinned**. The chain never errors, but its last pass reads zeros. Ranked:
1. A placed resident reads empty on sample. The `placed_probe` earlier measured 558/2645 empty
   samples (NOTES 29/10 16h). `placed_generation … recreated` → `rt_placed_first_pass_clear`
   opens Clear(0) on every re-creation, and the guest re-creates the same refs (211/251/210/190
   at heap 99 offsets 0x0/0x4000/0x8000) for every icon.
2. Icon layer sources that are IOSurfaces written by compute (Host route, no writeback seen).
3. Skipped passes from translation still pending at the sync boundary (7 seen).

The deciding experiment (tester, one boot, about 20 min): `REIMS_VGPU_PLACED_PROBE=on`, then
`REIMS_VGPU_PLACED=0`, with a `placed_content`-style nz/alpha count on the source of pipe 149/144.

## (B) Wallpaper: black because YCbCr IOSurfaces (542/543) cannot be sampled

The guest side first, because it matters. WallpaperAgent 423 at 23:27:19–23:28:04 logs:
`makeWallpaper for 'com.apple.wallpaper.extension.aerials' ⏳: WallpaperExtensionError (3)`,
then `Failed to create system default wallpaper as fallback - using ultimate fallback error
wallpaper`, then a watchdog timeout. The ⏳ is a time-out under load 700 (**inferred**). Later
`WallpaperAerialsExtension` (pid 486, 10:50 CPU) comes up and logs `Loading fallback manifest`
and `Attempting to download full length default aerial`. FigVideoQueue says `0 frames enqueued`.
The default wallpaper is the Aerial (a video with a still poster).

Host: WindowServer samples one 4096×2160 BGRA IOSurface (`mapper_desc_path mapping=138 4096x2160
bpr=16384 fmt=0x42475241`, task-1 ref 251) at index 3 in 65 full-screen draws (pipes 261/71/11/
114/116/139, `smp=[b707:bytes:4096x2160]`). Task 9 builds that canvas:

```
mapper_desc_path mapping=233 512x512 bpr=512 fmt=0x34343466('444f') alloc=786432  t=1645562
compute_stage_tex view_fail reason=format_incompatible term=base_undeclared_here base=0x21e role=sampled ref=7 … 512x512 mapping=233
compute_linux stage_tex fail reason=compute_view_format pipe=6 i=0 ref=7 ot=11 bind=32 access=sampled
compute_linux storage_access pipe=11 bind=481 access=write_only seed=1 bytes=35389440           t=1645936
compute_dst_mapper_ref_texture bind=481 mid=138 dims=1024x2160 held=R32G32B32A32_UINT reason=GuestRefRefused{NoBackendImport}
mapping_write full_tight_direct mid=138 bytes=35389440 bpr=16384 rows=2160
```
The loop alternates two kernels. One converts a decoded HEIC tile (`444f` = 8-bit 4:4:4 biplanar,
Metal format **542/0x21E**, 512×512, plane 0 Y 256 KiB plus plane 1 CbCr 512 KiB = 48 pages) to
BGRA. That one is **refused**: `compute_view_format`. The other copies a 512×512 BGRA tile
(mid 232) into the canvas (mid 138). That one runs, and the CPU writeback lands. A 4096×2160
canvas is 8×5 tiles, and there are 39 `444f` mappings. So every tile is copied in empty, and the
canvas WindowServer shows is black. From t≈2.85M a second path appears (task 21): 4096×2160
`x420` (`fmt=0x78343230`, 10-bit 4:2:0 biplanar, Metal **543/0x21F**, bpr 13620, 1796 pages)
into 4096×2160 RGhA. That is the aerial video itself, and it hits the same refusal
(`base_fmt=0x21f … 4096x2160`, 5 dispatches).

Apple's host (from `C-objects-memory.md`) handles this in GPUTask. Object 0xB is created in
`createMapperRefTexture` @0x10004D788, which calls `newIOSurfaceTexture` @0x10004CF90, which calls
`newTextureWithDescriptor:iosurface:plane:`. `validateIOSurfaceDescriptor` @0x100046580 returns
early for any surface with planes, so 542/543 go straight to Metal, which samples them natively.
No conversion happens on the host. Orchard has no row for 542/543 in `protocol::pixel_format`,
which leads to `BaseUndeclared` (`runtime/draw/texture_view.rs`), then
`runtime/compute_exec/mod.rs:2275-2280`.

Dozen has no `samplerYcbcrConversion`, and the translated SPIR-V declares *one* texture. That
leaves two routes. One is a CPU two-plane gather into one host image (like `xr10_planes.rs`):
542 becomes RGBA8 (Y, Cb, Cr, 1); 543 becomes RGBA16 unorm (Y, Cb, Cr upsampled 2×2, 1).
The other is per-plane R8/RG8 images plus a shader rewrite in metal2vulkan, which costs more.
It all depends on what a 542/543 sample returns in Metal. Raw Y/Cb/Cr in .rgb, with the kernel
applying the matrix, is **inferred**.

## Change list for the porter (ranked)

1. **542 two-plane sampled (compute, then fragment).** This is what fixes the wallpaper still.
   Add rows for 542 (and 543) in `protocol::pixel_format`. Keep the plane geometry from the
   IOSurface plane records (the mapper already parses the planes). Add a CPU gather: plane 0 R8 +
   plane 1 RG8 → RGBA8 (Y, Cb, Cr, 255), staged as a sampled image in `compute_exec::stage_tex`.
   About 150–250 lines, medium risk (the channel semantics are inferred; verify item 5 first, or
   A/B on the screen).
2. **543 `x420` 10-bit 4:2:0** on the same rail. Chroma ×2 upsample, 16-bit unorm with the data
   in the top 10 bits. bpr 13620 does not fit a plain 16-bit layout (8192), so it may be
   compressed or padded: read it from the plane records, and decline if they disagree. About
   80–120 lines on top of item 1. This fixes the live aerial.
3. **Icon placed-chain diagnosis, before any fix:** the tester runs `REIMS_VGPU_PLACED_PROBE=on`
   with an nz/alpha count on the sources of the flatten passes (pipes 144/149), plus a
   `REIMS_VGPU_PLACED=0` A/B. About 30 lines (debug-gated count), no risk. The fix depends on what
   that finds (the generation reset on re-creation, or a lost resident).
4. **Do not drop draws on `m2v_translation_pending_at_sync_boundary`**: wait for the pending
   translation, or compile it synchronously, for vertex/fragment in `draw_prepare` (7 icon passes
   lost). About 40–80 lines, low–medium risk (stall cost).
5. **RE check (guest RE):** the names and sample semantics of 542/543 (the Metal.i64
   `MTLPixelFormat` info table), and what task 9's pipe-6/10 kernel does with the sampled vec4
   (SPIR-V dump of pipe 6). No code.
6. Low priority. XR10 `b3a8` 256×256 mapper-ref (`rt_mapper_ref_texture_format fmt=0x226` ×2,
   `mapper_ref_texture_sample` ×1, task 14 / WindowServer pipe 48): a single-plane view of a 2P
   surface. About 60 lines.

## Open questions
- Does WallpaperAgent's ⏳ time-out (WallpaperExtensionError 3) clear once the still decodes
  faster? It may also need a provision step (`gg provision`) that sets a non-Aerial static
  wallpaper as a control.
- Do the 115 compute writes to icon IOSurfaces on the Host route reach guest pages?
- Which process is task 16 (iconservicesagent 280 or Dock)?
