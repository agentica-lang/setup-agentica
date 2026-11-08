#!/bin/sh
# Installer behind action.yml. POSIX sh only: the action runs it with `sh` on Linux and macOS, so it works in a
# `container:` job that has no bash, and with Git's bash on Windows. It needs curl and tar (unzip or PowerShell
# for the Windows .zip); it does not need jq, python or node.
#
# Subcommands:
#   prepare   check the inputs, map the runner to an archive name, write the step outputs
#   install   download (unless the cache restored it), verify and extract, add bin/ to PATH, write the outputs
#
# The inputs arrive as environment variables (INPUT_*), never pasted into the script text, so a value cannot
# become code.
set -eu

API=https://api.github.com/repos/agentica-lang/agentica
DIRECT=https://github.com/agentica-lang/agentica/releases/download

fail() {
  printf '::error title=setup-agentica::%s\n' "$*"
  exit 1
}

# Print the id of the asset called $1 from the release JSON on stdin.
#
# No jq: tr puts every JSON member on its own line, then awk remembers the last `.../releases/assets/ID` url
# and prints it when it meets the matching `"name"`. In the API every asset object lists its `url` before its
# `name`, and the uploader (the only nested object in between) has no `name`, so the last url seen is the
# asset's own. This works for compact and for pretty-printed JSON. A name inside a string value cannot match:
# the line must start with the `"name"` key.
asset_id() {
  # shellcheck disable=SC2020 # three characters to three newlines, on purpose
  tr ',{}' '\n\n\n' | awk -v name="$1" '
    /"url"[ \t]*:[ \t]*"[^"]*\/releases\/assets\/[0-9]+"/ {
      s = $0
      sub(/.*\/releases\/assets\//, "", s)
      sub(/[^0-9].*/, "", s)
      id = s
      next
    }
    /^[ \t]*"name"[ \t]*:[ \t]*"/ {
      s = $0
      sub(/^[ \t]*"name"[ \t]*:[ \t]*"/, "", s)
      sub(/".*/, "", s)
      if (s == name && id != "") { print id; exit }
    }'
}

# The file goes in on stdin: given a path with backslashes (Windows), sha256sum prefixes the digest with `\`.
# $sha_tool is chosen before the first call, because a `fail` inside `$(...)` would lose its message.
sha256_of() {
  if [ "$sha_tool" = sha256sum ]; then
    sha256sum <"$1" | cut -d ' ' -f 1
  else
    shasum -a 256 <"$1" | cut -d ' ' -f 1
  fi
}

# Windows wants backslashes in GITHUB_PATH and in paths other tools read; Git's bash accepts both.
native_path() {
  if [ "${RUNNER_OS:-}" = Windows ]; then
    printf '%s' "$1" | sed 's|/|\\|g'
  else
    printf '%s' "$1"
  fi
}

output() {
  printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
}

prepare() {
  version=${INPUT_VERSION:-}
  sha256=$(printf '%s' "${INPUT_SHA256:-}" | tr 'A-F' 'a-f')

  [ -n "$version" ] || fail "input 'version' is required, for example 0.26.1"
  case $version in
    v[0-9]*) fail "version '$version' starts with 'v': release tags have none, use '${version#v}'" ;;
    [!0-9A-Za-z]* | *[!0-9A-Za-z._+-]*) fail "version '$version' is not a release tag (letters, digits, '.', '_', '+', '-')" ;;
  esac

  [ -n "$sha256" ] || fail "input 'sha256' is required: the sha256 of the archive, from SHA256SUMS of the release"
  case $sha256 in
    *[!0-9a-f]*) fail "input 'sha256' must be hexadecimal" ;;
  esac
  [ "${#sha256}" -eq 64 ] || fail "input 'sha256' must have 64 hexadecimal digits, it has ${#sha256}"

  exe=
  ext=tar.gz
  case "${RUNNER_OS:-}:${RUNNER_ARCH:-}" in
    Linux:X64) platform=linux-x86_64 ;;
    Linux:ARM64) platform=linux-arm64 ;;
    macOS:X64) platform=macos-x86_64 ;;
    macOS:ARM64) platform=macos-arm64 ;;
    Windows:X64)
      platform=windows-x86_64
      ext=zip
      exe=.exe
      ;;
    *) fail "unsupported platform ${RUNNER_OS:-unknown}/${RUNNER_ARCH:-unknown}: Agentica releases have Linux (x64, arm64), macOS (x64, arm64) and Windows (x64)" ;;
  esac

  top="agentica-$version-$platform"
  output sha256 "$sha256"
  output archive "$top.$ext"
  output top "$top"
  output exe "$exe"
  output root "${RUNNER_TEMP:?RUNNER_TEMP is not set}/setup-agentica/$version"
}

