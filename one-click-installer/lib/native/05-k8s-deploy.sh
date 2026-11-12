#!/usr/bin/env bash
# one-click-installer/lib/native/05-k8s-deploy.sh <envcode>
# Deploy the cce-<envcode> k3s namespace. A deployment may have no public DNS name, so the ingress is
# rewritten to plain HTTP (set INGRESS_HOST + ACME_EMAIL to use TLS instead).
#
# Config/secrets come from the environment (`infisical run --env=<envcode>`, or a .meta-resolved
# project for a bootstrapped env — see one-click-installer/lib/infisical-run.sh).
#
# CH_METRICS_PORT defaults to ClickHouse's standard 9363 (dedicated machine); PROD's wrapper
# overrides to 9364 (its historical shift). The host-IP rewrite itself is NOT optional for any
# native-install env — the base Prometheus config's default target (172.18.0.1:9363) is UAT's
# docker-bridge IP, wrong for every native install regardless of port.
#
# NODE_EXPORTER_SHIFT_PORT is unset by default (dedicated machine, no collision -> keep node-
# exporter on the base's standard :9100). PROD's wrapper sets it to 9101 to dodge UAT's :9100 on
# their shared host.
set -euo pipefail

ENVCODE="${1:?usage: 05-k8s-deploy.sh <envcode>}"
NS="cce-${ENVCODE}"
CH_METRICS_PORT="${CH_METRICS_PORT:-9363}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
K8S="$REPO/k8s"
OVERLAY="$K8S/overlays/${OVERLAY_NAME:-$ENVCODE}"
INGRESS_REWRITE="$REPO/one-click-installer/lib/plain-http-ingress.py"   # shared helper (was rw/uat/lib/ — a hidden cross-dependency for one-click installs)

[ -d "$OVERLAY" ] || { echo "ERROR: no overlay at $OVERLAY — generate it first (one-click-installer/lib/generate-overlay.sh)"; exit 1; }

if [ -z "${KUBECTL:-}" ]; then
  if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"
  elif command -v k3s >/dev/null 2>&1; then KUBECTL="sudo k3s kubectl"
  else echo "ERROR: no kubectl / k3s found"; exit 1; fi
fi
: "${VM_HOST_IP:?set VM_HOST_IP}"
export VM_HOST_CIDR="${VM_HOST_CIDR:-${VM_HOST_IP}/32}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; [ -f "$OVERLAY/kustomization.yaml.bak" ] && mv "$OVERLAY/kustomization.yaml.bak" "$OVERLAY/kustomization.yaml"' EXIT

echo "=== [$ENVCODE 1/5] render overlays/$ENVCODE (envsubst BEFORE kustomize) ==="
cp "$OVERLAY/kustomization.yaml" "$OVERLAY/kustomization.yaml.bak"
envsubst < "$OVERLAY/kustomization.yaml.bak" > "$OVERLAY/kustomization.yaml"
$KUBECTL kustomize "$OVERLAY" > "$TMP/render.yaml"
mv "$OVERLAY/kustomization.yaml.bak" "$OVERLAY/kustomization.yaml"

# ClickHouse (native install) Prometheus scrape target: base config defaults to UAT's docker-
# bridge IP, wrong for every native env — always repoint to the host IP; only the PORT varies.
sed -i "s#172.18.0.1:9363#${VM_HOST_IP}:${CH_METRICS_PORT}#g" "$TMP/render.yaml"
# postgres_exporter (:9187) and kafka_exporter (:9308) are installed on the host by 07-monitoring-exporters.sh and their Grafana
# dashboards ship in data-pipeline/, but the base Prometheus config has no job for them (PROD's overlay once carried one; it was
# dropped) — so both dashboards stayed empty. Append the two jobs after the ClickHouse one, at its indentation.
python3 - "$TMP/render.yaml" "${VM_HOST_IP}:${CH_METRICS_PORT}" "$VM_HOST_IP" <<'PY'
import re, sys
path, ch_target, ip = sys.argv[1:]
text = open(path).read()
if '"postgres-exporter"' in text:
    sys.exit(0)
