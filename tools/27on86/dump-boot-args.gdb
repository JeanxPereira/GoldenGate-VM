python
import gdb, os
pc = int(os.environ.get("HANDOFF_PC", "0xE0A00000"), 0)
gdb.execute("set architecture aarch64", to_string=True)
gdb.execute("target remote :1234", to_string=True)
bp = gdb.Breakpoint(f"*{pc:#x}", type=gdb.BP_HARDWARE_BREAKPOINT, internal=True)
bp.ignore_count = 1
gdb.execute("continue", to_string=True)
regs = {r: int(gdb.parse_and_eval(f"${r}")) for r in ("pc", "x0", "x1", "x2", "x3")}
print("regs", {k: hex(v) for k, v in regs.items()})
inf = gdb.selected_inferior()
open("/tmp/bootargs.bin", "wb").write(bytes(inf.read_memory(regs["x1"], 0x400)))
print("dumped 0x400 bytes at x1 to /tmp/bootargs.bin")
bp.delete()
gdb.execute("detach", to_string=True)
end
