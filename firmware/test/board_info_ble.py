# firmware/test/board_info_ble.py — reads the board info characteristic (A7C00005-...) from the flashed board.
# Usage: python3 board_info_ble.py [expected hex]  (default: version 2 and the base font bits)
# Value: [version u8][font_sets u32 LE]; version 2 = pairing by code enforced (board_info.h);
# bits: 1 Latin VI, 2 Latin Ext-A, 4 CJK, 8 Hangul, 0x10 Thai.
import asyncio, sys
from bleak import BleakScanner, BleakClient

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC = "a7c00001" + B
INFO = "a7c00005" + B

async def main():
    expected = bytes.fromhex(sys.argv[1]) if len(sys.argv) > 1 else None
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        value = bytes(await c.read_gatt_char(INFO))
    print("board info:", value.hex(" "), "version", value[0], "font sets", hex(int.from_bytes(value[1:5], "little")))
    assert len(value) == 5, "board info must be 5 bytes"
    if expected is not None:
        assert value == expected, f"expected {expected.hex(' ')}"
    else:
        # Version 2 = pairing by code enforced; Latin VI + Ext-A are always built in, the fonts partition adds more
        assert value[0] == 2, "board info version must be 2"
        assert int.from_bytes(value[1:5], "little") & 0x3 == 0x3, "Latin VI and Latin Ext-A fonts must be present"
    print("ok")

asyncio.run(main())