curl_get() {
  curl -fsSL --connect-timeout 20 --max-time 120 "$@"
}

# curl_get with the token ($1, may be empty) as a bearer header. The token goes only to api.github.com; curl
# drops it when the API redirects to the storage host.
api_get() {
  token=$1
  shift
  if [ -n "$token" ]; then
    curl_get -H "Authorization: Bearer $token" "$@"
  else
    curl_get "$@"
  fi
}

# The release asset through the API: its id from the release JSON, then its bytes into $1. $2 is the token.
via_api() {
  json=$(api_get "$2" "$API/releases/tags/$INPUT_VERSION") || return 1
  id=$(printf '%s' "$json" | asset_id "$ARCHIVE")
  [ -n "$id" ] || return 1
  api_get "$2" -H "Accept: application/octet-stream" -o "$1" "$API/releases/assets/$id"
}

# One download try. The direct link is last: it can answer 5xx for a while (504 for an hour on 2026-11-08). The
# API goes first with the token and, if that fails, once more without it, in case the token is the problem.
fetch_once() {
  if via_api "$1" "$INPUT_TOKEN" || { [ -n "$INPUT_TOKEN" ] && via_api "$1" ""; }; then
    printf 'downloaded %s through the release API\n' "$ARCHIVE"
  elif curl_get -o "$1" "$DIRECT/$INPUT_VERSION/$ARCHIVE"; then
    printf 'downloaded %s through the direct link\n' "$ARCHIVE"
  else
    return 1
  fi
}

# 5 tries, waiting 10, 20, 40 and 80 s between them.
fetch() {
  delay=10
  try=1
  while ! fetch_once "$1"; do
    if [ "$try" -ge 5 ]; then
      fail "download of $ARCHIVE failed after $try tries"
    fi
    printf 'download failed (try %s), retrying in %ss\n' "$try" "$delay"
    sleep "$delay"
    delay=$((delay * 2))
    try=$((try + 1))
  done
}

unzip_archive() {
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$1" -d "$2"
  elif command -v powershell >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    powershell -NoProfile -NonInteractive -Command \
      "Expand-Archive -LiteralPath '$(cygpath -w "$1")' -DestinationPath '$(cygpath -w "$2")'"
  else
    fail "cannot unpack $1: unzip and PowerShell are missing"
  fi
}

cleanup() {
  [ -z "${work:-}" ] || rm -rf "$work"
  [ -z "${partial:-}" ] || rm -rf "$partial"
}

install() {
  : "${ARCHIVE:?}" "${TOP:?}" "${ROOT:?}" "${INPUT_VERSION:?}" "${INPUT_SHA256:?}"
  bin="$ROOT/$TOP/bin"
  work=
  partial=
  trap cleanup EXIT

  if [ -x "$bin/agentica${EXE:-}" ]; then
    printf 'Agentica %s is already in %s\n' "$INPUT_VERSION" "$ROOT"
  else
    command -v curl >/dev/null 2>&1 || fail "curl is required (in a container, install curl and ca-certificates first)"
    if command -v sha256sum >/dev/null 2>&1; then
      sha_tool=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
      sha_tool=shasum
    else
      fail "sha256sum or shasum is required"
    fi

    work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/setup-agentica-download.$$"
    mkdir -p "$work"
    fetch "$work/$ARCHIVE"

    # A wrong sha256 is not retried: another download would give the same bytes.
    actual=$(sha256_of "$work/$ARCHIVE")
    if [ "$actual" != "$INPUT_SHA256" ]; then
      fail "sha256 of $ARCHIVE does not match: expected $INPUT_SHA256, got $actual"
    fi

    # Unpack beside ROOT and move it in at the end, so a failed install leaves nothing for the cache to save.
    rm -rf "$ROOT"
    partial="$ROOT.partial.$$"
    mkdir -p "$partial"
    case $ARCHIVE in
      *.zip) unzip_archive "$work/$ARCHIVE" "$partial" ;;
      *) tar -xzf "$work/$ARCHIVE" -C "$partial" ;;
    esac
    [ -f "$partial/$TOP/bin/agentica${EXE:-}" ] || fail "$ARCHIVE has no $TOP/bin/agentica${EXE:-}"
    chmod +x "$partial/$TOP/bin/agentica${EXE:-}"
    mv "$partial" "$ROOT"
    partial=
  fi

  native_bin=$(native_path "$bin")
  printf '%s\n' "$native_bin" >>"${GITHUB_PATH:?GITHUB_PATH is not set}"
  output path "$native_bin"
  output version "$INPUT_VERSION"
}

case ${1:-} in
  prepare) prepare ;;
  install) install ;;
  *) fail "usage: install.sh prepare | install" ;;
esac
