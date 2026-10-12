#!/usr/bin/env python3
"""Kinship diagnostics tool.

  decode <file|->            report string(s) ("!KIN-DIAG1!...") -> JSON
  svars <Kinship.lua>         SavedVariables file -> JSON (inbox reports decoded)
  merge <input> [<input>...]  one timeline across clients (inputs: report text,
                              decoded JSON, or a Kinship.lua SavedVariables file)
  selftest                    checks the decoders (used by CI)

Report string = "!KIN-DIAG1!" + base64(deflate(CBOR(bundle))), produced in game
by C_EncodingUtil. No third-party packages needed.
"""
import base64
import datetime as dt
import json
import re
import struct
import sys
import zlib

TAG = "!KIN-DIAG1!"
LEVELS = {1: "ERROR", 2: "WARN", 3: "INFO", 4: "DEBUG", 5: "TRACE"}


# --------------------------------------------------------------------------- CBOR
class _Cbor:
    def __init__(self, data):
        self.d, self.i = data, 0

    def _take(self, n):
        chunk = self.d[self.i:self.i + n]
        if len(chunk) < n:
            raise ValueError("truncated CBOR")
        self.i += n
        return chunk

    def _arg(self, info):
        if info < 24:
            return info
        if info == 24:
            return self._take(1)[0]
        if info == 25:
            return struct.unpack(">H", self._take(2))[0]
        if info == 26:
            return struct.unpack(">I", self._take(4))[0]
        if info == 27:
            return struct.unpack(">Q", self._take(8))[0]
        if info == 31:
            return None  # indefinite length
        raise ValueError(f"bad additional info {info}")

    def item(self):
        b = self._take(1)[0]
        major, info = b >> 5, b & 31
        if major == 7:
            return self._simple(info)
        n = self._arg(info)
        if major == 0:
            return n
        if major == 1:
            return -1 - n
        if major in (2, 3):
            if n is None:
                parts = []
                while self.d[self.i] != 0xFF:
                    parts.append(self.item())
                self.i += 1
                raw = b"".join(p if isinstance(p, bytes) else p.encode() for p in parts)
            else:
                raw = self._take(n)
            if major == 3:
                return raw.decode("utf-8", errors="replace")
            try:  # WoW strings are bytes; show text when it is text
                return raw.decode("utf-8")
            except UnicodeDecodeError:
                return raw.hex()
        if major == 4:
            out = []
            if n is None:
                while self.d[self.i] != 0xFF:
                    out.append(self.item())
                self.i += 1
            else:
                out = [self.item() for _ in range(n)]
            return out
        if major == 5:
            out = {}
            count = 0
            while True:
                if n is None:
                    if self.d[self.i] == 0xFF:
                        self.i += 1
                        break
                elif count == n:
                    break
                k = self.item()
                out[str(k) if not isinstance(k, str) else k] = self.item()
                count += 1
            return out
        if major == 6:
            return self.item()  # ignore tags
        raise ValueError(f"bad major type {major}")

    def _simple(self, info):
        if info == 20:
            return False
        if info == 21:
            return True
        if info in (22, 23):
            return None
        if info == 25:
            h = struct.unpack(">H", self._take(2))[0]
            return _half(h)
        if info == 26:
            return struct.unpack(">f", self._take(4))[0]
        if info == 27:
            return struct.unpack(">d", self._take(8))[0]
        if info < 24:
            return info
        raise ValueError(f"bad simple value {info}")


def _half(h):
    s, e, f = (h >> 15) & 1, (h >> 10) & 31, h & 1023
    if e == 0:
        v = f * 2 ** -24
    elif e == 31:
        v = float("inf") if f == 0 else float("nan")
    else:
        v = (1 + f / 1024) * 2 ** (e - 15)
    return -v if s else v


def cbor_decode(data):
    return _Cbor(data).item()


