# D7: NaN from the icon accumulate draw (pipes 104/80, RG16F s1.G)

Run: Orchard `372973e`, fork `23f192a`, Dozen (kisak Mesa 26.2.5, RX 6750 XT). Log
`~/gg/run/gg27/logs/current.log` (pass 181: lines 10551–10590). Dumps: `shots/icons-372973e/00072-…`.
Shaders: `~/gg/run/gg27/spirv-dump-02c9b85/pipe104-{vertex-511e8a5b,fragment-bdb6dd0f}.air`,
re-translated with the release CLI into `/tmp/d7/{vs,fs}.spv` in WSL. Offline harness:
`tools/shaderlab/` (C + GLSL, built in WSL against the system Vulkan loader, run on the kisak Dozen ICD).

## Result in one line

**The translated shaders do not make the NaN.** I ran the fork's exact pipe-104 VS+FS SPIR-V on the
same Dozen ICD and GPU. With any finite path data it fills correctly with zero NaN, and 4 M random
cases of the FS arithmetic give zero non-finite values. The FS can only output NaN when a varying
reaches it already non-finite. A finite segment buffer cannot cause that. A **topology/index**
fault can (sketched below), so the next step is a measurement: the draw arguments and the
buffers of one pipe-104 draw. There is no fork change to make.

## 1. Which function

- FS: the AIR entry `fjba9ila4fmha4` (pipe 104), `fjba10la3jbmhia3` (pipe 30). Apart from the name
  the body is byte-identical to D4's `762a2fbb`. It is `RB::Shader::exterior_shape(PathExteriorVertex)`.
  Inputs (all `center no_perspective`): `path_y` float2 (L0), `path_slope` (L1), `path_intercept` (L2),
  `path_value` half (L3, widened to float by the fork). Output: `half2 coverage` → `[[color(1)]]`.
  Compile options: `fast_math_enable`, `denorms_disable`.
- VS: `RB::Shader::exterior_vertex` (`fast_math_disable`, so IEEE on Apple too). It computes:
  `slope = dx/dy` (only when `|dy| > 1e-4`, otherwise the vertex goes to (−2,−2,0,1));
  `intercept = x0 − y0·slope`; `path_y = (minY, maxY)`; `value = dy>0 ? +1h : −1h`; corners 0/3 at
  `fast_fmin(x0,x1) − 0.5`, corners 1/2 at `maxX + 0.5`.

## 2. The FS math, AIR → fork SPIR-V → Dozen NIR

With `(ix,iy) = trunc(pos.xy)`, `y0 = max(iy, path_y.x)` and `y1 = min(iy+1, path_y.y)`, x is measured
from the pixel's left edge, `x(y) = intercept − ix + slope·y`. The two ends are swapped if `slope < 0`:

In words: `h = sat(y1-y0)`, `r = h*(1-sat(x1))`, and when `x1 != x0` the trapezoid term
`(sat(x1)-sat(x0)) * h*(mean(sat(x0),sat(x1)) - x0)/(x1-x0)` is added (AIR uses a fast `une` compare and a
fast divide there); the output is `G = half(r) * path_value`.

| AIR | fork SPIR-V (`fs.spvasm`) | Dozen NIR (`DXIL_DEBUG=verbose spirv2dxil`) |
|---|---|---|
| `convert.s.v2i16.f.v2f32(pos)` → f32 | FClamp ±32768, ConvertFToS, ConvertSToF | `ftrunc` |
| `fast_fmax/fmin` | FMax/FMin | `fmax/fmin` |
| `fast_saturate` | FClamp 0..1 | `fsat` |
| `fcmp fast une %31, 0` | **OpFUnordNotEqual** | `fneu` |
| `fdiv fast` | OpFDiv | `fdiv` (branch flattened to `bcsel`, the d==0 side selects `r`) |
| `fptrunc` + `fmul fast half` | OpFConvert half, OpFMul half | `f2f16`, 16-bit `fmul` |

Every row is faithful. The guard is the only NaN gate. `|s1 − s0| ≤ |d|`, and a non-zero `d` is at
least one ulp of the larger `|x|`, so `|t| ≲ 1e7·(1+|x|)/|x|`. For finite inputs the FS is bounded
(|r| ≤ ~1) and cannot reach the half-overflow range. NaN therefore needs `x0`/`x1`/`d` to be
non-finite, which means a non-finite `slope` or `intercept` at a fragment that gets rasterized.
**There is no OpFOrd/OpFUnord mismatch that matters for finite data.** `une` only differs from
`one` when `d` is NaN, and `d` is NaN only when the varyings already are.

## 3. Measured offline on Dozen (same ICD, same GPU)

