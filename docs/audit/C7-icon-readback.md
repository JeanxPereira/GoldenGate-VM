# C7: the flattened icon is transparent to the guest's CPU

Symptom: `iconservicesagent` (pid 462) renders the icon chain correctly on the host. The guest still
logs `Flattened representation is seemingly a fully transparent image`, then `Central pixel is still
transparent even with retry`, then `Failed to generate flatten representation … NaturalStack` (20×
in `/tmp/ics4.txt`). The Dock keeps placeholders.

Sources: host log `/tmp/reims-vgpu-fail.log` (run from 09:18:50 local, t = ms). Orchard is at `9b29cf7`,
and paths are relative to `reims-vgpu/crates/reims-vgpu/src/`. Apple GPUTask comes from
`ParavirtualizedGraphicsGPUTask.c/`.

## 1. How the guest reads the flattened pixels

The flatten does **not** use a blit. In the whole boot there are 4 blit records, all from task 1 at
240×135 (`blitrec_copy_n=1`, `blit_rows_n=135`, lines 8752/46196/47180/48993). There is also no
`CmdSynchronizeResources`: op 0x35 (`model/regs.rs:509`) never appears in any `drain_ops` window.
Every flatten renders into a **fresh 128×128 `RGhA` IOSurface**, which is a mapper-ref texture:

```
mapper_desc_path mapping=25 … 128x128 bpr=1024 fmt=0x52476841 (RGhA = RGBA16F, 8 B/px) t=686649
pass_target task=4 mid=25 128x128 t=687906      ← first flatten
pass_target task=4 mid=26 128x128 t=699178      ← the "retry", a second fresh surface 11.3 s later
```

Task 4 is pid 462: `delete_task task=4` at 625467 and `define_task tid=4` at 626510 match the
relaunch at guest time 12:29:07. The pairs (25,26), (40,41), (48,49), … line up with the guest's
"transparent" → "retry" pairs. Guest 12:30:28.3 maps to about t = 687 s, using the guest clock against
the host clock (+66 s) and QEMU's start time. So the guest checks the pixels by **CPU-reading the
IOSurface** after the command buffer completes (IOSurfaceLock / CGImage over the surface; inferred,
because IconServices is not in the corpus). It sends nothing to the host first.

## 2. Ordering: the stamp retires and the pixels stay in the host image

For a mapper-ref-texture target, `runtime/draw/vulkan.rs:11809 surface_store_plan` picks
**`DeferCopy`** whenever the lazy rail is on (the default: `lazy_writeback on=true switch=Unset`,
t=204910) and the target is not guest-backed. It is never guest-backed here, because Dozen cannot
import guest RAM (`render_flush_gpu_declined reason=gpuwb_guest_ref_refused
via=guest_ram_map_no_backend_import`, 135×). `store_surface_resident` (:11819) then arms a debt
(`arm_surface_writeback_debt` :11905, `writeback_debt.rs:386`) and **returns without writing a byte**.
The module says so explicitly: "*Completion stamps alone do not publish resources*"
(`runtime/writeback_debt.rs:37`). The stamp path (`runtime/drain/mod.rs:3356 write_stamp` →
`drain/vulkan.rs:137 order_completion_stamp`) settles only *outstanding GPU copies*. An unpaid debt
has no copy submitted, so the stamp retires immediately.

The debt is paid only when:
- the guest names the object in `CmdSynchronizeResources` (`submit_for_resources` :1658), which this
  guest never does,
- a host reader names the mapping (`pay_for_mapping` :724),
- the 32-entry ledger evicts it (`MAX_DEBTS` :59),
- or `pay_all` runs.

Measured payment latency for the flatten surfaces:

| mid | rendered (t) | landed in guest pages (t) | delay |
|---|---|---|---|
| 25 | 687 906 | 777 592 | 90 s |
| 26 | 699 178 | 777 593 | 78 s |
| 40 | 740 405 | 777 582 | 37 s |
| 41 | 740 747 | 809 452 | 69 s |
| 81 | 797 781 | 863 277 (`wbdebt_paid_evicted=1` in that window) | 65 s |

Across the boot there are 623 arms, 421 superseded and only 170 Stores ever landed (86 evicted,
84 named). So the guest reads zero-filled IOSurface pages within about 1 s of completion: centre
pixel alpha = 0.

**Apple's host:** a `PGMapperRefTextureResource` is a host IOSurface over the guest's pages
(`PGResourceManager::createMapperRefTexture` @0x10004D788 → `retainIOSurfaceWithMappingID:`).
`isHostValid` @0x1000531B0 and `isGuestValid` @0x1000531B8 both return `true`, and
`synchronizeInEncoder:` @0x1000531A0 and `prepareInEncoder:` @0x10005319C are empty. The GPU writes
the guest memory itself, so command-buffer completion means the pixels are visible.
`-[PGBaseTask synchronizeResources:…]` @0x100027E2C acts only on resources that report `needsSync`.
The guest therefore has no reason to sync an IOSurface, and Orchard's "wait to be named" contract
can never be met for this path.

The hypothesis is confirmed: completion is signalled before the writeback. This is not a race
between threads. The write is a **deferred debt that nothing calls in**.

## 3. Pixel position and format

When a debt does get paid, the layout looks right. `store_render_frame` (`render_writeback/vulkan.rs:28`)
goes `read_target` → `into_bgra8` → `write_bgra8_owned` → `write_bgra8_inner`
(`mapping_write/mod.rs:724`). That path uses the mapping's own window and bpr
(`mapper_ref_texture_sample_window`, bpr 1024) and converts each row with
`Rgba8ToRow::Rgba16Float` (8 B/px, `reims-vgpu-protocol/src/pixel_format.rs:3793`). There is no row
pitch or RGBA/BGRA mismatch (**inferred**: the landed bytes were not probed). The one defect is
smaller: the copy path quantizes RGBA16F through 8-bit BGRA. That costs precision and HDR, but alpha
survives, so it cannot cause this symptom.

## 4. Fix (sized)

1. **Experiment, 0 lines:** boot with `REIMS_VGPU_LAZY_WRITEBACK=off` (`reims-vgpu-config/src/lib.rs:538`).
   This selects `CopyNow`, where the Store lands synchronously in the draw path before the stamp. If
   the Dock icons appear, the cause is proven. The code comment estimates the cost at about 45 %
   slower surface Stores.
2. **Real fix (P0, about 40-60 lines, medium risk):** pay surface debts before the completion stamp
   that covers them, which is Apple's "completion ⇒ visible" rule. Tag each `WritebackDebt` with the
   arming task (and seq). In `write_stamp` (`drain/mod.rs:3356`, where `state` is `&mut`), before
   `order_completion_stamp`, pay the debts of the stamping task armed up to this point. Debts still
   coalesce within one command buffer. To keep the compositor cheap, exempt mappings that are present
   targets (display buffers already settle through the scanout path). A simpler variant (about 15
   lines) pays every surface debt at every stamp and measures `wbdebt_pay_us`.
3. Optional (about 30 lines): land RGBA16F surfaces without the 8-bit detour (`read_target` native
   texel → `Rgba16Float` row copy).

## 5. Open questions

- Which reader paid 6 debts by name at t≈777.6 s (Dock/WindowServer sampling the surfaces?). If Dock
  samples the IOSurface on the GPU it gets the right pixels. The failure is only in iconservicesagent's
  CPU check, and it then discards the icon.
- After fix 2, check `wbdebt_paid_*` against `surface_flush` and the guest count of "fully transparent"
  (should be 0).