def cbor_encode(v):
    """Minimal encoder, only for the self-test."""
    def head(major, n):
        if n < 24:
            return bytes([major << 5 | n])
        for info, fmt, lim in ((24, ">B", 0xFF), (25, ">H", 0xFFFF), (26, ">I", 0xFFFFFFFF)):
            if n <= lim:
                return bytes([major << 5 | info]) + struct.pack(fmt, n)
        return bytes([major << 5 | 27]) + struct.pack(">Q", n)
    if v is None:
        return b"\xf6"
    if v is True:
        return b"\xf5"
    if v is False:
        return b"\xf4"
    if isinstance(v, int):
        return head(0, v) if v >= 0 else head(1, -1 - v)
    if isinstance(v, float):
        return b"\xfb" + struct.pack(">d", v)
    if isinstance(v, str):
        b = v.encode()
        return head(3, len(b)) + b
    if isinstance(v, list):
        return head(4, len(v)) + b"".join(cbor_encode(x) for x in v)
    if isinstance(v, dict):
        return head(5, len(v)) + b"".join(cbor_encode(k) + cbor_encode(x) for k, x in v.items())
    raise TypeError(type(v))


# --------------------------------------------------------------------------- report strings
def _inflate(data):
    for wbits in (-15, 15, 31):  # raw deflate, zlib, gzip
        try:
            return zlib.decompress(data, wbits)
        except zlib.error:
            continue
    raise ValueError("cannot decompress (not deflate/zlib/gzip)")


def decode_report(text):
    text = text.strip()
    if text.startswith(TAG):
        text = text[len(TAG):]
    text = re.sub(r"\s+", "", text)
    return cbor_decode(_inflate(base64.b64decode(text + "=" * (-len(text) % 4))))


def find_reports(text):
    return re.findall(re.escape(TAG) + r"[A-Za-z0-9+/=]+", text)


# --------------------------------------------------------------------------- SavedVariables
class _LuaParser:
    TOKEN = re.compile(r"""
        (?P<ws>\s+|--[^\n]*)
      | (?P<str>"(?:\\.|[^"\\])*")
      | (?P<num>-?(?:0x[0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|inf|nan))
      | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
      | (?P<op>[{}\[\]=,;])
    """, re.X)

    def __init__(self, src):
        self.toks = []
        pos = 0
        while pos < len(src):
            m = self.TOKEN.match(src, pos)
            if not m:
                raise ValueError(f"unexpected character at {pos}: {src[pos:pos + 20]!r}")
            pos = m.end()
            kind = m.lastgroup
            if kind != "ws":
                self.toks.append((kind, m.group()))
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self, value=None):
        tok = self.peek()
        if value is not None and tok[1] != value:
            raise ValueError(f"expected {value!r}, got {tok[1]!r}")
        self.i += 1
        return tok

    def value(self):
        kind, text = self.take()
        if kind == "str":
            return _lua_unescape(text[1:-1])
        if kind == "num":
            if text in ("inf", "nan"):
                return float(text)
            n = int(text, 16) if text.lower().startswith(("0x", "-0x")) else float(text)
            return int(n) if isinstance(n, float) and n.is_integer() and "." not in text and "e" not in text.lower() else n
        if kind == "name":
            return {"true": True, "false": False, "nil": None}.get(text, text)
        if text == "{":
            return self.table()
        raise ValueError(f"unexpected {text!r}")

    def table(self):
        arr, obj = [], {}
        while self.peek()[1] != "}":
            if self.peek()[1] == "[":
                self.take("[")
                key = self.value()
                self.take("]")
                self.take("=")
                obj[key] = self.value()
            elif self.peek()[0] == "name" and self.toks[self.i + 1][1] == "=":
                key = self.take()[1]
                self.take("=")
                obj[key] = self.value()
            else:
                arr.append(self.value())
            if self.peek()[1] in (",", ";"):
                self.take()
        self.take("}")
        # Pure positional table (or [1]..[n] keys) -> list.
        if obj and not arr and all(isinstance(k, int) for k in obj) and set(obj) == set(range(1, len(obj) + 1)):
            return [obj[k] for k in range(1, len(obj) + 1)]
        if obj:
            for idx, v in enumerate(arr, 1):
                obj[idx] = v
            return {str(k): v for k, v in obj.items()}
        return arr

    def assignments(self):
        out = {}
        while self.peek()[0] is not None:
            name = self.take()[1]
            self.take("=")
            out[name] = self.value()
        return out


def _lua_unescape(s):
    def rep(m):
        e = m.group(1)
        return {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}.get(e) or chr(int(e))
    return re.sub(r"\\(\d{1,3}|.|\n)", rep, s)


def parse_svars(text):
    return _LuaParser(text).assignments()


