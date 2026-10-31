# C17: where the Dock glass gets its backdrop (Orchard 5a634ef, DRAW_TRACE boot)

Read-only diagnosis. Log `~/gg/run/gg27/logs/reims-vgpu-fail.5a634ef-trace.log` (77 246 lines, `REIMS_VGPU_DRAW_TRACE=1`,
placed probe on task 1). Line numbers below are in that log. Source: Orchard `gg-macos27` @ `5a634ef`, paths relative to
`reims-vgpu/crates/reims-vgpu/src/`. Shader roles come from the 363-AIR corpus `~/gg/run/gg27/spirv-dump-02c9b85`
(`pipe133-fragment-44985b8bf37f7672.air`, AIR 17104 = `glass_background_cr_lph`). Guest code is from
`<RE corpus>/AppleParavirtGPUMetalIOGPUFamily.c/`.

**Short answer.** The host executes everything the guest sends. In this boot, the guest never sends a backdrop capture
into a 1920×128 texture after t = 1 096 s: no blit, no compute, no fragment-storage write, and no render pass that
samples the screen or the wallpaper. Nothing is declined, dropped, or left unhandled. Ref 151 is a **pooled**
1920×128 RGBA16F that CoreAnimation reuses for unrelated layers. Each time the Dock glass reads it as `source_texture`,
the latest write before that read (in guest order) is a non-backdrop pass, and the host hands the glass exactly that
content. The alert's 64×64 snapshot has the same "captured once, never again" shape: it was last written at
t ≈ 817 s and is still sampled at t = 1 548 s. The next step is on the guest side: what makes QuartzCore issue (or
skip) a backdrop capture.

## 0. Corrections to the brief

1. **The 1920×128 is the glass `source_texture`, and it is not always a backdrop.** Per the AIR, slot 3 is
   `source_texture` and slot 4 is `sdf_texture`. In `frefs=[3:151,4:230]` (line 60262), ref 151 is the source and
   ref 230 is the shape. Ref 230 is drawn just before by pipes 160/153 with **no** sampled textures (line 60244,
   `smp=[]`), so it is procedural geometry, which is what an SDF/shape should be.
   - The same pipe 162 (fw 6596) also runs on the display with `frefs=[3:138,4:151]` (line 60467). There ref 151 is
     the **shape**.
   - At that point ref 151 also serves as `b708` for the menu-bar title and icon draws (pipes 223/103/150/48, lines
     60474-60530). The titles are 89×27, 73×30, …: "Finder File Edit View Go Window Help".
   - So ref 151 changes role between frames.
2. **In pass 345 the non-zero UberShader draws have `b707` = the zero 1×1, not a non-zero texture.** Lines 18326,
   18337 and 18344 show `smp=[b707:bytes:1x1] frefs=[3:25,…]`. The zero pass 347 is the one with a non-zero `b707`:
   ref 105, a 256×1 RGBA8 (line 18486). See Q3.

## Q1. Backdrop capture: blits, copies, computes, storage writes

### Blit and compute: nothing reaches the 1920×128, and nothing is lost

