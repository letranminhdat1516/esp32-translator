# firmware/test/claude_ble_test.py — run with the iPhone app closed or open (board takes 2 links)
import asyncio, struct, sys
from bleak import BleakScanner, BleakClient

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC = "a7c00001" + B
REQ, ANS = "a7c00011" + B, "a7c00012" + B

def message(kind, mid, text):
    return bytes([kind]) + struct.pack("<I", mid) + text.encode()

def chunks(data, size):
    out = []
    for off in range(0, len(data), size - 1):
        part = data[off:off + size - 1]
        flags = (1 if off == 0 else 0) | (2 if off + size - 1 >= len(data) else 0)
        out.append(bytes([flags]) + part)
    return out

async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        answers = asyncio.Queue()
        await c.start_notify(ANS, lambda _, d: answers.put_nowait(struct.unpack("<IB", bytes(d))))
        mid = 4242
        for ch in chunks(message(0, mid, "esp32-translator\nBash\nnpm test -- --watch=false"), c.mtu_size - 3):
            await c.write_gatt_char(REQ, ch, response=True)
        print("Request shown on the board: tap", sys.argv[1] if len(sys.argv) > 1 else "Allow or Deny")
        got = await asyncio.wait_for(answers.get(), 60)
        print("answer:", got)
        assert got[0] == mid and got[1] in (1, 2)
        for ch in chunks(message(1, mid + 1, "esp32-translator\nAll tests passed."), c.mtu_size - 3):
            await c.write_gatt_char(REQ, ch, response=True)
        print("finished message sent")

asyncio.run(main())
