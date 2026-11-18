#!/bin/sh
# /docker-entrypoint.d/40-merge-custom-esms.sh
#
# Splices custom ESMs into the official frontend image's importmap.json and
# routes.registry.json at container boot.
#
# Reads /usr/share/nginx/html/custom-esms/manifest.json which lists modules:
#   { "modules": [ { "name": "@scope/x", "dir": "x", "entry": "x.js" }, ... ] }
#
# For each module:
#   1. Adds entry to importmap.json:    "<name>": "./custom-esms/<dir>/<entry>"
#   2. Reads custom-esms/<dir>/routes.registry.json and inserts it as
#      "<name>": <routes-object> in the top-level routes registry.
#
# Idempotent: skips if the module name is already present.
# Safe-fail: any error logs to stderr but does not block nginx startup.

set -u

LOG_PREFIX="[40-merge-custom-esms]"
HTML_DIR="/usr/share/nginx/html"
CUSTOM_DIR="$HTML_DIR/custom-esms"
MANIFEST="$CUSTOM_DIR/manifest.json"
IMPORTMAP="$HTML_DIR/importmap.json"
ROUTES="$HTML_DIR/routes.registry.json"

log() { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX WARN: $*" >&2; }
fail_soft() { echo "$LOG_PREFIX ERROR: $*" >&2; exit 0; }

[ -d "$CUSTOM_DIR" ] || { log "no $CUSTOM_DIR; nothing to merge"; exit 0; }

# Optional branding: custom-esms/branding/title.txt replaces the browser tab title (<title> in
# index.html; the app shell never sets document.title). Re-running just writes the same title again.
TITLE_FILE="$CUSTOM_DIR/branding/title.txt"
INDEX="$HTML_DIR/index.html"
if [ -f "$TITLE_FILE" ] && [ -f "$INDEX" ]; then
  # first line only; drop characters that would break the sed replacement or the HTML
  title=$(head -n 1 "$TITLE_FILE" | tr -d '\r<>&|\\')
  if [ -n "$title" ] && sed -i "s|<title>[^<]*</title>|<title>$title</title>|" "$INDEX"; then
    log "browser tab title set to '$title'"
  else
    warn "could not set the browser tab title from $TITLE_FILE"
  fi
fi

[ -f "$MANIFEST" ] || { log "no manifest at $MANIFEST; nothing to merge"; exit 0; }
[ -f "$IMPORTMAP" ] || fail_soft "upstream importmap missing at $IMPORTMAP"
[ -f "$ROUTES" ] || fail_soft "upstream routes registry missing at $ROUTES"

# Refuse to run if upstream files are not single-line minified JSON.
# (sed-based splice depends on this; if it ever changes, ship pre-merged file.)
imap_lines=$(wc -l < "$IMPORTMAP")
routes_lines=$(wc -l < "$ROUTES")
# wc -l counts trailing newlines; a single-line file may report 0 or 1.
if [ "$imap_lines" -gt 1 ] || [ "$routes_lines" -gt 1 ]; then
  fail_soft "upstream JSON is multi-line (importmap=$imap_lines routes=$routes_lines); refusing to splice"
fi

# Parse module list from manifest using POSIX tools (no jq).
# Manifest is small, hand-authored, single-line or pretty-printed; collapse first.
manifest_flat=$(tr -d '\n\r\t' < "$MANIFEST" | tr -s ' ')

# Extract each {...} module object naively (manifest is trusted, hand-authored).
# Use a small awk to iterate on objects between [ ... ] of "modules".
echo "$manifest_flat" | awk '
  BEGIN { depth=0; capture=0; buf="" }
  {
    s = $0
    n = length(s)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "[") { capture=1; continue }
      if (c == "]") { capture=0; continue }
      if (!capture) continue
      if (c == "{") { depth++; if (depth==1) buf="" }
      if (depth >= 1) buf = buf c
      if (c == "}") { depth--; if (depth==0) print buf }
    }
  }
' | while IFS= read -r mod; do
  # Pull simple "key":"value" pairs out of one module object.
  name=$(echo "$mod"  | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  dir=$(echo "$mod"   | sed -n 's/.*"dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  entry=$(echo "$mod" | sed -n 's/.*"entry"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

  if [ -z "$name" ] || [ -z "$dir" ] || [ -z "$entry" ]; then
    warn "skipping malformed module entry: $mod"
    continue
  fi

  bundle_url="./custom-esms/$dir/$entry"
  bundle_path="$CUSTOM_DIR/$dir/$entry"
  routes_path="$CUSTOM_DIR/$dir/routes.registry.json"

  if [ ! -f "$bundle_path" ]; then
    warn "bundle missing for $name at $bundle_path; skipping"
    continue
  fi

  # ---------- importmap.json ----------
  # Look for the exact module-name token; if present, assume already spliced.
  if grep -q "\"$name\"" "$IMPORTMAP"; then
    log "$name already in importmap; skipping importmap splice"
  else
    insertion="\"$name\":\"$bundle_url\","
    awk -v INS="$insertion" '
      NR==1 {
        # find the start of the imports object: "imports":{
        m = match($0, /"imports"[[:space:]]*:[[:space:]]*\{/)
        if (m > 0) {
          end = m + RLENGTH - 1
          print substr($0, 1, end) INS substr($0, end + 1)
          next
        }
      }
      { print }
    ' "$IMPORTMAP" > "$IMPORTMAP.new" \
      && mv "$IMPORTMAP.new" "$IMPORTMAP" \
      && log "spliced $name into importmap" \
      || warn "failed to splice $name into importmap"
  fi

  # ---------- routes.registry.json ----------
  if [ ! -f "$routes_path" ]; then
    warn "no routes.registry.json for $name; extension list will be empty"
  elif grep -q "\"$name\"" "$ROUTES"; then
    log "$name already in routes registry; skipping routes splice"
  else
    # Read the module's routes object (single-line it).
    routes_blob=$(tr -d '\n\r\t' < "$routes_path" | tr -s ' ')
    # Use sed with a non-/ delimiter because the blob contains slashes.
    # Find the leading '{' of the registry and inject "name": <blob>,
    name_for_sed=$(echo "$name" | sed 's/[\/&]/\\&/g')
    # Build insertion as a temp file to avoid shell escape issues with sed
    tmp=$(mktemp)
    printf '"%s":%s,' "$name_for_sed" "$routes_blob" > "$tmp"
    insertion=$(cat "$tmp"); rm -f "$tmp"
    # sed cannot easily take the multi-thousand-char replacement on the
    # command line on some shells; write it through a tiny inline script.
    awk -v INS="$insertion" '
      NR==1 {
        # find first "{" and inject after it
        p = index($0, "{")
        if (p > 0) {
          print substr($0,1,p) INS substr($0,p+1)
          next
        }
      }
      { print }
    ' "$ROUTES" > "$ROUTES.new" && mv "$ROUTES.new" "$ROUTES" \
      && log "spliced $name into routes registry" \
      || warn "failed to splice $name into routes registry"
  fi
done

log "done"
exit 0
