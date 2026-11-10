#!/usr/bin/env bash
# For the permissions hunt steps: links that lead nowhere (one to a folder on a disk that isn't there, one to itself),
# and a folder with a file to move while a card covers it. All inside the fixture home, in a folder of their own.
set -u
rm -rf "$fix/home/HuntPermissions"
mkdir -p "$fix/home/HuntPermissions/Links" "$fix/home/HuntPermissions/Drop/Into"
ln -s "$fix/home/Unplugged Disk/Projects" "$fix/home/HuntPermissions/Links/Old Projects"
ln -s "Loop" "$fix/home/HuntPermissions/Links/Loop"
echo m > "$fix/home/HuntPermissions/Drop/move-me.txt"
true
