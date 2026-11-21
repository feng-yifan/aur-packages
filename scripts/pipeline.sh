#!/usr/bin/env bash
# Orchestrate the AUR automation.
#   pipeline.sh check    -> reconcile upstream vs GitHub vs AUR, build, commit, publish
#   pipeline.sh publish  -> build the current package and publish if AUR is behind
# Env: PKG, DRY_RUN (true/false), AUR_AUTOPUBLISH (true/false), GH_TOKEN,
#      AUR_SSH_PRIVATE_KEY, AUR_KNOWN_HOSTS, GITHUB_REPOSITORY, GITHUB_REF_NAME
set -euo pipefail

MODE="check"
for a in "$@"; do case "$a" in check|publish) MODE="$a" ;; esac; done

PKG="${PKG:-twilight-echo-bin}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
DRY_RUN="${DRY_RUN:-false}"
AUTOPUBLISH="${AUR_AUTOPUBLISH:-false}"
STATE_FILE="$REPO_ROOT/.ci-state"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"

need_publish=false
changed=false
PKGVER=""; PKGREL=""

open_issue() { # $1 title, $2 body
  if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GH_TOKEN:-}" ]]; then
    gh issue create --repo "$GITHUB_REPOSITORY" --title "$1" --body "$2" || true
  else
    echo "[no-issue] $1"
  fi
}

if [[ "$MODE" == check ]]; then
  bash scripts/check-upstream.sh "$PKG"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  changed="$CHANGED"; need_publish="$NEED_PUBLISH"
else
  PKGVER=$(grep -m1 '^pkgver=' "$PKG/PKGBUILD" | cut -d= -f2- | tr -d '[:space:]')
  PKGREL=$(grep -m1 '^pkgrel=' "$PKG/PKGBUILD" | cut -d= -f2- | tr -d '[:space:]')
  DESIRED="${PKGVER}-${PKGREL}"
  AUR_VER=$(curl -fsSL "https://aur.archlinux.org/rpc/v5/info?arg[]=${PKG}" \
    | jq -r '.results[0].Version // empty' 2>/dev/null || true)
  if [[ -z "$AUR_VER" ]] || [[ "$(vercmp "$DESIRED" "$AUR_VER" 2>/dev/null || echo 0)" -gt 0 ]]; then
    need_publish=true
  fi
  echo "publish-mode: desired=$DESIRED aur=${AUR_VER:-<none>} need_publish=$need_publish"
fi

# Build verification gate (runs for any change or pending publish).
if [[ "$need_publish" == true || "$changed" == true ]]; then
  if ! bash scripts/build-verify.sh "$PKG"; then
    echo "BUILD/VERIFY FAILED" >&2
    if [[ "$DRY_RUN" != true ]]; then
      open_issue "[$PKG] build/verify failed for ${PKGVER:-?}-${PKGREL:-?}" \
        "Automated build verification failed; AUR was not updated. See ${SERVER}/${GITHUB_REPOSITORY:-repo}/actions"
    fi
    exit 1
  fi
fi

# Commit + push GitHub changes (check mode, files changed, not dry-run).
if [[ "$MODE" == check && "$changed" == true && "$DRY_RUN" != true ]]; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add "$PKG/PKGBUILD" "$PKG/.SRCINFO"
  git commit -m "upgpkg(${PKG}): update to ${PKGVER}-${PKGREL}"
  git push "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${GITHUB_REF_NAME:-main}"
  echo "pushed GitHub update ${PKGVER}-${PKGREL}"
fi

# Publish to AUR.
if [[ "$need_publish" == true ]]; then
  TARGET="${PKGVER}-${PKGREL}"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] would publish ${TARGET} to AUR"
    bash scripts/aur-publish.sh "$PKG"
  elif [[ "$MODE" == check && "$AUTOPUBLISH" != true ]]; then
    echo "AUR_AUTOPUBLISH disabled -> not publishing ${TARGET}"
    open_issue "[$PKG] new build ready to publish: ${TARGET}" \
      "A build was verified and committed to GitHub, but AUR auto-publish is OFF (AUR_AUTOPUBLISH=false). Trigger the publish-aur workflow or set the variable to true."
  else
    bash scripts/aur-publish.sh "$PKG" --push
  fi
fi

echo "pipeline done (mode=$MODE changed=$changed need_publish=$need_publish)"
