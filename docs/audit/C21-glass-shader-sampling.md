# C21 — How the Liquid Glass shader reads its blur pyramid (26A428)

Source: guest RE, 31/10. Evidence in `<RE corpus>/qc-metallib/` (disassembled `.ll`,
`mlib.py` extractor, QuartzCore pseudo-C). Shaders: guest
`QuartzCore.framework/Versions/A/Resources/default.metallib`, AIR slice of 240 functions;
`glass_background_cr_lph` there has the same body and sampler states as the host-captured `pipe133` AIR.

## 1. Sampling of the source

- `source_texture` (texture 3) is read only with `sample(..., level(x))` (no `read`/`bias`/`gradient`), through
  the **constexpr** sampler `state.4` = `0x7bff0000084a49`: linear min/mag, **mipFilter linear**,
  clamp-to-edge, lod clamp [0, 65504].
- Four lod sites: `lod = max(0, log2(r < 2 ? r/2 + 1 : r))`, r = `u.blur_radius` (fragment buffer 1, offset 40)
  × per-pixel edge falloff (`blur_alpha0..3`, `blur_dist0..3`). One extra tap at lod 0 for the highlight composite.
- `sdf_texture` (texture 4): constexpr `state.1` (linear, mip nearest), implicit lod (bias 0).

## 2. Samplers

- QuartzCore creates no sampler for this shader; both are compile-time constants in the AIR.
- The pass still calls `bind_surface(src, unit 0, filter 0, 0)`; `MetalContext::get_sampler` @0x18B23477C builds
  that runtime sampler with mipFilter **NotMipmapped** unless the filter code is 2 or 7. That is the sampler the
  host sees bound (`smpl=...:gNNnee`).
- The shader never references the runtime sampler: its SPIR-V uses Bindings 160/161 (the static samplers). The host
  must use those (`sampler_origin 'c'`) and ignore the runtime bind.
- **Inferred:** CA puts the runtime sampler at index 3; if Orchard maps it onto binding 160/161, first-writer-wins in
  `runtime/draw/vulkan.rs` replaces the mip-linear constexpr sampler → every lod clamps to level 0. This matches
  b2e72c5 and cfb27eb rendering the Dock pixel-identical.

## 3. Metal semantics

Apple's documentation: NotMipmapped reads level 0 only and `level()` is clamped to it (documentation, not binary
evidence). Irrelevant here, because the draw uses the constexpr mip-linear sampler.

## 4. Where the blur lives

- `prepare_blur_mipmap` @0x18B3516EC → `MetalContext::create_variable_blur_mip_surface` @0x18B249294.
- Level count, `compute_variable_blur_parameters` @0x18B10CCD0:
  `min(⌊log2 max(w,h)⌋+1, ⌈log2(1.6·r_max)⌉+1 (≥2), 6 or 7)`.
- 20×20 kernel = `variable_blur_copy_base_mip_compute` (imageblock 32×32, threadgroups `ceil(dst_0_size/32)`):
  reads `textureIn` level 0 with point reads; writes a raw 32×32 copy at `dst_1_level-1` and a 2×2-average +
  13-tap blur (0.105/0.090/0.077/0.056) 16×16 tile at `dst_1_level`. With `no_base_mip` (min level ≥ 1) the surface
  is half-res, the base copy is skipped and level 0 is already the downsampled blur.
- 16×16 kernel = `variable_blur_downsample_compute_agx2` (16×32 per threadgroup): textures 0 and 1 are the same
  pyramid; samples level L-1, writes level L, for L up to levels-1.
- So level 0 is sharp or lightly softened; **the real blur is in levels ≥ 1** and the plate depends on them.
- With QuartzCore defaults (blur-radius key 0x174 = 30 × 1.6 × scale) the shader would want lod ≈ 4–5.6;
  **inferred**: the real radius is a runtime value. An 832×64 pyramid with `levels=2` caps lod at 1 — verify that
  texture is really the Dock source.

## 5. Rest of the shader

SDF `.x` distance, `.yz` normal (via `displacement_mat`), `.w` coverage; inner/outer refraction (lens offset along
the normal near the rim: `inner/outer_refraction_amount`, `inv_height`, `refraction_threshold0/1`); optional
blur-fill taps; face colour matrix (`face_cm0..2`, saturation/tint); outer and ring shadows from offset SDF samples;
key-fill specular rim (`key_fill_highlight_*`); `holding_tone`, `clamp_limit`, output × `edr_scale`.

## Fix (ranked)

1. Host: constexpr samplers win over the runtime sampler bind for bindings the shader declares as static
   (`sampler_origin 'c'`); never let a guest runtime sampler overwrite a constexpr binding.
2. Census: log fragment buffer 1 offset 40 (`blur_radius`) and the mip count of texture 3 for the glass draw.

## Open

Dock's actual `u.blur_radius`, the pyramid's mip count, `Renderer+796/+800`.
