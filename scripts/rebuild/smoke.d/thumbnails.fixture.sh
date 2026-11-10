#!/usr/bin/env bash
# New pictures for the grid's thumbnails (thumbnails.txt): JPEG and PNG files of a few sizes and shapes in
# Thumbnails/New Pictures. Each run draws them in new colours, so Quick Look has none of them cached and makes every
# thumbnail while the grid is on show, as it does for pictures just copied in.
pictures="$fix/home/Thumbnails/New Pictures"
seeds="$root/thumbnail-seeds"
mkdir -p "$pictures" "$seeds"
# A small gradient with a stripe for each picture, in colours picked at random, which sips then sizes and saves.
python3 -I - "$seeds" 8 <<'PY'
import os, random, struct, sys, zlib
folder, count = sys.argv[1], int(sys.argv[2])
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
for number in range(1, count + 1):
    width, height = 160, 120
    top = [random.randrange(256) for _ in range(3)]
    bottom = [random.randrange(256) for _ in range(3)]
    rows = []
    for y in range(height):
        colour = bytes(int(top[c] + (bottom[c] - top[c]) * y / (height - 1)) for c in range(3))
        stripe = bytes(255 - value for value in colour)
        rows.append(b'\x00' + b''.join(stripe if 60 <= x < 76 else colour for x in range(width)))
    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    with open(os.path.join(folder, f'seed-{number}.png'), 'wb') as out:
        out.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(b''.join(rows)))
                  + chunk(b'IEND', b''))
PY
number=0
picture() {  # <width> <height> <jpeg|png> <name>
    number=$((number + 1))
    sips -s format "$3" -z "$2" "$1" "$seeds/seed-$number.png" --out "$pictures/$4" >/dev/null \
        || echo "thumbnails.fixture.sh: sips could not make $4" >&2
}
picture 3000 2000 jpeg "Harbour 3000x2000.jpg"
picture 2400 1600 jpeg "Meadow 2400x1600.jpg"
picture 1200 1200 jpeg "Square 1200.jpg"
picture 160 120 jpeg "Small 160x120.jpg"
picture 2560 1440 png "Skyline 2560x1440.png"
picture 1200 1800 png "Tall 1200x1800.png"
picture 800 800 png "Square 800.png"
picture 120 160 png "Small 120x160.png"