m = re.search(r'^( *)- targets: \["' + re.escape(ch_target) + r'"\]\n', text, re.M)
if not m:
    print("  WARNING: ClickHouse scrape target not found — postgres/kafka exporter jobs NOT added", file=sys.stderr); sys.exit(0)
job = len(m.group(1)) - 4                     # "- job_name" sits 4 columns left of "- targets"
pad = lambda n: " " * (job + n)
add = "".join(f'{pad(0)}- job_name: "{name}"\n{pad(2)}static_configs:\n{pad(4)}- targets: ["{ip}:{port}"]\n'
              for name, port in (("postgres-exporter", 9187), ("kafka-exporter", 9308)))
open(path, "w").write(text[:m.end()] + add + text[m.end():])
print("  prometheus: + postgres-exporter :9187, kafka-exporter :9308")
PY

# The base NetworkPolicy carries a literal ${VM_HOST_CIDR}: the overlay's envsubst only covers kustomization.yaml, not base files.
# Applying the render with it left in makes kubectl reject that one resource ("ipBlock.cidr: Invalid value") and exit 1, which under
# `set -e` aborted the whole deploy BEFORE step 3 (which applies the properly-substituted policy) — fatal on every fresh install.
sed -i "s#\${VM_HOST_CIDR}#${VM_HOST_CIDR}#g" "$TMP/render.yaml"

# k8s/base/services/keycloak.yaml mounts the Insights UI login theme via a hostPath that is hardcoded to the first reference VM's checkout
# (/home/cceadmin/deploy-scripts/keycloak-themes/...). On any other machine that path does not exist, so the keycloak pod sat in
# ContainerCreating forever ("hostPath type check failed") and the whole stack had no IdP. Point it at THIS checkout — the themes
# ship in the repo (keycloak-themes/).
# Which theme: KEYCLOAK_THEME_DIR (default: the unbranded keycloak-themes/cce-insights-theme/dev). It is mounted under the theme
# NAME the realm already selects (insights-ui-theme), exactly like docker-compose does for dev, so no realm change is needed.
THEME_DIR="${KEYCLOAK_THEME_DIR:-keycloak-themes/cce-insights-theme/dev}"
[ "${THEME_DIR#/}" = "$THEME_DIR" ] && THEME_DIR="$REPO/$THEME_DIR"
sed -i "s#/home/cceadmin/deploy-scripts/keycloak-themes/insights-ui-theme#${THEME_DIR}#g" "$TMP/render.yaml"
sed -i "s#/home/cceadmin/deploy-scripts#${REPO}#g" "$TMP/render.yaml"
[ -r "$THEME_DIR/login/theme.properties" ] || echo "  WARNING: $THEME_DIR has no login/theme.properties — keycloak will not start (copy the keycloak-themes/ directory)"

if [ -n "${INGRESS_HOST:-}" ]; then
  : "${ACME_EMAIL:?set ACME_EMAIL for TLS - the ACME/LetsEncrypt contact}"
  echo "=== [$ENVCODE 2/5] domain ${INGRESS_HOST}: apply Traefik ACME (le) + TLS ingress ==="
  envsubst < "$K8S/base/traefik/traefik-helmchartconfig.yaml" > "$TMP/traefik-hcc.yaml"
  $KUBECTL apply -f "$TMP/traefik-hcc.yaml"          # cluster-global le/lestaging resolvers
  $KUBECTL apply -f "$TMP/render.yaml"               # ingress keeps host=${INGRESS_HOST} + tls
else
  echo "=== [$ENVCODE 2/5] no INGRESS_HOST: rewrite ingress to plain HTTP + apply ==="
  python3 "$INGRESS_REWRITE" < "$TMP/render.yaml" > "$TMP/render.http.yaml"
  $KUBECTL apply -f "$TMP/render.http.yaml"
fi

