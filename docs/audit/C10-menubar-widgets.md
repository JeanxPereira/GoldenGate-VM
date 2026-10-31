# C10 — menu bar loses its left half; desktop widgets are dark tiles

Orchard `gg-macos27` @ `6af5dfe`. Evidence: live host log `/tmp/reims-vgpu-fail.log` (6af5dfe,
~52 min, 71 904 lines), previous run `~/gg/run/gg27/logs/reims-vgpu-fail.a61708e-final.log`,
`shots/dzn-6af5dfe-{6,9,13}.png`.

## Verdict

Both are **format gaps that refuse a draw. Each refusal then skips the rest of its pass.** With
609111d no translation is pending any more (0 `draw_prepare_*_translate` refusals in this run),
so what is left is two pixel formats that Apple's host binds natively:

| Bug | Format | Where it dies | Lost |
|---|---|---|---|
| Menu bar | `MTLPixelFormatRGBA16Unorm` (110 = 0x6e), sampled | CPU row converter has no arm: `buftex convert_unsupported` (buffer texture) and `RowConvertUnsupported` (type-2 linear texture) | The menu-bar layer pass (cleared, nothing drawn) and the rest of the display composite pass |
| Widgets | `MTLPixelFormatRGB10A8_2P_XR10` (550 = 0x226) on an **IOSurface mapping** (object type 11) | `rt_mapper_ref_texture_format` (render target) and `capture_bpp_unknown` (sample) | 85 producer draws into the surface, then every widget-tile pass that samples it |

The "Photos will appear here when they are finished processing" text is **legit** guest content: a
fresh account with an empty library. It rendered, so that tile's content pass survived. The dark,
opaque glass on all three tiles, and the empty content of the other two, are rendering failures.

## Bug 1 — menu bar

### Host log

```
34571 buftex convert_unsupported ref=231 buf=230 fmt=0x6e 384x384 t=1035193
34572 linux_m2v_draw reason=draw_prepare_texture_resolve_missing stage=fragment index=3 texture_ref=231
      detail=type=8 ... buf=230 off=0 bpr=3072 384x384 fmt=0x6e reason=buftex_load pipe=11 task=1 geom=1600x128
      colors=[s0:r116 ... 1600x128 fmt=0x73, s1:r75 memoryless] scissors=[x:0,y:0,w:165,h:128]
34573 linux_clear_store draws_skipped reason=draws_skipped_after_engine_refusal pipe=11 ... 1600x128 load=0x2 store=0x1
44891 buftex convert_unsupported ref=231 buf=230 fmt=0x6e 384x384 t=1462890
44892 ... texture_ref=231 ... reason=buftex_load pipe=243 task=1 geom=1920x128 ... scissors=[w:165,h:128]
44893 ... draws_skipped ... pipe=243 mid=0 gva=0x45a4000 1920x128 load=0x2 store=0x1
44898 ... texture_ref=232 detail=type=2 fmt=0x6e mips=5 L0=128x128 bpr=1024 reason=linear_sample
      pipe=241 task=1 geom=1920x1080 ftex=[i3:r232,i4:r252]      (r252 = the 1920x128 menu-bar target)
44899 ... draws_skipped ... pipe=241 mid=3 1920x1080 load=0x1      draw_encode_fail ... di=1/14
```

