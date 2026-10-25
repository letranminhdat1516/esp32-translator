# firmware/test/board_info_ble.py — reads the board info characteristic (A7C00005-...) from the flashed board.
# Usage: python3 board_info_ble.py [expected hex, default "01 03 00 00 00"]
# Value: [version u8][font_sets u32 LE]; bits: 1 Latin VI, 2 Latin Ext-A, 4 CJK, 8 Hangul, 0x10 Thai.
import asyncio, sys
from bleak import BleakScanner, BleakClient

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC = "a7c00001" + B
INFO = "a7c00005" + B

async def main():
    expected = bytes.fromhex(sys.argv[1]) if len(sys.argv) > 1 else bytes([1, 3, 0, 0, 0])
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        value = bytes(await c.read_gatt_char(INFO))
    print("board info:", value.hex(" "), "version", value[0], "font sets", hex(int.from_bytes(value[1:5], "little")))
    assert len(value) == 5, "board info must be 5 bytes"
    assert value == expected, f"expected {expected.hex(' ')}"
    print("ok")

asyncio.run(main())
