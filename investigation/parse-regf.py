#!/usr/bin/env python3
r"""
parse-regf.py — 读取 Windows 注册表蜂巢 (regf)，导出指定键及其所有值。

只读，不需要 root，不需要额外依赖。

用法:
    python3 parse-regf.py <hive 文件> [键路径] [--tree]

例子:
    python3 parse-regf.py /mnt/win/Windows/System32/config/SYSTEM 'ControlSet001\Enum\ACPI\TXRA9530\1'
    python3 parse-regf.py /mnt/win/Windows/System32/config/SYSTEM 'ControlSet001\Enum\ACPI\TXRA9530' --tree

键路径用反斜杠或斜杠分隔；不区分大小写。省略路径时列出根键的子键。
"""
import struct
import sys

HIVE_BINS_START = 0x1000


class Hive:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.buf = f.read()
        if self.buf[:4] != b"regf":
            raise SystemExit("不是 regf 蜂巢文件")
        self.root_off = struct.unpack_from("<I", self.buf, 0x24)[0]

    # ---- 底层 ----
    def cell(self, off):
        """返回某 cell 的内容（去掉 4 字节长度头）"""
        base = HIVE_BINS_START + off
        size = struct.unpack_from("<i", self.buf, base)[0]
        n = abs(size)
        return self.buf[base + 4: base + n]

    def u32(self, off, delta):
        """直接从蜂巢读一个 u32（不依赖 cell 尺寸字段，避免分配大小不一致）"""
        return struct.unpack_from("<I", self.buf, HIVE_BINS_START + off + 4 + delta)[0]

    def _nk(self, off):
        d = self.cell(off)
        if d[:2] != b"nk":
            raise ValueError("cell 不是 nk: %r" % d[:2])
        n_sub = struct.unpack_from("<I", d, 0x14)[0]
        sub_off = struct.unpack_from("<I", d, 0x1C)[0]
        n_val = struct.unpack_from("<I", d, 0x24)[0]
        val_off = struct.unpack_from("<I", d, 0x28)[0]
        name_len = struct.unpack_from("<H", d, 0x48)[0]
        # NK 键名是 ASCII/Latin-1（不是 UTF-16）
        name = d[0x4C:0x4C + name_len].decode("latin-1", "replace")
        return dict(name=name, n_sub=n_sub, sub_off=sub_off,
                    n_val=n_val, val_off=val_off)

    def _subkeys(self, off):
        nk = self._nk(off)
        if nk["n_sub"] == 0:
            return []
        d = self.cell(nk["sub_off"])
        sig = d[:2]
        offsets = []
        if sig in (b"lf", b"lh"):
            n = struct.unpack_from("<H", d, 2)[0]
            for i in range(n):
                offsets.append(struct.unpack_from("<I", d, 4 + i * 8)[0])
        elif sig == b"li":
            n = struct.unpack_from("<H", d, 2)[0]
            for i in range(n):
                offsets.append(struct.unpack_from("<I", d, 4 + i * 4)[0])
        elif sig == b"ri":
            n = struct.unpack_from("<H", d, 2)[0]
            for i in range(n):
                sub = struct.unpack_from("<I", d, 4 + i * 4)[0]
                dd = self.cell(sub)
                s2 = dd[:2]
                if s2 in (b"lf", b"lh"):
                    m = struct.unpack_from("<H", dd, 2)[0]
                    for j in range(m):
                        offsets.append(struct.unpack_from("<I", dd, 4 + j * 8)[0])
                elif s2 == b"li":
                    m = struct.unpack_from("<H", dd, 2)[0]
                    for j in range(m):
                        offsets.append(struct.unpack_from("<I", dd, 4 + j * 4)[0])
        else:
            raise ValueError("未知的子键表签名 %r" % sig)
        return offsets

    def _values(self, off):
        nk = self._nk(off)
        if nk["n_val"] == 0:
            return []
        vl = nk["val_off"]
        # 注意：实测 Win11 26100 的蜂巢里，值列表 cell 直接就是偏移数组，
        # 没有规范的"计数字段"（计数由 nk.n_val 给出）。这里自适应两种布局。
        content_size = abs(struct.unpack_from("<i", self.buf, HIVE_BINS_START + vl)[0]) - 4
        n = nk["n_val"]
        delta = 0 if n * 4 == content_size else 4
        out = []
        for i in range(n):
            vk_off = self.u32(vl, delta + i * 4)
            vd = self.cell(vk_off)
            name_len = struct.unpack_from("<H", vd, 2)[0]
            data_size = struct.unpack_from("<I", vd, 4)[0]
            data_off = struct.unpack_from("<I", vd, 8)[0]
            vtype = struct.unpack_from("<I", vd, 12)[0]
            flags = struct.unpack_from("<H", vd, 16)[0]
            raw_name = vd[0x14:0x14 + name_len]
            # VK flags bit0 = 名字为 ASCII，否则 UTF-16LE
            name = (raw_name.decode("latin-1", "replace")
                    if flags & 1 else raw_name.decode("utf-16-le", "replace"))
            if data_size & 0x80000000:           # 内联数据
                size = data_size & 0x7FFFFFFF
                data = struct.pack("<I", data_off)[:size]
            else:
                size = data_size
                data = self.cell(data_off)[:size] if size else b""
            out.append(dict(name=name, type=vtype, size=size, data=data))
        return out

    # ---- 导航 ----
    def find(self, path):
        off = self.root_off
        for part in [p for p in path.replace("/", "\\").split("\\") if p]:
            hit = None
            for sub in self._subkeys(off):
                if self._nk(sub)["name"].lower() == part.lower():
                    hit = sub
                    break
            if hit is None:
                return None
            off = hit
        return off

    def tree(self, off, depth=0, maxdepth=3):
        nk = self._nk(off)
        print("  " * depth + "[" + nk["name"] + "]")
        if depth >= maxdepth:
            return
        for sub in self._subkeys(off):
            self.tree(sub, depth + 1, maxdepth)


