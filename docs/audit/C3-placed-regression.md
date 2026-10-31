# C3: the c452508 screen regression (heap-placed textures)

Follow-up to `C2-placed-textures.md`. The runs compared are `/tmp/reims-vgpu-fail.log` (c452508) and
`/tmp/reims-vgpu-fail.6fc0f4f.log` (6fc0f4f). Serial is `~/gg/run/gg27/serial.txt` (c452508 only; the
6fc0f4f serial was overwritten). Shots are `shots/dzn-c452508-{3,5,7}.png` and `shots/dzn-6fc0f4f-6.png`. Orchard paths
are relative to `reims-vgpu/crates/reims-vgpu/src/` at `gg-macos27` HEAD `c452508`.

## 0. Headline: the placed textures never reach the screen task

| | 6fc0f4f | c452508 |
|---|---|---|
| `rt_placed` objects by task | (refused, `rt_wrong_type`) | task 4: 48, task 12: 27, task 13: 166. **Task 1 (WindowServer): 0** |
| placed sizes | — | all small: 104×104, 228×124, 124×124, 110×110, 114×148, 56×90 … (fmt 0x73/0x41/0x50/0x19) |
| `frag_neutral_texture_substituted` by task | 5 (task 13) | 201 task 13, 38 task 4, 14 task 12, **0 in task 1** |
| task 1 draw refusals | 17 | 2 |
| window content 800×632 (task 1, `m2v_store_gva … pipe=11`) | t=791 s, `rgb_nz=505600 max_rgb=255` | t=778 s, `rgb_nz=505600 max_rgb=255` |
| `device_lost` / `fence_timeouts` | 0 / 0 | 0 / 0 |
| draws executed (`draw_phase draws=` sum) | 6547 | 9405 |
| compute `desc_decode` refusals | 1522 (task 1: 814, task 13: 708) | 12 (task 1) |

- WindowServer is task 1. It owns every 1920×1080 pass and the 800×632 window composite.
- In both runs, task 1 rendered the Keyboard Setup Assistant content in full: all 505 600 px non-zero at ~13 min.
- The shot still shows that window's content black, with the same file from 15:12 to 15:22 (`-3`…`-7`, 11 990 B).
  The loss is therefore **after** the content pass: in task 1's later recomposites or in scanout.
- Task 1 neither renders nor samples a placed texture.
- The placed chains belong to tasks 4 (alive 659–830 s), 12 and 13. Slot 13 was redefined 11× between 934 and 1400 s,
  and the serial shows `iconservicesagen` crashing 12×. These are the icon renderers (**inferred**).
  The outputs are 106×106 RGB10A2 and 104×104 R8 buffer textures, e.g. `rt_buffer_texture task=4 ref=3 … fmt=0x5a`.
- **Conclusion:** the counters alone cannot tie c452508's placed rung to the black window. Causality has to be
  measured (fix 1) before more porting is driven by this regression.

## 1. Why the draws count "ok" while sampling a neutral 1×1

- The substitution is always **fragment texture index 1**: `binding=705` is the slot for frag tex1, and the
  trail shows `b704` = tex0. The line is `pipe=71 unbound=[tex1] provided_tex={0} 114x148`.
  Pipes 56–79 and 120 match it, in tasks 4/12/13 only. It is the same shader family as 6fc0f4f's `pipe=67` (45 lines).
- It grew 5→253 only because these passes now execute instead of dying at `rt_wrong_type`.
- The guest never binds tex1 in these encoders. Apple's 114 handler binds `getTextureForReference(0)` = nil
  (D-render row 114), and nil reads zero, so Orchard's `solid_rgba8(1,1,[0;4])` (draw/vulkan.rs:8444) is
  faithful. **This is not a defect.**
- The placed textures themselves:
  - All 1509 placed samples were `placed_sample_resident`.
  - `placed_sample_unwritten` = 0, `placed_sample_pending_clear` = 0, `placed_sample_refused` = 0, and every
    sample was self-format with no view over a placed base.
  - Readiness is asked through the object lease (`placed_resident_ready` draw/vulkan.rs:1288, rung :1316, called at :1461).
  - The order is correct. In task 4 the chain is ref 20 R16F → 35 → 51 → 60 ⇄ 63, each produced (`rt_placed_draw`) before it is
    sampled, ping-ponging ×4 at 114×148, then pipe 85 → buffer texture ref 3. Every `placed_retired` (t=712021–712041) comes
    after the last sample.
- **Heap aliasing**: refs 12 and 95 sit at `heap=33 off=0x0` and are live at the same time (717 072–717 564 s).
  The guest never reads one through the other: no sample of an unwritten placed texture was logged.
  - First passes are DontCare: `rt_placed_load_unwritten` 366 ≈ `rt_placed_opened` 689 − `load_resident` 323, and
    `passbegin_undefined` went 3→369.
  - Metal leaves aliased contents undefined, so a per-texture image is still faithful. **Aliasing is not the cause.**
