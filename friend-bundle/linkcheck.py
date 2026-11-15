# linkcheck.py <mod.jar> <lib.jar> [<lib.jar>...]
# Reports every field/method/class reference in mod.jar that does not resolve
# against the library jars (game jar, Viewpoint jar, ...). JDK refs are skipped.
import sys, zipfile, struct, io

def parse(data):
    if data[:4] != b"\xca\xfe\xba\xbe":
        return None
    off = 8
    n = struct.unpack(">H", data[off:off+2])[0]; off += 2
    cp = [None] * n
    i = 1
    while i < n:
        t = data[off]; off += 1
        if t == 1:
            ln = struct.unpack(">H", data[off:off+2])[0]; off += 2
            cp[i] = (1, data[off:off+ln].decode("utf-8", "replace")); off += ln
        elif t in (3, 4): off += 4
        elif t in (5, 6): off += 8; i += 1
        elif t in (7, 8, 16, 19, 20):
            cp[i] = (t, struct.unpack(">H", data[off:off+2])[0]); off += 2
        elif t in (9, 10, 11, 12, 17, 18):
            cp[i] = (t,) + struct.unpack(">HH", data[off:off+4]); off += 4
        elif t == 15: off += 3
        else: raise Exception("tag %d" % t)
        i += 1
    utf = lambda k: cp[k][1]
    cname = lambda k: utf(cp[k][1])
    acc, this, sup = struct.unpack(">HHH", data[off:off+6]); off += 6
    ic = struct.unpack(">H", data[off:off+2])[0]; off += 2
    ifaces = [cname(struct.unpack(">H", data[off+2*j:off+2*j+2])[0]) for j in range(ic)]
    off += 2 * ic
    members = []
    for _ in range(2):
        c = struct.unpack(">H", data[off:off+2])[0]; off += 2
        s = set()
        for _ in range(c):
            a, ni, di, ac = struct.unpack(">HHHH", data[off:off+8]); off += 8
            for _ in range(ac):
                ln = struct.unpack(">I", data[off+2:off+6])[0]; off += 6 + ln
            s.add((utf(ni), utf(di)))
        members.append(s)
    ac = struct.unpack(">H", data[off:off+2])[0]; off += 2
    annos = []
    def elem(o, out):
        t = chr(data[o]); o += 1
        if t in "BCDFIJSZs":
            k = struct.unpack(">H", data[o:o+2])[0]; o += 2
            out.append(cp[k][1] if cp[k] and cp[k][0] == 1 else None)
        elif t == "e": o += 4; out.append(None)
        elif t == "c": o += 2; out.append(None)
        elif t == "@": o = anno(o, [])
        elif t == "[":
            c = struct.unpack(">H", data[o:o+2])[0]; o += 2
            for _ in range(c): o = elem(o, [])
            out.append(None)
        return o
    def anno(o, sink):
        ti, np = struct.unpack(">HH", data[o:o+4]); o += 4
        d = {"@": utf(ti)}
        for _ in range(np):
            ni = struct.unpack(">H", data[o:o+2])[0]; o += 2
            v = []; o = elem(o, v); d[utf(ni)] = v[0] if v else None
        sink.append(d); return o
    for _ in range(ac):
        ni, ln = struct.unpack(">HI", data[off:off+6]); off += 6
        if utf(ni) in ("RuntimeVisibleAnnotations", "RuntimeInvisibleAnnotations"):
            o = off; c = struct.unpack(">H", data[o:o+2])[0]; o += 2
            for _ in range(c): o = anno(o, annos)
        off += ln
    refs, classes, strings = [], set(), set()
    for e in cp:
        if not e: continue
        if e[0] in (9, 10, 11):
            nat = cp[e[2]]
            refs.append((e[0], cname(e[1]), utf(nat[1]), utf(nat[2])))
        elif e[0] == 7:
            classes.add(utf(e[1]))
        elif e[0] == 1:
            strings.add(e[1])
    return dict(name=cname(this), sup=cname(sup) if sup else None, ifaces=ifaces,
                fields=members[0], methods=members[1], annos=annos, refs=refs, classes=classes, strings=strings)

def load(path):
    out = {}
    def walk(zf):
        for n in zf.namelist():
            if n.endswith(".class"):
                try:
                    c = parse(zf.read(n))
                    if c: out[c["name"]] = c
                except Exception as ex:
                    print("  !! parse fail", n, ex)
            elif n.endswith(".jar"):
                walk(zipfile.ZipFile(io.BytesIO(zf.read(n))))
    walk(zipfile.ZipFile(path))
    return out

mod = load(sys.argv[1])
lib = {}
for p in sys.argv[2:]:
    lib.update(load(p))
known = dict(lib); known.update(mod)
prefixes = set(k.split("/")[0] + "/" + (k.split("/")[1] if "/" in k else "") for k in lib)

def ours(c):
    c = c.lstrip("[").lstrip("L").rstrip(";")
    if c in known: return True
    return c.startswith("zombie/")

MAYBE=set()
def find(cls, name, desc, kind, seen=None):
    seen = seen or set()
    if cls in seen: return True
    seen.add(cls)
    c = known.get(cls)
    if c is None:
        return not cls.startswith("zombie/")  # JDK/unknown parent: assume ok
    if (name, desc) in (c["fields"] if kind == 9 else c["methods"]): return True
    for p in ([c["sup"]] if c["sup"] else []) + c["ifaces"]:
        if p in known or p.startswith("zombie/"):
            if find(p, name, desc, kind, seen): return True
        elif p not in ("java/lang/Object","java/io/Serializable","java/lang/Cloneable","java/lang/Runnable","java/lang/Comparable"):
            MAYBE.add(cls)
    return False

bad = set()
for c in mod.values():
    for k in c["classes"]:
        kk = k.lstrip("[")
        if kk.startswith("L"): kk = kk[1:].rstrip(";")
        if kk.startswith("zombie/") and kk not in known:
            bad.add(("MISSING CLASS", kk, "", "", c["name"]))
    for kind, cls, name, desc in c["refs"]:
        if cls.startswith("["): continue
        if not ours(cls): continue
        if cls not in known:
            continue
        MAYBE.clear()
        if not find(cls, name, desc, kind):
            if MAYBE and not any(n == name for k2 in known.values() if k2["name"]==cls for (n,d) in k2["methods"]|k2["fields"]): continue
            alts = sorted(d for (n, d) in (known[cls]["fields"] if kind == 9 else known[cls]["methods"]) if n == name)
            bad.add(("FIELD" if kind == 9 else "METHOD", cls, name, desc, c["name"] + ("  now: " + " | ".join(alts) if alts else "  (gone)")))
npatch = 0
for c in mod.values():
    for a in c["annos"]:
        cn = a.get("className")
        if not cn: continue
        npatch += 1
        t = known.get(cn.replace(".", "/"))
        mn = a.get("methodName")
        if t is None:
            if cn.startswith("zombie."): bad.add(("PATCH CLASS", cn, "", "", c["name"]))
        elif mn and not any(n == mn for (n, d) in t["methods"]):
            bad.add(("PATCH METHOD", cn, mn, "", c["name"] + "  (gone)"))
print("  patches checked: %d" % npatch)
print("%s: %d classes, %d broken refs" % (sys.argv[1].replace("\\", "/").split("/")[-1], len(mod), len(bad)))
for b in sorted(bad):
    print("  %-13s %s.%s %s   <- %s" % b)
