# tools/fake_iphone.py: the Mac plays the iPhone app towards the real board over BLE, to check the translator
# screen on the glass without the phone. Needs `bleak` (pip install bleak). Close the iPhone app first, or the
# board shows both links' text.
#
#   python3 tools/fake_iphone.py                 demo loop: label, subtitles, mic on; prints the board mic level
#   python3 tools/fake_iphone.py --label 日本語 --text "朝食付きで80万ドンです。"   one subtitle, then stays connected
#
# Protocol (firmware/main/ble_link.c): text ...0003 = [flags][kind][UTF-8], flags bit0 first chunk, bit1 last;
# kind 0 subtitle, 1 status, 2 time "<unix s> <offset min>", 3 language label. control ...0004: 0 / 1 mic,
# 0xFF keepalive (every 20 s). audio ...0002 notify: [seq u16][predictor i16][index u8][IMA ADPCM, 16 kHz].
import argparse, asyncio, math, struct, time

from bleak import BleakClient, BleakScanner

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
SVC, AUDIO, TEXT, CONTROL = ("a7c0000" + n + B for n in "1234")

DEMO = [
    ("English", "Hi! How much is the room per night?"),
    ("English", "800,000 dong, breakfast included."),
    ("English", "Great, and the airport shuttle leaves at seven tomorrow morning from the lobby, "
                "right next to the reception desk."),
    ("日本語", "朝食付きで80万ドンです。"),
    ("한국어", "공항 셔틀은 내일 아침 7시에 출발합니다."),
    ("Français", "Le petit-déjeuner est inclus, à côté de la réception."),
]

STEP = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88,
        97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
        4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
        18500, 20350, 22385, 24623, 27086, 29794, 32767]
IDX = [-1, -1, -1, -1, 2, 4, 6, 8]


def adpcm_rms_db(pkt: bytes) -> float:
    if len(pkt) < 6:
        return -99.0
    pred, idx = struct.unpack_from("<hB", pkt, 2)
    idx = min(idx, 88)
    acc = n = 0
    for byte in pkt[5:]:
        for code in (byte & 15, byte >> 4):
            step = STEP[idx]
            d = step >> 3
            if code & 4: d += step
            if code & 2: d += step >> 1
            if code & 1: d += step >> 2
            pred = max(-32768, min(32767, pred - d if code & 8 else pred + d))
            idx = max(0, min(88, idx + IDX[code & 7]))
            acc += pred * pred
            n += 1
    return 20 * math.log10(math.sqrt(acc / n) / 32768 + 1e-9)


async def send(c: BleakClient, kind: int, text: str, chunk: int = 160):
    data = text.encode("utf-8")
    parts = [data[i:i + chunk] for i in range(0, len(data), chunk)] or [b""]
    for i, p in enumerate(parts):
        flags = (1 if i == 0 else 0) | (2 if i == len(parts) - 1 else 0)
        await c.write_gatt_char(TEXT, bytes([flags, kind]) + p, response=False)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label")
    ap.add_argument("--text")
    ap.add_argument("--every", type=float, default=4.0, help="seconds between demo subtitles")
    ap.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = until Ctrl-C)")
    a = ap.parse_args()

    print("scanning for the board…")
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: SVC in [u.lower() for u in ad.service_uuids], timeout=20)
    if not dev:
        raise SystemExit("board not found (is it awake? touch the screen or press BOOT)")
    async with BleakClient(dev) as c:
        print("connected:", dev.name or dev.address)
        offset = -time.timezone // 60 if not time.localtime().tm_isdst else -time.altzone // 60
        await send(c, 2, f"{int(time.time())} {offset}")

        levels = []
        await c.start_notify(AUDIO, lambda _, d: levels.append(adpcm_rms_db(bytes(d))))
        await c.write_gatt_char(CONTROL, b"\x01", response=True)

        script = [(a.label or "English", a.text)] if a.text else DEMO
        start = last_keep = last_text = 0.0
        i = 0
        start = time.monotonic()
        while not a.seconds or time.monotonic() - start < a.seconds:
            now = time.monotonic()
            if now - last_keep > 20:
                await c.write_gatt_char(CONTROL, b"\xff", response=False)
                last_keep = now
            if (not a.text or i == 0) and now - last_text >= a.every:
                label, text = script[i % len(script)]
                await send(c, 3, label)
                await send(c, 1, "Live translation")
                await send(c, 0, text)
                print(f"→ [{label}] {text}")
                i += 1
                last_text = now
            await asyncio.sleep(1.0)
            if levels:
                print(f"  board mic: {len(levels)} packets/s, loudest {max(levels):.0f} dBFS")
                levels.clear()
        await c.write_gatt_char(CONTROL, b"\x00", response=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
