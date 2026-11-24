#!/usr/bin/env bash
# one-click-installer/lib/beckn/openmrs-import.sh <envcode> <archive.tgz> — restore an openmrs-export.sh archive into the k3s
# OpenMRS of the Beckn add-on, REPLACING what is there. Run under infisical-run.sh, with the installer config loaded:
#
#   sudo bash one-click-installer/lib/beckn/run.sh --config <file> openmrs-import.sh <archive.tgz> [--yes]
#
# What it replaces, in the OpenMRS namespace:
#   the openmrs database        dropped, recreated, restored from the dump
#   the backend's data volume   emptied, then filled from the archive (configuration, modules, images, search index)
#   the frontend's site files   <BECKN_OPENMRS_HOST_DIR>/config-core_demo.json and frontend/custom-esms/
#   the backend's site files    <BECKN_OPENMRS_HOST_DIR>/backend/ (extra modules, ECG AI prompt), when the archive has them
# What it keeps: this installation's own database passwords. The archive's openmrs-runtime.properties is rewritten to
# connect with them, so nothing from the source machine's database login is carried over.
# What comes WITH the data: the OpenMRS user accounts, and so the admin password. The adaptors sign in with
# OPENMRS_ADMIN_USER / OPENMRS_ADMIN_PASSWORD from Infisical /beckn — set them to the source's values before or after
# (the last step checks, and tells you).
#
# The backend and the two adaptors are stopped for the import and started again. The emitter's checkpoint is left alone: it
# keeps a time, not a row id, so it stays valid, and a new emitter (no checkpoint) starts from "now" — history is not sent.
set -euo pipefail
ENVCODE="${1:?usage: openmrs-import.sh <envcode> <archive.tgz> [--yes]}"
ARCHIVE="${2:?usage: openmrs-import.sh <envcode> <archive.tgz> [--yes]}"
[ "${3:-}" = "--yes" ] && ASSUME_YES=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/beckn-lib.sh"
export ENVCODE
beckn_defaults
beckn_kubectl
NS="$(beckn_component_ns openmrs)"
[ -r "$ARCHIVE" ] || { echo "ERROR: cannot read $ARCHIVE"; exit 1; }
: "${OPENMRS_DB_PASSWORD:?OPENMRS_DB_PASSWORD not set — run under infisical-run.sh, after install-beckn.sh}"
$KUBECTL -n "$NS" get deploy openmrs-db openmrs-backend >/dev/null 2>&1 || { echo "ERROR: no OpenMRS in namespace $NS — run install-beckn.sh first"; exit 1; }
umask 077
W="$(mktemp -d)"; HELPER="openmrs-import-$$"
cleanup() { rm -rf "$W"; $KUBECTL -n "$NS" delete pod "$HELPER" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
tar -C "$W" -xzf "$ARCHIVE"
for f in db/openmrs.sql.gz data.tgz MANIFEST; do [ -r "$W/$f" ] || { echo "ERROR: $ARCHIVE has no $f — not an openmrs-export.sh archive"; exit 1; }; done
gzip -t "$W/db/openmrs.sql.gz"; gzip -t "$W/data.tgz"

dbq() { $KUBECTL -n "$NS" exec deploy/openmrs-db -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "$1" 2>/dev/null' sh "$1"; }
$KUBECTL -n "$NS" rollout status deploy/openmrs-db --timeout=300s >/dev/null
HAVE="$(dbq "select count(*) from information_schema.tables where table_schema='openmrs' and table_name='patient'" || echo 0)"
NOW="-"; [ "$HAVE" = 1 ] && NOW="$(dbq 'select count(*) from openmrs.patient where voided=0' || echo '?')"
echo "[openmrs-import] archive:"; sed 's/^/    /' "$W/MANIFEST"
echo "[openmrs-import] target: namespace $NS, patients there now: $NOW"
if [ -z "${ASSUME_YES:-}" ]; then
  read -r -p "Replace the OpenMRS database and data volume in $NS with this archive? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || { echo "Aborted — nothing changed."; exit 0; }
fi

echo "[openmrs-import] stopping backend + adaptors…"
STOPPED="openmrs-backend"
for d in openmrs-cce-emitter-adaptor openmrs-cce-receiver-adaptor; do $KUBECTL -n "$NS" get deploy "$d" >/dev/null 2>&1 && STOPPED="$STOPPED $d"; done
for d in $STOPPED; do $KUBECTL -n "$NS" scale deploy "$d" --replicas=0 >/dev/null; done
$KUBECTL -n "$NS" wait --for=delete pod -l app=openmrs-backend --timeout=180s >/dev/null 2>&1 || true

echo "[openmrs-import] database: drop, create, restore…"
dbq "DROP DATABASE IF EXISTS openmrs; CREATE DATABASE openmrs CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; GRANT ALL PRIVILEGES ON openmrs.* TO '${OMRS_DB_USER:-openmrs}'@'%'; FLUSH PRIVILEGES;"
zcat "$W/db/openmrs.sql.gz" | $KUBECTL -n "$NS" exec -i deploy/openmrs-db -- sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --default-character-set=utf8mb4 openmrs'
echo "    patients: $(dbq 'select count(*) from openmrs.patient where voided=0')   encounters: $(dbq 'select count(*) from openmrs.encounter')   users: $(dbq 'select count(*) from openmrs.users')"

echo "[openmrs-import] data volume…"
# A helper pod on the backend's volume (the backend is stopped, so the ReadWriteOnce claim is free). Works with any storage class.
$KUBECTL -n "$NS" run "$HELPER" --image=busybox:1.36 --restart=Never --overrides='{
  "spec": {"containers": [{"name": "h", "image": "busybox:1.36", "command": ["sleep", "3600"],
            "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"cpu": "500m", "memory": "256Mi"}},
            "volumeMounts": [{"name": "d", "mountPath": "/data"}]}],
           "volumes": [{"name": "d", "persistentVolumeClaim": {"claimName": "openmrs-data"}}]}}' >/dev/null
$KUBECTL -n "$NS" wait --for=condition=Ready "pod/$HELPER" --timeout=180s >/dev/null
$KUBECTL -n "$NS" exec "$HELPER" -- sh -c 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} +'
$KUBECTL -n "$NS" exec -i "$HELPER" -- tar -C /data -xzf - < "$W/data.tgz"
# Connect with THIS installation's database login (the Service is openmrs-db here too), and hand the files to the backend's user.
PROPS="$W/openmrs-runtime.properties"
if $KUBECTL -n "$NS" exec "$HELPER" -- cat /data/openmrs-runtime.properties > "$PROPS" 2>/dev/null && [ -s "$PROPS" ]; then
  python3 - "$PROPS" <<'PY'
