# C15 — Display VBL in the macOS 27 guest (26A428): what arms it, what consumes it

Question: what makes the guest arm and consume display VBL from the PG device, and what happens
to backdrop re-rendering when no VBL is delivered? Companion to `C15-vbl-host.md` (host side).
Sources: corpus `<RE corpus>/kc.c/` (AppleParavirtGPU kext, arm64e) and the
Metal plugin dump `AppleParavirtGPUMetalIOGPUFamily.c/`.

## Answer

**The macOS 27 guest has no host VBL at all.** Its "VBL" is a guest-side `IOTimerEventSource`
(log string "Failed to create VBL timer") that runs `swap_begin_gated` and re-arms itself for 16
(ms, **inferred** from the IOTimerEventSource vtable slot) on every run. The host can only reach a display through
the display-page interrupt word, and the guest enables only bits 2 and 3 (connect/disconnect,
mask `0xC`). It never enables or handles bit 0 or bit 1. Swap completion arrives through the
event-stamp path (fence retire), not through a display interrupt. No feature bit gates VBL,
and the guest kext never reads `presentCount` (0xf98) or the other present fields (0xfa0/0xfa4/0xfb0).
**`delivered=0 arm=not_enabled` is expected for this guest. It does not explain the stale backdrop.**

## Interrupt path (read)

| Step | Where | What |
|---|---|---|
| Device IRQ | `AppleParavirtGPU::setupInterruptsEarly` @0xfffffe00086a1854 | One `IOInterruptEventSource` on the provider, index 0 |
| IRQ handler | `setupInterruptsEarly_block_invoke` @0xfffffe00086a3b00 | Reads regs `+24` (stamps: `IOGPU::signalStampsUpdated`, `AppleParavirtEventMachine::signalStamps`), `+20` (display bitmask: bit n means display n, n <= 7, calls `AppleParavirtDisplay::signalInterrupt`), `+44` (fault: `handleFaultInterrupt`). The regs base is `gpu+992`; the host doc puts these at MMIO 0x1018/0x1014/0x102C (base 0x1000 **inferred**) |
| Per-display | `AppleParavirtDisplay::signalInterrupt` @0xfffffe000869a9e8 | `interruptOccurred` on the "online processInterrupt" source (`this[1017]`) |
| Handler | `AppleParavirtDisplay::handleHostInterrupt` @0xfffffe0008694f90 | `v4 = atomic_fetch_and(page+0x100, ~mask) & mask`, with `mask = page+0x104`. Only `v4 & 4` (connect: `createDisplayAttributes`, message `0xE0000230`, FIFO display cmd 2 `{port, page[0x200]}`) and `v4 & 8` (disconnect: `destroyDisplayAttributes`, message `0xE0000230`) have branches. Bits 0/1 have none |
| Enable mask | `start_hardware_block_invoke` @0xfffffe000869a6cc | `atomic_store(0xC, page+0x104)` (twice), then `interruptOccurred` on `this[1017]`. This is the only write of a nonzero mask. `setupSharedState` first stores `0xFFFFFFFF` into a page word (the decompiler types it as `[37]._flags`; offset not resolved) |
| Page setup | `setupSharedState` @0xfffffe00086957e0 | 16 KiB `IOBufferMemoryDescriptor`, zeroed. FIFO display cmd 1 `{port, pa>>14}` is sent with a barrier event and waited on. Then it checks `page+18 (u16) == port` and caches `page+28` |

## The guest "VBL" (read)

| Item | Where | What |
|---|---|---|
| Timer creation | `start_hardware_block_invoke` @0xfffffe000869a6cc | `IOTimerEventSource::timerEventSource(1, this, block)` stored in `this[1413]`, added to the work loop and enabled |
| Timer action | `start_hardware_block_invoke_2` @0xfffffe000869a9b0 | calls vtable +3288 |
| vt+3288 = swap_begin | `IOMobileFramebufferLegacy::swap_begin_async_gated` @0xfffffe000869e1cc | is just a call to `vt+3288`, so the slot is `AppleParavirtDisplay::swap_begin_gated` (**inferred** from that thunk) |
| Tick body | `AppleParavirtDisplay::swap_begin_gated` @0xfffffe000869d6cc | `cancelTimeout` (vt+568). Then, while `clean_queue_gated` @0xfffffe000869d5c8: pop the next swap, `update_swap_info_state_gated`, program it (vt+3472) or complete it empty (vt+3864). Last, `timer->vt+496(16)` re-arms (`setTimeoutMS(16)`, **inferred**) |
| Stop | `stop_hardware_gated` @0xfffffe000869aa50 | `disable` + `cancelTimeout` + `removeEventSource` |

So the guest generates its own ~60 Hz swap-drain tick. A swap that cannot be programmed is retried
on the next tick. Nothing in this kext needs a host VBL to make progress.

## Swap completion (read)

