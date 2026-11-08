#!/bin/sh
# Installer behind action.yml. POSIX sh only: the action runs it with `sh` on Linux and macOS, so it works in a
# `container:` job that has no bash, and with Git's bash on Windows. It needs curl and tar (unzip or PowerShell
# for the Windows .zip); it does not need jq, python or node.
#
# Subcommands:
#   prepare   check the inputs, map the runner to an archive name, write the step outputs
#   install   download (unless the cache restored it), verify and extract, add bin/ to PATH, write the outputs
#   asset-id NAME   read the JSON of a release on stdin and print the id of the asset NAME (used by the tests)
#
# The inputs arrive as environment variables (INPUT_*), never pasted into the script text, so a value cannot
# become code.
set -eu

API=https://api.github.com/repos/agentica-lang/agentica
DIRECT=https://github.com/agentica-lang/agentica/releases/download

fail() {
  echo "::error title=setup-agentica::$*"
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

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r "$1" | cut -d ' ' -f 1
  else
    fail "no sha256 tool found (sha256sum, shasum or openssl)"
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
  echo "$1=$2" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
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

# One download try: the release asset through the API, then the direct link. Either can answer 5xx for a
# while (the direct link gave 504 for an hour on 2026-11-08). The token goes only to api.github.com; curl drops
# it when the API redirects to the storage host.
fetch_once() {
  out=$1
  curl_opts="-fsSL --connect-timeout 20 --max-time 120"

  if [ -n "${INPUT_TOKEN:-}" ]; then
    auth="Authorization: Bearer $INPUT_TOKEN"
  else
    auth="X-GitHub-Api-Version: 2022-11-28" # a harmless header, so the curl lines are the same without a token
  fi

  # shellcheck disable=SC2086 # curl_opts is a list of fixed words
  if json=$(curl $curl_opts -H "$auth" "$API/releases/tags/$INPUT_VERSION") &&
    id=$(printf '%s' "$json" | asset_id "$ARCHIVE") && [ -n "$id" ] &&
    curl $curl_opts -H "$auth" -H "Accept: application/octet-stream" -o "$out" "$API/releases/assets/$id"; then
    echo "downloaded $ARCHIVE through the release API"
    return 0
  fi

  # shellcheck disable=SC2086
  if curl $curl_opts -o "$out" "$DIRECT/$INPUT_VERSION/$ARCHIVE"; then
    echo "downloaded $ARCHIVE through the direct link"
    return 0
  fi
  return 1
}

# 5 tries, waiting 10, 20, 40 and 80 s between them.
fetch() {
  delay=10
  try=1
  while ! fetch_once "$1"; do
    if [ "$try" -ge 5 ]; then
      fail "download of $ARCHIVE failed after $try tries"
    fi
    echo "download failed (try $try), retrying in ${delay}s"
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
    cache_hit=true
    echo "Agentica $INPUT_VERSION is already in $ROOT"
  else
    cache_hit=false
    command -v curl >/dev/null 2>&1 || fail "curl is required (in a container, install curl and ca-certificates first)"

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
  echo "$native_bin" >>"${GITHUB_PATH:?GITHUB_PATH is not set}"
  output path "$native_bin"
  output version "$INPUT_VERSION"
  output cache-hit "$cache_hit"
}

case ${1:-} in
  prepare) prepare ;;
  install) install ;;
  asset-id) asset_id "${2:?usage: install.sh asset-id NAME}" ;;
  *) fail "usage: install.sh prepare | install | asset-id NAME" ;;
esac
