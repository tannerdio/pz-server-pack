# pzfix.py <in.jar> <out.jar>
# 42.22 removed zombie.util.list.PZArrayList; IsoGridSquare.getObjects() now returns java.util.List.
# Rewrites every class in the jar so that:
#   - every "zombie/util/list/PZArrayList" in the constant pool becomes "java/util/List"
#   - invokevirtual PZArrayList.size()/get(int) becomes invokestatic pzcompat/ListShim.size(List)/get(List,int)
#     (same instruction length, so no offsets or stack maps move)
# and adds the pzcompat/ListShim class to the jar.
import sys, zipfile, struct

OLD = "zombie/util/list/PZArrayList"
NEW = "java/util/List"
SHIM = "pzcompat/ListShim"
SHIM_DESC = {("size", "()I"): "(Ljava/util/List;)I",
             ("get", "(I)Ljava/lang/Object;"): "(Ljava/util/List;I)Ljava/lang/Object;"}

# operand byte counts for fixed-length opcodes
LEN = {}
for op in range(0x00, 0xCA): LEN[op] = 0
for op in (0x10, 0x12, 0x15, 0x16, 0x17, 0x18, 0x19, 0x36, 0x37, 0x38, 0x39, 0x3A, 0xA9, 0xBC): LEN[op] = 1
for op in (0x11, 0x13, 0x14, 0x84, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xBB, 0xBD, 0xC0, 0xC1, 0xC6, 0xC7): LEN[op] = 2
for op in range(0x99, 0xA9): LEN[op] = 2
LEN[0xC5] = 3
for op in (0xB9, 0xBA, 0xC8, 0xC9): LEN[op] = 4