- Remaining risks in the chain:
  - (a) `linear_memo_narrowed ref=67 fmt=0x19 16x16 to=rgba8 lost=clamp_to_unit_and_256_levels` (t=711827), sampled by
    `pipe=69` inside the blur chain. An R16F LUT is clamped to [0,1] and cut to 8 bits.
  - (b) A placed DontCare first pass now begins **Undefined**
    (`Color0Load::Undefined` backend/vulkan/engine/exec.rs:5225). On dzn, what that pass starts with is whatever the driver leaves.
    118 partial draws (`draw_partial_preserving_unseeded_resident_only`, 1.25 M texels) leave the area outside the scissor as it began.
  - (c) The identity `(task, ref, w, h, fmt)` (`placed_identity` draw/vulkan.rs:10419) survives `placed_retired`
    (images_and_registry.rs:2221). A recreated texture with the same ref and shape can see the old resident as "ready".
    That is legal under Metal's undefined contents, but nondeterministic.

## 2. `view_base_or_swizzle` (12 lines): views over **buffer textures**, not over placed textures

- Every case is `fmt_ov=Some(1)` (A8Unorm) on a cmd-9 base. Example: task 4 view 6 → base 86 =
  `rt_buffer_texture … buf=7 bpr=0x100 104x104 fmt=0xa` (R8Unorm), and `view_base_typed_texture … opcode=Some(9)`
  (draw/texture_view.rs:383). The mask is reinterpreted as alpha.
- Orchard path:
  - 3851d69 now stops the chain at that base.
  - `placed_sample` returns `None`, because the base is not placed.
  - `buffer_texture_descriptor` (draw/mod.rs:1352) only matches the sampled ref itself, not a view's base.
  - The view rung then fails, and draw/mod.rs:1936 labels the failure.
  - Result: `draw_vk_nothing_stored`, and the rest of the pass is dropped. Example: `pipe=62 task=4 di=2/51`, so 49 draws are lost.
  - This failure is pre-existing: 30 × `res_texture_view_opcode` in 6fc0f4f.
- Apple: `newSerializerTextureViewWithPixelFormat` @0x100048444 resolves the base (`sub_10005A27C`), then calls
  `getTexture` (polymorphic: buffer-backed, placed or plain), then `validateTextureViewForTexture` and
  `newTextureViewWithPixelFormat:` (+`newChildTextureResourceWithTexture:`). The bytes are the same; only the channel
  mapping changes: R8 to A8 gives (0,0,0,r).

## 3. Guest-visible behaviour

- No GPU error path fired: no `IOGPU`/`AppleParavirt` lines in the serial, and `device_lost` and `fence_timeouts` are 0.
- The crash reasons are unknown. The kernel suppressed the reports ("AMFI: Denying core dump", "Too many corpses").
- **The crash loop predates c452508 (inferred):**
  - In 6fc0f4f, slot 16/17 was redefined 12× (1055–1376 s), with ~4 s lifetimes.
  - In c452508, slot 13 was redefined 11×, with ~40 s lifetimes.
  - The compute-info reply is identical in both runs (`get_compute_info ok … count=6 wrote=3`, drain/mod.rs:3755).
  - Longer-lived crashers, plus 44 % more host draws, fit the guest load average of 509 at 18:07 and the fact
    that sshd was "not running". **Inferred:** fewer shaders (321→239) means the guest progressed less, not that it rendered differently.

## Ranked change list (porter)

| # | Change | Where | Size | Risk |
|---|---|---|---|---|
| 1 | **Causality A/B first**: `REIMS_VGPU_PLACED=0` restores the c452508 refusal (placed rung off in render_target + `placed_sample`). Boot both ways and shoot at the same minutes. Add a debug-gated `placed_content` probe: on the first sample of a resident, read it back and log `nz/a_max`. | render_target.rs, draw/vulkan.rs:1316 | ~50 | none |
| 2 | Views (7/8/0x1B) over buffer textures (9/0x37): when a view's base is a buffer texture, load the base bytes (`load_buffer_texture_rgba` draw/mod.rs:1555) and apply the view format/swizzle for same-size reinterpretations (R8→A8 = (0,0,0,r); identity otherwise). Clears the 12 refusals and the dropped tails of their passes. | draw/vulkan.rs ~1440, texture_view.rs | ~60 | low-med |
| 3 | Native R16F (0x19) and RG16F linear sampled uploads instead of RGBA8 narrowing (D-render fix 6). | sampled upload path | ~80 | med |
| 4 | A placed first pass with DontCare/Load and no resident: begin with Clear(0,0,0,0), not Undefined. Then it is deterministic on dzn and matches the zero answer `placed_sample_unwritten` already gives. | draw/vulkan.rs:8619-8645 / exec.rs:5225 | ~10 | low |
| 5 | Put an object epoch (descriptor GVA or a create counter) in `TargetIdentity::Placed`, so a recreated ref never inherits a retired resident. | types.rs, draw/vulkan.rs:10419 | ~25 | low |
| 6 | Get the iconservicesagent crash reason: `GG_KEEP=1`, then `gg single` → `log show --last boot --predicate 'process=="iconservicesagent"'` plus `/Library/Logs/DiagnosticReports`. | tester | — | — |

## Open questions
1. Does disabling the placed rung (fix 1) bring back the window content on dzn? If it does not, the black window is a
   task-1 recomposite/scanout loss. That class of loss was already seen at ea4dfb5 (NOTES 29/10 13h) and is unrelated to placed textures.
2. Why did task 13's 708 compute `desc_decode` retries (6fc0f4f) vanish? Was it the same process?
3. Are the icon outputs (`m2v_store_gva 106x106 … rgb_nz=0`) all-zero in both runs because of the RGB10A2 store, or because the content really is black?
