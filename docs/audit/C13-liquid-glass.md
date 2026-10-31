# C13: Liquid Glass missing or flat (Orchard 28f9823)

Read-only diagnosis. Live log `/tmp/reims-vgpu-fail.log` (134k lines, t up to ~4 639 s), VM untouched
(no `REIMS_VGPU_*` env on QEMU pid 112001, so there is no per-draw trace). Shots: `dzn-28f9823-8*.png`
(flat grey Quit/Continue with a ghost square, transparent Dock with a sharp wallpaper),
`dzn-89e87cc-15.png` (flat dark widgets, flat grey alert), `dzn-b3e58a4-8.png` (earlier glass alert).
Shader identity comes from the 363-AIR corpus `~/gg/run/gg27/spirv-dump-02c9b85`, matched by AIR size
(`linux_m2v_async queued … air=`) and by SPIR-V word count (`fw=` in the hold trails). The corpus was
re-translated with the current fork (`23f192a`) into `/tmp/c13/`.

## Who is who (this run)

| Pipe (task) | Shader | Evidence |
|---|---|---|
| 2 (task 1, WindowServer) | `A2Xghfc`, the CoreAnimation UberShader (vibrancy, color programs, `sdf_glass_*`, `box_sample_*`, `mipmapped_box_sample`) | fw=220444 = 220 444 words of the retranslation |
| 111 (task 1) | `glass_background_sdf_cr_lph` (1 texture `source_texture`, explicit-LOD samples) | air=21772, fw=26503 |
| 228 (task 1) | `glass_background_cr_lph` (source + `sdf_texture`) / `variable_blur_vert_lph` | air=17104/4004 |
| 93 (task 15) | `inplace_copy_lph` (backdrop snapshot to storage texture) | air=3544 |
| 91/442, 106/206, 44/27, 430/258 (task 4) | CA blur kernels F11, D2F6, F7, U2P3F3 (H/V) | air 5284/4860/5032/5276 |

All of these translate (0 failures) and run. Nothing in the glass chain is refused. What is wrong is
what the shaders compute.

## Ranked causes

### 1. UberShader `A2Xghfc` reads zero for every constant-buffer helper argument (P0, high confidence)

`METAL2VULKAN_UNMODELED_WHY=1` on `A2Xghfc` gives 28 `site=constant_call_cursor … kept=false`:
`apply_color_opcode_noinline` (22 call sites, offsets 112, 224, 336, 448, 560 …),
`vibrant_color_matrix` (2), `vibrant_color_matrix_sover` (2), and
`backdrop_aware_vibrant_color_matrix_sover` (2). When a constant-buffer helper has more than one call
site, the fork binds its parameter to the Private zero placeholder. The result is **2408
`OpCopyObject %uint %null`** in the module. The same count is in NOTES 30/10 03h, so it is unchanged
since then.

The effect: every color program, including saturation, tint and the vibrancy and backdrop-aware color
matrices, multiplies by a zero matrix. The material comes out flat: dark or grey, or zero. That is
the vibrancy/glass look missing on widgets, buttons and alerts. Log: the task-1 glass chain at
832×64 RGBA16F has `m2v_store_gva … pipe=2 tex_ref=101 load=2 rgb_nz=0` and `pipe=84 … rgb_nz=0` (×2),
and the next sample of it is `lin_rung_guest_blank` with `host_blank=1`, so the blank is real and not
lost on the way. The b3e58a4 alert looked right because that alert's glass went through
`glass_background_*` (fixed by `23f192a`), not through the UberShader's color programs (**inferred**).

