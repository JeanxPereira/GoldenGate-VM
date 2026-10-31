#!/usr/bin/env python3
"""Convert an Apple Sparse Image Format (ASIF, header v1) disk to a raw image.

Layout from https://github.com/huven/asif-format (reverse engineered):
  header (big-endian) @0: 'shdw', version, header size, flags,
    directory offsets[2] @0x10, uuid @0x20, sector count @0x30,
    max sector count @0x38, chunk size @0x40 (u32), block size @0x44 (u16).
  N = 4 * block size data chunks per chunk-group, then one bitmap entry;
  S = 8 * (N + 1) bytes per group, C = chunk size // S groups per table,
  D = C * N * chunk size bytes addressed per table.
  directory: u64 sequence, then one u64 table chunk number per table (0 = sparse).
  entry: status = e >> 62 (00 zero, 01 full, 10 unmapped, 11 partial/bitmap),
         physical chunk = e & 0x007FFFFFFFFFFFFF.
  bitmap: 2 bits per sector, LSB first; 01 = data, 00/10 = zero, 11 invalid.

Only non-zero data is written, so the output stays sparse on a filesystem that
supports holes (on NTFS through WSL, set the sparse flag on the file first).

usage: asif2raw.py info <in.asif>
       asif2raw.py convert <in.asif> <out.raw> [--consume]   (--consume frees the input as it goes)
       asif2raw.py read <in.asif> <offset> <length>   (hexdump a logical range)
"""
import os
import struct
import sys


