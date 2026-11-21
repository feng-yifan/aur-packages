#!/usr/bin/env bash
# Build with makepkg, then run namcap.
# Fails on: build errors, missing package, or namcap ERRORS that are NOT in the
# documented allowlist of inherent findings for this binary Electron package.
#
# Why an allowlist? Repackaging an upstream Electron .deb under /opt always trips
# a few namcap errors that cannot be fixed without patching upstream binaries or
# restructuring the install root (e.g. "ELF files outside of a valid path",
# upstream's embedded CI RUNPATH, and bundled optional Python/ML scripts). Those
# are reported but do not block publishing; anything else does.
#
# Usage: build-verify.sh [pkgdir]
set -euo pipefail

PKGDIR="${1:-twilight-echo-bin}"
export PACKAGER="${PACKAGER:-Feng Yifan <fengyifan@blocgo.com>}"
cd "$PKGDIR"

ALLOW_RE='ELF files outside of a valid path|Insecure RUNPATH|Dependency python(-numpy)? detected and not included|Referenced python module'

echo "== makepkg build =="
makepkg -f --noconfirm --nodeps --nocheck

PKGFILE=$(makepkg --packagelist | head -1)
[[ -f "$PKGFILE" ]] || { echo "ERROR: package file not produced: $PKGFILE" >&2; exit 1; }

check_namcap() { # $1 target, $2 logfile
  set +e; namcap "$1" > "$2" 2>&1; set -e
  echo "== namcap $1 =="
  cat "$2" || true
  local blocking
  blocking=$(grep ' E: ' "$2" | grep -Ev "$ALLOW_RE" || true)
  if [[ -n "$blocking" ]]; then
    echo "ERROR: namcap reported blocking errors (not in allowlist):" >&2
    printf '%s\n' "$blocking" >&2
    return 1
  fi
  local allowed
  allowed=$(grep -c ' E: ' "$2" || true)
  if [[ "${allowed:-0}" -gt 0 ]]; then
    echo "note: ${allowed} namcap error line(s) matched the documented allowlist (inherent to this -bin Electron package)"
  fi
  return 0
}

check_namcap PKGBUILD /tmp/namcap-pkgbuild.log
check_namcap "$PKGFILE" /tmp/namcap-pkg.log
echo "build-verify OK: $PKGFILE"