| what | evidence | verdict |
|---|---|---|
| Blit records, whole boot | `walk_records_blit` sums to **3**. They are the 3 `draw_trace blit` lines 10902, 61362 and 63319, all `TextureToBuffer` 240×135 (refs 15→76, 234→232, 233→226). These are the CA blur readbacks | none target ref 151 or any 1920×128, and none read the display surface or the wallpaper |
| Unknown or refused records | 0 `stream_frame_fail`, 0 `stream_record_fail` (`runtime/exec/mod.rs:1719`, `:1427`), 0 `note_unimplemented_render_opcode`. `render_ops` shows only known opcodes (0x01 0x03 0x06 0x07 0x09 0x1a 0x68 0x6e-0x82) | no unhandled opcode, in any family |
| Task-1 compute | 3 segments (lines 10879, 61350, 63307), all the 240×135 blur. Destinations: `compute_dst host … dims=240x135` (lines 10895, 61360…) | none 1920×128 |
| Fragment storage (`inplace_copy_lph`, the alert's capture rail) | 42 `frag_storage_image_bound` = 42 `frag_storage_landed_readback`. Destinations: 38 × 64×64 (gva 0x268000/0x270000, t = 790-817) and 4 × 128×128 (lines 69405-69673, t = 1 961-1 964) | none 1920×128. The rail works: every bound write lands |
| Other tasks | no draw in tasks 3/7/11/15/16 targets 1920×128 or 1600×128 | — |

**Draws that were "missing" from the trace.** Task 1 has 43 render segments with no draw line. To reproduce, run awk over
`draw_trace seg` and keep each segment that is followed by another `seg` before any `draw` or `blit` line. The sum of `stream_draws_*` across the boot is
53+215+77+65+989+670+2 = **2 071**. The number of render segments that have draw lines is **2 070**, and the last
segment is never closed. `stream_draw_dropped_no_pipeline` and `_zero_count` never appear.

So **no stream lost draws.** In particular, no attachment-less pass was skipped by the `!acc.color_slots.is_empty()`
gate (`runtime/exec/mod.rs:5178`, `:4975`), which would show as `stream_draws_N` without trace lines. The 43 empty
segments are draw-less encoders: load/clear/store only.

They do sit in a telling place: **two right before every Dock-glass pass** (2158/2159, 2172/2173, 2188/2189) and
**one right before every pipe-225 pass** (2163, 2176, 2192). The trace does not name their attachments (see fix 1).

### Who samples the screen or the wallpaper

- **Wallpaper**: refs 229/244, 4096×2160, `route=bytes`. It is sampled only into:
  - the display (mid 3/42; lines 60026, 60604, 62792, 69354-69373);
  - the 1920×30 menu-bar surface (mid 1, pipes 21/23/241; lines 60570, 61255, 63217, 63230);
  - the 1920×1152 blur source (pipes 83/243; lines 61311, 63279).

  It is never sampled into a 1920×128 or 1600×128 target.
- **Display surface as a source** (`res:s3g…`/`s42g…`): only pipe 51, the full-frame flush copy, and pipe 48 reading
  `s30` (256×256). There is no capture into a layer-sized target.

### Every write to ref 151 (gva 0x1a34000, 1920×128 RGBA16F), and every glass read of it

| line | t (s) | pass | pipes | what | store |
|---|---|---|---|---|---|
| 49165-49209 | 1 096.4 | 1799 | 112 ×3 (fw 26903, samples ref 138), 11 ×4 | blur ping-pong with ref 138, then UberShader | copying Store `rgb_nz=131492 max=97 mean=21` (49209). These are the "menu-bar layer" numbers of C11/C14 |
| 49444 | 1 097.7 | 1801 | 11 | Clear + 165×128 strip sampling **ref 203** (384×384) | resident-authoritative |
| 49563 | 1 099.3 | 1809 | 11 | Load, 147×117, ref 203 | resident |
| 49726 | 1 100.6 | 1816 | 87 | Clear + 800×63 draw (b707 = ref 105 ramp), `frag_out=0x01` | resident, flushed (CPU) at **1 149.96** (53219) |
| 60456 | 1 425.6 | 2164 | 225 (AIR 6124) | Clear + 165×128 from ref 203 | resident, debt armed |
| 61168 | 1 431.0 | 2177 | 225 | same | resident, debt paid by 1 548 (`gva_flush_copied=2`, window 61287-62960) |
| 63114 | 1 549.4 | 2193 | 225 | same | resident |
| 70923 | 1 984.2 | — | — | the gva is reused for a 180×180 (ref 134) | — |

Dock glass reads (pipe 162, `glass_background_cr_lph`, target ref 138 1600×128, `source=151`, `sdf=230`):

| line | t (s) | pass | source route | newest guest-order writer of ref 151 | so the glass sees |
|---|---|---|---|---|---|
| 60262 | 1 424.29 | 2161 | bytes | pass 1816 (t = 1 100.6, pipe 87; guest pages paid at 1 149.96) | the 324 s-old pipe-87 layer |
| 60829 | 1 429.61 | 2174 | resident | pass 2164 (the ref-203 strip) | the menu-bar shape strip |
| 62960 | 1 548.09 | 2190 | bytes | pass 2177 (paid to guest) | the menu-bar shape strip |

**Verdict for Q1.**
- The host serves each read with the newest content in guest order. The routes differ (bytes vs resident), but there
  is no stale-vs-resident split here, because every debt was paid before the bytes read.
- No producer is missing from the log. The guest itself feeds `source_texture` a texture whose last writer is not a
  backdrop capture.
- Compared with the alert:
  - The alert's capture is an `inplace_copy_lph` draw on the display pass, with a fragment-storage write to a 64×64
    (line 18404, `frag_storage_stage pipe=94 … 64x64 dst=Host`), and it lands.
  - The Dock never gets an equivalent draw.
  - The alert's 64×64 is itself stale: its last write is t ≈ 817 s, and at t = 1 548 it is still sampled as
    `b708:bytes:64x64` (pipes 128/132, pass 2187, ~line 62945).

  So **neither glass is re-captured after its first build.** This is the C14 Dock verdict (a) again, now on a full
  trace.

## Q2. Ref 203 (384×384 RGBA16Unorm, sampled by pipe 225)

- **What it is.** A **buffer-backed texture**: `buftex_rgba16unorm_native ref=203 buf=202 384x384 bpr=3072`
  (line 49442, t = 1 097.7). It is exactly the NOTES 30/10 14h30 / C11 texture (there it was ref 233 / buf 232). It is
  read through `load_buffer_texture` (`runtime/draw/mod.rs:1711`): bytes of buffer 202, 16 bits, native.
- **Who produces it.** The guest CPU, through the MTLBuffer it aliases (`newTextureWithDescriptor:offset:bytesPerRow:`).
  - No host path writes ref 203 or buffer 202 in any task. No draw targets them, no compute or blit destination names
    them, and there is no `gva_store_buffer_texture` for them.
  - The only task-1 uses are as a sampled input: pass 1801 and 1809 (pipe 11) and passes 2164, 2177 and 2193
    (pipe 225), always into ref 151 with a 165×128 / 147×117 scissor.
- **What it is for (inferred, high confidence).** The strip it produces in ref 151 is then used as **`sdf_texture`**
  by pipe 162 on the display and as `b708` by the menu-bar title and icon pipes (pass 2165, lines 60467-60530). So it
  is the menu-bar glass **shape/SDF source**, a 16-bit shape LUT as C11 suspected. It is **not** the Dock backdrop.
- **Is it blank on the host?** The log cannot say. The blank latch (`lin_rung_guest_blank`,
  `runtime/draw/vulkan.rs:6390-6399`) covers GVA texture rails only, and `load_buffer_texture` has no content census.
  The C11 run showed structured non-zero content in the same buffer (`rgb_nz>0` garbage after 8-bit narrowing), so it
  is at least sometimes non-zero (**inferred**). Fix 2 adds the census.

## Q3. Refs 25/26: the 1×1 BGRA8 on b708-b712 / b714-b718

- **The objects.**
  - Ref 25 is gva 0x320000 and ref 26 is gva 0x324000. Both are BGRA8 (`fmt=0x50`), each a 4-byte extent inside its
    own 16 KiB allocation, declared at t = 207.68 (lines 2057-2058).
  - Ref 28 is the 32×32 at 0x328000, non-zero (`t4a5462c2`).
  - First read at t = 212.685: `lin_rung_guest_blank` for 25 and 26 (lines 2237, 2240).
  - Bound as `frefs=[…5:25,7:25,10:25,12:26,4:25,6:25,8:25,11:25,13:26,9:28,14:26]` on every task-1 UberShader draw.
- **Who writes them on the guest.** CPU `replaceRegion:`. `-[AppleParavirtTexture replaceRegion:…]` @0x9e3b copies
  the bytes straight into the texture's backing (`res + offset`, or the IOSurface base address). It sends no command
  to the host.
  - No blit precedes t = 658 s, and none targets them afterwards.
  - So the host reads whatever the guest put in the pages, and that is all zero. Nothing on the host side is
    withheld.
- **What they hold.** CA's placeholder textures for unused optional slots (**inferred**). Ref 25 fills 8 slots and
  ref 26 fills 3. Whether ref 26 should be opaque white rather than zero is a guest question (open question 2).
- **Do zeros force the UberShader to 0? No.** Pass 345 (ref 75, 832×64) runs pipe 11 three times with **all twelve**
  binds being refs 25/26/28: `b707` = ref 25 (lines 18326/18337/18344). After each draw the s1 probe reads
  `nz=25600/53248, range 0…1.03` (lines 18335, 18342, 18350), and the Store is `rgb_nz=25600 max=255 mean=122`.
  - The zero pass 347 (ref 102, line 18486) differs in three ways:
    - `b707` = **ref 105**, a 256×1 RGBA8 served from bytes (line 18485). It is never blank-latched, so it is
      non-zero.
    - `load=Clear` instead of Load-after-pipe-71.
    - A different draw: an 800×63 scissor and its own uniforms.
  - It outputs zero on both MRT slots (line 18498 `rgb_nz=0`; s1 probe `nz=0`, line 18490+).
  - So the zero is not from the 1×1s. The candidates are the uniforms/material path with a ramp lookup, or a
    legitimately empty layer. Settling it needs that draw's constant buffers.

## Ranked fix list (for the porter)

1. **Name the attachments of draw-less render segments in the trace.** Size: ~15 lines. Risk: none (`DRAW_TRACE`
   only).
   - In `finish_stream` (`runtime/exec/mod.rs:~4975`), when `!will_draw` and `draw_trace::enabled()`, print one
     `draw_trace seg_targets` line: color refs, gva, w×h, load/store actions and clear colours.
   - This answers what the two empty encoders before every Dock-glass pass touch. It is the last host-side place a
     capture could hide, for example a Clear on ref 151 whose host resident is not invalidated.
2. **One-shot content census for buffer textures.** Size: ~10 lines. Risk: none.
   - In `load_buffer_texture` (`runtime/draw/mod.rs:~1790`), latch `buftex_blank` / `buftex_nz` with nz and fnv per
     (buffer, extent). This answers "is ref 203 blank".
3. **Guest RE, not host code (guest RE): what drives a CoreAnimation backdrop capture on macOS 27.** Size: 0 host
   lines. Risk: none. This is where the Dock and alert glass actually stall. In QuartzCore and WindowServer:
   - which call produces the `source_texture` of `glass_background_cr_lph` (render-pass capture as in D2 pipe 152,
     `inplace_copy_lph`, or a blit);
   - what invalidates and re-issues it: a display or VBL event (`display_vbl … not_enabled`, C14/C15), a layer-tree
     commit, or a device-capability gate that makes CA keep a cached backdrop.
4. **Refs 25/26 intent (guest RE).** Size: 0 lines. Risk: none.
   - Find who creates the two 1×1s at t ≈ 207 s, and with which bytes: CA's `MetalContext` default/null textures.
   - Low priority: pass 345 proves they do not zero the output.
5. **Pass-347 zero (the C14 Q1 / C16 class).** Size: ~20 lines of probe. Risk: low.
   - Extend `placed_probe_draw` to dump the fragment constant buffer bytes for task-1 832×64 Clear passes.
   - Then compare pass 345 against pass 347 against the UberShader's material inputs.
   - Not a glass-backdrop blocker.

## Open questions

- What do the draw-less encoders at passes 2158/2159, 2172/2173 and 2188/2189 attach to (fix 1)? If one of them is a
  Clear/Load on ref 151 or 138 whose effect never reaches the resident, it is a host bug. If not, Q1 is entirely
  guest-side.
- Should ref 26 (bound to slots 12-14) be opaque white? If it should, any UberShader term that multiplies by it would
  be zero here. That is not visible in pass 345, but it is untested for other material paths.
- Why does CA keep feeding the Dock glass a pooled texture last written by unrelated passes? Possibilities: a
  capture-skip decision in QuartzCore (capability, reduced transparency, or "backdrop unchanged" logic keyed on events
  the host never sends), or a capture that is supposed to happen in another encoder type this guest never emits.
- Is the content of buffer 202 meaningful (fix 2)? This decides whether the menu-bar pill shape is right even once the
  backdrop is.
