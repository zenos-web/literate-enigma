#!/usr/bin/env python3
"""Verify CarWithin's live LAN transport (WebSocket packets, not browser rendering)."""

import argparse
import asyncio
import json
import ssl
import time
from contextlib import AsyncExitStack, asynccontextmanager

from websockets.exceptions import InvalidStatusCode
from websockets.legacy.client import connect


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


def endpoint(args, secure):
    scheme, port = ("wss", args.https_port) if secure else ("ws", args.http_port)
    options = {}
    if secure and args.insecure:
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        options["ssl"] = context
    return connect(f"{scheme}://{args.host}:{port}/stream", open_timeout=5,
                   close_timeout=1, max_size=16 * 1024 * 1024, **options)


@asynccontextmanager
async def viewer(args, decoder):
    async with endpoint(args, secure=decoder == "webcodecs") as ws:
        hello = json.loads(await asyncio.wait_for(ws.recv(), 5))
        if hello.get("type") != "hello":
            raise RuntimeError("missing hello message")
        await ws.send(json.dumps({"type": "ready", "decoder": decoder}))
        yield ws


async def monitor(ws, name, decoder, duration, max_gap):
    start = last_frame = last_report = time.monotonic()
    next_ping = start
    frames = keyframes = pongs = 0
    recovery_at = None
    recoveries = idle_probes = 0
    initialized = False
    last_ping = None
    fmt = None
    largest_gap = 0
    while time.monotonic() - start < duration:
        now = time.monotonic()
        if now >= next_ping:
            if last_ping is not None:
                raise TimeoutError(f"{name}: no pong within 5 seconds")
            last_ping = int(now * 1000)
            await ws.send(json.dumps({"type": "ping", "t0": last_ping}))
            next_ping = now + 5
        try:
            msg = await asyncio.wait_for(ws.recv(), min(1, max_gap))
        except asyncio.TimeoutError:
            msg = None
        now = time.monotonic()
        if now - last_frame >= max_gap:
            raise TimeoutError(f"{name}: no video frame for {now - last_frame:.2f}s")
        if isinstance(msg, str):
            data = json.loads(msg)
            if data.get("type") == "format":
                fmt = data
                if data.get("decoder") != decoder or (
                    decoder == "webcodecs" and not data.get("description")
                ):
                    raise RuntimeError(f"{name}: unexpected format {data}")
                log(f"{name}: {data['codec']} {data['width']}×{data['height']} ({decoder})")
            elif data.get("type") == "pong" and last_ping is not None and data.get("t0") == last_ping:
                pongs += 1
                last_ping = None
        elif msg is not None:
            if not msg or msg[0] not in (0, 1, 2):
                raise RuntimeError(f"{name}: malformed video packet")
            if msg[0] == 2:
                initialized = b"ftyp" in msg and b"moov" in msg
            else:
                if decoder == "mse" and (not initialized or b"moof" not in msg or b"mdat" not in msg):
                    raise RuntimeError(f"{name}: malformed MP4 fragment")
                if decoder == "webcodecs" and (len(msg) <= 13 or not int.from_bytes(msg[1:9], "big")):
                    raise RuntimeError(f"{name}: malformed WebCodecs packet")
                frames += 1
                keyframes += msg[0] == 1
                if msg[0] == 1 and recovery_at is not None:
                    recoveries += 1
                    recovery_at = None
                largest_gap = max(largest_gap, now - last_frame)
                last_frame = now
        if recovery_at is not None and now - recovery_at >= 3:
            raise TimeoutError(f"{name}: no keyframe within 3 seconds of a recovery request")
        # CarPlay can stop producing ordinary frames when the screen is static.
        # Probe the source with a keyframe request before treating a pause as a stall.
        if recovery_at is None and (now - last_frame >= min(3, max_gap / 2) or (frames >= 30 and not recoveries)):
            await ws.send('{"type":"keyframe","reason":"transport stability test"}')
            recovery_at = now
            idle_probes += now - last_frame >= min(3, max_gap / 2)
        if now - last_report >= 20:
            log(f"{name}: {now-start:.1f}s, {frames} frames, {pongs} pongs, max gap {largest_gap:.3f}s")
            last_report = now
    if not fmt or not frames or not recoveries or not pongs:
        raise RuntimeError(f"{name}: incomplete stream or keyframe recovery")
    log(f"{name}: PASS {time.monotonic()-start:.1f}s, {frames} frames, "
        f"{keyframes} keyframes, {recoveries} recoveries ({idle_probes} idle probes), "
        f"{pongs} pongs, max gap {largest_gap:.3f}s")


async def run(args):
    async with viewer(args, args.decoder) as primary:
        if not args.multi:
            await monitor(primary, "primary", args.decoder, args.duration, args.max_gap)
            return
        async with AsyncExitStack() as stack:
            second = await stack.enter_async_context(viewer(args, "mse"))
            third = await stack.enter_async_context(viewer(args, "webcodecs"))
            fourth = None if args.existing_viewer else await stack.enter_async_context(viewer(args, "mse"))
            try:
                async with endpoint(args, secure=False):
                    raise RuntimeError("unexpectedly accepted a fifth viewer")
            except InvalidStatusCode as error:
                if error.status_code != 503:
                    raise
                log("fifth viewer: PASS HTTP 503")

            async def reconnect():
                await monitor(second, "second", "mse", 8, args.max_gap)
                await second.close()
                await asyncio.sleep(0.5)
                async with viewer(args, "mse") as reconnected:
                    await monitor(reconnected, "second reconnected", "mse", 8, args.max_gap)

            checks = [monitor(primary, "primary", args.decoder, args.duration, args.max_gap),
                      reconnect(), monitor(third, "third", "webcodecs", args.duration, args.max_gap)]
            if fourth is not None:
                checks.append(monitor(fourth, "fourth", "mse", args.duration, args.max_gap))
            await asyncio.gather(*checks)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", help="iPhone IPv4 address on this LAN")
    parser.add_argument("--http-port", type=int, default=9888)
    parser.add_argument("--https-port", type=int, default=9889)
    parser.add_argument("--decoder", choices=["webcodecs", "mse"], default="webcodecs")
    parser.add_argument("--duration", type=float, default=30, help="seconds per persistent connection")
    parser.add_argument("--max-gap", type=float, default=5, help="maximum acceptable gap between packets in seconds")
    parser.add_argument("--multi", action="store_true", help="check four viewers, limit, and reconnect")
    parser.add_argument("--existing-viewer", action="store_true", help="with --multi, keep one already connected viewer in the four slots")
    parser.add_argument("--insecure", action="store_true", help="accept the phone's self-signed certificate on this test LAN")
    args = parser.parse_args()
    if args.duration < (20 if args.multi else 8) or args.max_gap <= 0:
        parser.error("use at least 8 seconds (20 with --multi) and a positive --max-gap")
    if args.existing_viewer and not args.multi:
        parser.error("--existing-viewer requires --multi")
    asyncio.run(run(args))
