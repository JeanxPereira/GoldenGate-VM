# C16: the 5a634ef "regression" (Orchard a360c8a → 5a634ef, headless)

Read-only diagnosis. Source: Orchard `gg-macos27`, `git diff a360c8a 5a634ef` (commits `ec70db6` and `5a634ef`), paths
relative to `reims-vgpu/crates/reims-vgpu/src/`, line numbers at `5a634ef`.

Logs (WSL):
- **bad**: `/tmp/reims-vgpu-fail.log`, 66 971 lines, t = 0 … 2 856 s. This is the live run; it was not rotated.
- **good**: `~/gg/run/gg27/logs/reims-vgpu-fail.a360c8a-final.log`, 110 058 lines, t = 0 … 6 060 s. The `-45m` log is
  an earlier cut of the same run.
- **variance references**: the `28f9823-final`, `a360c8a-window`, `c2ce29f-{final,freshcache}` and
  `e118d61{,-final}` logs in the same directory.

Counters are sums of the per-second `OFF store_routes` census lines.

**Verdict.** No hunk in the diff changes what the host renders or routes in this run. Every new branch with a
behavioural effect is gated behind a slug that measured 0, or behind a condition that is false headless. The bad
shots come from a different guest trajectory: a different order of the boot UI, alert and widgets. That order meets
hazards that already exist in both builds (D2-class stale backdrop, stale guest bytes under a recycled reference).
The numbers sit inside the spread already seen across earlier runs. Confidence: high that the diff is inert here.
Medium on which pre-existing hazard produced each artefact, because there is no per-draw trace.

## 1. Hunk by hunk: what can change behaviour when the new slugs never fire

| hunk | always active? | effect when slugs = 0 | evidence |
|---|---|---|---|
| `scanout/mod.rs:225` `console_refresh` (ec70db6) | only when `display_from_resident` is set (a window presents the resident directly) | **none headless.** `display_needs_cpu_frame` is the same as before | bad: `capture_sampling full=128 light=0` (last line). No light capture means no direct present, so `display_from_resident` was never true. 0 `console_refresh` lines; the first refresh would log at n = 1 |
| `scanout/mod.rs:274` `last_full_capture_at = Some(now)` | yes | a timestamp, read only by the gate above | — |
| `vulkan.rs:5170` `Err(refusal) → try_gva_resident_pending(...)` | yes, on every refused sampled bind (`gvaw_no_entry` and `gvarung_resident_absent`; `NoGeneration` now also enters) | **pass-through.** `try_gva_resident_pending` (`:5246`) returns `None` before any side effect if `pending_writebacks.is_empty()` or if `owed_gva_planes_over(...)` is empty. Once it gets past those, it always ends in `note_store_route("gvarung_resident_pending")` or `..._paid`. Both are 0, so every call returned `None` at those gates, which is exactly the old `return None` | `gva_resident_pending_mode mode=on` printed once (bad line 4573, t = 376 s), so the path is compiled in and was reached with a non-empty ledger. `gvarung_resident_pending` and `gvarung_resident_pending_paid` are both absent from all store_routes lines |
| `writeback_debt.rs:675` `owed_gva_planes_over` | as above | a pure filter over `gva_debts`, with no mutation | code |
| `writeback_debt.rs:1232` `pay_gva_over_span` | only after a non-empty `owed` | **never ran.** It would have counted `_paid` | `_paid` = 0 |
| silent arm inside `try_gva_resident_pending`: `exact && quiet && ready`, then `translate(...)?` fails | — | in theory, a `None` without a slug after `gva_store_witness::reach()` (a page-state query) has run | needs exactly one owed plane that matches the span exactly. If one had existed, the non-exact cases would also have produced `_paid` > 0. Not plausible |
| `vulkan.rs:10831-10846` `note_gva_pass_draw` (pass summary) | **yes**, on every task-1 draw | logging only: a global `Mutex`, a `first_sight` latch, and `fragment_output_locations_memoized`. The memo keeps an `Arc` of each fragment SPIR-V, holds pure answers, and is cleared when full. `req`, `resources` and `writeback_guest` (a plain `bool` parameter, `:113`) are only read. It cannot reorder draws or change state | 40 `gva_pass_summary` lines. The "last draw = `writeback_guest`" assumption only decides **when the summary is printed**, never what is drawn. If it is wrong, it only merges two passes' sums in one log line |
| `config/lib.rs` `GVA_RESIDENT_PENDING` | — | a new constant. Default on, but only for the dead path above | — |

