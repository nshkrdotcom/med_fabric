#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for tool in git curl tar make cc mix elixir erl; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done

elixir -e 'unless System.version() == "1.20.5" and
  String.trim(File.read!(Path.join([:code.root_dir() |> to_string(), "releases", "29", "OTP_VERSION"]))) == "29.1.2",
  do: System.halt("Activate the Erlang and Elixir versions in .tool-versions")'

if [[ "${1:-}" == "--integration" ]]; then
  for tool in node npm uv jq openssl psql shasum; do
    command -v "$tool" >/dev/null || { echo "Missing integration prerequisite: $tool" >&2; exit 1; }
  done
  if [[ -z "${FHIR_BASE_URL:-}" ]]; then
    jdk_prefix="${JAVA_HOME:+$JAVA_HOME/bin/}"
    command -v "${jdk_prefix}javac" >/dev/null && "${jdk_prefix}javac" -version 2>&1 | grep -Fqx 'javac 21.0.9' || {
      echo "Activate the full Temurin JDK 21.0.9+10, or set FHIR_BASE_URL for an existing test server." >&2
      exit 1
    }
  fi
  [[ "$(node --version)" == "v24.19.0" ]] || {
    echo "Activate Node 24.19.0 with asdf or mise." >&2; exit 1;
  }
fi

mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get --check-locked
mix blitz.workspace deps_get -- --check-locked

if [[ "${1:-}" == "--integration" ]]; then
  (cd ops/browser && npm ci --ignore-scripts && ./node_modules/.bin/playwright install chromium)
fi
