# C9: `released_write_after_release` — the burst at 33 min is a false positive

Question: after `a61708e`, the `released_write_after_release` count went from 30 to 67, and all 67 came in
one burst at t≈1979 s. Is the host writing into guest pages that are already freed? Did the stamp-time
debt payment cause it?

Sources: current log `/tmp/reims-vgpu-fail.log` (a61708e), previous log
`~/gg/run/gg27/logs/reims-vgpu-fail.9b29cf7-final.log`. Paths are relative to
`reims-vgpu/crates/reims-vgpu/src/` at `a61708e`.

## 1. What the slug means

- **Arm:** `runtime/drain/mod.rs:5457 note_released_or_remapped` is called only from the task
  `MapMemory`/`UnmapMemory` audit (`drain/mod.rs:5694`). On an **UnmapMemory**, every guest page of the
  task GVA range is armed (`host_writes.rs:558 release_page`, which stores the current write epoch).
- **Disarm:** only a later task **MapMemory** that covers the page (`host_writes.rs:563 remap_page`).
- **Fire:** any host write that names its pages (`note_pages`/`note_footprint`/`note_mapping`) and lands
  on an armed page. It is queued, then `runtime/released_pages.rs:84 sweep` reports it once and disarms
  the page. The report queue holds 64 entries. Anything beyond that only increments `dropped`.

The module's own doc lists the blind spot (`released_pages.rs:56-71`): "a page mapped by a route this
guard does not see". The IOSurface mapper is one of those routes. When the guest builds a new
IOSurface out of pages it unmapped earlier, the guard never disarms them, so the first legitimate
write to that surface reads as a finding.

## 2. What happened at t = 1979 s

```
mapper_desc_path mapping=226 pages=4321 indirect=1 4096x2160 bpr=32768 fmt=RGhA alloc=70778944   t=1975602
mapping_gpa_span mid=226 gen=1 pages=4321 src=mapper prev_pages=0 changed=1
                 lo=0x70a48000 hi=0x1ef484000                                                       t=1975602
ycbcr_2p_staged 4096x2160 mapping=225 (Aerial video frame)                                          t=1975869
compute_dst_mapper_ref_texture bind=481 mid=226 4096x2160 RGBA16F reason=GuestRefRefused{NoBackendImport}
mapping_write full_tight_direct mid=226 bytes=70778880 ; mapping_write_runs mid=226 pages=4321       t=1979054
TRANSPORT sync_exec_lock_hold ch=1 total_us=3458694 (one op 0x37, one compute, 3.46 s)              t=1979085
released_pages ... gpa=0x1c911c000 released_at=35032 wrote_at=45083   ×64 lines                    t=1979086
released_pages_levels armed=256 → armed=142 dropped=50
```

- All 64 lines carry the same `wrote_at=45083`. That is **one** write: the synchronous CPU writeback of
  the compute kernel's 70 MB destination, a **brand-new** IOSurface (mid 226, gen 1, `prev_pages=0`).
  Every reported gpa (0x1c911c000, 0x1c90dc000, 0x1169dc000, …) lies inside its span.
- 114 pages were hit (64 reported and 50 dropped, since the queue holds 64). `armed` fell from 256 to 142.
- These are pages the guest had unmapped from some task (epochs 35032/38200) and then reused, through
  its allocator, as the backing of a new IOSurface that it handed to the host in the mapper
  descriptor. **The guest asked for this write.** It is not a write into freed memory.
- The second hit (t = 2070248, `wrote_at=45085`) is the same pattern: a fresh mid 228, 4096×2160 RGhA,
  4321 pages, the same compute dst writeback.
- The trigger at about 33 min is the **Aerial wallpaper's 4K pipeline**. The 4096×2160 4:2:0 frame
  (mid 225/227) is converted by a compute kernel into a fresh 4096×2160 RGBA16F IOSurface. Because Dozen
  refuses guest import, the destination is written back on the CPU in full. That is the first 70 MB
  surface the guest assembles from recycled pages.

## 3. Not caused by a61708e, and the same bug as before

- The writer is `compute_dst_mapper_ref_texture` → `mapping_write full_tight_direct`, inside the
  exec. That is not a debt payment: there is no `wbdebt_paid_at_stamp` in that window, and the stamp
  path is not involved.
- In the 9b29cf7 run it is the same class. The first hit is at t = 2363595 with 18 pages, and the
  writer is `mapping_write full_tight_direct mid=259`, a fresh mapper surface (gen 1, 4321 pages,
  4096×2160 RGhA, compute dst refused import). There are 4 more small hits later.
- 30 → 67 is not a regression. The counts are greps, and each includes the `store_routes` summary lines.
  How many pages hit depends on how many armed pages the guest's allocator happens to recycle into
  the 70 MB surface (18 then, 114 now). The burst moved from 39 min to 33 min because the wallpaper's 4K
  frame arrived earlier.
- a61708e itself narrows the real write-after-free window. A mapper debt used to be paid up to 90 s
  later (C7); now it is paid at its own channel's stamp. `pay` (`writeback_debt.rs:1832`) refuses a
  missing mapping or a moved `map_generation`. `condemn_surface_backing` (`model/state.rs:5456`) takes
  `page_entries` on an IOSurface delete, so a payment after the delete has no pages to write.

**Corruption risk:** none is shown by this slug. It does not explain the CampoRemoteService panic or the
"computer was restarted" dialog. Note what the guard does *not* cover: it never arms on an IOSurface
delete (only on a task unmap), so a real debt-after-delete write would not show up here at all.

## 4. Fix spec (porter)

**F1 — disarm pages the guest hands over as an IOSurface backing (required, low risk).**
`runtime/mapper/mod.rs`, `adopt_resolved_plan` (:804). Just before the final `true` (:973), so that it
runs after the reprieve check `surface_pages_are_exclusively_owned` and the rewire/alias guard:

```rust
if crate::runtime::node_guard::enabled() {
    if let Some(m) = state.mappings.get(&mapping_id) {
        let gpas: Vec<u64> = m.page_entries.iter()
            .filter_map(|&e| crate::protocol::iosurface_pages::entry_gpa_shift(e, page_shift))
            .collect();
        for gpa in gpas { state.host_writes.remap_page(gpa); }
    }
}
```

Do the same at the backing adoption site `runtime/objects/mod.rs` (~:3905, the `src=backing` span
emitter) after its plan is adopted. Cost: one cell per page, once per adoption (4321 for a 4K surface).
Risk: diagnostic only, with no data-path change. If an adopted plan were itself stale, disarming would
mask it, but the alias guards that run first already fail that case closed. If you want it narrower,
gate it on `pages_changed || incarnation_changed`.

**F2 — optional, adds real coverage:** in `condemn_surface_backing` (`model/state.rs:5456`) and the
fresh-MAP clear (:5508), call `host_writes.release_page` on the condemned entries. Then a write after an
IOSurface delete becomes a true finding, and F1's disarm on re-adoption clears the legitimate reuse.

**Expected after F1:** `released_write_after_release` = 0 in the Aerial window, and `armed` does not
drop in steps of 100.
