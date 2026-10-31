# C14: what the glass passes are fed (Orchard a360c8a, headless)

Read-only diagnosis. Log `~/gg/run/gg27/logs/reims-vgpu-fail.a360c8a-45m.log` (64 296 lines, t = 0 … 2 707.9 s; the
last line was written at 17:49:30, so t = 0 ≈ 17:04:22). Comparison logs: `reims-vgpu-fail.28f9823-final.log` and
`reims-vgpu-fail.a360c8a-window.log`. Source: Orchard `gg-macos27` @ `ec70db6`,
`reims-vgpu/crates/reims-vgpu/src/`. Shader names come from the 363-AIR corpus `~/gg/run/gg27/spirv-dump-02c9b85`
(`llvm-dis`), matched by AIR size. A match is called **unique** only where that size occurs once in the corpus.

Map from shot to log time: shot 6 (desktop, Dock) 17:35:59 = **t ≈ 1 897 s**. Shot 7 (alert, widgets) 17:38:25 =
t ≈ 2 043 s. Shot 10 = t ≈ 2 708 s.

## 0. Two corrections to the brief

1. **`load=2` is Clear, not "loaded by a later pass".** `reims-vgpu-protocol/src/pass_action.rs:32-36`: 0 = DontCare,
   1 = Load, 2 = Clear. The `m2v_store_gva … load=2` line *is* the producer's own Store. It does not record a
   consumer.
2. **Ref 101 is not the Dock or widget glass.** It is stored at t = 995.6 s (≈ 17:21), about 15 minutes before the
   desktop exists. The screen at that time is a boot-time UI: `present_content px0=[1,1,1]` from t = 1 076.9 s, and
   the wallpaper's sky only from t = 1 680.4 s (line 46808).

Also useful for reading the log: `m2v_store_gva` is not sampled. Every copying GVA Store logs one: `gva_store_sync` =
168 = the number of lines (`runtime/draw/vulkan.rs:310-314`, `:765`). The other kind is the resident-authoritative
Store. It arms a debt and logs **nothing per store**: `gva_resident_authoritative` = 37, `vulkan.rs:254-307`.
Together `gva_flush` = 205 = 168 + 37.

## Q1. Ref 101 (832×64 RGBA16F, gva 0x14e4000), traced through every line

| line | t (ms) | what happens |
|---|---|---|
| 21608 | 995 609 | `memo_wrong_type task=1 ref=101 want=[8]`: ref 101 is resolved as the colour attachment of a new pass (the same line precedes every 832×64 / 192×128 target pass) |
| 21609 | 995 609 | `rt_transient ref=102 832x64 fmt=0x73`: memoryless s1 of this pass |
| 21610 | 995 609 | `sampled_ref_backing ref=104 view=256x1 route=bytes`: the pass's only sampled texture is a 256×1 ramp |
| 21611 | 995 609 | `color_input_mrt mask=0x03 pipe=2 colors=2 832x64`: **one** draw, UberShader (`fw=248005`), MRT with framebuffer fetch on both slots |
| 21612-14 | 995 610-611 | `color_pass_optimal … fetch_mask=0x03`; `fetch_snapshot copy 0/1 … op=clear` (the fetch reads the cleared values) |
| 21615-16 | 995 612 | `m2v_store_gva gva=0x14e4000 832x64 pipe=2 tex_ref=101 load=2 ok=1 rgb_nz=0 max_rgb=0` |
| 21617-18 | 995 613 | `lin_rung_guest_blank` + `lin_rung_blank_with_host_entry … host_blank=1 backing=Same` |
| 21619-20 | 995 613 | consumer: the next 1920×1080 pipe-2 pass samples ref 101 `route=bytes` |
| 22201 | 999 583 | ref 101 is recycled as a memoryless 1920×1080 (`rt_transient`); the 832×64 is never stored again |

Conclusions, each with its evidence:

- **The producer ran on the host and its output reached the GVA.** `ok=1`. The host cache entry over the same pages
  is also all zero (`host_blank=1`, `backing=Same`), so nothing was lost between resident, cache and guest pages.
  There is no decline, no `draws_skipped`, no `frag_color_unwritten` for pipe 2 and no translation wait in the window.
  The target is a guest-backed texture (not memoryless, not placed).
- **The output is zero in every channel, alpha included.** `lin_rung_guest_blank` fires only when *every byte* is 0
  (`vulkan.rs:6176-6180`, `rgba.iter().any(|&b| b != 0)`). So this is not a black shadow (rgb 0 with alpha > 0). The
  single draw put nothing into colour 0.
