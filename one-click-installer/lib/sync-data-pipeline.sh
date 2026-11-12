#!/usr/bin/env bash
# one-click-installer/lib/sync-data-pipeline.sh — choose which cce-data-pipeline version this environment gets.
#
#   DATA_PIPELINE_REF empty (default) -> use data-pipeline/ as vendored in this repo (what the installer is tested with).
#   DATA_PIPELINE_REF=<branch|tag|commit> -> fetch that ref of DATA_PIPELINE_REPO and sync its schema/ cdc/ connectors/
#                                            infra/ into this repo's data-pipeline/ (the copy every installer and day-2
#                                            script reads), so a later redeploy uses the same version. Like the generated
#                                            overlay, the change shows in `git status` — review and commit it.
# Only those four directories — what actually gets deployed — are replaced. scripts/ stays: this repo's copies carry
# deploy-side fixes, and the one the installer runs (apply-schema.py) is the same upstream. run-with-infisical.sh, .env kept.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
DP="$REPO/data-pipeline"
REF="${DATA_PIPELINE_REF:-}"
URL="${DATA_PIPELINE_REPO:-https://github.com/openphc/cce-data-pipeline.git}"

if [ -z "$REF" ]; then
  echo "  data pipeline: vendored copy ($DP)"
  exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
# --depth 1 fetch of a single ref works for branches, tags and (on GitHub) full commit SHAs
GIT_TERMINAL_PROMPT=0 git -C "$T" fetch -q --depth 1 "$URL" "$REF" \
  || { echo "ERROR: cannot fetch '$REF' from $URL (branch, tag or full commit SHA?)"; exit 1; }
git -C "$T" checkout -q FETCH_HEAD
SHA="$(git -C "$T" rev-parse --short HEAD)"
for need in schema/01-create-tables.sql cdc/01-configure-replication.sql connectors/debezium-postgres-source.json; do
  [ -r "$T/$need" ] || { echo "ERROR: $URL@$REF has no $need — not a cce-data-pipeline tree the installer can deploy"; exit 1; }
done
# data-pipeline/ may be absent: a deployment branch that always deploys a fetched version need not vendor it. Then scripts/ comes from the fetched version too — apply-schema.py, the one day-2 helper the installer uses, is the same.
mkdir -p "$DP"
[ -d "$DP/scripts" ] || { [ -d "$T/scripts" ] && cp -r "$T/scripts" "$DP/scripts"; }
for d in schema cdc connectors infra; do
  [ -d "$T/$d" ] || continue
  rm -rf "${DP:?}/$d"; cp -r "$T/$d" "$DP/$d"
done
printf '%s %s %s\n' "$URL" "$REF" "$SHA" > "$DP/.deployed-ref"
echo "  data pipeline: $URL @ $REF ($SHA) -> synced into $DP"
echo "  note: replaces the vendored copy, including local edits to it (e.g. this repo's 200-day ClickHouse TTL) — git diff data-pipeline/"