The only change that does not come from a slug is per-draw CPU time: a mutex and a hash lookup on task-1 draws. That
is microseconds against drain holds of 300–700 ms. It can perturb guest timing only the way any rebuild can.

## 2. The t = 940–956 blank burst

- **The burst sits in a boot-UI phase that both runs have.**
  - Bad: 28 presents between t = 941.8 and 956.5 s, alternating mid 3 and mid 5. The content is constant
    (`rgb_nz=505430`, `px0=[0,0,0,255]`), so the guest animates something that does not change the composited
    frame.
  - Good: the same phase at t ≈ 996–1 008 s, with 23 presents and changing generations (`gen=4/5/6`).
- **What the guest draws in it differs.** `color_input_mrt` passes per window:

  | | bad, t = 939–958 | good, t = 995–1 009 |
  |---|---|---|
  | total MRT passes | **828** | 160 |
  | pipe 2 at 1920×1080 | 413 | 75 |
  | pipe 2 at **192×128** | **222** | 0 |
  | pipe 2 at 800×632 | 0 | 10 (the alert) |

  In good, the alert (800×632, first pass t = 996.9) opens in this phase and the 192×128 layers come at t ≈ 1 220.
  In bad, the 192×128 layers animate here for 16 s and the alert only opens at **t = 1 078.0**. **This is a
  different guest order.** Nothing on the host chooses which layers the guest submits.
- **Why so many reads are blank.**
  - The bin holds 10 713 guest-byte reads, 9 359 of them all zero. They are ~380 reads per present, against ~95
    in good.
  - Only **two new blank spans** were latched in the burst: ref 104 (832×64, gva 0x148c000, t = 941.221) and ref 108
    (192×128, gva 0x1514000, t = 941.471). So the ~9 000 blanks are the same few spans read again on every
    animation frame.
  - **Ref 104 is a copying Store of an all-zero result** (`m2v_store_gva … tex_ref=104 load=2 rgb_nz=0`). Its pages
    really are zero, the C14 Q1 / ref 101 pattern.
  - **Ref 108 is read before its first Store** (blank at 941.471, Store at 941.584): the C14 read-before-write
    pattern.
  - Neither case has an unpaid debt over the pages. That is why fix 2 found nothing: `owed` was empty, as §1
    shows.
- **Bonus for C14 Q1.** The new summary rules out zero coverage for this class:
  `gva_pass_summary task=1 ref=104 … 832x64 pipes=[2] draws=1 vtx_sum=6 scissor=0,0+800x63 wmask=0xf frag_out=0x03 load=2`.
  One full quad and a non-empty scissor, all channels enabled, both outputs written. So the UberShader writes zeros
  (alpha included) for real; the cause is its inputs or the material, not the geometry.

## 3. The extra `gva_resident_authoritative` (38 → 233)

| bin | bad | good |
|---|---|---|
| t = 940–957 | **159** (152 `gvadebt_superseded`) | — |
| t = 1 900–1 930 (alert and widgets build) | 33 | ≈ 3, plus 16 at t = 1 220 |
| steady state | same | same |

The 192×128 animation stores each frame resident-authoritatively, and each new frame supersedes the previous frame's
debt. That gives about one superseded debt per Store: `gvadebt_armed` 233 = `paid_named` 31 + `superseded` 201 + 1.
`gvaseed_elided` (11 → 73) and `color_seed_rgba16f_native` (7 → 16) rise for the same reason. **The diff touches
none of these counters**: arming, superseding and seed elision are all upstream of the new code. It is the same
mechanism run on more frames.

## 4. The artefacts in the shots: guest order meeting pre-existing hazards

- **Alert ghost** (`dzn-5a634ef-9-alert-vs-a360c8a-10.png`): a sharp alert over a translucent panel that shows a
  shifted copy of the alert. This is the **D2 signature** (`docs/audit/D2-glass-ghosting.md`): the backdrop snapshot
  during the open animation bakes an older frame, which then freezes.
  - In bad, the open-animation chain (label textures 239×46 / 252×65 / 39×19 / 52×19, glass targets 192² → 256² →
    320² → 384²) runs at **t = 1 913.2**, 31 s after the widgets were stored (t = 1 881.9–1 882.0).
  - In good, the same chain runs at t = 1 929.73, 0.1 s after the widgets (t = 1 929.56–1 929.62), in one burst.
  - Whether a stale frame gets baked depends on what lies in the double-buffered drawable at capture time, which is
    timing.
