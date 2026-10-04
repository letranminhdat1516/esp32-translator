# firmware/test/claude_ble_voice.py — fake Mac daemon for the Phase 3 on-device voice checks.
# The board takes one Claude subscriber: stop the real daemon first and restart it afterwards:
#   launchctl bootout gui/$(id -u)/dev.cicca.claude-board
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.cicca.claude-board.plist
# usage: python3 claude_ble_voice.py command|empty|error|other|deny|gone   (needs bleak: python3 -m pip install --user bleak)
# Every capture's audio is saved to /tmp/board-voice-<voice id>.wav (listen with afplay).
import asyncio
import struct
import sys
import time
import wave

from bleak import BleakClient, BleakScanner

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC = "a7c00001" + B
REQ, ANS, VOICE = "a7c00011" + B, "a7c00012" + B, "a7c00013" + B

INDEX = [-1, -1, -1, -1, 2, 4, 6, 8] * 2
STEP = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80,
        88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598,
        658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289,
        16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]


def adpcm_decode(packet):
    pred = struct.unpack("<h", packet[2:4])[0]
    idx = min(88, packet[4])
    out = []
    for byte in packet[5:]:
        for code in (byte & 0x0F, byte >> 4):
            step = STEP[idx]
            delta = step >> 3
            if code & 4:
                delta += step
            if code & 2:
                delta += step >> 1
            if code & 1:
                delta += step >> 2
            pred = max(-32768, min(32767, pred - delta if code & 8 else pred + delta))
            idx = max(0, min(88, idx + INDEX[code]))
            out.append(pred)
    return out


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
    if code == 0x30:
        kind = {0: "command", 1: "other q%d" % (d[5] >> 4), 2: "deny reason"}.get(d[5] & 0x0F, "?")
        return "voice %d start: %s, target %d" % (mid, kind, struct.unpack("<I", d[6:10])[0])
    if code in (0x31, 0x32, 0x33):
        return "voice %d %s" % (mid, {0x31: "stop", 0x32: "cancel", 0x33: "send"}[code])
    if code in (1, 2, 3):
        return "id %d %s" % (mid, {1: "allow", 2: "deny", 3: "always allow"}[code])
    if code == 0x10:
        return "id %d answers %s" % (mid, [hex(m) for m in d[6:6 + d[5]]])
    return "unknown " + d.hex()