TYPES = {1: "REG_SZ", 2: "REG_EXPAND_SZ", 3: "REG_BINARY", 4: "REG_DWORD",
         5: "REG_DWORD_BIG_ENDIAN", 6: "REG_LINK", 7: "REG_MULTI_SZ",
         11: "REG_QWORD"}


def hexdump(data, prefix="      "):
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        hx = " ".join("%02x" % b for b in chunk)
        asc = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print("%s%04x  %-47s  %s" % (prefix, i, hx, asc))

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    hive_path = sys.argv[1]
    want_tree = "--tree" in sys.argv
    args = [a for a in sys.argv[2:] if not a.startswith("--")]
    key_path = args[0] if args else ""

    h = Hive(hive_path)
    if not key_path:
        h.tree(h.root_off)
        return 0

    off = h.find(key_path)
    if off is None:
        print("找不到键: %s" % key_path)
        return 2

    nk = h._nk(off)
    print("### 键: %s" % key_path)
    if want_tree:
        print("--- 子键树 ---")
        h.tree(off)
    print("--- 值 (%d 个) ---" % nk["n_val"])
    for v in h._values(off):
        t = TYPES.get(v["type"], "type=%d" % v["type"])
        print("\n  %s  [%s, %d bytes]" % (v["name"], t, v["size"]))
        if v["type"] in (1, 2, 6):
            print("    %s" % v["data"].decode("utf-16-le", "replace").rstrip("\x00"))
        elif v["type"] == 7:
            for s in v["data"].decode("utf-16-le", "replace").split("\x00"):
                if s:
                    print("    %s" % s)
        elif v["type"] == 4 and v["size"] >= 4:
            print("    0x%08x (%d)" % (struct.unpack_from("<I", v["data"], 0)[0],
                                       struct.unpack_from("<I", v["data"], 0)[0]))
        elif v["type"] == 11 and v["size"] >= 8:
            print("    0x%016x" % struct.unpack_from("<Q", v["data"], 0)[0])
        else:
            hexdump(v["data"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
