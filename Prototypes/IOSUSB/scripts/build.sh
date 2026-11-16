#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/build-backend.sh"
"$SCRIPT_DIR/build-viewer.sh"
