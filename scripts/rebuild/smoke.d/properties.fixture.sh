#!/usr/bin/env bash
# A folder whose contents Properties counts to known totals: four files and a package (45 bytes in all), two folders
# that can be read, and one that can't, whose file isn't counted. properties.cleanup.sh opens it again.
measured="$fix/home/Measured"
mkdir -p "$measured/sub/deeper" "$measured/Closed" "$measured/Tool.app/Contents"
printf 'hello' > "$measured/a.txt"
printf 'abc' > "$measured/.hidden"
printf '0123456789' > "$measured/sub/b.txt"
printf '01234567890123456789' > "$measured/sub/deeper/c.txt"
printf '<plist>' > "$measured/Tool.app/Contents/Info.plist"
printf 'not counted' > "$measured/Closed/x.txt"
chmod 000 "$measured/Closed"
