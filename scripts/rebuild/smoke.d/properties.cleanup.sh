#!/usr/bin/env bash
# Opens the folder properties.fixture.sh closed, and unlocks the file it locked, so the fixture can be removed.
[ -e "$fix/home/Measured/Closed" ] && chmod 755 "$fix/home/Measured/Closed" 2>/dev/null
[ -e "$fix/home/Access/Locked.txt" ] && chflags nouchg "$fix/home/Access/Locked.txt" 2>/dev/null
true
