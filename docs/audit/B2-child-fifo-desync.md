# B2: the "child FIFO desync" in run 92a086c is the IOSurface mapper ring wrapping

Run: `92a086c` (log `/tmp/reims-vgpu-fail.log`, 198 801 lines, about 46 min). Baseline:
`~/gg/run/gg27/logs/reims-vgpu-fail.e118d61-final.log` (79 min, 0 occurrences). Orchard
`gg-macos27` @ `92a086c`. Paths are relative to `reims-vgpu/crates/`. Read-only diagnosis.

## Verdict

**This is not a child FIFO and not a regression from 9c05963 or 27d3a0b.** The `unknown_child_opcode
ch=0 … total_size=16 stamps=0 plen=0` events do not come from the FIFO packet decoder. They come from
`drain_iosfc` (`reims-vgpu/src/runtime/drain/mod.rs:~7270`), which reuses `FailEvent::UnknownChildOpcode`
with `channel: 0`, `opcode: rtype`, `total_size: MAPPER_REQUEST_ENTRY_LEN (16)`, `stamp_count: 0` and
an empty payload for an **IOSurface mapper ring entry whose request type is neither MAP (1) nor UNMAP (2)**.
Every one of the 576 events has exactly that signature. A real FIFO desync would show varying
`total_size` values, nonzero `stamps`, and `child_opcode_out_of_range` lines. There are none.

The mapper ring is indexed **without the modulo**. `drain_iosfc` reads entry `idx` at
`ring_base + idx * 16` for `idx in consumer..producer`, and `producer` is the guest's **free-running**
counter:

```rust
// drain/mod.rs, drain_iosfc
for idx in start..end {
    let entry_off = (idx as u64) * MAPPER_REQUEST_ENTRY_LEN as u64;   // no % capacity
    host.read_gpa(state.iosfc.ring_base + entry_off, &mut e)
```

The guest (`IOSurfaceParavirtMapperDevice::do_host_mapping_gated` @0xFFFFFE00086BD320) writes request
`n` at `ring + 16 * (n % capacity)`. It then publishes `n+1` to `0x1018` (MMIO +4120) and waits for
the read counter. The capacity is `page_size >> 4` (`::init` @0xFFFFFE00086BA34C, `this+40`), which is
**1024 entries in one 16 KiB page**. `::start` @0xFFFFFE00086BACA4 writes it to `0x1008`
(`v26[513]`), the register Orchard stores as `iosfc.capacity` and never uses. A grep shows
`iosfc.capacity` is read only by MMIO readback. `mapper/mod.rs:2146` says outright that its units
were never established. They are entries: the guest sets the value with `>>4` and indexes with
`n % capacity`, and the spec host agrees: `reims-vgpu-core/src/iosurface/regs.rs:28`
`REG_RING_SIZE = 0x1008 /// length in commands`, `ring.rs:119`
`rem0(ring_rd_counter, ring_size) * RING_COMMAND_SIZE`, with u64 counters.

So host request 1024 reads `ring_base + 0x4000`, the page **after** the ring, and every later
request reads further into unrelated guest memory.

## (1) What precedes the first event (line 155342, t=2177294 ms ≈ 36.3 min)

Nothing FIFO-related. The 70 lines before it are a quiet census second: `drain_ops` has only
`op0x28_n=2`, `max_tranche_us=672`, `irq_wait_max_us=70`, no stall. The last mapper activity before
it is `mapper_desc_path mapping=614` (line 155250, t=2175571, 32x32 RGhA). After the onset there is
**no `mapper_desc_path` at all**: no MAP is ever processed again, because none is read from its real
slot. The request count matches the wrap exactly:
- 614 MAPs (`mapper_desc_path` mapping=1…614) before the onset;
- `host_cache_levels surfaces=206` just before the onset, so about 408 surfaces had been unmapped;
- 614 + about 410 UNMAPs ≈ **1024 = capacity**.

No read offset is advanced wrong after a FIFO command, and no ExecIndirect segment is aborted. The
child FIFO path is clean: no `malformed_child`, no head writeback fault, no `child_opcode_out_of_range`.

## (2) Correlation with the onset

- **No** GPU fault, device-lost, reset or FIFO redefinition. There is one `device_reset` at t=25,
  at boot.