echo "=== [$ENVCODE 3/5] NetworkPolicy (host egress incl. ClickHouse $CH_METRICS_PORT) ==="
envsubst < "$K8S/base/network-policy.yaml" > "$TMP/netpol.yaml"
# The base policy lets pods reach only the data ports + ClickHouse metrics on the host. Prometheus also scrapes three host-side
# exporters — node-exporter (hostNetwork), postgres_exporter, kafka_exporter — and was refused on all of them ("connection
# refused", target down). Add their ports to the same host rule.
python3 - "$TMP/netpol.yaml" "${NODE_EXPORTER_SHIFT_PORT:-9100}" <<'PY'
import re, sys
path, node_port = sys.argv[1], sys.argv[2]
text = open(path).read()
m = re.search(r'^( *)- protocol: TCP\n\1  port: 9364\n', text, re.M)
if not m:
    print("  WARNING: host-port rule not found in network-policy — exporter ports NOT added", file=sys.stderr); sys.exit(0)
have = set(re.findall(r'port: (\d+)', text))
add = "".join(f"{m.group(1)}- protocol: TCP\n{m.group(1)}  port: {p}\n" for p in (node_port, "9187", "9308") if p not in have)
open(path, "w").write(text[:m.end()] + add + text[m.end():])
PY
$KUBECTL apply -f "$TMP/netpol.yaml" -n "$NS"

if [ -n "${NODE_EXPORTER_SHIFT_PORT:-}" ]; then
  echo "=== [$ENVCODE] node-exporter -> :$NODE_EXPORTER_SHIFT_PORT (shared-host port avoidance) ==="
  $KUBECTL patch ds node-exporter -n "$NS" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--web.listen-address=:${NODE_EXPORTER_SHIFT_PORT}\"},{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/ports/0/containerPort\",\"value\":${NODE_EXPORTER_SHIFT_PORT}},{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/ports/0/hostPort\",\"value\":${NODE_EXPORTER_SHIFT_PORT}}]" 2>/dev/null || true
  $KUBECTL patch svc node-exporter -n "$NS" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/targetPort\",\"value\":${NODE_EXPORTER_SHIFT_PORT}}]" 2>/dev/null || true
else
  echo "=== [$ENVCODE] node-exporter: standard :9100 (dedicated machine, no shift needed) ==="
fi

# Map the public host to the in-cluster Traefik ClusterIP on the gateway pod so it can fetch
# the JWKS in-cluster (the token issuer is the public URL; pods can't hairpin to the node IP).
if [ -n "${INGRESS_HOST:-}" ]; then
  echo "=== [$ENVCODE 4/5] gateway hostAlias ${INGRESS_HOST} -> Traefik ClusterIP (in-cluster JWKS) ==="
  TIP=$($KUBECTL get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}')
  $KUBECTL patch deploy gateway-service -n "$NS" -p "{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":[{\"ip\":\"${TIP}\",\"hostnames\":[\"${INGRESS_HOST}\"]}]}}}}"
fi

# Grafana dashboards: provision ALL grafana/dashboards/*.json (+ the data-pipeline pipeline-health
# dashboard), rewriting the dangling ${DS_PROMETHEUS} input -> datasource uid "prometheus". Globbing
# (rather than a hardcoded list) keeps this in lock-step with one-click-installer/lib/grafana-redeploy.sh, so a new
# dashboard ships just by adding its .json — and a full deploy never drops one.
echo "=== [$ENVCODE 5/5] grafana dashboards configmap ==="
GDASH="$TMP/gdash"; mkdir -p "$GDASH"
python3 - "$REPO" "$GDASH" <<'PY'
import sys, os, glob
repo, out = sys.argv[1], sys.argv[2]
for p in sorted(glob.glob(os.path.join(repo, 'grafana', 'dashboards', '*.json'))):
    open(os.path.join(out, os.path.basename(p)), 'w').write(
        open(p).read().replace('${DS_PROMETHEUS}', 'prometheus'))
dp = os.path.join(repo, 'data-pipeline', 'infra', 'grafana', 'provisioning',
                  'dashboards', 'json', 'pipeline-health.json')
if os.path.exists(dp):
    open(os.path.join(out, 'pipeline-health.json'), 'w').write(open(dp).read())
PY
$KUBECTL create configmap grafana-dashboards -n "$NS" --from-file="$GDASH" \
  --dry-run=client -o yaml | $KUBECTL apply --server-side --force-conflicts -f -

echo ""
echo "Applied. Watch:  $KUBECTL get pods -n $NS -w"
