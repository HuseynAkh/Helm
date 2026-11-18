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
# Items whose permissions Properties changes: a file, a script, a folder, a file whose group may only write, which
# Finder calls Custom, a locked file and a link. properties.cleanup.sh unlocks the locked file.
access="$fix/home/Access"
# A run that stopped before its cleanup leaves the locked file behind, which nothing removes while it's locked.
if [ -e "$access" ]; then chflags -R nouchg "$access" 2>/dev/null; rm -rf "$access"; fi
mkdir -p "$access/Shared"
printf 'notes' > "$access/notes.txt"
printf '#!/bin/sh\n' > "$access/script.sh"
printf 'odd' > "$access/odd.txt"
printf 'locked' > "$access/Locked.txt"
chmod 644 "$access/notes.txt" "$access/Locked.txt"
chmod 755 "$access/script.sh" "$access/Shared"
chmod 624 "$access/odd.txt"
chflags uchg "$access/Locked.txt"
ln -s notes.txt "$access/link.txt"
