#!/bin/sh
# Invoked through the installed worker shell, with the pane input still open.
set -eu
receipts=${0%/*}
printf 'ready\n' > "$receipts/interrupt.ready"
cat -u > "$receipts/interrupt.out"
printf 'returned\n' > "$receipts/interrupt.returned"
