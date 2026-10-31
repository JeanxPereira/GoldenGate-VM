# D4: the first icon shape pass (task 5, pass 204)

Run: Orchard `eadb240`, Dozen (kisak Mesa 26.2.5, RX 6750 XT), host log `/tmp/reims-vgpu-fail.log`
lines 10449–10485. Dump: `shots/icons/00000-t5-p204-pipe32-ref20-after_pass-56x90-R16Float-m0x19.ppm`.
SPIR-V: the modules are content-hashed, so the hashes in `pipeline_create_*` lines match
`~/gg/run/gg27/spirv-dump-02c9b85/mod-<hash>.spv`.

## What pass 204 is

One render pass, 56×90, with three colour attachments: s0 = ref 20 R16F (heap-placed), s1 = ref 21
RG16F (memoryless), s2 = ref 22 RGBA16F (memoryless). It runs three draws:

| Draw | Pipe | VS / FS module | What it does (from the SPIR-V) | Masks (Metal bits) |
|---|---|---|---|---|
| 1 | 27 | `2d64eed7…` / `1610f74c…` | "plane" quad: `pos = M·(u,v) + t`, with M = `float[3][2]` at buffer 0 offset 0 and depth at offset 24. Writes s0 = `color.a`. | s0 0xF, s1 0 |
| 2 | 30 | `9e3b88c0…` (1876 w) / `762a2fbb…` | Analytic-coverage path rasterizer, explained below. Writes `half2(0, cov·sign)` to s1. | s1 0x4 (G) |
| 3 | 32 | `2d64eed7…` / `fe0e63b4…` | Plane quad. Reads s1 by framebuffer fetch (`InputAttachmentIndex 1`) and applies the **even-odd** rule: `f = fract(|acc|)`, `cov = (floor even) ? f : 1-f`. Writes s0 = `color.a·cov` and s1.G = 0. | s0 0xF, s1 0x4 |

Stream census for the window (`render_ops`, t=698834): `r0x09=3` (drawIndexed…instanceCount, the
16-byte form), `r0x7d=2 r0x7e=2` (setVertexBuffers / setVertexBufferOffset), `r0x6e=1 r0x6f=2`,
`r0x68=4 r0x77=3` (depth-stencil state and stencil ref; there is no depth attachment, so they do
nothing), and **no 0x82/0x75**: no setViewport and no scissor.

### Pipe 30's vertex shader (`9e3b88c0`)

- There are **no vertex attributes**. The shader pulls everything from two storage buffers through
  `vertex_id` and `instance_id`. Binding 0 holds uniforms
  `{float m[3][2]; float2 scale@24; float2 @32; float depth@40; float maxX@44; float @48}`. Binding 1
  is a segment array with a 32-byte stride, `{uint start; float dt; float2 p1,p2,p3}`, and record 0
  is a header that holds the count.
- `idx = instance·13 + (vid>>2)`, `corner = vid&3`. The shader binary-searches the segment
  (`OpLoopMerge` over a 64-bit index with emulated carry). It loads P0 from the **previous** record
  (`OpPtrAccessChain %seg -1 member 4`) and evaluates the cubic at `t0 = dt·k` and `t1 = dt·(k+1)`.
- Corners 0 and 3 sit at `x = min(B(t0).x, B(t1).x) − 0.5`. **Corners 1 and 2 sit at
  `x = maxX + 0.5`, taken from the uniform.** By design every sub-segment draws a trapezoid that
  runs from the curve to the right edge of the path's bounds. The fragment shader then adds the
  signed area to the right of the line. A pixel inside the shape ends up at ±1 and a pixel outside
  at 0. `x_ndc = x·scale.x − 1`, `y_ndc = 1 − y·scale.y`.
- A segment with |dy| ≤ 1e-4, or a P1.x that is inf/NaN, goes to `(−2,−2,0,1)`.

**So the slivers at x ≈ 50–55 are not collapsed vertices.** All the trapezoid geometry ends at
`maxX+0.5` on purpose. They are the place where the signed contributions failed to cancel.

## What the dump says (decoded from the PPM)

- Columns 55 and every row outside 15–75 are 0.
- Column 54 holds **0.70** (179/255) steadily over rows 23–73 and tapers at both ends (rows 15–19:
  2, 90, 112; rows 66–73: 173 → 35). That is the anti-aliased right outline of a rounded shape.
- Columns 50–53 are **1.0** in small notch triangles (rows 19, 25–26, 30–32, 36–40, 42–44, 57–58,
  60–61, 64–66, 70–72).
- Everything left of x≈50 is 0 at 8 bits. The probe still says `nz=4702/5040`
  (`range 0..1`). Those 4 600 texels are either < 1/510, or **NaN**: `placed_probe.rs`
  `stats()` counts `NaN != 0` as non-zero, `f32::min`/`max` skip NaN, and `to_unorm8(NaN)=0`. The
  probe cannot tell the two apart.
- A correct even-odd fill would have the interior at ≈1. What we see is the right outline only, so
  **the contributions from one side of the contour (the left edges) are missing, ≈0, or NaN**,
  while the right-side ones arrive with sane coverage.

## Ruled out (with evidence)

