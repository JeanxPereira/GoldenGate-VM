# D2: Liquid-Glass alert ghosting (Orchard 50c3331)

Symptom (`shots/dzn-50c3331-45min.png`): a "Your computer was restarted…" alert. The glass panel is
correct: it is translucent, blurred and has rounded corners. Behind the sharp content, a second copy of
the whole alert is visible inside the glass: icon, title, body text and both buttons, blurred.
Measured on the shot, the copy is a **pure translation of (+22, −29) px** (right and up), with no
scale: title 852,313 → 874,284; "Ignore" 901,439 → 923,410; "Report…" 1018 → 1040. The copy is
clipped to the panel.

Log: WSL `/tmp/reims-vgpu-fail.50c3331.log` (65 682 lines, t = ms). Orchard tree: `gg-macos27`, paths
are relative to `reims-vgpu/crates/reims-vgpu/src/`. The default log carries no per-draw trace.
Everything below comes from the `TRANSPORT sync_exec_lock_hold_trail` ring (the last 12 draws),
latched `first_sight` lines, and the per-second `store_routes` census. Anything drawn from those
indirectly is marked **inferred**.

## 1. What the frames do around the alert (t ≈ 2 491–2 502 s)

The alert opens with an animation that runs at about 1–2 frames/s, because each command buffer holds
the exec lock for 330–740 ms. Each animation step allocates a larger set of task-1 textures (fmt 0x73
RGBA16F, `gva_view_fragmented … map_fresh_span_within`): 64² → 128² → 192² → 192×256 → 256² → 320²/384².
The last step is at about t = 2 501.5 s. After that only the clock redraws (`p107` samples 126×16),
and the 320×320 glass result is reused as it is. **So whatever was baked at the last step is
frozen on screen.**

The draw chain per frame, reconstructed from the trails (target @ size, sampled sources; `t:` = engine
resident, `b:` = guest bytes):

| Step | Pipe | Target | Reads | Meaning (**inferred**) |
|---|---|---|---|---|
| capture | **152** | 64²…192²…(320²) | **display surface mid 5 / mid 3** (`sampled_full_screen_consumer pipe=152 ref=73 src_mid=5 … target=64x64 route=target t=2491617`; `ref=46 src_mid=3 … target=192x192 route=target t=2494368`) | backdrop snapshot: the region under the alert, read out of the drawable being composed |
| content | 269, 187 | 320² | glyph and label textures 52×19, 39×19, 239×46, 252×65 (`b:`) | alert text and buttons drawn offscreen |
| glass | 49 → **11** (fw=219 260, 26 frag decls) → 170 | 320² / 384² | `320x320`, **`b:` in one frame (t=2500161) and `t:` in the next (t=2500792)**, same bind | blur, glass and lens |
| composite | 150 (animating), 106/138 (steady state; `color_input_mrt mask=0x03 pipe=106 colors=2`) | 1920×1080 | `t:320x320` (and 384²) | glass result composited onto the frame, with framebuffer fetch of dest0/dest1 |
| flush | 51 | 1920×1080 | `b32:t:1920x1080` | copy to the display buffer |

The display is double-buffered. `present_content` alternates mid 5 and mid 3 (gen 72/74/77).
Capture always samples **the buffer being composed**: at t=2494368 it reads mid 3, and the next
present is mid 3 at t=2494461.

**Blits play no part.** In the whole boot there are 4 blit records, all texture→buffer
(`blitrec_copy_n=1`, `blit_kind_t2b`, at lines 9598/43061/44002/45802), and none near the alert. The
backdrop is a render-pass snapshot (pipe 152 sampling the drawable), not `copyFromTexture`.
Reordered or deferred blits are therefore ruled out.

## 2. Where Orchard can hand a pass newer or older pixels than the guest's order implies

**(a) Display-surface LOAD seeded from bytes, not from the live image. This is the prime suspect.**
During the alert, the composite pass on mid 3 was opened with `LoadAction.Load` and a **CPU byte seed**
twice, not with the resident:

```
compositor_plane_pass mid=3 1920x1080 pipe=114 load=0x1 … seed=served door=mapping t=2493107
compositor_plane_pass mid=3 1920x1080 pipe=129 load=0x1 … seed=served door=mapping t=2501568   ← last animation step
```

The census for that window agrees: `mapper_ref_texture_seed_provided`=2 and `load_seed_ok_mapping`=2,
against `mapper_ref_texture_seed_elided`=39. The seed is `MapperRefTextureLoadSeed::Host(bytes)` from
the mapping door (`runtime/draw/vulkan.rs:~9110–9160`; door doc at :6160–6191). Those bytes are what the
last writeback of mid 3 published. With double buffering that is **frame N−2, which already contains
the alert at its position two animation steps earlier**.

If that seeded LOAD opens any pass on mid 3 after this frame's lower layers were drawn, it puts the
N−2 image back in place. That includes the old alert. Pipe 152 then snapshots the region, and the
glass blurs the alert's own earlier picture. The (+22, −29) offset is then the alert's displacement
across those steps (**inferred**: the per-draw order that would prove the seeded pass precedes
pipe 152 in the same frame is not logged). The second seeded pass falls exactly on the last animation
step, the one whose result stays frozen.

