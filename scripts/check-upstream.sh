#!/usr/bin/env bash
# Detect a new upstream release for a -bin AUR package and surgically update the
# PKGBUILD (pkgver / pkgrel / sha256sums) + regenerate .SRCINFO.
# Also reports whether AUR is behind the local desired version (NEED_PUBLISH).
#
# Usage: check-upstream.sh [pkgdir]
# Env:   UPSTREAM_REPO (default Px-asen/Twilight_Echo)
#        GH_TOKEN      (optional, avoids anonymous rate limits)
#        PM, PR        (asset name pattern, see _asset in PKGBUILD)
#        STATE_FILE    (default <repo>/.ci-state)
# Writes KEY=VALUE to STATE_FILE: CHANGED NEED_PUBLISH ACTION REASON PKGVER PKGREL
set -euo pipefail

PKGDIR="${1:-twilight-echo-bin}"
PKGBUILD="$PKGDIR/PKGBUILD"
[[ -f "$PKGBUILD" ]] || { echo "ERROR: no PKGBUILD at $PKGBUILD" >&2; exit 2; }

UPSTREAM_REPO="${UPSTREAM_REPO:-Px-asen/Twilight_Echo}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="${STATE_FILE:-$REPO_ROOT/.ci-state}"

get_local() {
  LPKGVER=$(grep -m1 '^pkgver=' "$PKGBUILD" | cut -d= -f2- | tr -d '[:space:]')
  LPKGREL=$(grep -m1 '^pkgrel=' "$PKGBUILD" | cut -d= -f2- | tr -d '[:space:]')
  # first sha256 in sha256sums_x86_64=(...) is the .deb checksum
  LSHA=$(grep -m1 '^sha256sums_x86_64=' "$PKGBUILD" \
          | sed -E "s/^sha256sums_x86_64=\(//; s/\).*//" \
          | tr -d "'\"" | awk '{print $1}')
}

api_get() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$1"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$1"
  fi
}

cmp_ver() { vercmp "$1" "$2" 2>/dev/null || echo 0; }

get_local
echo "local: pkgver=$LPKGVER pkgrel=$LPKGREL deb_sha=$LSHA"

LATEST_JSON=$(api_get "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest") \
  || { echo "ERROR: cannot query upstream release" >&2; exit 3; }
UP_TAG=$(printf '%s' "$LATEST_JSON" | jq -r '.tag_name // empty')
[[ -n "$UP_TAG" ]] || { echo "ERROR: no tag_name in upstream response (rate limited?)" >&2; exit 3; }
UP_VER="${UP_TAG#v}"
echo "upstream: tag=$UP_TAG ver=$UP_VER"

asset="TwilightEcho_${UP_VER}_amd64.deb"
sha_url="https://github.com/${UPSTREAM_REPO}/releases/download/${UP_TAG}/${asset}.sha256"
UP_SHA=$(curl -fsSL "$sha_url" | awk '{print $1}') \
  || { echo "ERROR: cannot fetch $sha_url" >&2; exit 3; }
[[ -n "$UP_SHA" ]] || { echo "ERROR: empty upstream sha" >&2; exit 3; }
echo "upstream deb sha=$UP_SHA"

AUR_VER=$(curl -fsSL "https://aur.archlinux.org/rpc/v5/info?arg[]=${PKGDIR}" \
  | jq -r '.results[0].Version // empty' 2>/dev/null || true)
echo "aur published: ${AUR_VER:-<none>}"

CHANGED=false; NEED_PUBLISH=false; ACTION=none; REASON=""
NEW_VER="$LPKGVER"; NEW_REL="$LPKGREL"; NEW_SHA="$LSHA"

if [[ "$UP_VER" != "$LPKGVER" ]]; then
  if [[ "$(cmp_ver "$UP_VER" "$LPKGVER")" -gt 0 ]]; then
    CHANGED=true; ACTION=update; REASON="new upstream version $UP_VER"
    NEW_VER="$UP_VER"; NEW_REL=1; NEW_SHA="$UP_SHA"
  else
    ACTION=warn; REASON="upstream $UP_VER < local $LPKGVER (upstream rollback?)"
  fi
else
  if [[ "$UP_SHA" != "$LSHA" ]]; then
    CHANGED=true; ACTION=update; REASON="upstream re-released $UP_VER with a different checksum"
    NEW_REL=$((LPKGREL + 1)); NEW_SHA="$UP_SHA"
  else
    ACTION=none; REASON="up to date ($LPKGVER-$LPKGREL)"
  fi
fi

DESIRED="${NEW_VER}-${NEW_REL}"
if [[ -z "$AUR_VER" ]]; then
  NEED_PUBLISH=true
elif [[ "$(cmp_ver "$DESIRED" "$AUR_VER")" -gt 0 ]]; then
  NEED_PUBLISH=true
fi
echo "decision: action=$ACTION reason=$REASON changed=$CHANGED need_publish=$NEED_PUBLISH desired=$DESIRED"

if [[ "$CHANGED" == true ]]; then
  echo "updating PKGBUILD -> pkgver=$NEW_VER pkgrel=$NEW_REL"
  NEW_LIC_SHA=$(curl -fsSL "https://raw.githubusercontent.com/${UPSTREAM_REPO}/v${NEW_VER}/LICENSE" \
                 | sha256sum | awk '{print $1}')
  sed -i -E "s|^pkgver=.*|pkgver=${NEW_VER}|" "$PKGBUILD"
  sed -i -E "s|^pkgrel=.*|pkgrel=${NEW_REL}|" "$PKGBUILD"
  sed -i -E "s|^sha256sums_x86_64=.*|sha256sums_x86_64=('${NEW_SHA}' '${NEW_LIC_SHA}')|" "$PKGBUILD"
  # makepkg requires the PKGBUILD to live in the current working directory.
  ( cd "$PKGDIR" && PACKAGER="${PACKAGER:-Feng Yifan <fengyifan@blocgo.com>}" \
      makepkg --printsrcinfo > .SRCINFO )
  echo "regenerated ${PKGDIR}/.SRCINFO"
fi

{
  printf 'CHANGED=%q\n' "$CHANGED"
  printf 'NEED_PUBLISH=%q\n' "$NEED_PUBLISH"
  printf 'ACTION=%q\n' "$ACTION"
  printf 'REASON=%q\n' "$REASON"
  printf 'PKGVER=%q\n' "$NEW_VER"
  printf 'PKGREL=%q\n' "$NEW_REL"
} > "$STATE_FILE"
echo "state written to $STATE_FILE"
