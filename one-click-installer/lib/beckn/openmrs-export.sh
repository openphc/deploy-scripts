#!/usr/bin/env bash
# one-click-installer/lib/beckn/openmrs-export.sh [archive.tgz] — pack a RUNNING docker-compose OpenMRS (the dev layout) into one
# archive, to be restored into the k3s OpenMRS of the Beckn add-on with openmrs-import.sh.
#
# Run it on the SOURCE machine (it needs only docker and this one file — copy it there). Read-only: the source keeps running
# and nothing on it is changed. The archive holds PATIENT DATA: move it over SSH, keep it off shared disks, delete it after
# the import.
#
#   archive contents
#     db/openmrs.sql.gz        mysqldump of the openmrs database (one consistent snapshot)
#     data.tgz                 /openmrs/data of the backend: configuration, modules, images, search index, runtime properties
#                              (not: logs, the library cache, the message broker's journal — all rebuilt at start)
#     frontend/…               config-core_demo.json and custom-esms/ (the extra frontend modules), when present
#     backend/…                the backend's site files (backend/modules/*.omod, backend/ecgai/prompt.txt), when present
#     MANIFEST                 where and when it was taken, image versions
#
#   DB_CONTAINER=openmrs-db  BACKEND_CONTAINER=openmrs-backend  OPENMRS_HOST_DIR=/opt/openmrs   override the dev names
set -euo pipefail
OUT="${1:-openmrs-export-$(date -u +%Y%m%dT%H%M%SZ).tgz}"
DB_CONTAINER="${DB_CONTAINER:-openmrs-db}"; BACKEND_CONTAINER="${BACKEND_CONTAINER:-openmrs-backend}"; HOST_DIR="${OPENMRS_HOST_DIR:-/opt/openmrs}"
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found — this script exports a docker-compose OpenMRS"; exit 1; }
for c in "$DB_CONTAINER" "$BACKEND_CONTAINER"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { echo "ERROR: container $c is not running"; exit 1; }
done
umask 077
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/db" "$W/frontend"

echo "[openmrs-export] database (mysqldump from $DB_CONTAINER)…"
# The password stays inside the container: it is read from the container's own environment.
docker exec "$DB_CONTAINER" sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --triggers --hex-blob --default-character-set=utf8mb4 openmrs' \
  | gzip > "$W/db/openmrs.sql.gz"
gzip -t "$W/db/openmrs.sql.gz"
zcat "$W/db/openmrs.sql.gz" | tail -n 3 | grep -q 'Dump completed' || { echo "ERROR: the dump is incomplete (no 'Dump completed' line)"; exit 1; }

echo "[openmrs-export] /openmrs/data (the volume of $BACKEND_CONTAINER)…"
# The backend image has no tar, so a throwaway container reads the same volume, read-only. It uses the database container's
# image: that one is already on this machine (nothing is pulled) and has tar.
# Left out — all three are rebuilt at start, and none belongs to the data:
#   ./*.log                the server logs. --anchored + --no-wildcards-match-slash keep the pattern to the TOP level: without
#                          them "*.log" also matches the message broker's journal files (activemq-data/…/db-N.log), and an
#                          OpenMRS restored without them starts its core but none of its modules (no REST, no FHIR).
#   ./.openmrs-lib-cache   the library cache, rebuilt from modules/
#   ./activemq-data        the event module's embedded message broker: undelivered messages of the SOURCE machine
HELPER_IMAGE="${HELPER_IMAGE:-$(docker inspect -f '{{.Config.Image}}' "$DB_CONTAINER")}"
DATA_SRC="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/openmrs/data"}}{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}' "$BACKEND_CONTAINER")"
[ -n "$DATA_SRC" ] || { echo "ERROR: $BACKEND_CONTAINER has no volume at /openmrs/data"; exit 1; }
docker run --rm --network none --entrypoint tar -v "$DATA_SRC:/src:ro" "$HELPER_IMAGE" \
  -C /src --anchored --no-wildcards-match-slash --exclude='./*.log' --exclude='./.openmrs-lib-cache' --exclude='./activemq-data' \
  -czf - . > "$W/data.tgz" \
  || { echo "ERROR: could not read /openmrs/data (helper image $HELPER_IMAGE)"; exit 1; }
gzip -t "$W/data.tgz"
[ "$(tar -tzf "$W/data.tgz" | wc -l)" -gt 10 ] || { echo "ERROR: the data volume archive is (nearly) empty"; exit 1; }

if [ -r "$HOST_DIR/config-core_demo.json" ]; then cp "$HOST_DIR/config-core_demo.json" "$W/frontend/"; fi
if [ -d "$HOST_DIR/frontend/custom-esms" ]; then cp -r "$HOST_DIR/frontend/custom-esms" "$W/frontend/custom-esms"; fi
if [ -d "$HOST_DIR/backend" ]; then cp -r "$HOST_DIR/backend" "$W/backend"; fi

{
  echo "exported_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "source_host=$(hostname)"
  echo "db_image=$(docker inspect -f '{{.Config.Image}}' "$DB_CONTAINER")"
  echo "backend_image=$(docker inspect -f '{{.Config.Image}}' "$BACKEND_CONTAINER")"
  echo "patients=$(docker exec "$DB_CONTAINER" sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "select count(*) from openmrs.patient where voided=0"' 2>/dev/null || echo '?')"
} > "$W/MANIFEST"

tar -C "$W" -czf "$OUT" .
echo "[openmrs-export] wrote $OUT ($(du -h "$OUT" | cut -f1))"; sed 's/^/    /' "$W/MANIFEST"
echo "    Holds patient data: copy it over SSH, import with openmrs-import.sh, then delete it."