**Fix (fork `src/native/emitter/body/calls.rs:742–782`, `raw_device_call_arg_id`).** Today a
constant-buffer helper that is called at more than one offset gets the zero placeholder. Instead,
give the helper an extra `uint` byte-cursor parameter that is added to its raw word index, and pass
`raw.const_off` from each call site. Another option is to clone the helper once per distinct offset,
since there are only 5–12 offsets. Size: ~100–150 lines plus a unit test (a helper called at 2
offsets, each loading its own float4). Risk: medium, because this touches every raw helper
signature. Gate the change to addrspace 2. Check: the `A2Xghfc` retranslation has 0 null copies, the
363-AIR corpus still validates, and on boot the 832×64 stores have rgb_nz>0.

### 2. Glass RGBA16F targets are seeded through RGBA8 (P1, medium)

`sampled_texture_narrowed reason=settle_linear_texture_seed fmt=0x73` fires for **1920×128** (the Dock
backdrop, ref 157), **1600×128** (the Dock glass layer), 832×64, 192×128 and 800×632. Every Load of
these glass layers clamps them to [0,1] and to 256 levels. That destroys the EDR highlights and the
signed values that `edr_scale`/`sdr_white_value` rely on. The site is
`runtime/render_writeback/mod.rs:654` (`LinearTextureSeed`), which feeds `seed_color_load`
(`runtime/draw/mod.rs:3769`).

**Fix.** Seed fmt 0x73 as native `R16G16B16A16_SFLOAT`, the same way `sampled_r16f_native` and the
unorm16 path already work. Size: ~40 lines. Risk: low.

### 3. Backdrop read from guest bytes, not the resident (P1, the ghost square)

The Dock glass draw is `pipe=111 1600x128 smp=[b707:b:f97:1920x128]`, which means route=bytes. This
run has 601 samples with route=bytes and 4263 with route=target. The GPU writeback of ref 157 is
refused (`gva_flush_gpu_declined reason=gvawb_guest_ref_refused via=guest_ram_map_no_backend_import`,
7 in the run), so the backdrop reaches the glass shader through the CPU copy. That copy can be one
frame stale, which is the D2 mechanism, and it would explain the offset square beside Continue
(**inferred**: there is no per-draw order in the log). Before reading ref 157, its first use is
`lin_rung_guest_blank` (t=883 659 s).

**Fix.** Prefer the resident (`try_gva_resident_sample`, `runtime/draw/vulkan.rs`, D2 §2b) for
memoryless-free task-1 RGBA16F snapshots that the same channel just stored. Size: ~30 lines. Risk:
medium, the same guard as D2.

### Not causes (checked)

- `frag_declared_descriptor_unbound` / `frag_neutral_texture_substituted` (3105 each; this is the
  top slug). These are all `tex1` with `provided_tex={0}`, on RenderBox pipes in task 4/15 (8, 38,
  229, 116 …; AIR 3688/5524/4848). None of them are glass pipes (2/111/228 have 0 of these). The
  shader's optional second texture is not bound, and a zero 1×1 texture is what Metal gives there
  too (`runtime/draw/vulkan.rs:8180`, `:8850`). Impact ≈ 0.
- `read_target_texel_not_four_bytes` (631) and `gpuwb_guest_ref_refused`/`GuestRefRefused` (596).
  These are CPU fallbacks for RGBA16F writeback. They cost time but are not visual (they feed cause 3).
- Mips. The draw path binds level 0 only (`runtime/draw/texture_view.rs:800`). The glass shaders sample
  with an explicit LOD, but every heap texture in this run is `mips=1` (1025/1025), so the result is
  the same as Apple's. The one exception is the 5-mip RGBA16Unorm 128×128 menu-bar texture (C10),
  which only loses its LOD>0 levels. That costs a little highlight quality.
- Blur compute kernels (task 4). They translate, and they dispatch with Rgba16Float storage. No
  declines.

## Open questions

- Which UberShader color program the Dock and widget materials actually hit. A one-boot
  `REIMS_VGPU_DRAW_TRACE=1` with the store probe on task 1 would settle it after fix 1.
- Whether fix 1 alone also removes the ghost square, which would mean cause 3 is only latent.
