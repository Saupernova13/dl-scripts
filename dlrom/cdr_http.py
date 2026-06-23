#!/usr/bin/env python3
"""cdr_http.py - Cloudflare-passing HTTP fetch for dlrom.

Why this exists: cdromance.org sits behind Cloudflare. PowerShell/.NET requests are
rejected because their TLS fingerprint isn't a browser's, and FlareSolverr (a headless
browser) can solve the challenge but cannot set request headers like X-Requested-With
that the link-reveal endpoint requires.

Strategy:
  1. FlareSolverr mints a cf_clearance cookie + matching User-Agent (real browser solve).
  2. curl_cffi replays that cookie while impersonating Chrome's TLS/HTTP2 fingerprint, so
     Cloudflare accepts it - and unlike a browser navigation we can set any header.

The cf_clearance + UA are cached on disk and reused across runs; a 403/503/429 triggers a
single re-mint + retry. Only scraping goes through here; the file download itself is a
normal direct URL handled by dlrom's downloaders.

Output contract: the response body is written to --out (UTF-8). stdout gets "OK <status>"
on success; a non-zero exit + stderr message signals failure to the PowerShell caller.
"""
import argparse
import json
import os
import sys
import time
import urllib.request
from urllib.parse import urlsplit, parse_qsl


# Progress/result go to stdout with a prefix so the PowerShell caller can parse them and
# stderr stays empty (an empty stderr avoids PowerShell wrapping native output as errors).
def log(msg):
    sys.stdout.write("LOG " + msg + "\n")
    sys.stdout.flush()

def err(msg):
    sys.stdout.write("ERR " + msg + "\n")
    sys.stdout.flush()


def solver_mint(solver_url, site_root, timeout_ms):
    """Ask FlareSolverr to solve the challenge for site_root; return (ua, cookies list).
    Cookies keep their domain/path so they are replayed to the correct host."""
    body = json.dumps({"cmd": "request.get", "url": site_root, "maxTimeout": timeout_ms}).encode()
    req = urllib.request.Request(solver_url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=(timeout_ms / 1000) + 20) as resp:
        data = json.load(resp)
    if data.get("status") != "ok":
        raise RuntimeError("FlareSolverr: " + str(data.get("message")))
    sol = data["solution"]
    cookies = [{"name": c["name"], "value": c["value"],
                "domain": c.get("domain", ""), "path": c.get("path", "/")}
               for c in sol.get("cookies", [])]
    return sol.get("userAgent", ""), cookies


def load_cache(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            o = json.load(f)
        if o.get("userAgent") and isinstance(o.get("cookies"), list) and o["cookies"]:
            return o
    except Exception:
        pass
    return None


def save_cache(path, ua, cookies):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"savedAt": time.time(), "userAgent": ua, "cookies": cookies}, f)
    except Exception as e:
        log("warn: could not write cache: %s" % e)


def make_session(ua, cookies, host):
    from curl_cffi import requests as cr
    s = cr.Session(impersonate="chrome")
    if ua:
        s.headers.update({"User-Agent": ua})
    bare = host.split(":")[0]
    for c in cookies:
        domain = c.get("domain") or ("." + bare)
        s.cookies.set(c["name"], c["value"], domain=domain, path=c.get("path") or "/")
    return s


def do_request(session, method, url, headers, data):
    if method == "POST":
        form = dict(parse_qsl(data, keep_blank_values=True)) if data else {}
        return session.post(url, data=form, headers=headers, timeout=60, allow_redirects=True)
    return session.get(url, headers=headers, timeout=60, allow_redirects=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--method", default="GET", choices=["GET", "POST"])
    ap.add_argument("--data", default="")
    ap.add_argument("--header", action="append", default=[], help="repeatable 'Key: Value'")
    ap.add_argument("--out", required=True)
    ap.add_argument("--solver", default="http://localhost:8191/v1")
    ap.add_argument("--cache", required=True)
    ap.add_argument("--timeout-ms", type=int, default=120000)
    args = ap.parse_args()

    try:
        import curl_cffi  # noqa: F401
    except ImportError:
        err("curl_cffi not installed")
        return 3

    parts = urlsplit(args.url)
    host = parts.netloc
    site_root = "%s://%s/" % (parts.scheme, host)

    headers = {}
    for h in args.header:
        if ":" in h:
            k, v = h.split(":", 1)
            headers[k.strip()] = v.strip()

    cache = load_cache(args.cache)
    if cache is None:
        log("minting cf_clearance via FlareSolverr...")
        ua, cookies = solver_mint(args.solver, site_root, args.timeout_ms)
        save_cache(args.cache, ua, cookies)
    else:
        ua, cookies = cache["userAgent"], cache["cookies"]

    blocked_codes = (403, 503, 429)
    for attempt in (1, 2):
        session = make_session(ua, cookies, host)
        try:
            r = do_request(session, args.method, args.url, headers, args.data)
        except Exception as e:
            if attempt == 2:
                err("request error: %s" % e)
                return 2
            log("request error (%s); re-minting and retrying..." % e)
            ua, cookies = solver_mint(args.solver, site_root, args.timeout_ms)
            save_cache(args.cache, ua, cookies)
            continue

        if r.status_code in blocked_codes and attempt == 1:
            log("HTTP %d (Cloudflare); re-minting and retrying..." % r.status_code)
            ua, cookies = solver_mint(args.solver, site_root, args.timeout_ms)
            save_cache(args.cache, ua, cookies)
            continue

        with open(args.out, "w", encoding="utf-8", newline="") as f:
            f.write(r.text)
        if r.status_code < 400:
            sys.stdout.write("OK %d\n" % r.status_code)
            return 0
        err("http %d" % r.status_code)
        return 2

    return 2


if __name__ == "__main__":
    sys.exit(main())
