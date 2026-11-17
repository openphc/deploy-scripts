#!/usr/bin/env bash
# one-click-installer/lib/sync-data-pipeline.sh — choose which cce-data-pipeline version this environment gets.
#
#   DATA_PIPELINE_REF empty -> use the data-pipeline/ kept in this repository (branches that track a copy in git).
#   DATA_PIPELINE_REF=<branch|tag|commit> -> fetch that ref of DATA_PIPELINE_REPO and sync its schema/ cdc/ connectors/
#                                            infra/ into this repo's data-pipeline/ (the copy every installer and day-2
#                                            script reads), so a later redeploy uses the same version.
# Those four directories — what actually gets deployed — are always replaced. scripts/ is replaced too when git does not
# track it (a deployment branch without a copy, e.g. release-2.0.0); a tracked scripts/ stays, as it may carry deploy-side
# fixes (apply-schema.py, the one the installer runs, is the same upstream). run-with-infisical.sh, .env are kept.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
DP="$REPO/data-pipeline"
REF="${DATA_PIPELINE_REF:-}"
URL="${DATA_PIPELINE_REPO:-https://github.com/openphc/cce-data-pipeline.git}"

if [ -z "$REF" ]; then
  [ -d "$DP/schema" ] || { echo "ERROR: no $DP/schema and DATA_PIPELINE_REF is empty — set DATA_PIPELINE_REF (e.g. demo-v2)"; exit 1; }
  echo "  data pipeline: copy in this repository ($DP)"
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
# data-pipeline/ may be absent: a deployment branch that always deploys a fetched version need not keep a copy. Then
# scripts/ comes from the fetched version too, refreshed on every sync so it matches the deployed ref.
mkdir -p "$DP"
if [ -d "$T/scripts" ] && [ -z "$(git -C "$REPO" ls-files -- data-pipeline/scripts 2>/dev/null)" ]; then
  rm -rf "${DP:?}/scripts"; cp -r "$T/scripts" "$DP/scripts"
fi
for d in schema cdc connectors infra; do
  [ -d "$T/$d" ] || continue
  rm -rf "${DP:?}/$d"; cp -r "$T/$d" "$DP/$d"
done
printf '%s %s %s\n' "$URL" "$REF" "$SHA" > "$DP/.deployed-ref"
echo "  data pipeline: $URL @ $REF ($SHA) -> synced into $DP"
if [ -n "$(git -C "$REPO" ls-files -- data-pipeline/schema 2>/dev/null)" ]; then
  echo "  note: replaced the copy tracked in git, including local edits to it — review: git diff data-pipeline/"
fi