- **It is not C13 cause 1 (the constant-buffer helper cursor).** The pattern is byte-identical before and after that
  fix:
  - `28f9823` (UberShader 220 444 words, 2408 null copies): line 17589, `tex_ref=101 load=2 rgb_nz=0`, with
    ref 102 memoryless and `op=clear` ×2.
  - `a360c8a-window`: refs 99 and 141 (lines 18912, 19933).
  - This run: UberShader 248 005 words.
  - The sibling is the same in every run: an 832×64 `load=1` Store of 25 600 px, `max_rgb=255`, `mean=122`, on the
    preceding pass (ref 83, line 21564).
- **Open: why the one draw writes nothing.** Three possibilities: zero coverage (degenerate vertices or scissor),
  an alpha=0 result of the 256×1 ramp (ref 104; no blank line was ever latched for a 256×1 span, so its bytes are
  non-zero), or a layer that is legitimately empty at that moment. The always-on log cannot separate these: there
  is no per-draw trace in a run without `REIMS_VGPU_DRAW_TRACE`. Since this is a boot-UI layer, it is **not** worth
  the porter's time before Q2.

## Q2. What the glass passes on the shots actually sample

### Dock (shot 6)

The Dock glass chain is the six-draw sequence that `sync_exec_lock_hold_trail` keeps at lines 42768, 42930, 43349,
43651, 44015, 44524 and 46790 (t = 1 434 … 1 680 s):

| pipe | frag | target | samples (b = guest bytes, t = resident; f97 = `R16G16B16A16_SFLOAT`) | shader |
|---|---|---|---|---|
| 39 | fw 238 | 1920×1080 | — | generic layer |
| 220 | fw 1842 | 1600×128 | — | Dock platter shape |
| 226 | fw 1218 | 1600×128 | — | Dock platter shape |
| **197** | fw 6596, AIR 17104 | 1600×128 | **b707 = 1920×128 b f97 (source), b708 = 1600×128 b f97 (sdf)** | `glass_background_cr_lph` (**unique** AIR size) |
| 2 | fw 248005 | 1600×128 | b707 = 1600×128 b f97 | UberShader |
| 94 | fw 796 | 1920×1080 | b707 = 1600×128 **t** f97 | composite of the Dock layer |

- **There is no blur in the Dock chain.** No compute dispatch and no downsample pass. The only "glass" stage is
  `glass_background_cr_lph`, which samples the 1920×128 backdrop through explicit LOD.
- **The 1920×128 backdrop is ref 145, gva 0x19ec000, route = bytes.** `sampled_ref_backing … ref=145
  view=1920x128 route=bytes` (line 28184). Its next backing change only comes at t = 1 928 s (line 51150,
  `was=mid0:1920x128`).
- **Its last writes are at t = 1 228.6–1 228.7 s, onto a black screen.**
  - The copying Store at line 35864: `rgb_nz=131492 max_rgb=97 mean_rgb=21`. That is the same numbers as C11's
    "menu-bar layer" (ref 76), so the content is deterministic.
  - Then one Clear 1920×128 pass (lines 35968-69). It took the resident-authoritative Store: there is no
    `m2v_store_gva` line for it, and the t = 1 229 window has `gva_resident_authoritative=1`. It was paid to the guest
    at t = 1 316.2 s (line 39337, `gva_flush_gpu_declined … gva=0x19ec000 geom=1920x128` → copied).
  - The **last 1920×128 pass in the whole run** is line 36115 (t = 1 230.8 s).
  - At that time the presented frame is black: `px0=[1,1,1]`, t = 1 076.9 … 1 680.4.
- **The Dock glass layer is never re-rendered after the wallpaper appears.** The trail's glass sequence ends at
  t = 1 680.1 (line 46790). The first frame with the wallpaper is t = 1 680.4 (line 46808). After that, the Dock
  layer is only composited (`pipe=147 … smp=[b707:b:f97:1600x128, …]`, line 50188, t = 1 900.9).

**Verdict for the Dock (inferred, high confidence on the facts, medium on the cause).** The glass shader works on a
1920×128 backdrop captured while the screen was still black, and nothing re-captures it. Glass over a black
backdrop is exactly "dark translucent platter, no blur or refraction". No host-side refusal is involved. Two
explanations remain open:

- (a) The guest's WindowServer never re-issued the backdrop capture. That would be a guest-visible effect of
  something else, such as a missed completion or display event telling it the backdrop changed.