import os, re, sys
p = sys.argv[1]; out = []
esc = lambda s: re.sub(r'([\\:=#! ])', r'\\\1', s)          # .properties escaping
for line in open(p).read().splitlines():
    if line.startswith("connection.username="): line = "connection.username=" + esc(os.environ.get("OMRS_DB_USER", "openmrs"))
    elif line.startswith("connection.password="): line = "connection.password=" + esc(os.environ["OPENMRS_DB_PASSWORD"])
    elif line.startswith("connection.url="): line = re.sub(r'(mysql\\?://)[^/\\:]+', r'\1openmrs-db', line, count=1)
    out.append(line)
open(p, "w").write("\n".join(out) + "\n")
PY
  $KUBECTL -n "$NS" exec -i "$HELPER" -- sh -c 'cat > /data/openmrs-runtime.properties' < "$PROPS"
  echo "    openmrs-runtime.properties: database login set to this installation's"
else
  echo "    no openmrs-runtime.properties in the archive — the backend will write one from its environment"
fi
$KUBECTL -n "$NS" exec "$HELPER" -- sh -c 'chown -R 1001:0 /data && chmod -R g+rwX /data && du -sh /data | cut -f1' | sed 's/^/    size: /'
$KUBECTL -n "$NS" delete pod "$HELPER" --wait=true >/dev/null

if [ -d "$W/frontend" ] && [ -n "$(ls -A "$W/frontend" 2>/dev/null)" ]; then
  D="$BECKN_OPENMRS_HOST_DIR"
  echo "[openmrs-import] frontend site files -> $D"
  ( umask 022; mkdir -p "$D/frontend/custom-esms"
    [ -r "$W/frontend/config-core_demo.json" ] && install -m 644 "$W/frontend/config-core_demo.json" "$D/config-core_demo.json"
    if [ -d "$W/frontend/custom-esms" ]; then rm -rf "$D/frontend/custom-esms"; cp -r "$W/frontend/custom-esms" "$D/frontend/custom-esms"; chmod -R a+rX "$D/frontend"; fi )
  $KUBECTL -n "$NS" rollout restart deploy/openmrs-frontend >/dev/null
fi

if [ -d "$W/backend" ]; then
  D="$BECKN_OPENMRS_HOST_DIR"
  echo "[openmrs-import] backend site files -> $D/backend"
  ( umask 022; rm -rf "$D/backend"; cp -r "$W/backend" "$D/backend"; mkdir -p "$D/backend/modules"; chmod -R a+rX "$D/backend" )
fi

echo "[openmrs-import] starting the backend (a few minutes: it checks the database and loads its modules)…"
$KUBECTL -n "$NS" scale deploy openmrs-backend --replicas=1 >/dev/null
# "Rolled out" means ready, and ready means the REST module answers (k8s/beckn/openmrs/openmrs.yaml).
$KUBECTL -n "$NS" rollout status deploy/openmrs-backend --timeout=1500s >/dev/null \
  || echo "    backend NOT ready: the core may be up with its modules failed — $KUBECTL -n $NS logs deploy/openmrs-backend | grep -E 'ERROR|Exception' | head"
for d in $STOPPED; do [ "$d" = openmrs-backend ] || $KUBECTL -n "$NS" scale deploy "$d" --replicas=1 >/dev/null; done

# The adaptors' OpenMRS login must be an account of the IMPORTED database.
AUTH="$($KUBECTL -n "$NS" exec deploy/openmrs-gateway -- sh -c 'curl -s -m 30 -u "$1:$2" http://localhost/openmrs/ws/rest/v1/session' sh "${OPENMRS_ADMIN_USER:-admin}" "${OPENMRS_ADMIN_PASSWORD:-}" 2>/dev/null | grep -o '"authenticated":[a-z]*' || true)"
case "$AUTH" in
  *true)  echo "[openmrs-import] done. Adaptor login ${OPENMRS_ADMIN_USER:-admin}: accepted by the imported OpenMRS.";;
  *false) echo "[openmrs-import] done, BUT the adaptor login ${OPENMRS_ADMIN_USER:-admin} (Infisical /beckn OPENMRS_ADMIN_USER / OPENMRS_ADMIN_PASSWORD) is NOT"
          echo "    accepted by the imported OpenMRS. Set both to an account of the source, then re-run install-beckn.sh --only openmrs.";;
  *)      echo "[openmrs-import] done. Could not check the adaptor login yet (OpenMRS still starting?) — check the adaptor logs once it is up.";;
esac
echo "    Delete the archive now: it holds patient data.   rm -f $ARCHIVE"
