#!/usr/bin/env bash
# rw/lib/build-from-source.sh [--check-only] [repo...] — clone the CCE repos from git (RW-MOH GitLab), build their images on this
# machine and import them straight into k3s's containerd. No registry: k3s runs them with imagePullPolicy IfNotPresent.
#
# Reads (exported by rw/one-click-install.sh from the config): SRC_<KEY>_REPO / SRC_<KEY>_BRANCH per repo (rw/lib/source-services.sh),
# SOURCE_DIR, LOCAL_IMAGE_REGISTRY, INSIGHTS_UI_VITE_*, GIT_TOKEN or GIT_TOKEN_FILE, STATE_DIR. FORCE_REBUILD=1 rebuilds images
# that already exist.
#
#   --check-only   only verify every repo + branch is reachable (nothing cloned or built) — the pre-flight
#   repo...        build only these (default: all). The pins file keeps the other repos' last values.
#
# SRC_*_BRANCH is a branch, a tag, or a full 40-character commit SHA (an exact pin; image tag commit-<sha10>).
# Images are tagged <branch>-<commit>[-u<common-util commit>][-c<ui build-args hash>], so a tag names exactly what was built: an
# unchanged commit is not rebuilt, and a new commit gets a new tag (which is what makes k8s roll the pod).
# Output: $STATE_DIR/pins.env (IMAGE_<SERVICE>=<tag> + DATA_PIPELINE_REPO/REF) and $STATE_DIR/build-manifest.tsv. Build logs:
# $STATE_DIR/logs/<repo>.log.
#
# The token never reaches argv or .git/config: it goes to git as an Authorization header through GIT_CONFIG_* environment
# variables, scoped to the repo's host.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/source-services.sh"

CHECK_ONLY=0; WANT=()
for a in "$@"; do case "$a" in --check-only) CHECK_ONLY=1;; -*) echo "unknown option $a"; exit 2;; *) WANT+=("$a");; esac; done

SOURCE_DIR="${SOURCE_DIR:-/opt/cce-src}"
REG="${LOCAL_IMAGE_REGISTRY:-cce.local/rw}"; REG="${REG%/}"
STATE_DIR="${STATE_DIR:?STATE_DIR not set (run via rw/one-click-install.sh)}"
PINS="$STATE_DIR/pins.env"; MANIFEST="$STATE_DIR/build-manifest.tsv"; LOGS="$STATE_DIR/logs"

TOKEN="${GIT_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -n "${GIT_TOKEN_FILE:-}" ]; then
  [ -r "$GIT_TOKEN_FILE" ] || { echo "ERROR: GIT_TOKEN_FILE=$GIT_TOKEN_FILE is not readable"; exit 1; }
  TOKEN="$(tr -d '[:space:]' < "$GIT_TOKEN_FILE")"
fi