| Step | Where | What |
|---|---|---|
| Present cmd | `program_hardware_swap_gated` @0xfffffe000869be10 | FIFO display cmd 8, 40 B: `{u32 port, u32 gpuTaskId, u64 mappingId, u64 gammaVA, u64 gammaLen, u32 gammaFlags=257, ...}`. It merges the surface's barrier event and calls `addCommand(channel, desc, this+7936)`. Cmd 10 is the variant used when `gpu+1407 & 1` (a host feature byte) |
| Fence | same, `AppleParavirtDisplayFence::fence(gpu, map, this[1016])` @0xfffffe000869bce0 | `IOGPUFenceMachine::addEventFence` on the swap's event |
| Retire | `AppleParavirtDisplayFence::free` @0xfffffe000869dddc | `completeMapping`, then `interruptOccurred` on `this[1016]` (the "transaction" source) |
| Transaction handler | `AppleParavirtDisplay::init` block @0xfffffe0008694ef8 | `vt+3328` (retires the current swap; also the fall-through of `program_hardware_gated` @0xfffffe000869d4f8), then `vt+3288`, which is `swap_begin_gated` |
| To userspace | `notify_swap_done_gated` @0xfffffe000869ad68 calls `IOMobileFramebufferLegacy::swap_info_notify_dispatch_gated`, which reaches `do_swap_info_notify_gated` @0xfffffe000869ac34 | `sendAsyncResult64WithOptions` for IOMFB notify type 3 (`set_notify_tag_mask_gated` @0xfffffe000869abd8 accepts only type 3). These are the swap-done/timestamp messages WindowServer paces on |

So swap completion needs only the event stamp (regs `+24`, then `signalStamps`) for the cmd-8
barrier event. It does not need a display interrupt bit or `presentCount`. If the stamp never
retires, `this[1016]` never fires. The 16 ms timer then keeps ticking, but the current swap is
never retired (**inferred**).

## Host-advertised conditions

| Gate | Where | Effect |
|---|---|---|
| none for VBL | - | The timer is created unconditionally in `start_hardware` |
| `gpu+1403 & 1` | `do_power_state_change_gated` @0xfffffe000869c9d8 | Sends FIFO display cmd 9 `{port, u8 on}` on a power change |
| `gpu+1407 & 1` | `program_hardware_swap_gated` | cmd 10 (alt swap) instead of cmd 8 |
| `gpu+816` | `AppleParavirtDisplay::init` @0xfffffe00086947e4 | Display count. Port must be `< gpu+816` |

## Page fields 0xf98 / 0xfa0 / 0xfa4 / 0xfb0 (coordinator question)

No function in the `kc.c/` dump (both paravirt kexts) reads or writes these offsets. Grep for
3992/4000/4004/4016 and 0xF98..0xFB0 finds only an unrelated `this`-relative byte in
`createDisplayAttributes`. The Metal plugin dump has no display-page access and no
vbl/vsync/present strings. Page reads that do exist: +18, +28, +44..+79 (colour points), +76, +81,
+88, +104 (protection), +0x100/+0x104 (IRQ), +0x200, +3584 (cursor), and the mode-list walk
(bounded by 0x4000). So `presentCount` staying 0 cannot stall the guest. Writing it on Orchard is
harmless parity, not a fix.

## What this means for the stale backdrop (C13/C14)

The guest kext does not support the hypothesis "no VBL means no backdrop re-render". Frame pacing
reaches WindowServer through IOMFB swap-done notifications. Two things drive those: (a) the guest
16 ms timer and (b) the cmd-8 barrier event retiring through the stamp interrupt. Orchard already
delivers stamps (swaps complete and the screen updates), so swap-done notifications flow. Whether
CoreAnimation re-captures the backdrop is decided above the kext (CA/WindowServer damage
tracking), not by a display interrupt (**inferred**).

## Ranked fix list

1. None on VBL. Keep Orchard's bit-0 grid silent and do not force the mask (0 lines, no risk).
2. Optional parity: write 0xf98/0xfa0/0xfa4/0xfb0 like steelbrain (~25 lines, low risk, no
   expected visible effect).
3. Look for the backdrop cause elsewhere. In swap timing: check that every cmd-8 barrier event
   retires (stamp latency vs the 16 ms tick). Above the kext: CA backdrop invalidation.

## Open questions

- Vtable names for slots +3288/+3328/+3472/+3864 (next: `gq.py names kc _ZTV20AppleParavirtDisplay`,
  then read the vtable qwords).
- Byte-level confirmation that nothing reads 0xf98/0xfa0/0xfb0: `gq.py imm kc 0xf98` (and 0xfa0,
  0xfb0), filtered to AppleParavirtGPU segments.
- The page offset of the `0xFFFFFFFF` store in `setupSharedState`: `gq.py disasm kc 0xfffffe00086957e0`.
- WindowServer/CoreAnimation's own use of IOMFB vblank (the `IOMobileFramebuffer` kext and
  framework) is not in this corpus.
