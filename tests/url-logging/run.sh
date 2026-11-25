#!/bin/bash
# Run the public URL regression against an already built Simulator app.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$root/../simulator-app.sh" "${1:?Pass the path to the built Simulator .app}" "$root/check.sh" --confirm-open
