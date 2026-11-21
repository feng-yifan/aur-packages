#!/usr/bin/env bash
# Publish a package directory to the AUR (aur.archlinux.org).
# Default is dry-run; pass --push to actually create/update the AUR package.
# AUR repositories use the 'master' branch (not 'main').
#
# Usage: aur-publish.sh [pkgname] [--push]
# Env (required for --push): AUR_SSH_PRIVATE_KEY, optional AUR_KNOWN_HOSTS
set -euo pipefail

PKG=""; PUSH=false
for a in "$@"; do
  case "$a" in
    --push) PUSH=true ;;
    -*) : ;;
    *) PKG="$a" ;;
  esac
done
PKG="${PKG:-twilight-echo-bin}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/$PKG"
AUR_URL="ssh://aur@aur.archlinux.org/${PKG}.git"

[[ -f "$SRC/PKGBUILD" && -f "$SRC/.SRCINFO" ]] \
  || { echo "ERROR: missing PKGBUILD/.SRCINFO in $SRC" >&2; exit 2; }

if [[ "$PUSH" != true ]]; then
  echo "[dry-run] would publish $PKG to $AUR_URL"
  echo "files: PKGBUILD .SRCINFO${PKG:+ $PKG.install}"
  exit 0
fi

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [[ -n "${AUR_SSH_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$AUR_SSH_PRIVATE_KEY" > "$HOME/.ssh/aur"; chmod 600 "$HOME/.ssh/aur"
else
  echo "ERROR: AUR_SSH_PRIVATE_KEY not set" >&2; exit 3
fi
if [[ -n "${AUR_KNOWN_HOSTS:-}" ]]; then
  printf '%s\n' "$AUR_KNOWN_HOSTS" > "$HOME/.ssh/known_hosts"
else
  ssh-keyscan aur.archlinux.org >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/aur -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"

tmp="$(mktemp -d)"
if git clone "$AUR_URL" "$tmp" 2>/dev/null; then
  echo "cloned existing AUR repo"
  cd "$tmp"
else
  echo "clone failed (likely new package) -> initializing fresh repo"
  rm -rf "$tmp"; mkdir -p "$tmp"; cd "$tmp"
  git init -q
  git remote add origin "$AUR_URL"
  git checkout -q -b master
fi

cp "$SRC/PKGBUILD" ./PKGBUILD
cp "$SRC/.SRCINFO" ./.SRCINFO
[[ -f "$SRC/${PKG}.install" ]] && cp "$SRC/${PKG}.install" ./

git config user.name "Feng Yifan"
git config user.email "fengyifan@blocgo.com"
git add -A
if git diff --cached --quiet; then
  echo "no changes to publish for $PKG"; exit 0
fi
ver=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2-)
rel=$(grep -m1 '^pkgrel=' PKGBUILD | cut -d= -f2-)
git commit -q -m "upgpkg: ${PKG} ${ver}-${rel}"
git push origin HEAD:master
echo "published ${PKG} ${ver}-${rel} to AUR"