**(b) GVA residents refused on a dirty-bitmap "guest wrote" verdict, followed by a fallback read of guest pages.**
`gvaw_guest_wrote`=**38 for the whole boot, and all 38 fall in this window**. They equal
`gvadebt_armed`=38 and `gvaw_armed`=38 one for one: every Store armed during the animation was refused
on its next read. That moves the reader off the resident and onto guest pages:
- sampled: `try_gva_resident_sample` (`runtime/draw/vulkan.rs:4863`) → `gva_resident_if_current` :4705 →
  `gva_store_witness::reach` (`runtime/gva_store_witness.rs:340`), then the linear loader reads guest
  bytes (memo :5818);
- LOAD: `seed_color_load` (`runtime/draw/mod.rs:3618`, `gvaseed_not_quiet`=12 in the window).

The visible result is the route flip on the glass chain's 320² bind (`b:` and then `t:` in consecutive
identical frames). Another result is `lin_rung_guest_blank`=3 269 out of `lin_rung_guest_memo`=3 768
(87 %): the guest pages behind most of these textures are zero or older than the resident. Debts
are mostly superseded and never paid (`gvadebt_superseded` 30, `gvadebt_paid_named` 5). The fresh
mappings (`map_fresh_span_within`) make a guest-side zero-fill or remap after the Store plausible.
That is a write which, on Apple, never moves pixels into the texture (see section 3).

**(c) Things that are not involved.** Orchard does not defer or reorder blits, and none are present.
The linear memo cannot serve stale bytes, because it re-reads and memcmps on every bind
(`vulkan.rs:5818`). Segment order is not disturbed (`seg_chain_none` only).

## 3. Apple's host: strictly in order, with no second copy of the pixels

- `-[_PGDeserializer decodeSegments:into:]` @0x100029764 walks the segments in order into **one**
  command buffer (`into:`), calling `decodeSegmentWithHeader…` @0x1000292B0 for each. Render, compute
  and blit encoders are created and ended in sequence. The blit decoder @0x1000033D8 runs its copies
  inline, in that order. Metal's hazard tracking orders a sample of the drawable after the earlier
  encoder's Store.
- A display or IOSurface texture is `PGMapperRefTextureResource`. Its `prepareInEncoder:` @0x10005319C
  is **empty**: no page-in and no seed. A LOAD therefore always loads the live texture, which holds
  everything earlier in the command buffer.
- Normal textures (`PGSinglePlaneTextureResource` @0x100051E54 / @0x100051F38) page guest→host
  **only when `!_hostValid`**, which is set by the guest's explicit invalidate (`clear_host_valid`).
  They page host→guest only on synchronize. A guest write the hypervisor sees but the guest never
  declared does not change what the GPU samples.

## Conclusion

Most likely cause: on the last animation step, a LOAD pass on the display buffer (mid 3, pipe 129) was
seeded from the **mapping byte cache**, which holds the N−2 frame that still contains the alert, and
not from the live resident. The backdrop capture (pipe 152) then snapshotted that stale region. Apple
has no seed rail for mapper-ref surfaces, so this cannot happen there. Contributing cause: GVA residents
are dropped on a dirty-bitmap verdict alone, which sends the glass chain to older guest pages (route
flip b/t).

## Change list (sized)

1. **Trace first** (~60 lines, no risk). Add a per-draw line for one task behind an env gate: target
   (mid/gva/ref, content epoch), load action, seed door and seed source epoch, and each sampled
   ref → route/identity/epoch. Log every `seed=served` on a mapper-ref surface with its position in
   the command buffer (today it is `first_sight`-latched, `vulkan.rs:15131`). This proves or refutes
   (a) in one run.
2. **Mapper-ref LOAD never seeds over a live resident** (~40–60 lines, medium risk). If the surface's
   resident exists and its content epoch is at or after the seed's source, LOAD from the resident.
   Use bytes only when the guest *declared* a CPU write (`buffer_write_gen`, the `_hostValid` analogue),
   and then only for the written pages. Site: `vulkan.rs:~9110–9160` plus the mapping-door seed helper.
3. **GVA readers trust the resident unless the guest declared a write** (~30 lines, medium risk).
   In `gva_resident_if_current` (:4705) and `seed_color_load` (mod.rs:3618), use `GuestWriteVerdict::Wrote`
   from the dirty bitmap only to drive a page-merge (`pay_gva` merge rail, `writeback_debt.rs:1825`),
   not to drop the resident in favour of older guest bytes.
4. **Retest**: the alert scenario, with `compositor_plane_pass seed=served` mid-frame = 0,
   `gvaw_guest_wrote` → 0 or merged, no b/t flip on the 320² bind, and a screenshot with no ghost.

## Open questions

- Does the seeded mid-3 pass at t=2501568 precede pipe 152 within the same frame? The trace in item 1
  answers this.
- Who wrote the 38 "guest wrote" pages: a guest zero-fill on fresh mappings, or this device's own
  writes reaching `DIRTY_MEMORY_VGA` through a dirtying path?
