# D5: the icon mask composite writes zero (pass 206, pipe 57)

Run: Orchard `eadb240`, Dozen. Symptom: pass 206 opens with a Clear, draws pipe 38 (no sampler), then
pipe 57 samples mask ref 35 (56×90 RGBA16F, alpha non-zero on 4587 texels) into placed ref 51
(114×148 RGBA16F). The result is `nz=0/16872`, alpha included. The same thing happens about 40 times
(pipes 57/70/84/144/456/297), and again on `83e3b84` (`placed-dump-83e3b84/00019→00020`: a 17×16 mask
with alpha nz=25 goes to 40×40 and comes out all zero).

The host log `/tmp/reims-vgpu-fail.eadb240.log` no longer exists (`/tmp` was wiped). The mapping
from pipe to shader below therefore comes from the SPIR-V dumps, not from `pipeline_create` lines.

## Which shader pipe 57 is

- `spirv-dump-02c9b85` (the run closest to eadb240) has `pipe57-fragment-49260c0e…` /
  `pipe57-vertex-3ff7dd3c…` (the AIR shows **RenderBox `custom_effect_fragment` /
  `custom_effect_vertex`**) and `pipe38-fragment-804544df…` (**`plane_color_fragment`**, which has no
  texture). Per-task pipe numbers carried over between these runs. D4's pipe 30 (`9e3b88c0` /
  `762a2fbb`) is pipe 30 in this dump too.
- The draw line fits this shader: fragment texture index 0 (`fill_tex`, binding 704), and outputs
  `color` (rt 0) plus `coverage` (rt 1), so `written=0x03`. Slot 1's write mask is 0, which is
  expected.
- Target 114×148 is the mask plus 29 px on each side (114−56 = 148−90 = 58). That makes this the
  padded canvas for an effect (a shadow or blur), and the draw has to place the mask in its centre.

## What the AIR does and what the SPIR-V does

AIR (`ffgea5ba3ca3gcoha4`), summarised: the shader takes a pointer to the custom-effect
parameters at `globals+56` (a rect in words 0-3 and a 5x float2 matrix `M` in words 4-13), clamps the
effect coordinate into the rect, maps it through `M` (clamped to `M[3]..M[4]`) to a UV, samples the fill
texture with a constexpr sampler, multiplies by `globals.alpha` (@52) and writes coverage `(color.a, 0)`.
The SPIR-V (`mod-0651ab79…`, and the same in the 175aa0e and 5b042af dumps) turns **every load
through `p` into a constant zero**: `%67 = OpCopyObject %float %null`, plus six
`OpCopyObject %uint %null`. Only `alpha` (word 13 of binding 672) is read for real. So the rect is 0,
M is 0, `uv = clamp(0, 0, 0) = (0,0)`, and every fragment samples the mask's corner texel. That texel
is transparent black, so `color = 0·alpha = 0` everywhere. This matches the dump exactly. The
sampler, vertices, blend and viewport do not matter: the coordinate never depends on the fragment.

## Root cause (reproduced offline on the current fork, `08c8f98`)

I ran `metal2vulkan` (release build from 29/10 23:40) on `pipe57-fragment-49260c0e….air`. It still
emits 7 null copies. `METAL2VULKAN_UNMODELED_WHY` reports `define_unmodeled_pointer name=%6`
and then `%7 %9 %11 %14 %19 %24` (custom_fn's loads) as Private zero placeholders.

| Variant (`.ll` edit) | Null copies |
|---|---|
| original | 7 |
| `%6` as `gep i8, %2, 56` | 6 |
| `%6` in-bounds (`i64 0, i32 1, …`) | 7 |
| **`custom_fn` called with root `%2` instead of `%6`** | **0** |

So the problem is not the past-the-end index. It is **a non-root pointer into a constant buffer
(addrspace 2) that is passed to a helper function**. `bind_inline_parameter`
(`src/native/emitter/body/core_inst.rs` ~775–800) keeps the raw buffer cursor across inlining only
when `raw.addrspace == 1` (device) or for BDA. For addrspace 2, the helper parameter is bound to the
GEP's Private zero placeholder, so every load through it reads 0. Its own comment already describes
this failure ("silently turns helper writes into Private writes"), but only for device buffers.

## Fix (sized)

1. **Fork, ~10 lines plus a ~60-line unit test, low risk.** In `bind_inline_parameter`, also accept
   `raw.addrspace == 2` when `raw_buffer_params.contains(name)`. Call edges already propagate for
   any address space that matches on both sides (`raw_param_call_edges`). Constant buffers are
   load-only, so no store path changes. The test should look like `custom_fn`: a helper that takes
   `gep(struct, %buf, 1, …)` and loads floats from it.
2. **Check:** retranslate the 49260c0e AIR and expect 0 null copies with loads from words 14…27 of
   binding 672. Rerun the 363-AIR corpus (translation and validation). Boot with the probe on task 5:
   ref 51 should have nz>0 (centre 56×90).

## Blast radius (02c9b85 modules that copy a null constant)

Same pattern, with an addrspace-2 pointer argument to an internal function: `ffgea5…` (2 variants),
`ffkia5…` (3), `fi2a2…` (RenderBox custom effects), `glass_background_sdf_cr_lph` (62 placeholders),
`A2Xghfc` (500). The CoreImage `ci_lanczosDown*`/`asgDown*` kernels also have 8 null copies each,
but no addrspace-2 call. That is a different path, still unexamined. Fix 1 may also change the
Liquid Glass background.

Aside (not the cause): `plane_image_stretch_fragment`'s `bias(-0.25)` comes out as
`ExplicitLod -0.25`. That does nothing on single-level textures.
