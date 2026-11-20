#!/usr/bin/env python3
"""Read-only Matter Server check.

usage:
  uv run --no-project --with websockets python matter-check.py            # every node: availability
  uv run --no-project --with websockets python matter-check.py --live     # plus a live on/off read per node
  uv run --no-project --with websockets python matter-check.py --node 87  # one node: MAC, serial, last interview

A node that is "available" can still have lost its subscription (see the 2026-11-16 note in
docs/homeassistant): a live read that disagrees with the cached on/off value is the tell.
The Matter Server runs alongside Home Assistant at ws://10.1.10.3:5580/ws.
"""
import argparse
import asyncio
import base64
import json

import websockets

URL = "ws://10.1.10.3:5580/ws"


async def call(ws, mid, command, args=None):
    await ws.send(json.dumps({"message_id": str(mid), "command": command, "args": args or {}}))
    while True:
        msg = json.loads(await ws.recv())
        if msg.get("message_id") == str(mid):
            return msg


def mac_of(attrs):
    for iface in attrs.get("0/51/0") or []:
        hw = iface.get("4")
        if hw:
            try:
                return base64.b64decode(hw).hex(":")
            except Exception:
                return hw
    return ""


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", action="store_true", help="read each node's on/off state live")
    ap.add_argument("--node", type=int, help="show one node in detail")
    opts = ap.parse_args()

    async with websockets.connect(URL, max_size=None, open_timeout=10) as ws:
        await ws.recv()  # server info
        if opts.node is not None:
            node = (await call(ws, 1, "get_node", {"node_id": opts.node}))["result"]
            a = node["attributes"]
            print(f"node {opts.node}: available={node.get('available')} vendor={a.get('0/40/1')} "
                  f"product={a.get('0/40/3')} serial={a.get('0/40/15')} mac={mac_of(a)} "
                  f"last_interview={node.get('last_interview')}")
            return

        nodes = (await call(ws, 1, "get_nodes"))["result"]
        mid = 100
        unavailable, mismatched = [], []
        for n in nodes:
            a = n.get("attributes", {})
            line = f"{n['node_id']:>4} | {'up  ' if n.get('available') else 'DOWN'} | {a.get('0/40/1') or ''} | {a.get('0/40/3') or ''} | {mac_of(a)}"
            if not n.get("available"):
                unavailable.append(n["node_id"])
            onoff = next((k for k in a if k.endswith("/6/0")), None)
            if opts.live and onoff and n.get("available"):
                mid += 1
                try:
                    r = await asyncio.wait_for(
                        call(ws, mid, "read_attribute", {"node_id": n["node_id"], "attribute_path": onoff}), 10)
                    live = (r.get("result") or {}).get(onoff)
                except asyncio.TimeoutError:
                    live = "timeout"
                line += f" | cached={a[onoff]} live={live}"
                if live != a[onoff]:
                    mismatched.append(n["node_id"])
            print(line)
        print(f"nodes: {len(nodes)}  unavailable: {unavailable}" + (f"  live/cached mismatch: {mismatched}" if opts.live else ""))


asyncio.run(main())