class Asif:
    def __init__(self, path):
        self.f = open(path, "rb")
        h = self.f.read(0x50)
        magic, ver, hsize, flags = struct.unpack(">4sIII", h[:16])
        if magic != b"shdw":
            raise ValueError(f"not ASIF (magic {magic!r})")
        if ver != 1:
            raise ValueError(f"unsupported ASIF version {ver}")
        self.dir_offs = struct.unpack(">QQ", h[0x10:0x20])
        self.uuid = h[0x20:0x30].hex()
        self.sectors, self.max_sectors = struct.unpack(">QQ", h[0x30:0x40])
        self.chunk, self.block, segs = struct.unpack(">IHH", h[0x40:0x48])
        (self.meta_chunk,) = struct.unpack(">Q", h[0x48:0x50])
        if segs != 0:
            raise ValueError("total_segments != 0 is rejected by Apple's parser")
        self.n = 4 * self.block
        self.s = 8 * (self.n + 1)
        self.c = self.chunk // self.s
        self.d = self.c * self.n * self.chunk
        self.t = -(-self.max_sectors * self.block // self.d)
        self.size = self.sectors * self.block
        self.flen = os.fstat(self.f.fileno()).st_size
        # active directory = highest sequence number
        best = None
        for off in self.dir_offs:
            self.f.seek(off)
            seq = struct.unpack(">Q", self.f.read(8))[0]
            if best is None or seq > best[0]:
                best = (seq, off)
        self.dir_seq, self.dir_off = best
        self.f.seek(self.dir_off + 8)
        self.tables = list(struct.unpack(f">{self.t}Q", self.f.read(8 * self.t)))
        self._tcache = {}

    def table(self, ti):
        if ti not in self._tcache:
            tc = self.tables[ti]
            if tc == 0:
                self._tcache[ti] = None
            else:
                self.f.seek(tc * self.chunk)
                self._tcache[ti] = self.f.read(self.c * self.s)
        return self._tcache[ti]

    def entry(self, lchunk):
        """(status, physical chunk, bitmap chunk) for logical data chunk index."""
        per_table = self.c * self.n
        ti, rel = divmod(lchunk, per_table)
        tab = self.table(ti)
        if tab is None:
            return 0, 0, 0
        g, k = divmod(rel, self.n)
        base = g * self.s
        (e,) = struct.unpack_from(">Q", tab, base + 8 * k)
        (bm,) = struct.unpack_from(">Q", tab, base + 8 * self.n)
        return e >> 62, e & 0x007FFFFFFFFFFFFF, bm & 0x007FFFFFFFFFFFFF

    def read_chunk(self, lchunk, raw_partial=False):
        """Logical chunk contents as bytes, or None if it reads as all zeros.

        raw_partial=True returns a partial chunk's physical bytes without applying
        the bitmap (what dissect.hypervisor does); only for cross-checking."""
        status, phys, bmchunk = self.entry(lchunk)
        if status in (0, 2):
            if phys != 0:
                raise ValueError(f"chunk {lchunk}: status {status:02b} with phys {phys} is uncharacterised")
            return None
        self.f.seek(phys * self.chunk)
        data = self.f.read(self.chunk)
        if len(data) < self.chunk:
            data = data + b"\0" * (self.chunk - len(data))
        if status == 1 or raw_partial:
            return data
        # partial: consult the group's bitmap; sector index within the group
        if bmchunk == 0:
            raise ValueError(f"chunk {lchunk}: partial but no bitmap chunk")
        g_first = (lchunk % (self.c * self.n)) // self.n * self.n
        k = lchunk % (self.c * self.n) - g_first
        spc = self.chunk // self.block
        self.f.seek(bmchunk * self.chunk + (k * spc) // 4)
        bits = self.f.read(spc // 4)
        out = bytearray(data)
        for sct in range(spc):
            st = (bits[sct // 4] >> ((sct % 4) * 2)) & 3
            if st == 3:
                raise ValueError(f"chunk {lchunk}: bitmap state 11 is invalid")
            if st != 1:
                out[sct * self.block:(sct + 1) * self.block] = b"\0" * self.block
        return bytes(out)

    def read(self, off, length, raw_partial=False):
        out = bytearray()
        while length > 0:
            lc, intra = divmod(off, self.chunk)
            take = min(length, self.chunk - intra)
            data = self.read_chunk(lc, raw_partial)
            out += (data[intra:intra + take] if data else b"\0" * take)
            off += take
            length -= take
        return bytes(out)


def cmd_info(a):
    print(f"uuid {a.uuid}  dir seq {a.dir_seq} @ {a.dir_off:#x}")
    print(f"logical size {a.size} bytes ({a.size / 2**30:.2f} GiB), max {a.max_sectors * a.block / 2**40:.1f} TiB")
    print(f"chunk {a.chunk:#x}  block {a.block}  N={a.n} S={a.s} C={a.c} D={a.d / 2**30:.0f} GiB  tables={a.t}")
    used = [i for i, t in enumerate(a.tables) if t]
    print(f"tables present: {used[:10]}{'...' if len(used) > 10 else ''} ({len(used)})")
    print(f"file length {a.flen} ({a.flen / 2**30:.2f} GiB), metadata chunk {a.meta_chunk:#x}")
    counts = {0: 0, 1: 0, 2: 0, 3: 0}
    nchunks = -(-a.size // a.chunk)
    for lc in range(nchunks):
        counts[a.entry(lc)[0]] += 1
    print(f"data chunks in logical range: {nchunks}  status counts {counts}")


def punch_hole(fd, off, length):
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]
    # FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE
    if libc.fallocate(fd, 0x01 | 0x02, off, length) != 0:
        raise OSError(ctypes.get_errno(), "fallocate punch hole")


def cmd_convert(a, out_path, consume=False):
    """consume=True frees each data chunk of the input once copied, so the
    input and the output never coexist in full (input is destroyed)."""
    nchunks = -(-a.size // a.chunk)
    refs = {}
    if consume:
        for lc in range(nchunks):
            status, phys, _ = a.entry(lc)
            if status in (1, 3):
                refs[phys] = refs.get(phys, 0) + 1
        shared = sum(1 for v in refs.values() if v > 1)
        print(f"consume: {len(refs)} physical data chunks, {shared} shared (kept)", flush=True)
        in_fd = os.open(a.f.name, os.O_RDWR)
    fd = os.open(out_path, os.O_RDWR | os.O_CREAT, 0o644)
    os.ftruncate(fd, a.size)
    written = zero = 0
    for lc in range(nchunks):
        data = a.read_chunk(lc)
        if data is not None:
            if lc == nchunks - 1:
                data = data[:a.size - lc * a.chunk]
            if data.count(0) == len(data):
                zero += 1
            else:
                os.pwrite(fd, data, lc * a.chunk)
                written += 1
            if consume:
                status, phys, _ = a.entry(lc)
                if refs.get(phys) == 1:
                    os.fdatasync(fd)  # the copy is durable before the source goes
                    punch_hole(in_fd, phys * a.chunk, a.chunk)
        if lc % 4096 == 0:
            print(f"  {lc}/{nchunks} chunks, {written} written", flush=True)
    os.close(fd)
    if consume:
        os.close(in_fd)
    print(f"done: {written} chunks written ({written * a.chunk / 2**30:.2f} GiB), {zero} allocated-but-zero skipped")


def main():
    cmd = sys.argv[1]
    a = Asif(sys.argv[2])
    if cmd == "info":
        cmd_info(a)
    elif cmd == "convert":
        cmd_convert(a, sys.argv[3], consume="--consume" in sys.argv[4:])
    elif cmd == "read":
        sys.stdout.buffer.write(a.read(int(sys.argv[3], 0), int(sys.argv[4], 0)))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
