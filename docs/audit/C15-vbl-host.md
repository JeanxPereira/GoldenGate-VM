# C15 — Display VBL on the host: steelbrain vs Orchard

Question: does a correct host generate display VBL for a macOS 27 guest, and is
Orchard's `display_vbl ... delivered=0 arm=not_enabled` a host bug?
Spec: steelbrain `steelbrain/reims-vgpu` @ 12765ee. Target: Orchard
`external/orchard/reims-vgpu` @ ec70db6 (`gg-macos27`). Log:
`~/gg/run/gg27/logs/reims-vgpu-fail.a360c8a-45m.log`.

## Answer

**steelbrain generates no VBL at all.** It has no timer, no refresh grid and no
bit-0 signal. The guest never asks for one either: for the whole 45-minute
macOS 27 boot the enable word is `0xc` (online+offline). Orchard's VBL tick is
correct to stay silent. The "no VBL, so no display-link" hypothesis does not
come from a host omission. If the guest's display-link stalls, the cause is on
the guest side (its own timebase) or in how presents complete, not in a missing
host VBL.

## Spec (steelbrain)

Shared display page (one guest page per port), `crates/reims-vgpu-core/src/display/page.rs`:
- `RAISED_INTERRUPTS` 0x100 (:73), `ENABLED_INTERRUPTS` 0x104 (:75)
- `PRESENT_COUNT` u64 0xf98, `PRESENTED_SURFACE` u32 0xfa0, `FIELD_FA4` u32 0xfa4,
  `PRESENTED_MAPPING_ID` u64 0xfb0 (:126-137)

Interrupt bits, `display/guest_display.rs:90-98`: PRESENT=2, CONNECT=4,
DISCONNECT=8, UPDATE=12. **Bit 0 (Orchard's "VBL") is never defined or set.**

The only raisers of display interrupts are:
1. Present completion, `display/guest_display/present.rs:124-137`. It always
   does `fetch_or(RAISED, 2)`, then calls `poke()` only if `ENABLED & 2`. It is
   handed to `DisplayCore::present_frame` and runs **synchronously** at the end
   of it, under the display mutex (`display/frame.rs:133`). Before that, the
   present waits for host frames in flight, up to 2 s (`frame.rs:139-155`).
   With no client it runs immediately (`present.rs:344, 485`).
2. Connect/ack state machine, `guest_display.rs:715-792` (4/8/12, poke if enabled).

`poke()` (`guest_display.rs:562`) leads to `device/fifos.rs:442`
`display_poke_port`. That sets `interrupt_display |= 1<<port` and calls
`raiseInterrupt(0)`, the single device IRQ, only while Running (`fifos.rs:424`).
The guest reads and clears it at MMIO 0x1014 (`device/mmio.rs:56,159`).

Cadence: one present interrupt per guest present, paced by the guest. No
periodic signal exists. The refresh rate only reaches the guest as data in the
mode list (`reims-vgpu/src/display.rs:57,333`).

After each present the page is also updated: `bump64(PRESENT_COUNT)` plus the
presented surface/mapping id, and `FIELD_FA4=0` (`present.rs:229-231` surface
path, `:508-510` mapped path). The restore path reads `PRESENT_COUNT`
(`guest_display.rs:861`).

## Orchard

- Log line: `runtime/drain/census/mod.rs:344` (`note_vbl` :355). It is fed by
  `signal_display_refresh_classes` (`runtime/drain/mod.rs:~7782-7863`), a
  ~120 Hz grid (`DISPLAY_VBL_MIN_INTERVAL_US`, :7448) called from the poll at
  `device/mod.rs:740` and the contended path at `device/mod.rs:784`.
- Each tick reads the enable word at 0x104. If neither bit 0 (VBL,
  `model/regs.rs:758`) nor bit 1 (transaction, :774) is set, it counts
  `not_enabled` and returns (:7812-7814). The log shows
  `display_enable_mask first mask=0xc armed=online+offline t=20252`, and the
  mask never changes after that (the census logs only changes,
  `census/mod.rs:480-487`). That gives `not_online=4954` before the ack
  (~20 s), then `not_enabled` reaching 650240 and `delivered=0` (650 lines).
- Present completion, `signal_display_present_complete` (`drain/mod.rs:7370`),
  sets bit 1 only if enabled (:7383), so `display_present_signal delivered=0`.
  steelbrain would still OR bit 2 (value 2) into RAISED and not poke. Neither
  host sends an IRQ.
- Bit numbering agrees: steelbrain PRESENT=2 is Orchard
  `DISPLAY_PRESENT_EVENT_MASK=1<<1`, and 4/8 are online/offline.

## Real differences

1. **Orchard never writes `PRESENT_COUNT` 0xf98 / `PRESENTED_SURFACE` 0xfa0 /
   `FIELD_FA4` 0xfa4 / `PRESENTED_MAPPING_ID` 0xfb0.** No constant or write for
   them exists in the tree. A macOS 27 guest that relies on `presentCount`
   moving (rather than IRQs, since it arms none) sees it stuck at 0. guest RE
   should confirm whether the guest kext reads 0xf98.
2. Orchard's VBL grid is an Orchard invention for macOS 11/13 guests. It is
   harmless on 27 (gated by mask), and there is no steelbrain counterpart.

## Minimal Orchard change (if guest-re confirms 0xf98 is read)

At the one present-completion call site, `runtime/drain/mod.rs:5291` (just before
`signal_display_present_complete`), after a
present that did not fault, do what steelbrain does:
`page[0xf98] += 1` (u64), `page[0xfa0] = surface` (u32) or
`page[0xfb0] = mapping_id` (u64), `page[0xfa4] = 0`, using `shared_w32`/a
64-bit equivalent. Add 4 constants in `model/regs.rs`. Size: ~25 lines.
Risk: low, because these are guest-RAM writes the guest expects on real hosts.
Do NOT add a bit-0 VBL source or force the enable mask: steelbrain does neither.
