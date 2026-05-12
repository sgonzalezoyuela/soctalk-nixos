#!/usr/bin/env bash
# Convenience wrapper: deploy a host via nixos-anywhere using the
# flake-pinned version. Equivalent to `nix run .#deploy -- <host> <ip>`,
# but chdir's into the project root first so it works from any CWD.
#
# Usage:
#   ./scripts/deploy.sh <hostname> <target-ip> [extra nixos-anywhere args...]
#
# Example:
#   ./scripts/deploy.sh soctalk 10.0.1.50
#   ./scripts/deploy.sh soctalk 10.0.1.50 --no-reboot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$SCRIPT_DIR")"

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <hostname> <target-ip> [extra nixos-anywhere args...]" >&2
  exit 1
fi

cd "$FLAKE_DIR"
exec nix run .#deploy -- "$@"
