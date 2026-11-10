#!/usr/bin/env bash
# Unlocks anything the file-operations steps locked and a failed step left that way, so the fixture can be removed.
[ -e "$fix/home/HuntOps" ] && chmod -R u+rwX "$fix/home/HuntOps" 2>/dev/null
true