async def main(what):
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        inputs = asyncio.Queue()
        cap = {"seq": None, "lost": 0, "packets": 0, "samples": []}

        def on_input(_, data):
            data = bytes(data)
            print("board ->", describe(data))
            inputs.put_nowait(data)

        def on_voice(_, data):
            data = bytes(data)
            seq = struct.unpack("<H", data[:2])[0]
            if cap["seq"] is not None and seq != (cap["seq"] + 1) & 0xFFFF:
                cap["lost"] += (seq - cap["seq"] - 1) & 0xFFFF
            cap["seq"] = seq
            cap["packets"] += 1
            cap["samples"] += adpcm_decode(data)

        await c.start_notify(ANS, on_input)
        # Phase 5: the board gives this link the Mac role only after the hello (kind 9 "mac")
        for ch in chunks(message(9, 0, "mac"), c.mtu_size - 3):
            await c.write_gatt_char(REQ, ch, response=True)
        await c.start_notify(VOICE, on_voice)

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

        def voice_input(vid, *codes):
            return lambda d: d[:4] == struct.pack("<I", vid) and d[4] in codes

        async def capture(final_text):
            """Waits for a voice start, streams fake partials until the stop, answers with final_text (None: the
            start is refused with an error). Returns the voice id."""
            d = await wait_for(lambda d: d[4] == 0x30, 180)
            vid = struct.unpack("<I", d[:4])[0]
            cap.update(seq=None, lost=0, packets=0, samples=[])
            if final_text is None:
                await send(8, vid, "x\nOpen with cb for voice")
                return vid
            while True:
                try:
                    d = await asyncio.wait_for(inputs.get(), 0.5)
                except asyncio.TimeoutError:
                    await send(8, vid, "p\n(fake Mac) %.1f s of audio" % (len(cap["samples"]) / 16000))
                    continue
                if voice_input(vid, 0x31)(d):
                    break
                if voice_input(vid, 0x32)(d):
                    print("cancelled while recording")
                    return vid
            total = cap["packets"] + cap["lost"]
            print("audio: %.2f s in %d packets, %d lost (%.1f%%)" % (len(cap["samples"]) / 16000, cap["packets"],
                                                                     cap["lost"], 100.0 * cap["lost"] / max(1, total)))
            path = "/tmp/board-voice-%d.wav" % vid
            with wave.open(path, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(16000)
                w.writeframes(struct.pack("<%dh" % len(cap["samples"]), *cap["samples"]))
            print("saved", path)
            await send(8, vid, "f\n" + final_text)
            return vid

        async def confirm(vid, done_text):
            """Send → answers done; returns "sent", or "cancel" (Cancel or Say again)."""
            d = await wait_for(voice_input(vid, 0x32, 0x33), 180)
            if d[4] == 0x33:
                await send(8, vid, "k\n" + done_text)
                return "sent"
            return "cancel"

        now = int(time.time())
        await send(3, 0, "%d %d" % (now, time.localtime().tm_gmtoff // 60))

        if what in ("command", "empty", "error"):
            print("Press PWR x2 on the board (Claude screen).")
            await wait_for(lambda d: d[:5] == b"\0\0\0\0\x20" and d[5] == 1, 120)
            await send(6, 0)
            await send(4, 1, "i %d %d 5\nesp32-translator\nReady for a command." % (now - 60, now))
            await send(4, 2, "i %d %d 0\nno-cb\nRuns without tmux." % (now - 30, now - 30))

        if what == "command":
            print("Expect Speak under 'Ready for a command.'. Tap Speak, say a sentence, then stop talking.")
            vid = await capture("chạy các bài kiểm tra")
            print("Expect 'Send this?' + 'chạy các bài kiểm tra'. Tap Say again once, speak again, then Send.")
            while await confirm(vid, "Sent to esp32-translator") != "sent":
                vid = await capture("chạy các bài kiểm tra")
            print("Expect 'Sent' / 'Sent to esp32-translator', then the session view with Speak.")
            await asyncio.sleep(3)

        if what == "empty":
            print("Tap Speak and say nothing for 5 s.")
            vid = await capture("")
            print("Expect 'Didn't catch that' / 'Say again, or Cancel.' and no Send. Tap Cancel.")
            await confirm(vid, "")
            await asyncio.sleep(2)

        if what == "error":
            print("Tap Speak.")
            await capture(None)
            print("Expect 'Not sent' / 'Open with cb for voice' for ~3.5 s, then the session view.")
            await asyncio.sleep(5)

        if what == "other":
            qid = 7171
            await send(7, qid, "0 1 0 2\nesp32-translator\nFruit\nWhich fruit should the demo use?\n"
                               "Apple\nCrisp\nBanana\nSoft")
            print("Expect the question with an 'Other (speak)' row. Tap it, say a fruit, then Use.")
            vid = await capture("Sầu riêng")
            while await confirm(vid, "Added as your answer") != "sent":
                vid = await capture("Sầu riêng")
            print("Expect the Other row to read 'Sầu riêng', selected. Tap Send.")
            d = await wait_for(lambda d: d[:4] == struct.pack("<I", qid) and d[4] == 0x10, 120)
            print("answers:", describe(d), "(expect ['0x80'])")

        if what == "deny":
            pid = 8181
            await send(0, pid, "esp32-translator\nBash\nnpm test -- --watch=false")
            print("Expect Deny / Allow and 'Deny + why'. Tap Deny + why, give a reason, then Send.")
            vid = await capture("dùng pnpm thay vì npm")
            while await confirm(vid, "Denied with your reason") != "sent":
                vid = await capture("dùng pnpm thay vì npm")
            print("Expect 'Denied' / 'Claude gets your reason.', then the previous screen.")
            await asyncio.sleep(3)

        if what == "gone":
            pid = 9191
            await send(0, pid, "esp32-translator\nBash\nrm -rf build")
            print("Tap Deny + why and keep talking: the request is answered elsewhere after 3 s.")
            d = await wait_for(lambda d: d[4] == 0x30, 180)
            vid = struct.unpack("<I", d[:4])[0]
            await asyncio.sleep(3)
            await send(2, pid)
            await wait_for(voice_input(vid, 0x32), 10)
            print("Expect the overlay gone and 'Answered in the terminal or timed out.', then the previous screen.")
            await asyncio.sleep(3)


asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "command"))
