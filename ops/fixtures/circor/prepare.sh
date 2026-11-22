#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:?Usage: bash prepare.sh /path/to/cache}"
mkdir -p "$target"
target="$(cd "$target" && pwd)"

# Keep the platform-specific venv outside Mix dependencies and the SDK artifact.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/med-fabric"
lock="$(shasum -a 256 "$here/uv.lock")"
export UV_PROJECT_ENVIRONMENT="$cache/circor-${lock%% *}"
exec uv run --project "$here" --locked --python 3.12.14 python "$here/encode.py" "$target"
