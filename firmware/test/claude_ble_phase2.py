# firmware/test/claude_ble_phase2.py — fake Mac daemon for the Phase 2 on-device checks.
# The board takes one Claude subscriber: stop the real daemon first and restart it afterwards:
#   launchctl bootout gui/$(id -u)/dev.cicca.claude-board
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.cicca.claude-board.plist
# usage: python3 claude_ble_phase2.py sessions|permission|question|cancel|all
import asyncio
import struct
import sys
import time

from bleak import BleakClient, BleakScanner

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC = "a7c00001" + B
REQ, ANS = "a7c00011" + B, "a7c00012" + B


def message(kind, mid, text=""):
    return bytes([kind]) + struct.pack("<I", mid) + text.encode()


def chunks(data, size):
    out = []
    for off in range(0, len(data), size - 1):
        part = data[off:off + size - 1]
        flags = (1 if off == 0 else 0) | (2 if off + size - 1 >= len(data) else 0)
        out.append(bytes([flags]) + part)
    return out


def describe(d):
    mid, code = struct.unpack("<IB", d[:5])
    if mid == 0 and code == 0x20:
        return "mode " + {0: "other", 1: "claude", 2: "picker"}.get(d[5], str(d[5]))
    if mid == 0 and code == 0x21:
        return "focus %d" % struct.unpack("<I", d[5:9])[0]
    if code in (1, 2, 3):
        return "id %d %s" % (mid, {1: "allow", 2: "deny", 3: "always allow"}[code])
    if code == 0x10:
        return "id %d answers %s" % (mid, [bin(m) for m in d[6:6 + d[5]]])
    return "unknown " + d.hex()


async def main(what):
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        inputs = asyncio.Queue()

        def on_input(_, data):
            data = bytes(data)
            print("board ->", describe(data))
            inputs.put_nowait(data)

        await c.start_notify(ANS, on_input)

        async def send(kind, mid, text=""):
            for ch in chunks(message(kind, mid, text), c.mtu_size - 3):
                await c.write_gatt_char(REQ, ch, response=True)

        async def wait_for(pred, secs):
            end = time.monotonic() + secs
            while time.monotonic() < end:
                try:
                    d = await asyncio.wait_for(inputs.get(), end - time.monotonic())
                except asyncio.TimeoutError:
                    break
                if pred(d):
                    return d
            raise SystemExit("timed out")

        def is_id(mid):
            return lambda d: struct.unpack("<I", d[:4])[0] == mid

        now = int(time.time())
        await send(3, 0, "%d %d" % (now, time.localtime().tm_gmtoff // 60))

        if what in ("sessions", "all"):
            print("Press PWR x3 on the board (picker).")
            await wait_for(lambda d: d[:5] == b"\0\0\0\0\x20" and d[5] in (1, 2), 60)
            await send(6, 0)
            await send(4, 1, "w %d %d 1\nesp32-translator\nRunning the tests" % (now - 300, now))
            await send(4, 2, "i %d %d 2\nwebsite\nDeployed to staging." % (now - 60, now - 30))
            await send(4, 3, "n %d %d 0\napi\n" % (now - 10, now - 10))
            await send(4, 4, "e %d %d 0\nold-repo\nBye." % (now - 900, now - 900))
            print("Expect: api (red), esp32-translator (yellow, outlined), website · new (green), old-repo (grey). Tap website.")
            await wait_for(lambda d: d[:5] == b"\0\0\0\0\x21", 120)
            await send(4, 1, "w %d %d 0\nesp32-translator\nRunning the tests" % (now - 300, now))
            await send(4, 2, "i %d %d 1\nwebsite\nDeployed to staging." % (now - 60, now - 30))
            print("Expect the Claude screen: website / Idle · 1m / Deployed to staging.")

        if what in ("permission", "all"):
            await send(0, 4242, "esp32-translator\nBash\nnpm test -- --watch=false")
            print("Expect Deny / Allow only. Tap Allow.")
            print("answer:", describe(await wait_for(is_id(4242), 90)))
            await asyncio.sleep(2)
            await send(0, 4243, "esp32-translator\nBash\nnpm test -- --watch=false\nBash(npm test:*)")
            print("Expect Deny / Allow / Always allow and 'Rule: Bash(npm test:*)'. Tap Always allow.")
            print("answer:", describe(await wait_for(is_id(4243), 90)))

        if what in ("question", "all"):
            await asyncio.sleep(2)
            await send(7, 5151, "0 2 0 3\nesp32-translator\nColor\nWhich colour should the ring use?\n"
                                "Red\nWarm and loud\nGreen\nCalm\nBlue\nThe current colour")
            await send(7, 5151, "1 2 1 4\nesp32-translator\nFruits\nWhich fruits?\n"
                                "Apple\nCrisp\nBanana\nSoft\nCherry\nSmall and red\nDurian\nStrong smell")
            print("Page 1/2 single-select, page 2/2 checkboxes. Pick Green, Next, tick Apple and Cherry, Send.")
            d = await wait_for(is_id(5151), 180)
            assert d[4] == 0x10, describe(d)
            print("answers:", describe(d), "(expect ['0b10', '0b101'])")

        if what in ("cancel", "all"):
            await asyncio.sleep(2)
            await send(7, 6161, "0 1 0 2\nesp32-translator\nGo\nProceed?\nYes\n\nNo\n")
            print("Question shown; cancelling in 5 s, as if answered in the terminal.")
            await asyncio.sleep(5)
            await send(2, 6161)
            print("Expect 'Answered in the terminal or timed out.', then the previous screen.")
            await asyncio.sleep(3)


asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "all"))