- `buftex convert_unsupported fmt=0x6e`: 6×. Refusals by pipe: 243 (1920×128 menu bar) 4×,
  241 (display composite, mids 2/3) 4×, 11 (the same chain at 1600×128 before the resolution
  change) 4×. The previous run has the same thing at `ref=215 buf=214` / pipe 223
  (C8's "missing 384×384"), so this is **not** a race: the format is simply unconverted.
- Two RGBA16Unorm textures feed the Liquid Glass menu bar (**inferred** role: a material /
  noise lookup and a 5-mip 128×128 lookup):
  - ref 231: a 384×384 **buffer-backed texture** (texture-view opcode 9 over buffer 230), sampled
    by the menu-bar layer draw (pipe 243, scissor x 0..165: the Apple menu + app-name glass).
  - ref 232: a type-2 **linear texture**, 128×128, 5 mips, sampled with r252 (the menu-bar layer)
    by the display composite (pipe 241).
- Why the whole left half disappears: the refusal skips **every remaining draw of the pass**
  (`draws_skipped_after_engine_refusal`). The menu-bar pass has `load=0x2` (Clear), so its target
  is stored cleared to (0,0,0,0) and the menus vanish. Pipe 241 loses draws 1..13 of the display
  composite (`di=1/14`). The clock survives because it is redrawn each minute in its own
  dirty-rect pass, which never samples these refs (**inferred**). Before the glass material is
  created (pre-login, `-6.png`), the menu bar draws without these refs and is fine.

### Orchard path

| Step | `file:line` (reims-vgpu crates) |
|---|---|
| Buffer-texture sample entry | `reims-vgpu/src/runtime/draw/vulkan.rs:1556-1576` (`resolve_sampled_source` → `load_buffer_texture_rgba`) |
| The decline | `reims-vgpu/src/runtime/draw/mod.rs:1680-1685` (`RowToRgba8::for_format(fmt)` is `None` → `buftex convert_unsupported`) |
| Linear-texture decline (ref 232) | `reims-vgpu/src/runtime/draw/texture_view.rs:1341-1344` (`RowConvertUnsupported`). The native rail `linear_native_upload_format` (`texture_view.rs:991-1039`) answers `None` because `sampled_class(0x6e)` is `None` (`reims-vgpu-protocol/src/pixel_format.rs:1911-1926`) |
| Row converter | `reims-vgpu-protocol/src/pixel_format.rs:3544` (`enum RowToRgba8`), `:3586` (`for_format`), `:3607` (`source_bytes_per_pixel`), `:3621` (`convert`); texel sibling `texel_to_rgba8` `:3306` (a test holds the two to the same format set); `narrows_to_unorm8` `:3480` |
| Already there | `MTL_FORMAT_RGBA16_UNORM = 0x6e` (`pixel_format.rs:142`), `TexelLayout::Rgba16Unorm` (`:650`), Vulkan `R16G16B16A16_UNORM` (`reims-vgpu-vulkan/src/pixel.rs:304`) |

### Apple host

The buffer texture is created natively. `sub_10004B238` / `sub_10004B9E8` (GPUTask) call
`validateTextureDescriptorForBuffer`, then `-[MTLBuffer newTextureWithDescriptor:offset:bytesPerRow:]`
(or `newLinearTextureWithDescriptor:…`) with the guest's own pixel format. Nothing converts it,
and no format gets refused unless Metal refuses it. Linear textures are likewise native
`MTLTexture`s.

### Fix spec

1. **CPU arm (required, covers both refs).** Add `RowToRgba8::Rgba16Unorm`:
   - `for_format`: `MTL_FORMAT_RGBA16_UNORM => Self::Rgba16Unorm`.
   - `source_bytes_per_pixel`: return `RGBA16_BPP` (8).
   - `convert`: for each channel, `u16` LE → `((v as u32 * 255 + 32767) / 65535) as u8`.
   - Add the same arm to `texel_to_rgba8` and to `narrows_to_unorm8` (it narrows 16→8 bits),
     so the rail-parity test and the `buftex_narrowed` note stay truthful.
   - Size ~30 lines plus one unit test. Risk **low**: it is purely additive and touches no
     existing arm. Lossy (8 bits) but visually fine for a material lookup.
2. **Native linear rail (optional, better quality).** Add `SampledClass::Rgba16Unorm` to
   `sampled_class`, and in `linear_native_upload_format` return `TexelLayout::Rgba16Unorm`. Gate
   it on the device's `SAMPLED_IMAGE_FILTER_LINEAR` for `R16G16B16A16_UNORM`, because Vulkan does
   not mandate it. Dozen/D3D12 has it. ~15 lines. Risk low–medium: check every exhaustive match
   on `SampledClass` (store tables, cross-checks). The buffer-texture rail stays CPU-only, so
   item 1 is still needed.
3. **(Robustness, separate.)** A sampled-texture miss currently kills the rest of the pass.
   Apple never skips draws. Consider binding the neutral texture (the
   `frag_neutral_texture_substituted` mechanism, 613× this run) for an unresolvable sampled ref
   instead of refusing, logging it once per ref. That would have left the menu text visible with
   a wrong-looking glass. ~20 lines. Risk **medium**: it masks real misses, so keep the fail line.

Expected test: `buftex convert_unsupported` = 0, no `draws_skipped` on the 1920×128 target or
on pipe 241, and the Apple menu and app menus stay after login.

## Bug 2 — desktop widgets

### Host log

```
57886 mapping_gpa_span mid=21 gen=9 pages=32 src=mapper          t=2269863  (~37.8 min)
57959 pass_target task=15 mid=21 384x256
57961 rt_resolve reason=rt_mapper_ref_texture_format base=8 mid=21 fmt=0x226 task=15 ref=8
      metal_draw mrt_request fail task=15 pipe=34 slots=[8, 30, 31] di=0/85
      exec_indirect2 ch=1 ... draws_ok=0 draws_fail=1 rt_resolves=1
58017 scanout_paint_mapping reason=capture_bpp_unknown format=550 mid=21 want=384x256
58018 sample_src=miss ref=263 mid=21 384x256 resident_ready=0 (no guest/cache/resident bytes)
58020 linux_m2v_draw reason=draw_prepare_texture_resolve_missing ... texture_ref=263
      detail=type=11 mid=21 384x256 fmt=0x226 mapped=1 pages=32 reason=mapper_ref_texture_sample pipe=48 task=1
58021 draws_skipped ... pipe=48 mid=3 1920x1080 load=0x1       (draw_encode_fail di=7/10)
58073 draws_skipped ... pipe=48 mid=0 gva=0x1e40000 180x180 load=0x1
58078 draws_skipped ... pipe=48 mid=2 1920x1080
58467 draws_skipped ... pipe=48 mid=0 gva=0x1e80000 360x180 load=0x1
```

- Task 15 (the widget renderer; **inferred**) renders an 85-draw MRT pass whose colour 0 is
  IOSurface mapping 21: 384×256, format 550 (`RGB10A8_2P_XR10`: an XR10 colour plane plus an A8
  alpha plane). The render-target resolver refuses it, so **all 85 draws are lost** and the
  surface stays zero. Its sibling, mid 23 (384×256 BGRA8), renders fine.
- WindowServer (task 1, pipe 48) then samples that surface as ref 263. Scanout capture has no
  bytes-per-pixel for 550, so the bind misses and pipe 48 skips the rest of each pass that samples
  it: the 180×180 (small) and 360×180 (medium) **widget tile targets**, which match the 2+1 tiles
  in `-13.png` with their 15 px margin, and two display frames. The tiles are static, so one lost
  pass is a permanently dark tile. `load=0x1` keeps whatever was there.
- The previous run (a61708e) shows the same failure on two surfaces: mid 21 384×256 and mid 28
  256×256 (`rt_mapper_ref_texture_format` 2×, `capture_bpp_unknown` 8×, pipe 48 skips on two
  180×180 targets). The failure is deterministic.
- Orchard already executes format 550/551 as RGBA16Float when it arrives as an object-type-12
  dual-plane texture over guest memory (`runtime/xr10_planes.rs`, `draw/vulkan.rs:1232`
  `sample_xr10_two_plane`). The **IOSurface-mapping (type 11) spelling of the same format has no
  rail**, either as a target or as a sample.

### Orchard path

| Step | `file:line` (reims-vgpu crate) |
|---|---|
| RT refusal | `runtime/draw/render_target.rs:1446-1454`: `render_target_bpp(550)` is `None` → `MapperRefTextureFormat` (slug at `:625`) |
| Sample refusal | `runtime/scanout/mod.rs:986` (`CaptureDecline::BppUnknown`, slug `:847`), reached from the type-11 rung of `resolve_sampled_source` (`runtime/draw/vulkan.rs:1652+`) |
| Plane windows of a mapping | `runtime/mapping_write/mod.rs:239-288` (`sample_window` / `ref_texture_sample_window(m, plane_index, …)` from the mapping's IOSurface device descriptor) |
| Reusable XR10 pieces | `runtime/xr10_planes.rs`: `Xr10Planes` (color/alpha gva+bpr), `load_rgba16f` `:281`, `write_frame` `:350`, `store_resident` `:447`, `note_render_target` `:187`; protocol `is_xr10_two_plane` `pixel_format.rs:2542`, `xr10a8_to_rgba16f` `:2661`, `rgba16f_to_xr10a8_planes` `:2808` |

### Apple host

`newIOSurfaceTexture` @0x10004CF90 (GPUTask) builds the descriptor from the guest
(`newTextureDescriptor`), runs `validateTextureDescriptorForDevice` and
`validateIOSurfaceDescriptor`, then calls `-[MTLDevice newTextureWithDescriptor:iosurface:plane:]`
with the guest's pixel format and plane. Format 550 is native on Apple GPUs, so the same texture is
rendered into and sampled with no conversion. There is no format allow-list on the host side.

### Fix spec

1. **Sample (smaller, do first).** In the mapper-ref-texture rung of `resolve_sampled_source`, when
   `is_xr10_two_plane(m.format)`:
   - Get plane 0 (XR10, 4 B/texel) and plane 1 (A8) windows from the mapping's device
     descriptor through `ref_texture_sample_window(m, 0|1, w, h, …)`. **Do not assume**
     `alpha_bpr == color_bpr` here. 32 pages × 16 KiB = 512 KiB < 2 × 384 × 256 × 4, so this
     IOSurface's alpha plane is probably 384 B/row.
   - Build an `Xr10Planes`, gather with `xr10_planes::load_rgba16f`, and return
     `SampledSourceRequest::Bytes(.., SampledByteFormat::from_source(TexelLayout::Rgba16Float, 550))`.
   - Prefer a host resident first if one exists (see 2).
   - Also give `scanout` a 550/551 arm instead of `BppUnknown`.
   - ~50 lines. Risk **low–medium**: it is new and only reached by format 550.
2. **Render target (required for content).** In `render_target.rs:1452`, before refusing, admit
   550/551 mapper-ref-texture targets the way the type-12 rail does:
   - Resolve them as format `RGBA16Float` at plane 0's address with plane 0's pitch (the
     "pitch < width×8" marker that the type-12 rail uses to fail closed). `ResolvedRenderTarget`
     here carries `mapping_id`/`target_gva=0`, so either convert to the GVA form (mapping
     page-backed, with `note_render_target` keyed on the plane-0 GVA), or add a mapping-keyed twin
     of `xr10_render_targets`.
   - On Store, split the frame into both planes with `rgba16f_to_xr10a8_planes` through the
     mapping writer, never deferred (as `xr10_planes` already documents).
   - Size ~100–150 lines. Risk **medium–high**: it touches the RT resolve, the colour LOAD seed
     and the Store licence on the mapping path. The deferred-store and stamp-debt (C7) rails must
     refuse it.
   - Interim option, if 2 is too big: resolve it as a host-only `RGBA16Float` resident with no
     Store, and let item 1 bind the resident. WindowServer is the only consumer seen. That is
     ~40 lines, but the guest-visible bytes stay zero (a CPU readback would see black).
3. Item 3 of bug 1 (neutral substitute instead of skipping the pass) would have kept the widget
   tile glass and text from being skipped, though the sampled content would still be blank.

Expected test: `rt_mapper_ref_texture_format` = 0, `capture_bpp_unknown format=550` = 0, no
`draws_skipped` on the 180×180 / 360×180 targets, and widget tiles with translucent glass
(plus real content in the two non-Photos tiles).

## Rows

| Op/type | Name | Payload | Apple host behaviour | Orchard handler `file:line` | Status | Seen in logs | Priority |
|---|---|---|---|---|---|---|---|
| Texture-view opcode 9, fmt 110 | Buffer-backed RGBA16Unorm texture, sampled | 384×384, bpr 3072, buf 230 | `newTextureWithDescriptor:offset:bytesPerRow:` (`sub_10004B9E8`), native | `runtime/draw/mod.rs:1680` | **missing** (no CPU arm) | 6 `buftex convert_unsupported` → 12 pass skips | **P0** |
| Object type 2, fmt 110 | Linear RGBA16Unorm texture, 5 mips | 128×128, bpr 1024 | native `MTLTexture` | `runtime/draw/texture_view.rs:1342`, `:1022` | **missing** | 4 pass skips (pipe 241) | **P0** |
| Object type 11, fmt 550 | IOSurface XR10+A8 render target | 384×384 / 256×256, MRT slot 0 | `newTextureWithDescriptor:iosurface:plane:` @0x10004CF90, native | `runtime/draw/render_target.rs:1452` | **missing** | 1 per run (85 draws lost) | **P0** |
| Object type 11, fmt 550 | IOSurface XR10+A8 sampled | 384×256 | same texture, sampled natively | `runtime/scanout/mod.rs:986`, `draw/vulkan.rs` type-11 rung | **missing** | 8 `capture_bpp_unknown`, 4 pass skips | **P0** |
| Any sampled miss | Pass continuation after one refused draw | — | n/a (Apple never refuses at bind) | `draws_skipped_after_engine_refusal` (draw/vulkan.rs) | **divergent**: one bad bind costs the pass | 16 | P1 |

## Fix list (ranked)

1. `RowToRgba8::Rgba16Unorm` + `texel_to_rgba8` + `narrows_to_unorm8` arms. ~30 lines, low risk.
   This brings back the menu bar.
2. Type-11 format-550 **sample** rail (gather both planes → RGBA16F) + scanout arm. ~50 lines,
   low–medium risk.
3. Type-11 format-550 **render target** rail (RGBA16F resident, split Store into both planes).
   ~100–150 lines, medium–high risk. Widgets need 2+3.
4. Optional: native `SampledClass::Rgba16Unorm`, gated on linear filter. ~15 lines.
5. Optional: neutral-texture substitute instead of skipping the remaining draws of a pass. ~20 lines,
   medium risk.

## Open questions

- Exact plane layout of the format-550 IOSurfaces (alpha-plane pitch, plane-1 offset): read from
  mid 21's device descriptor. The page count suggests 384 B/row alpha, unlike the type-12 note
  (alpha pitch = colour pitch).
- Which process is task 15 (chronod / WidgetKit / NotificationCenter), and is mid 21 widget
  content or a glass backdrop? The fix is the same either way.
- What lives in ref 231/232 (RGBA16Unorm). Two candidates: a glass refraction/normal lookup or a
  dither table. If precision matters visually, item 4 matters too.
- Bug 1 never got a translation-pending refusal in this run, so the translation wait (C8 item 2) is
  confirmed not to be the cause.
