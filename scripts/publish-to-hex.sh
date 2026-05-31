#!/usr/bin/env bash
#
# Publish evoq-testkit to hex.pm.
#
# Prerequisites:
#   - HEX_API_KEY environment variable set, OR `rebar3 hex user auth` already run
#   - working tree clean and the version in src/evoq_testkit.app.src bumped
#
# Usage:
#   ./scripts/publish-to-hex.sh
#
# This does NOT commit or tag — verify first, then tag manually (see footer).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

VSN="$(sed -nE 's/.*\{vsn,[[:space:]]*"([^"]+)"\}.*/\1/p' src/evoq_testkit.app.src)"
echo "==> evoq-testkit v${VSN}"

echo "==> Cleaning..."
rebar3 clean

echo "==> Compiling..."
rebar3 compile

echo "==> Running tests..."
rebar3 eunit

echo "==> Running dialyzer..."
rebar3 dialyzer || true

echo "==> Building docs..."
rebar3 ex_doc

echo "==> Publishing to hex.pm (will prompt for confirmation)..."
rebar3 hex publish

echo ""
echo "==> Done. Check https://hex.pm/packages/evoq_testkit"
echo ""
echo "==> Now tag the release (verify first — not automatic):"
echo "      git tag v${VSN} && git push origin v${VSN}"
echo "    (version comes from src/evoq_testkit.app.src)"