- (b) It re-issued the capture into a target the host routed elsewhere.

The log shows no other 1920×128 or 1600×128 pass after t = 1 680.1, which favours (a).

### Widgets and alert (shot 7)

- **The alert composite samples a 64×64 backdrop snapshot that has content.** The alert composite is pipe 129
  (AIR 7344 → `TbdsA2Xhfcu_Isup_Isrc`; size match). It samples the alert layer through the resident and a
  **64×64 RGBA16F backdrop snapshot through guest bytes** (trail line 36379, t = 1 233.3:
  `smp=2[b707:t:f97:800x632, b708:b:f97:64x64]`).
  - The 64×64 is written by `inplace_copy_lph` (pipe 93, AIR 3544, unique) as a fragment storage image:
    `frag_storage_stage pipe=93 ref=46 bind=483 … dst=Host` (line 21582). It reaches the guest through the readback
    rail (`compute_dst host … GuestRefRefused`; `vulkan.rs` `direct_destination` → `Host` = readback lands identical
    bytes).
  - **No `lin_rung_guest_blank` was ever latched for a 64×64 span**, so these snapshots are non-zero when sampled.
  - The alert's flat (133,133,133) therefore is **not** a zero input. It is either a 64×64 snapshot of a uniform
    region (the backdrop is 64×64, so it has almost no detail by construction) or the UberShader's material math.
- **The widget-sized 192×128 layers are not zero either.** Refs 209, 213 and 222 are all stored with identical
  content `rgb_nz=6378 max_rgb=255 mean_rgb=63` (lines 36194, 36213, 36320, t ≈ 1 231-1 233).
- **Widget surfaces on the final desktop are flushed late.** They are 180×180 / 360×180 RGBA16F, stored
  resident-authoritative and flushed late (`gva_flush_gpu_declined … 0x1b04000 180x180` t = 1 990.7, `0x1ac4000`
  t = 2 048.8, `0x1b44000 360x180` t = 2 316.6). Every one of these goes through the CPU copy because Dozen has no
  guest-RAM import.

### How samples are served (all GVA textures)

| counter (sum of all `store_routes` windows) | value |
|---|---|
| `lin_rung_guest_memo` (served from guest bytes) | 7 252 |
| `lin_rung_guest_blank` (…and every byte was 0) | **2 850 (39 %)** |
| `gvaw_no_entry` (resident could not vouch: no witness entry) | 7 117 |
| `gvarung_resident` / `gvarung_resident_copied` | 247 / 33 |

- **The blanks come in bursts on new glass layers and keep coming on the desktop.** Bursts: t = 1 229 (289 of 340),
  1 680-1 683, 1 930 (390 of 467). Steady state is **2 blank of 6 every ~59 s** (t = 2 048 … 2 697, the
  clock-minute recomposite).
- **Distinct blank spans are few** (first-sight latch). The ones that matter:
  - **ref 282**: a 1920×128 RGBA16F at gva 0x2554000, sampled by pipe 147 at t = 1 989.569 (lines 52435-52439).
    **No host path ever writes it**: no Store, no compute destination, no blit. There are only 3 blit records in
    the whole run.
  - ref 143 (1600×128): blank at t = 1 228.582, first written at 1 230.831.
  - ref 145 (1920×128): blank at t = 1 076.8, first written at 1 228.6.

  In all three cases a consumer reads a fresh texture **before** anything writes it, in guest submission order. For
  ref 143, the producer's pipelines 192/195/144 are only *queued* at t = 1 230.638, two seconds after the read.

## Q3. Blur: compute or render? Declines? The 613 unbound descriptors

- **The CoreAnimation blur is compute, and it is not in the Dock path.** Task-1 pipes 87/90
  (`compute_pipeline_texture_write_rounding`, lines 15682/15684) run 240×135 RGBA32Float. They are fed by pipe 82,
  which downsamples a 1920×1152 copy of the wallpaper (line 47202 → Store `rgb_nz=32400 mean=142`, line 47205). The
  result goes to gva 0x4f94000 through readback (line 47215). No GPU draw ever samples a 240×135, so it is
  CPU-consumed (desktop/material tint, **inferred**). Other computes are small mapping-target kernels (34×34, 66×66,
  the shadow blur, `compute_stage_resident_*`).
- **No compute work is lost.**
  - `compute_vk_translation_wait` = 2, both `outcome=ready` (line 30394).
  - There is no `compute_vk_translate_pending` and no compute decline slug.
  - `compute_dst_no_writeback` / `compute_wb_none` = 9 (storage images with no guest destination).
