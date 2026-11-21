#!/usr/bin/env python3
"""Rename Unleashed clients from the reservations CSV.

usage: unleashed_rename.py <reservations.csv> [--fallback unifi-clients.csv] [--apply]
Names from the reservations CSV win; the fallback CSV (UniFi export: name,mac) fills in clients it lacks.
Credentials come from env UL_USER / UL_PASS. Without --apply it only lists what would change.
One login per run; stops on the first login failure so the account is never locked.
"""
import csv, html, os, re, ssl, sys, time, random, http.cookiejar, urllib.request, urllib.parse

HOST = "https://unleashed.internal.greyrock.io"
csv_path = sys.argv[1]
apply = "--apply" in sys.argv

ctx = ssl.create_default_context()
jar = http.cookiejar.CookieJar()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                     urllib.request.HTTPCookieProcessor(jar), NoRedirect)


def req(url, data=None, headers=None):
    r = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        resp = opener.open(r, timeout=30)
        return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode("utf-8", "replace")


# login (single attempt)
req(HOST + "/admin/login.jsp")
body = urllib.parse.urlencode({"username": os.environ["UL_USER"], "password": os.environ["UL_PASS"], "ok": "Log in"}).encode()
code, hdrs, page = req(HOST + "/admin/login.jsp", body, {"Content-Type": "application/x-www-form-urlencoded"})
token = hdrs.get("HTTP_X_CSRF_TOKEN") or hdrs.get("Http_x_csrf_token")
if code != 302 or not token:
    m = re.search(r'authrc = "([^"]*)"', page)
    sys.exit(f"login failed (HTTP {code}, authrc={m.group(1) if m else '?'}); stopping")


def cmdstat(xml):
    c, _, out = req(HOST + "/admin/_cmdstat.jsp", xml.encode(),
                    {"Content-Type": "text/xml", "X-CSRF-Token": token})
    return c, out


# current clients (active + known)
c, out = cmdstat("<ajax-request action='getstat' comp='stamgr' enable-gzip='0'><client LEVEL='1' client-type='3'/></ajax-request>")
clients = {}
for m in re.finditer(r"<client\b([^>]*)>", out):
    attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', m.group(1)))
    mac = attrs.get("mac", "").lower()
    if mac:
        clients[mac] = html.unescape(attrs.get("hostname", ""))
print(f"Unleashed knows {len(clients)} clients")

rows = [r for r in csv.DictReader(open(csv_path)) if r.get("mac") and r.get("name")]
want = {r["mac"].lower(): r["name"].strip() for r in rows}
if "--fallback" in sys.argv:
    fb = sys.argv[sys.argv.index("--fallback") + 1]
    for r in csv.DictReader(open(fb)):
        m = (r.get("mac") or "").lower(); n = (r.get("name") or "").strip()
        if m and n and m not in want:
            want[m] = n
todo = [(m, want[m], clients[m]) for m in want if m in clients and clients[m] != want[m]]
same = sum(1 for m in want if m in clients and clients[m] == want[m])
absent = [m for m in want if m not in clients]
print(f"CSV names: {len(want)}  already correct: {same}  to rename: {len(todo)}  not seen by Unleashed (wired or offline): {len(absent)}")
for m, new, old in todo:
    print(f"  {m}  {old!r} -> {new!r}")

if not apply:
    sys.exit(0)

ok = 0
for m, new, old in todo:
    upd = f"stamgr.{int(time.time()*1000)}.{random.randint(1000,9999)}"
    esc = html.escape(new, quote=True).replace("&#x27;", "&apos;")
    xml = (f"<ajax-request action='docmd' xcmd='rename' updater='{upd}' comp='stamgr'>"
           f"<xcmd cmd='rename' tag='client' client='{m}' rename='{esc}'/></ajax-request>")
    c, out = cmdstat(xml)
    if c == 200 and "error" not in out.lower():
        ok += 1
    else:
        print(f"  FAILED {m} {new!r}: HTTP {c} {out[:120]}")
print(f"renamed {ok}/{len(todo)}")