# git with the token as a Basic-auth header for this URL's host only (GitLab accepts oauth2:<token>).
git_auth() {
  local url="$1"; shift
  (
    export GIT_TERMINAL_PROMPT=0
    if [ -n "$TOKEN" ] && [[ "$url" == https://* ]]; then
      local host="${url#https://}"; host="${host%%/*}"
      export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://${host}/.extraHeader"
      export GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'oauth2:%s' "$TOKEN" | base64 -w0)"
    fi
    git "$@"
  )
}

# SRC_*_BRANCH may also be a full commit SHA (pin an exact commit that no branch points at).
is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

selected() {   # selected <name>  — in WANT (or WANT empty)
  [ "${#WANT[@]}" -eq 0 ] && return 0
  local w; for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1
}

for w in "${WANT[@]}"; do
  printf '%s\n' "${RW_SOURCES[@]}" | cut -d'|' -f1 | grep -Fxq "$w" || { echo "ERROR: unknown repo '$w' (see rw/lib/source-services.sh)"; exit 2; }
done
# The 2.0 services compile against cce-common-util, so it is always needed when one of them is built.
if [ "${#WANT[@]}" -gt 0 ]; then
  for e in "${RW_SOURCES[@]}"; do IFS='|' read -r n r _ <<< "$e"
    if selected "$n" && { [ "$r" = boot-util ] || [ "$r" = docker-ws ]; }; then selected cce-common-util || WANT+=(cce-common-util); break; fi
  done
fi

# ───────────────────────────────────────────── pre-flight: every selected repo + branch reachable
echo "  checking repositories:"
problems=0
for e in "${RW_SOURCES[@]}"; do
  IFS='|' read -r name recipe _ <<< "$e"; selected "$name" || continue
  key="$(rw_src_key "$name")"; rv="SRC_${key}_REPO"; bv="SRC_${key}_BRANCH"
  url="${!rv:-}"; br="${!bv:-}"
  if [ -z "$url" ] || [ -z "$br" ]; then printf '    ✗ %-28s %s\n' "$name" "not configured ($rv / $bv)"; problems=$((problems+1)); continue; fi
  if ! refs="$(git_auth "$url" ls-remote --heads --tags "$url" 2>&1)"; then
    printf '    ✗ %-28s %s\n' "$name" "cannot access $url — $(printf '%s' "$refs" | tail -1 | sed "s#${TOKEN:-@@none@@}#<token>#g")"; problems=$((problems+1)); continue
  fi
  if is_sha "$br"; then
    # A commit is not listed by ls-remote: prove it exists by fetching just that commit (no trees/blobs) into a scratch repo.
    probe="$(mktemp -d)"
    if git -C "$probe" init -q && git_auth "$url" -C "$probe" fetch -q --depth 1 --filter=tree:0 "$url" "$br" >/dev/null 2>&1; then
      printf '    ✓ %-28s %s @ commit %s\n' "$name" "$url" "${br:0:10}"
    else
      printf '    ✗ %-28s %s\n' "$name" "commit $br not found in $url (needs the FULL 40-character SHA)"; problems=$((problems+1))
    fi
    rm -rf "$probe"
  elif printf '%s\n' "$refs" | awk '{print $2}' | grep -Ex "refs/(heads|tags)/${br//./\\.}" >/dev/null; then
    printf '    ✓ %-28s %s @ %s\n' "$name" "$url" "$br"
  elif [ -z "$refs" ]; then
    printf '    ✗ %-28s %s\n' "$name" "repository is EMPTY (not synced yet?): $url"; problems=$((problems+1))
  else
    printf '    ✗ %-28s %s\n' "$name" "no branch/tag '$br' in $url (has: $(printf '%s\n' "$refs" | awk '{sub("refs/(heads|tags)/","",$2); print $2}' | head -8 | tr '\n' ' '))"
    problems=$((problems+1))
  fi
done
[ "$problems" -eq 0 ] || { echo "ERROR: $problems repo(s) not ready — nothing was built. Fix the config or sync the repos, then re-run."; exit 1; }
[ "$CHECK_ONLY" = 1 ] && exit 0

# ───────────────────────────────────────────── build tools
command -v docker >/dev/null || { echo "ERROR: docker missing (rw/one-click-install.sh installs it via prereqs)"; exit 1; }
command -v k3s >/dev/null    || { echo "ERROR: k3s missing (rw/one-click-install.sh installs it via prereqs)"; exit 1; }
JAVAC="$(command -v javac || true)"
[ -n "$JAVAC" ] && export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$JAVAC")")")"
export DOCKER_BUILDKIT=1   # BuildKit sends only the paths a Dockerfile COPYs — the docker-ws context is the whole $SOURCE_DIR

mkdir -p "$SOURCE_DIR" "$LOGS"; chmod 700 "$STATE_DIR"
touch "$PINS"; chmod 600 "$PINS"
[ -s "$MANIFEST" ] || printf 'repo\tbranch\tcommit\timage\tbuilt_at\n' > "$MANIFEST"

set_pin() {   # set_pin KEY VALUE — replace or append in pins.env
  local k="$1" v="$2"
  grep -v "^${k}=" "$PINS" > "$PINS.tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$PINS.tmp"; mv "$PINS.tmp" "$PINS"; chmod 600 "$PINS"
}

# Move the checkout (shallow; created on first use) to the ref's current commit — a branch, tag or full commit SHA, which
# `git clone --branch` cannot take, hence init + fetch. Prints the commit.
checkout() {
  local name="$1" url="$2" br="$3" dir="$SOURCE_DIR/$1"
  if [ ! -d "$dir/.git" ]; then
    rm -rf "$dir"; git init -q "$dir"; git -C "$dir" remote add origin "$url"
  fi
  git -C "$dir" remote set-url origin "$url"
  git_auth "$url" -C "$dir" fetch -q --depth 1 origin "$br" >&2
  git -C "$dir" checkout -q -f --detach FETCH_HEAD >&2
  git -C "$dir" rev-parse HEAD
}

# Not `grep -q`: it exits at the first match, ctr then dies of SIGPIPE writing the rest, and pipefail turns the match into a
# failure (seen once the image list grew long enough).
in_k3s() { local list; list="$(k3s ctr -n k8s.io images ls -q 2>/dev/null)" || return 1; grep -Fx -- "$1" <<< "$list" >/dev/null; }

