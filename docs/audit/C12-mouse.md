# C12 — mouse never reaches the guest

Diagnosis on the live run (QEMU pid 112001, Orchard `28f9823`, started 14:10:29 30/10), no
code changed. Evidence commands are below each finding.

## Verdict

The guest pointer path works end to end. The mouse is lost **before QEMU**: the running QEMU has
**no reims host window at all**, because `gg up --window` (and so `GG_WINDOW=1`) never exports
`REIMS_VGPU_WINDOW=1`, which is what the reims device checks before it starts the window.
A second, cosmetic gap: even with the window open, the reims window does not draw the guest's
hardware cursor, and the scanout/screendump does not contain it either.

## 1. QEMU + guest: the tablet path works

- `gg hmp 'info mice'` → `* Mouse #2: QEMU HID Tablet (absolute)`, the active handler.
  `info usb`: keyboard on port 1, tablet on port 2 (both machine-created, `hw/vmapple/vmapple.c:546`,
  qemu-xhci). The tablet is not bound to a console (no `display=`), so
  `qemu_input_find_handler()` falls back to it for any ABS event, including ones queued on the
  reims console.
- HMP `mouse_move` is useless here: `ui/ui-hmp-cmds.c:41` queues **relative** axes, which the
  absolute tablet ignores. Use the reims device's QOM injection instead
  (`reims-vgpu-mmio.c:1128-1201`, it calls the same `reims_vgpu_shim_input_pointer_move()` the
  window uses):
  `gg hmp "qom-set /machine/unattached/device[17] inject-pointer $(( (X<<32) | Y ))"`.
- Measured (guest `NSEvent.mouseLocation` over ssh, screen 1920x1080, Cocoa y is bottom-up):

  | inject (x,y top-down) | guest mouseLocation |
  |---|---|
  | before | 10, 1070 |
  | 800, 450 | 799.9, 630.0 |
  | 400, 800 | 399.96, 280.04 |

  Trace `usb_xhci_xfer_*` during one injection: the tablet (slot 1, ep 3) completed one 6-byte
  interrupt transfer; the keyboard (slot 2) streams 8-byte reports (idle rate). Trace
  `reims_vgpu_mmio_cursor`: the guest answers each move with a hardware-cursor update
  (`x=199 y=199 show=1`, `1199 299`, `399 799`) → `qemu_console_set_mouse()`.
- So xhci, usb-tablet, the guest HID stack and WindowServer all work.

## 2. Host: the window does not exist in this run

- `reims_vgpu_mmio_window_requested()` (`qemu/hw/display/reims-vgpu-mmio.c:1232`) returns true
  only for a non-empty, non-"0/off/no/false" `REIMS_VGPU_WINDOW`; unset = no window.
- `tools/gg:67`: `[ $window = 1 ] || export REIMS_VGPU_WINDOW=0` — the `--window` branch does
  nothing, it only leaves the caller's value. `boot_injected` (`tools/gg:129`) passes `--window`
  for `GG_WINDOW=1`, so `GG_WINDOW=1` alone opens no window.
- Live proof: `/proc/112001/environ` has no `REIMS_VGPU_WINDOW`; the thread list has no
  `reims-vgpu-window` (spawned at `host_window/present.rs:597`); no visible msrdc (WSLg) window
  on Windows; `/tmp/reims-vgpu-fail.log` reports `window_publish ... no_window=250` every second
  since t=15 s.
- The forwarding code itself is correct when a window exists: `present.rs:996`
  `CursorMoved` → `pointer_move()` (`:1251`, aspect-fit to guest pixels) →
  `HostAction::input_pointer_move` → `reims-vgpu-mmio.c:847` → `reims-vgpu-shim.c:284`
  (`qemu_input_queue_abs` X/Y + `qemu_input_event_sync`). Buttons `present.rs:999` →
  `shim.c:296`; wheel `:1007`. Keys take the identical route (`present.rs:974` →
  `shim.c:275`, `qemu_input_event_send_key_linux`), so if keys ever arrived through a window,
  moves would too. (If the keyboard is "working" in this run, it is not coming from a reims
  window — there is none.)

## 3. Cursor is never drawn on the host

- Screendump before/after three injections: 0 pixels differ, also in a 35x35 box at each
  target (`shots/mouse-after-inject.png`). The guest cursor is a hardware plane, not in the
  scanout.
- `reims-vgpu-mmio.c:773/791` hand position and glyph to the QEMU console
  (`qemu_console_set_mouse`, `dpy_cursor_define`), but the run is `-display none` and
  `host_window/` has no cursor compositing (no glyph/cursor plane in `present.rs`,
  `window_publish.rs`, `backend/window`). Over the window the Windows arrow is still visible
  (winit leaves the host cursor shown), and the absolute tablet maps 1:1, so this is cosmetic.

## Fix spec (porter)

1. **Required** — `tools/gg:67` (project repo, not the QEMU tree), 1 line:
   ```sh
   if [ $window = 1 ]; then export REIMS_VGPU_WINDOW=1; else export REIMS_VGPU_WINDOW=0; fi
   ```
   Risk: low. Side effects to know: the window grabs desktop shortcuts on focus (capture), and
   closing it sends `WINDOW_CLOSED` → `qemu_system_shutdown_request` (`reims-vgpu-mmio.c:860`),
   i.e. closing the window stops the VM. Needs a VM restart to take effect.
2. **Optional** — composite the guest hardware cursor in the reims window: keep the last
   `CursorUpdate` (x, y, show) and `CursorGlyph` pixels in the `WindowLink`
   (`device/window_publish.rs`) and blend the glyph after the scanout blit in
   `host_window/present.rs` `draw()`; ~100-150 lines, medium risk (Dozen present path). Cheaper
   alternative: hide the host cursor over the window (`window.set_cursor_visible(false)`) only
   once (2) exists; until then keep the host arrow visible.

## How to verify

- After restart with `GG_WINDOW=1`: `tr '\0' '\n' </proc/$(cat ~/gg/run/gg27/qemu.pid)/environ |
  grep REIMS_VGPU_WINDOW` → `=1`; thread `reims-vgpu-window` present; log shows
  `window_publish ... no_window=0`.
- Move the host mouse over the window, then
  `gg ssh 'osascript -l JavaScript -e "ObjC.import(\"AppKit\"); var p=\$.NSEvent.mouseLocation; p.x+\",\"+p.y"'`
  changes; `gg hmp 'trace-event reims_vgpu_mmio_cursor on'` shows cursor updates following it
  in `run/gg27/qemu.log` (turn it off afterwards).
- Headless regression check (no window needed): the `inject-pointer` table above.
