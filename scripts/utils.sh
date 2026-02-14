# !/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# utils.sh
# Common utility functions for scripts
# ---------------------------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

OS="$(uname -s)"
ARCH="$(uname -m)"

PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="${PROJECT_DIR}/.talos"
MANIFESTS_DIR="${PROJECT_DIR}/manifests"
