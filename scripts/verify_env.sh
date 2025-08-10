#!/usr/bin/env bash
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }

need zpool
need zfs
need awk
need sed
need lsblk
echo "Environment OK."
