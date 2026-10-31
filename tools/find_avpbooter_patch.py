#!/usr/bin/env python3
"""Locate image4_validate_property_callback() in an AVPBooter image.

NyanSatan's Virtual-iBoot-Fun patches that routine to `mov x0, #0; ret` so the
VM firmware runs outside Apple's hypervisor; it was found through the immediate
0x4345 ("CE" of the Image4 tag 'CEPO'). Orchard hard-codes the file offset
0x2314 for the Ventura-era AVPBooter (iBoot-8422.141.2.700.1). This tool finds
it by pattern so a different AVPBooter build can be patched too:

  1. disassemble the whole image (it is a flat AArch64 blob loaded at 0);
  2. find instructions whose immediate is 0x4345 (movz/movk/mov w?, #0x4345...);
  3. walk back from each hit to the nearest `pacibsp` = function start;
  4. report candidates; the right one must begin `pacibsp; sub sp, sp, #...`.
On the macOS 27 (26A428) AVPBooter the routine sits at 0x2370 and opens with
`pacibsp; sub sp, sp, #0xd0`, so Orchard's patch-avpbooter.py (which expects
`sub sp, sp, #0x10` at 0x2314) refuses it; --write applies the same two-instruction
stub (`mov x0, #0; ret`) at the single candidate found by pattern.

usage: find_avpbooter_patch.py <AVPBooter.bin> [--write <AVPBooter.patched.bin>]
"""
import re
import sys

PACIBSP = bytes.fromhex("7f2303d5")
REPLACEMENT = bytes.fromhex("000080d2" "c0035fd6")  # mov x0, #0 ; ret


def disasm(path):
    """[(addr, word hex, 'mnemonic operands')] for every 4-byte slot (capstone;
    objdump aborts on this blob)."""
    from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    data = open(path, "rb").read()
    out = []
    for a in range(0, len(data) - 3, 4):
        w = data[a:a + 4]
        i = next(md.disasm(w, a), None)
        out.append((a, w[::-1].hex(), f"{i.mnemonic} {i.op_str}" if i else ".word"))
    return out


def main():
    ins = disasm(sys.argv[1])
    idx = {a: i for i, (a, _, _) in enumerate(ins)}
    hits = [i for i, (_, _, t) in enumerate(ins) if re.search(r"#0x4345\b", t)]
    starts = {}
    for h in hits:
        j = h
        while j >= 0 and not ins[j][2].startswith("pacibsp"):
            j -= 1
        if j >= 0:
            starts.setdefault(ins[j][0], []).append(ins[h])
    with open(sys.argv[1], "rb") as f:
        blob = f.read()
    # the Golden Gate (2026) build carries no "iBoot-x.y.z" tag, only a banner
    ver = re.search(rb"iBoot-[0-9.]+", blob) or re.search(rb"AVPBooter for [^\0]+", blob)
    print(f"version: {ver.group().decode() if ver else '?'}")
    good = []
    for a, refs in sorted(starts.items()):
        nxt = ins[idx[a] + 1][2]
        print(f"candidate @ {a:#x}  next: {nxt}  refs: " + ", ".join(f"{r[0]:#x} {r[2]}" for r in refs))
        if nxt.startswith("sub sp, sp, #"):
            good.append(a)
    if "--write" in sys.argv[2:]:
        out = sys.argv[sys.argv.index("--write") + 1]
        if len(good) != 1:
            sys.exit(f"refusing to patch: {len(good)} candidates of the form `pacibsp; sub sp, sp, #...`")
        a = good[0]
        if blob[a:a + 4] != PACIBSP:
            sys.exit(f"refusing to patch: {a:#x} is not pacibsp")
        data = bytearray(blob)
        data[a:a + 8] = REPLACEMENT
        open(out, "wb").write(data)
        print(f"patched {a:#x} -> mov x0, #0; ret   written {out}")


if __name__ == "__main__":
    main()