- **The 613 `frag_declared_descriptor_unbound` (+613 `frag_neutral_texture_substituted`) are not glass.**
  - All are `tex1` with `provided_tex={0}`.
  - By pipe: 169 (253), 171/173/177 (70 each), 270, 182, 223, 98, 55, 106 (5) and others.
  - The sizes are all icon-like (148², 91², 932², 478², 250², 40² …). **None** is at 832×64, 1600×128, 1920×128,
    800×632, 192×128 or 1920×1080.
  - The last one is at t = 1 366.3 s, before the desktop.
  - This is the RenderBox icon pipeline's optional second texture, as C13 already found. Impact on glass ≈ 0.
- **No pass in the glass chain is declined or waiting on translation.** On the 832×64 / 1600×128 targets, pipes 91
  (AIR 5480 → `Tc3sA2S1Xhfcu_Idst`, unique) and 106 (AIR 6020 → `TsdrA2Xhfcu_IsrcM1`, unique) run with
  `color_input_mrt mask=0x02` (fetch of the memoryless s1; lines 21716/21724, 36156/36158). They are per-pixel
  fetch shaders, not a blur.

## Ranked fix list (for the porter)

1. **Find out why the Dock backdrop is never re-captured.** This is a measurement, not code. Size: 0 lines (env) to
   about 20 lines. Risk: none.
   - One boot with `REIMS_VGPU_DRAW_TRACE=1`, `REIMS_VGPU_PLACED_PROBE=1`, `REIMS_VGPU_PLACED_PROBE_TASK=1` and
     `REIMS_VGPU_PLACED_PROBE_SIZE=2048`, run up to t ≈ 1 900 s.
   - Question: does task 1 submit any pass whose colour 0 is the 1920×128 backdrop (or a new 1920×128 ref) after the
     wallpaper appears?
   - If it does not, the gap is guest-side. Hand it to guest RE: what makes WindowServer/QuartzCore invalidate a
     backdrop capture. Likely candidates are a display or completion event the host never delivers. Note
     `display_vbl delivered=0 … arm=not_enabled` on every line, for example line 129 of the t = 1 230 window. That is
     **inferred** and needs checking.
   - If it does, the gap is a routing loss on the host, and item 2 applies.
2. **Make samples of a GVA texture with an unpaid resident debt read the resident** (if item 1 shows host-side
   passes). Size: about 40-60 lines. Risk: medium, the D2 guard.
   - Today a sample whose witness has no entry (`gvaw_no_entry`, 7 117) falls back to guest bytes.
   - Proposed: in `try_gva_resident_sample` (`runtime/draw/vulkan.rs` ~5041), when `writeback_debt` holds an
     unpaid `GvaWritebackDebt` for the same plane, serve the resident or pay the debt first.
   - The 37 resident-authoritative Stores are otherwise visible only after a late flush (for example ref 145 was paid
     87 s after its pass).
3. **Per-pass summary line for task-1 GVA targets** (`first_sight` on (pipe, w×h, load)): draws, vertex/instance
   counts, scissor, colour write mask and fragment outputs. It explains ref-101-class all-zero Stores without a full
   draw trace. Size: about 25 lines. Risk: low (OFF channel only).
4. **Ref 101 itself.** Defer. It is a boot-UI layer. Revisit only if item 3 shows zero coverage or a scissor of 0.

C13 fixes 2 and 3 fire (`color_seed_rgba16f_native` 5, `gvarung_resident_copied` 33) but act on inputs that are
already stale or legitimately empty, so it is consistent that they changed nothing visible.

## Open questions

- Does WindowServer re-render the Dock backdrop after the wallpaper loads? This decides item 1 vs item 2. It needs
  the draw-trace boot, or guest RE on QuartzCore's `CABackdropLayer` invalidation.
- What is the 1920×128 ref 282 for, and who is supposed to fill it? It is created at t = 1 989.5, sampled at
  1 989.569 and never written. It may be the next backdrop generation, sampled one frame before its capture.
- Is the alert's 64×64 snapshot flat because the area under the alert is flat (a black screen at t = 1 233), which
  would be the Dock story again, or because of the UberShader material? Dump the 64×64 at gva 0x268000/0x270000 with
  `REIMS_VGPU_PLACED_DUMP` on the same boot.
- `display_vbl … not_enabled` all run long: does the guest expect a VBL to drive CA's backdrop refresh?
