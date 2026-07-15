#!/usr/bin/env python3
# Build a compact index of a multi-file PS2 archive .torrent for dlrom's torrent
# fallback. Pure standard library (no pip deps). Emits JSON with the v1 infohash,
# the torrent name, its trackers, and every file's (index, path, length).
#
# The file order in a v1 torrent's info dict is exactly the file-index order that
# qBittorrent uses for per-file priority, so the emitted "index" can drive a
# selective (single-file) download.
#
# Usage:
#   python ps2_torrent.py build --torrent <path.torrent> --out <index.json> [--force]
#
# Exit codes: 0 ok (built or already current), 2 error.

import argparse
import hashlib
import json
import os
import sys


def _decode(data, i):
    """Decode one bencoded value at offset i. Returns (value, next_offset)."""
    c = data[i:i + 1]
    if c == b'i':
        j = data.index(b'e', i)
        return int(data[i + 1:j]), j + 1
    if c == b'l':
        i += 1
        out = []
        while data[i:i + 1] != b'e':
            v, i = _decode(data, i)
            out.append(v)
        return out, i + 1
    if c == b'd':
        i += 1
        out = {}
        while data[i:i + 1] != b'e':
            k, i = _decode(data, i)
            v, i = _decode(data, i)
            out[k] = v
        return out, i + 1
    if c.isdigit():
        colon = data.index(b':', i)
        n = int(data[i:colon])
        start = colon + 1
        return data[start:start + n], start + n
    raise ValueError("invalid bencode at offset %d: %r" % (i, c))


def _decode_top(data):
    """Decode the top-level dict and also capture the raw bytes of the info value,
    so the v1 infohash is computed over the original bytes (key order preserved)."""
    if data[0:1] != b'd':
        raise ValueError("not a bencoded dict")
    i = 1
    top = {}
    info_raw = None
    while data[i:i + 1] != b'e':
        k, i = _decode(data, i)
        v_start = i
        v, i = _decode(data, i)
        if k == b'info':
            info_raw = data[v_start:i]
        top[k] = v
    return top, info_raw


def _text(b):
    return b.decode('utf-8', 'replace') if isinstance(b, (bytes, bytearray)) else str(b)


def _trackers(top):
    seen = []
    def add(u):
        u = _text(u).strip()
        if u and u not in seen:
            seen.append(u)
    if b'announce' in top:
        add(top[b'announce'])
    for tier in top.get(b'announce-list', []) or []:
        for u in tier:
            add(u)
    return seen


def build(torrent_path, out_path, force):
    src_stat = os.stat(torrent_path)
    # Identity is the torrent's byte size only: it is stable across machines and
    # keeps no absolute/home path in the committed index. A 20+ MB archive torrent
    # will not collide on size in practice.
    src_meta = {"name": os.path.basename(torrent_path), "size": src_stat.st_size}

    if not force and os.path.exists(out_path):
        try:
            with open(out_path, 'r', encoding='utf-8') as fh:
                prev = json.load(fh)
            if prev.get("source", {}).get("size") == src_stat.st_size:
                print("index already current: %s (%d files)"
                      % (out_path, len(prev.get("files", []))))
                return 0
        except Exception:
            pass  # rebuild on any read/parse trouble

    with open(torrent_path, 'rb') as fh:
        data = fh.read()

    top, info_raw = _decode_top(data)
    if info_raw is None:
        raise ValueError("torrent has no info dict")
    info = top[b'info']

    infohash_v1 = hashlib.sha1(info_raw).hexdigest()
    name = _text(info.get(b'name', b''))
    meta_version = info.get(b'meta version')  # 2 => v2/hybrid
    files = []

    if b'files' in info:
        for idx, f in enumerate(info[b'files']):
            parts = [_text(p) for p in f.get(b'path', [])]
            rel = "/".join([name] + parts) if name else "/".join(parts)
            files.append({"index": idx, "path": rel, "length": int(f.get(b'length', 0))})
    else:
        files.append({"index": 0, "path": name, "length": int(info.get(b'length', 0))})

    doc = {
        "schema": 1,
        "source": src_meta,
        "name": name,
        "infohash_v1": infohash_v1,
        "meta_version": meta_version if meta_version is None else int(meta_version),
        "trackers": _trackers(top),
        "files": files,
    }

    out_dir = os.path.dirname(os.path.abspath(out_path))
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as fh:
        json.dump(doc, fh, ensure_ascii=False)

    kind = "hybrid/v2" if doc["meta_version"] else "v1"
    print("built %s: %d files, %s torrent, infohash_v1=%s"
          % (out_path, len(files), kind, infohash_v1))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="ps2_torrent.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="build the JSON index from a .torrent")
    b.add_argument("--torrent", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--force", action="store_true")
    args = ap.parse_args(argv)

    if args.cmd == "build":
        if not os.path.isfile(args.torrent):
            print("torrent not found: %s" % args.torrent, file=sys.stderr)
            return 2
        try:
            return build(args.torrent, args.out, args.force)
        except Exception as ex:  # noqa: BLE001 - report and fail cleanly
            print("index build failed: %s" % ex, file=sys.stderr)
            return 2
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