- **Calendar widget shows alert text; weather widget black.** This is a widget layer reading a texture that still
  holds an older tenant's content, or nothing.
  - In bad, **references and pages are recycled across these surfaces**:
    - ref 98 (calendar-sized 180×180) `was=mid0:64x64`.
    - ref 77 is renamed 192×64 → 192×192 → 384×384.
    - ref 266 goes 256² → 320².
    - gva 0x1b08000 is the 1600×128 ref 189 (blank at t = 1 880.27), then the 320×320 alert glass ref 270 at
      t = 1 913.
  - Widget surfaces are flushed late through `gva_flush_gpu_declined … guest_ram_map_no_backend_import` (0x26b8000
    at t = 1 967.8). In between, readers take `route=bytes`.
  - Which surface ends up with which leftover content depends on the guest's allocation order. That is **inferred**:
    there is no per-draw trace in this run.
- **"Focus on Quit"** is not keyboard focus. It is the same grey square with a corner triangle that good shows behind
  **Continue** (NOTES 30/10 17h: "botão Continue com o quadrado cinza"). The same glass-background artefact is
  attached to the other button's layer. Same class as above.

## 5. Plain run-to-run nondeterminism, and how to tell it apart

- **The guest timing differs from the start.**

  | event | bad | good | shift |
  |---|---|---|---|
  | first `present_content` burst | t ≈ 620 | t ≈ 740 | −120 s |
  | the 192×128 burst vs the alert | burst first | alert first | swapped |
  | widget Store → alert chain | 31 s apart | 0.1 s apart | — |
  | wallpaper | 1 595 s | 1 680 s | −85 s |
- **The counters vary as much between other runs.**

  | log | `gvaw_no_entry` | blank / memo | `gva_resident_authoritative` |
  |---|---|---|---|
  | `a360c8a-window` | 6 086 | 33 % | 36 |
  | `a360c8a-final` | 7 532 | 39 % | 38 |
  | **`5a634ef` (bad)** | **18 534** | **72 %** | **233** |
  | `28f9823-final` | 22 682 | 17 % | 43 |
  | `c2ce29f-final` | 28 748 | 45 % | 196 |
  | `c2ce29f-freshcache` | 19 826 | 65 % | 196 |
  | `e118d61-final` | 27 150 | 73 % | 255 |

  The bad run is inside this spread.
- **A rule to tell the cases apart.** Compare these **guest-trajectory markers** between runs before comparing pixels:
  - the time of the first 800×632 pass (alert open),
  - whether a ≥ 100-pass `pipe=2 … 192x128` MRT burst comes before it,
  - the gap between the 180×180 / 360×180 widget Stores and the first `view=239x46` bind,
  - the wallpaper time (`present_content … px0=[163,176,198,255]`).

  If the artefacts follow these markers (not the build or the switch), it is nondeterminism. If they follow the build
  while the markers match, it is a regression.

## 6. Minimal revert or fix, and the A/B

- **No revert is warranted for this symptom.** The minimal code-identical baseline, if wanted:
  - Fix 2 (`vulkan.rs:5163-5171` plus `:5198-5317`, `writeback_debt.rs:675-692` and `:1232-1253`) is already
    switchable. No code change is needed; see the A/B below.
  - Pass summary (`vulkan.rs:10831-10846`, 16 lines): delete the call to `note_gva_pass_draw`. Risk: none. It is
    logging only, and it loses the ref-104 evidence of §2.
  - ec70db6 (`scanout/mod.rs:225-237`): inert headless; keep it.
- **The real work is not in this diff.** It is the pre-existing hazards: D2-class backdrop capture of the drawable
  being composed, and route=bytes reads under recycled references and pages before the late Dozen flush. That needs a
  `REIMS_VGPU_DRAW_TRACE=1` boot to tie each widget composite to its source, as in C14 item 1.
- **Single A/B for the tester.** Boot 5a634ef headless with **`REIMS_VGPU_GVA_RESIDENT_PENDING=off`**. That removes
  the only new branch able to change routing.
  - Predicted: the log shows `gva_resident_pending_mode mode=off`, and the artefacts **do not** track the switch;
    they track the §5 markers.
  - If time allows, add a second boot of the same binary with the switch on (the default). It is the cleanest test of
    the nondeterminism rule: same build, two trajectories.

## Caveat

The binary was built at 18:40:09 and `writeback_debt.rs` was modified at 18:40:28, before the 18:42:05 commit.
`gva_resident_pending_mode` and the `gva_pass_summary` lines prove that fix 2 and fix 3 are in the binary. They do not
prove that the binary's `owed_gva_planes_over` matches the committed source byte for byte. Rebuild before the A/B, so
that the binary and `5a634ef` are known to match.