UTIL_SHA=""
built=() reused=()
for e in "${RW_SOURCES[@]}"; do
  IFS='|' read -r name recipe extra <<< "$e"; selected "$name" || continue
  key="$(rw_src_key "$name")"; rv="SRC_${key}_REPO"; bv="SRC_${key}_BRANCH"; url="${!rv}"; br="${!bv}"
  sha="$(checkout "$name" "$url" "$br")"
  dir="$SOURCE_DIR/$name"
  case "$recipe" in
    lib)      UTIL_SHA="$sha"; echo "  • $name @ $br ${sha:0:10} (library)"; continue ;;
    pipeline) set_pin DATA_PIPELINE_REPO "$dir"; set_pin DATA_PIPELINE_REF HEAD
              printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$br" "$sha" "-" "$(date -Is)" >> "$MANIFEST"
              echo "  • $name @ $br ${sha:0:10} (SQL/config — deployed by the data-pipeline step)"; continue ;;
  esac
  if is_sha "$br"; then tag="commit-${sha:0:10}"; else tag="$(printf '%s' "$br" | tr -c 'A-Za-z0-9._-' '-')-${sha:0:10}"; fi
  if [ "$recipe" = boot-util ] || [ "$recipe" = docker-ws ]; then
    [ -n "$UTIL_SHA" ] || UTIL_SHA="$(git -C "$SOURCE_DIR/cce-common-util" rev-parse HEAD)"
    tag="${tag}-u${UTIL_SHA:0:7}"
  fi
  UI_ARGS=()
  if [ "$recipe" = docker-ui ]; then
    UI_ARGS=(--build-arg "VITE_AUTH_ENABLED=${INSIGHTS_UI_VITE_AUTH_ENABLED:-true}"
             --build-arg "VITE_KEYCLOAK_URL=${INSIGHTS_UI_VITE_KEYCLOAK_URL:-}"
             --build-arg "VITE_KEYCLOAK_REALM=${INSIGHTS_UI_VITE_KEYCLOAK_REALM:-cce}"
             --build-arg "VITE_KEYCLOAK_CLIENT_ID=${INSIGHTS_UI_VITE_KEYCLOAK_CLIENT_ID:-cce-insights-ui}"
             --build-arg "VITE_ROUTER_BASE=${INSIGHTS_UI_VITE_ROUTER_BASE:-/insights}"
             --build-arg "VITE_TIMEZONE=${INSIGHTS_UI_VITE_TIMEZONE:-UTC}")
    tag="${tag}-c$(printf '%s\n' "${UI_ARGS[@]}" | sha1sum | cut -c1-6)"
  fi
  img="$REG/$name:$tag"

  if [ -z "${FORCE_REBUILD:-}" ] && in_k3s "$img"; then
    echo "  • $name @ $br ${sha:0:10} — $img already in k3s (unchanged, not rebuilt)"
    reused+=("$name")
  else
    echo "  • $name @ $br ${sha:0:10} — building $img ($recipe; log: $LOGS/$name.log)"
    start=$(date +%s)
    {
      case "$recipe" in
        boot|boot-util)
          [ -n "$JAVAC" ] || { echo "no JDK (javac) on PATH"; exit 1; }
          chmod +x "$dir/gradlew"
          [ "$recipe" = boot-util ] && chmod +x "$SOURCE_DIR/cce-common-util/gradlew"
          # shellcheck disable=SC2086  # $extra is a deliberate word list of Gradle args
          (cd "$dir" && ./gradlew --no-daemon bootBuildImage --imageName="$img" $extra) ;;
        docker-ws)
          docker build -f "$dir/Dockerfile" -t "$img" "$SOURCE_DIR" ;;
        docker-ui)
          docker build "${UI_ARGS[@]}" -t "$img" "$dir" ;;
      esac
    } > "$LOGS/$name.log" 2>&1 || { echo "ERROR: building $name failed — last lines of $LOGS/$name.log:"; tail -40 "$LOGS/$name.log"; exit 1; }
    echo "    built in $(( $(date +%s) - start ))s; importing into k3s…"
    docker save "$img" | k3s ctr -n k8s.io images import - >> "$LOGS/$name.log" 2>&1
    in_k3s "$img" || { echo "ERROR: $img is not in k3s after import (see $LOGS/$name.log)"; exit 1; }
    built+=("$name")
  fi
  set_pin "IMAGE_${key}" "$tag"
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$br" "$sha" "$img" "$(date -Is)" >> "$MANIFEST"
done

docker image prune -f >/dev/null 2>&1 || true   # dangling build layers only; the tagged images stay as build cache
echo "  built: ${built[*]:-none}   unchanged: ${reused[*]:-none}"
echo "  versions: $PINS"