- `tools/shaderlab/acc.comp` mirrors the FS op for op as compute.
  - Grid sweep: 22 slopes in [0, ±1e-9 … ±2e4], 6 curve x, 4 y-ranges, all 70×103 pixels.
    3 806 880 cases, **0 non-finite**, 0 mismatches against an IEEE CPU model.
  - Random sweep: slope ±10^U(−12, 8), arbitrary x, y-ranges 1e-4…100, 20 % integer x.
    4 000 000 cases, **0 non-finite**.
- `acc16.comp` checks the 16-bit tail: the VS `bcsel(±1.0h)` → f32 and the FS `f2f16(r)·f2f16(v)`.
  Both are exact.
- `gfx.c` runs the **real `vs.spv` + `fs.spv`** with a synthetic rounded rect (bindings 0/1 in the AIR
  layout, a 32-byte segment stride, header `{start=#segs, dt=bits(count)}`, P0 from record −1). It uses
  RG16F att1, One+One, mask G, clear 0, Y-flipped viewport, and indexed triangle lists of 13 quads per
  instance.
  - 8…800 segments, up to 1800 pieces / 139 instances, tilted and near-horizontal edges, maxX at the
    edge or mid-shape: **nan = 0** every time. The interior is −1 and the edges are anti-aliased.
  - A NaN or inf **x or y** in a segment does not give NaN: every point of that segment goes
    non-finite and Dozen drops the primitive.
  - **Indexed triangle strip with a 0xFFFF index after each quad, `primitiveRestartEnable = false`:
    nan ≈ 5 570.** The restart index becomes vertex 65535. It is culled to (−2,−2) with a `0/0` slope,
    and the strip makes fan triangles from it to the neighbouring quads, which interpolate NaN.
    With `primitiveRestartEnable = true`: nan = 0.

## 4. Where the NaN can come from

The NaN pattern sits per piece: pieces on the left of maxX and the top/bottom pieces are NaN, and
the slope-0 right edge stays finite. That pattern means bad varyings or bad primitives, not
arithmetic. Two candidates are left, and both are outside the fork:

1. **Primitive restart (Orchard).** `reims-vgpu-vulkan/src/topology.rs` says "Metal has no primitive
   restart" and hard-codes `primitive_restart_enable: false`. That is wrong for indexed draws. Metal
   cuts strips at `0xFFFF`/`0xFFFFFFFF` (the `drawIndexedPrimitives` documentation), and macOS 27 even
   carries `setPrimitiveRestartEnabled:index:` (opcode 0x91, manifest `Excluded`). Task 4 draws indexed
   strips (`prim=4`) from index buffer **ref 1 at +0x100 (n4) and +0x180 (n10)**. Those two offsets are
   0x80 apart, which is exactly 64 u16 = 13 quads × 4 + 12 restarts, the instancing stride of
   `exterior_vertex` (`idx = inst·13 + vid>>2`). This is consistent, but **not confirmed**. My synthetic
   footprint (5 570 NaN, spilling left of and below the shape) does not match the measured one
   (4 578, inside the shape), so the real index contents and order are needed.
2. **The VS gets different buffer data** (binding 0 `PathGlobals` 52 B, binding 1 segments, set with
   0x7d/0x7e). An exactly inside-the-shape NaN would also need a non-finite slope/intercept with a
   finite position. With IEEE math that cannot come from one segment record, so it would need a mixed
   primitive (corners of different pieces). That points back to the vertex/instance ids or the indices.

## 5. Measurement (one boot, tester + a ~30-line probe in Orchard)

On the first pipe-104/80 draw of the probed task, log `prim`, `index type/count/ref+offset`,
`baseVertex`, `instanceCount/baseInstance`, and dump the index bytes (128 B), VS binding 0 (52 B) and
binding 1 (`(count_records+1)·32` B) to `shots/`. Replay them through `tools/shaderlab/gfx.c` (replace
the synthetic path and indices with the dump; about 20 lines). The replay decides it:
- NaN with restart off and none with restart on → fix 1.
- NaN with both → the data is wrong at the source (binding/offset), not the shader.

## Fix (sized)

1. **Orchard, ~25 lines + a test, low risk (if the replay confirms strips with 0xFFFF):** in
   `topology.rs` set `primitive_restart_enable = true` for indexed draws of strip topologies (it is
   part of the pipeline key; a list ignores it, and VK 1.2 needs `primitiveTopologyListRestart` only
   for lists). Honour 0x91 if it ever arrives. Drop the module-doc claim. Non-indexed draws stay off.
2. **Fork: no change.** The `une`→`OpFUnordNotEqual`, `fdiv` and half lowerings are correct, and an
   "ordered" rewrite would only hide NaN that comes from upstream.
3. **Check:** `transient-s1-after-pipe104` `nan=[0,0]`, interior G = ±1, then ref 20/35 `nan=0`.