def u2(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u4(b, o): return struct.unpack(">I", b[o:o+4])[0]
def i4(b, o): return struct.unpack(">i", b[o:o+4])[0]

def patch_class(data):
    """returns (new_bytes, n_calls_patched) or (None, 0) if the class does not mention PZArrayList"""
    if OLD.encode() not in data: return None, 0
    n = u2(data, 8)
    off = 10
    entries = [None] * n          # raw (tag, payload bytes)
    i = 1
    while i < n:
        t = data[off]
        if t == 1:
            ln = u2(data, off + 1); size = 3 + ln
        elif t in (3, 4): size = 5
        elif t in (5, 6): size = 9
        elif t in (7, 8, 16, 19, 20): size = 3
        elif t in (9, 10, 11, 12, 17, 18): size = 5
        elif t == 15: size = 4
        else: raise Exception("cp tag %d" % t)
        entries[i] = bytearray(data[off:off + size])
        off += size
        i += 2 if t in (5, 6) else 1
    cp_end = off
    def utf(k): return bytes(entries[k][3:]).decode("utf-8")
    # which Methodrefs point at PZArrayList (before renaming)
    targets = {}
    for k in range(1, n):
        e = entries[k]
        if e and e[0] == 10:
            ci, ni = u2(e, 1), u2(e, 3)
            if utf(u2(entries[ci], 1)) == OLD:
                nat = entries[ni]
                key = (utf(u2(nat, 1)), utf(u2(nat, 3)))
                if key not in SHIM_DESC:
                    raise Exception("unsupported PZArrayList call %s%s" % key)
                targets[k] = (u2(nat, 1), key)
        if e and e[0] in (9, 11):
            ci = u2(e, 1)
            if utf(u2(entries[ci], 1)) == OLD:
                raise Exception("unsupported field/interface ref on PZArrayList")
    # rename in every utf8
    for k in range(1, n):
        e = entries[k]
        if e and e[0] == 1:
            s = bytes(e[3:])
            if OLD.encode() in s:
                s = s.replace(OLD.encode(), NEW.encode())
                entries[k] = bytearray(b"\x01" + struct.pack(">H", len(s)) + s)
    # append shim entries
    extra = []
    def add(raw):
        extra.append(raw); return n + len(extra) - 1
    def add_utf(s):
        b = s.encode(); return add(b"\x01" + struct.pack(">H", len(b)) + b)
    if targets:
        shim_cls = add(b"\x07" + struct.pack(">H", add_utf(SHIM)))
        for k, (name_idx, key) in targets.items():
            nat = add(b"\x0c" + struct.pack(">HH", name_idx, add_utf(SHIM_DESC[key])))
            entries[k] = bytearray(b"\x0a" + struct.pack(">HH", shim_cls, nat))
    new_cp = b"".join(bytes(e) for e in entries if e) + b"".join(extra)
    body = bytearray(data[cp_end:])
    # walk fields + methods, patch call sites inside Code attributes
    patched = 0
    o = 6
    o += 2 + 2 * u2(body, o)                     # interfaces
    for section in range(2):
        cnt = u2(body, o); o += 2
        for _ in range(cnt):
            name_i = u2(body, o + 2)
            ac = u2(body, o + 6); o += 8
            for _ in range(ac):
                an, ln = u2(body, o), u4(body, o + 2)
                if section == 1 and utf(an) == "Code":
                    clen = u4(body, o + 10)
                    cs = o + 14
                    p = cs
                    while p < cs + clen:
                        op = body[p]
                        if op == 0xAA:
                            q = p + 1 + ((4 - ((p - cs + 1) % 4)) % 4)
                            lo, hi = i4(body, q + 4), i4(body, q + 8)
                            p = q + 12 + 4 * (hi - lo + 1)
                        elif op == 0xAB:
                            q = p + 1 + ((4 - ((p - cs + 1) % 4)) % 4)
                            p = q + 8 + 8 * i4(body, q + 4)
                        elif op == 0xC4:
                            p += 6 if body[p + 1] == 0x84 else 4
                        else:
                            if op in (0xB6, 0xB7, 0xB8, 0xB9) and u2(body, p + 1) in targets:
                                if op != 0xB6: raise Exception("PZArrayList call via opcode %#x" % op)
                                body[p] = 0xB8
                                patched += 1
                            p += 1 + LEN[op]
                    if p != cs + clen: raise Exception("code walk desync in %s" % utf(name_i))
                o += 6 + ln
    if targets and not patched: raise Exception("methodrefs found but no call sites")
    out = data[:8] + struct.pack(">H", n + len(extra)) + new_cp + bytes(body)
    return out, patched

def shim_class():
    cp = []
    def add(raw): cp.append(raw); return len(cp)
    def U(s): b = s.encode(); return add(b"\x01" + struct.pack(">H", len(b)) + b)
    def C(s): return add(b"\x07" + struct.pack(">H", U(s)))
    def NAT(nm, d): return add(b"\x0c" + struct.pack(">HH", U(nm), U(d)))
    this, sup, lst = C(SHIM), C("java/lang/Object"), C("java/util/List")
    code = U("Code")
    m_size = add(b"\x0b" + struct.pack(">HH", lst, NAT("size", "()I")))
    m_get = add(b"\x0b" + struct.pack(">HH", lst, NAT("get", "(I)Ljava/lang/Object;")))
    def method(nm, desc, stack, locs, bc):
        attr = struct.pack(">HHI", stack, locs, len(bc)) + bc + struct.pack(">HH", 0, 0)
        return struct.pack(">HHHH", 0x0009, U(nm), U(desc), 1) + struct.pack(">HI", code, len(attr)) + attr
    ms = [method("size", "(Ljava/util/List;)I", 1, 1, b"\x2a\xb9" + struct.pack(">H", m_size) + b"\x01\x00\xac"),
          method("get", "(Ljava/util/List;I)Ljava/lang/Object;", 2, 2, b"\x2a\x1b\xb9" + struct.pack(">H", m_get) + b"\x02\x00\xb0")]
    return (b"\xca\xfe\xba\xbe" + struct.pack(">HH", 0, 52) + struct.pack(">H", len(cp) + 1) + b"".join(cp)
            + struct.pack(">HHHH", 0x0031, this, sup, 0) + struct.pack(">H", 0)
            + struct.pack(">H", len(ms)) + b"".join(ms) + struct.pack(">H", 0))

if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    zin = zipfile.ZipFile(src)
    total = classes = 0
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            data = zin.read(info.filename)
            up = info.filename.upper()
            if up.startswith("META-INF/") and up.endswith((".SF", ".RSA", ".DSA", ".EC")):
                print("  dropping signature file", info.filename); continue
            if info.filename.endswith(".class"):
                new, k = patch_class(data)
                if new is not None:
                    data = new; classes += 1; total += k
            zi = zipfile.ZipInfo(info.filename, info.date_time)
            zi.compress_type = zipfile.ZIP_STORED if info.is_dir() else zipfile.ZIP_DEFLATED
            zi.external_attr = info.external_attr
            zout.writestr(zi, data)
        if total or classes:
            zout.writestr(SHIM + ".class", shim_class())
    print("%s: %d classes rewritten, %d call sites" % (src.replace("\\", "/").split("/")[-1], classes, total))