| Suspect | Verdict |
|---|---|
| Vertex-descriptor formats (half2/short2n/packed), attribute offset/stride | **n/a.** Neither VS has an `Input` other than VertexIndex/InstanceIndex. The `stage_in` path is not involved. |
| Viewport / renderTargetWidth/Height | No setViewport in the pass. Orchard defaults to `req.width×req.height` = 56×90, Y-flipped (`backend/vulkan/engine/exec.rs:5378-5411`). The pass has attachments, so rtW/H is irrelevant. OK. |
| Half4 prefix reinterpret (fork `07e981d`) | Not present in these four modules. Every buffer load is a scalar `float`/`half`/`uint`. |
| Colour write-mask bit order | Metal→Vk is bit-reversed correctly (`reims-vgpu-vulkan/src/blend.rs:120-140`). |
| Blend tag identity | Tags 1..9 = pixelFormat, blendingEnabled, srcRGB, dstRGB, rgbOp, srcA, dstA, aOp, writeMask, confirmed in `Metal.i64` `deserializeColorAttachments` @0x18D58A0EC. These match `runtime/decode/resource/mod.rs:1325-1342`. An additive slot-1 shape `[00,01,02,04,07,09]` is seen at t=689781. |
| Memoryless s1 lost between draws | Records 2+ force Load (`runtime/exec/mod.rs:5262-5269`). Secondaries take LOAD and always STORE (`engine/caches.rs:2179-2196`; `runtime/draw/vulkan.rs:7180-7192`). The input-attachment array puts index 1 at attachment 1, with a BY_REGION self-dependency (`caches.rs:2274-2318`). OK. |
| Fragment-buffer layout | `color` half[4] sits at +28 (pipe 27) and +36 (pipe 32), from AIR array types (align 2). This is plausible, but the bytes are **unverified** (no buffer dump). |

## Most likely cause (inferred, not yet measured)

**Pipe 30's VS needs `VariablePointersStorageBuffer` (plus `Int64`), and its half varying needs
`StorageInputOutput16`. Dozen supports neither, and Orchard never enables either feature.**

- `vulkaninfo` on the kisak Dozen ICD reports `variablePointersStorageBuffer = false`,
  `variablePointers = false` and `storageInputOutput16 = false` (`shaderFloat16`/`shaderInt16` are
  true).
- The module declares `OpCapability VariablePointersStorageBuffer`. It uses an `OpPhi` of SSBO
  element pointers (the result of the binary search, `%149`) and `OpPtrAccessChain %149 -1` (the
  previous record's endpoint P0). The vertex output `Location 3` is `half` (the ±1 winding sign),
  and the module does not declare `StorageInputOutput16`.
- Orchard neither queries nor enables `variablePointers*` or `storageInputOutput16`
  (`backend/vulkan/caps/device_features.rs:663-666` enables only `storageBuffer16BitAccess`). The
  only gate is `spirv-val` (`runtime/spirv_bind.rs:819`), which accepted the module
  (`mod-9e3b….val.txt`). That makes this undefined behaviour on **every** driver, and on Dozen the
  feature does not exist at all.
- It is rare: only **9 of 356** modules in `spirv-dump-02c9b85` declare
  `VariablePointersStorageBuffer`. The icon path rasterizer is one of them, and WindowServer's
  shaders are not. That fits "the desktop draws, the icon masks do not".
- How it fails, **inferred**: a wrong segment pointer or a wrong P0 gives one side of the contour
  bad points or a bad sign. Its trapezoids then add ≈0 (or NaN). Only the right-side
  contributions survive the even-odd resolve, which matches the dump exactly.

Second candidate (lower): the `half` sign varying without `StorageInputOutput16`. Half varyings
are common in CoreAnimation shaders that do render, so this is less likely to be the cause on its
own.

## Fix (sized)

1. **Fork (metal2vulkan), about 120–180 lines, medium risk.** Extend
   `src/spirv_variable_ptr.rs` (today it lowers only `AccessChain`→`PtrAccessChain` with a zero
   base, lines 19–40). When every incoming value of a pointer `OpPhi` is an `AccessChain` into the
   same root with the same prefix, phi the **element index** (u32/u64) instead. Rewrite
   `PtrAccessChain(phi, k)` as `AccessChain(root, …, idx+k, …)`. Then drop
   `VariablePointersStorageBuffer` when nothing else needs it. Add a unit test shaped like
   `9e3b88c0`.
2. **Orchard, about 30 lines, low risk.** Query `variablePointersStorageBuffer` and
   `storageInputOutput16`, and enable them when present. In `spirv_bind`, decline a module that
   declares a capability the device lacks (`draw_prepare_capability_unsupported`) instead of
   running UB. Also make the fork either declare `StorageInputOutput16`, or widen 16-bit varyings
   to 32-bit (fork, about 60 lines) when the device lacks it.
3. **Before porting, measure (tester, one boot):** make `placed_probe` count NaN/inf separately
   (about 5 lines in `placed_probe.rs::stats`), and dump binding 0/1 of pipe 30's draw. Then compare
   one icon on a build with fix 1.

## Also seen (separate fault)

Pass 206 (pipe 57 places ref 35, 56×90, into ref 51, 114×148) writes **nothing** (`nz=0/16872`),
even though ref 35's alpha has 4587 non-zero texels up to 1.0. Even a perfect mask from pass 204
would die there. It needs its own look: pipe 57's plane matrix and UVs.

## Open questions
- Is the interior of ref 20 NaN or tiny? This needs the probe change in fix 3.
- Does Dozen's spirv_to_dxil actually miscompile the pointer phi or the `-1` PtrAccessChain, or is
  the `half` I/O the culprit? Fix 1 plus fix 3 answer both in one boot.
