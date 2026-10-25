#!/usr/bin/env bash
# Writes fonts/fonts.img (gen_fonts.sh store) to the 'fonts' partition. Needs the ESP-IDF environment (esptool.py).
# usage: flash_fonts.sh <serial port>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${1:?usage: flash_fonts.sh <serial port>}"
IMG="$HERE/../fonts/fonts.img"
# Always pack from the committed .bin files: no network, nothing regenerated
"$HERE/gen_fonts.sh" image
# Offset of the 'fonts' row in partitions.csv
OFFSET=$(awk -F'[ ,]+' '$1=="fonts"{print $4}' "$HERE/../partitions.csv")
esptool.py --chip esp32s3 --port "$PORT" -b 921600 write_flash "$OFFSET" "$IMG"