# --------------------------------------------------------------------------- inputs & timeline
def load_input(path):
    """Returns a list of (label, bundle) from any supported input."""
    text = sys.stdin.read() if path == "-" else open(path, encoding="utf-8", errors="replace").read()
    stripped = text.lstrip()
    if stripped.startswith("{"):
        data = json.loads(text)
        return [(data.get("from", path), data)]
    if re.match(r"^\s*Kinship\w*\s*=", text):
        sv = parse_svars(text)
        log = sv.get("KinshipLog") or {}
        bundles = [("local:" + path, {"from": "local", "sessions": log.get("sessions", [])})]
        for r in log.get("inbox", []) or []:
            if r.get("data"):
                b = decode_report(r["data"])
                bundles.append((b.get("from", r.get("from", "?")), b))
        return bundles
    return [(b.get("from", path), b) for b in (decode_report(s) for s in find_reports(text))]


def timeline(bundles):
    rows = []
    for label, b in bundles:
        for s in b.get("sessions", []) or []:
            h = s.get("header", {}) or {}
            a_srv, a_ms = h.get("anchorServer"), h.get("anchorMs")
            for r in s.get("records", []) or []:
                srv, ms = r[0], r[1]
                t = a_srv + (ms - a_ms) / 1000 if a_srv and a_ms else float(srv)
                data = r[5] if len(r) > 5 else None
                rows.append((t, label, LEVELS.get(r[2], r[2]), r[3], r[4], data))
    rows.sort(key=lambda x: x[0])
    return rows


def fmt_time(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


# --------------------------------------------------------------------------- commands
def cmd_decode(args):
    text = sys.stdin.read() if not args or args[0] == "-" else open(args[0], encoding="utf-8").read()
    reports = find_reports(text) or [text]
    out = [decode_report(r) for r in reports]
    json.dump(out[0] if len(out) == 1 else out, sys.stdout, indent=1, ensure_ascii=False)
    print()


def cmd_svars(args):
    sv = parse_svars(open(args[0], encoding="utf-8", errors="replace").read())
    for r in (sv.get("KinshipLog") or {}).get("inbox", []) or []:
        if r.get("data"):
            r["decoded"] = decode_report(r["data"])
    json.dump(sv, sys.stdout, indent=1, ensure_ascii=False)
    print()


def cmd_merge(args):
    bundles = []
    for path in args:
        bundles.extend(load_input(path))
    for t, label, lvl, cat, code, data in timeline(bundles):
        print(f"{fmt_time(t)}  {label:<16} {lvl:<5} {cat:<6} {code:<16} {json.dumps(data, ensure_ascii=False) if data is not None else ''}")


def cmd_selftest(_args):
    bundle = {"v": 1, "from": "Tester", "sessions": [
        {"header": {"version": "0.1.0-alpha", "anchorServer": 1760000000, "anchorMs": 5000},
         "records": [[1760000001, 6000, 3, "test", "S1_TX", {"seq": 1, "res": "Success"}]]}]}
    raw = cbor_encode(bundle)
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    s = TAG + base64.b64encode(co.compress(raw) + co.flush()).decode()
    assert decode_report(s) == bundle, "report roundtrip"
    assert decode_report(find_reports("x " + s + "\n y")[0]) == bundle, "find in text"
    sv = parse_svars('KinshipLog = {\n["inbox"] = {\n{\n["from"] = "A-B",\n["data"] = "' + s + '",\n},\n},\n["sessions"] = {},\n}\nKinshipDB = { ["x"] = 1.5, true, "a\\"b" }\n')
    assert sv["KinshipLog"]["inbox"][0]["from"] == "A-B"
    assert decode_report(sv["KinshipLog"]["inbox"][0]["data"]) == bundle
    assert sv["KinshipDB"]["x"] == 1.5 and sv["KinshipDB"]["1"] is True and sv["KinshipDB"]["2"] == 'a"b'
    rows = timeline([("t", bundle)])
    assert rows[0][0] == 1760000001.0 and rows[0][4] == "S1_TX"
    print("selftest ok")


COMMANDS = {"decode": cmd_decode, "svars": cmd_svars, "merge": cmd_merge, "selftest": cmd_selftest}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(2)
    COMMANDS[sys.argv[1]](sys.argv[2:])