- **No** QEMU stall. `vcpu_lock_wait` shows 0 waits, and the drain duty that second is 0.002.
- **Serial** (`~/gg/run/gg27/serial.txt`): no IOGPU, GPU restart or hang message, and no
  `IOSurfaceParavirtMapperDevice` error. The guest does not notice anything, because the host still
  sets `consumer = producer` and raises the IRQ, so the guest believes every MAP/UNMAP completed.
- The only thing that correlates is **mapper request volume**. MAPs per 5 min in this run:
  10/14/129/98/69/147/124/35, 626 in total. The baseline made 278 MAPs in 79 min, tapering off after
  20 min. It never got near 1024 requests, so the latent bug never fired. Any long enough or busy
  enough session hits it, whatever rendering commits are in the build.

## (3) Mapping 616 and the other secondary counters: consequences

Counts are given as before the onset / after it / in the baseline.

| Counter | Before | After | Baseline | Reading |
|---|---|---|---|---|
| `store_refused`/`write_refused` | 0 | 190 | 0 | consequence |
| `gpuwb_not_writable` / `surface_write_mapping_not_resident` (mid 616, 5x24) | 0 | 221 | 0 | **consequence**: 616's MAP fell in the wrapped region and was never applied, so the host knows the id only from FIFO references |
| `capture_unmapped` (mid 37, 606, …) | 0 | 11 | 0 | **consequence**: an off-ring entry that happens to read as type 2 unmaps a *live* old mapping (37 is from boot) |
| `model_map/unmap_surface_id_sentinel mapping=0` | 0 | 1+1 | 0 | consequence: a zero entry with type 1/2 |
| `released_write_after_release` | **26** | 4 | 0 | **independent and earlier** (first at line 85502, t≈25.9 min). All 26 are `released_at=21183`: one batch of guest-released pages that the device kept writing ~25 min later. It is not the cause of the wrap. It is a separate lead that also grows with surface churn (see below) |
| `map_audit_unmap_of_unmapped` | 27 | 9 | 24 | pre-existing, unrelated |

Worse cases the bug can still produce: an off-ring entry with type 1 maps a random id over a real
slot. Once `ring_base + idx*16` leaves guest RAM, `read_gpa` fails, the loop `break`s with
`consumer < producer`, and the guest stalls 60 s in `wait_for_ring_space_gated` ("Timed out waiting
for ring space") and then fails every IOSurface mapping.

## 9c05963 / 27d3a0b and the env switches

They do not cause the wrap. Neither touches the mapper ring, and the onset is purely a function of
the request count. **Do not** make `REIMS_VGPU_FETCH_SNAPSHOT=off` or `REIMS_VGPU_COLOR_PASS_OPTIMAL=off`
the default on account of this. Two loose ends deserve one A/B run each, after the fix:
- whether the higher IOSurface churn (626 vs 278 MAPs) is guest workload (session activity) or
  something these commits induce (re-created icon surfaces);
- what writes the 26 `released_write_after_release` pages (batch `released_at=21183`). Baseline 0.
  This is the one counter that is new before the onset.

## Fix (small: about 25 lines plus a test)

All of it is in `reims-vgpu/src/runtime/drain/mod.rs::drain_iosfc`, `reims-vgpu-protocol/src/iosurface_pages.rs`
and `runtime/mapper/mod.rs::capture_at_producer`:
1. Index the slot as `(idx % capacity) * 16`, with `capacity = state.iosfc.capacity` (entries). If it
   is 0 or `capacity * 16 > page_size`, fall back to `page_size / 16` and log once
   (`mapper_ring_capacity_invalid`). Give `mapper_request_entry_offset` /
   `mapper_request_published_entry_offset` a `capacity` parameter, because `capture_at_producer`
   (pre-26A428 path) has the same bug.
2. Make the counters u64 (the guest writes u64), or iterate with `wrapping_sub` instead of
   `producer > consumer`. Write `consumer` back as the free-running value, as now.
3. Stop borrowing `UnknownChildOpcode`. Add `FailEvent::MapperRequestUnknownType { index, slot,
   rtype, mapping_id }`, so a mapper fault never reads as a FIFO desync again.
4. Test: a capacity of 4, five MAP requests, and the fifth must be read from slot 0 and must map
   its id. Then a garbage-type entry must produce the new event and no map or unmap.

Verification: a run past 1024 mapper requests shows 0 `unknown_child_opcode`, `mapper_desc_path`
continues past the onset, and there are 0 `mapping_not_resident` events for fresh ids.
