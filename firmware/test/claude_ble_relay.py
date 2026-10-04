# firmware/test/claude_ble_relay.py — the board's relay path without the iPhone app (Phase 5).
# This Mac pretends to be the iPhone relay: it takes the translator audio role, says the "relay" hello and sends
# a permission request. Before running: stop the daemon (launchctl bootout gui/$(id -u)/dev.cicca.claude-board)
# and close the iPhone app or turn the iPhone's Bluetooth off (the board allows one translator role).
import asyncio, struct
from bleak import BleakScanner, BleakClient

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC, AUDIO = "a7c00001" + B, "a7c00002" + B
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

async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        inputs = asyncio.Queue()

        async def send(kind, mid, text=""):
            for ch in chunks(message(kind, mid, text), c.mtu_size - 3):
                await c.write_gatt_char(REQ, ch, response=True)

        await c.start_notify(ANS, lambda _, d: inputs.put_nowait(bytes(d)))
        print("1. relay hello without the translator role: the monitor logs 'Claude hello \"relay\" refused'")
        await send(9, 0, "relay")
        await send(0, 1111, "relay-test\nBash\nmust not show")
        input("   The board shows no request, and the monitor logs 'from an inactive link dropped'. Enter to go on")

        print("2. take the translator role: the kept relay hello is granted ('Claude link up: via the iPhone relay');")
        print("   the hello again is harmless")
        await c.start_notify(AUDIO, lambda _, d: None)
        await send(9, 0, "relay")
        input("   PWR x2: the Claude screen reads 'Claude · via iPhone'. Enter to go on")

        print("3. 'mac' on this (translator) link is refused: the monitor logs 'Claude hello \"mac\" refused'")
        await send(9, 0, "mac")

        print("4. a request over the relay: tap Allow on the board")
        await send(0, 4242, "relay-test\nBash\necho via the relay")
        while True:
            d = await asyncio.wait_for(inputs.get(), 90)
            mid, code = struct.unpack("<IB", d[:5])
            if mid == 4242:
                break
            print("   (board input", d.hex(), ")")
        print("   answer:", code)
        assert code == 1, "expected Allow"
        print("5. leaving: the board drops the relay link ('Claude · Mac not connected')")

asyncio.run(main())
