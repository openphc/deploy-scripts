#!/usr/bin/env bash
# one-click-installer/lib/portainer.sh <envcode> — Portainer, NATIVE: the portainer-ce release binary as the systemd service
# cce-portainer (no container), managing the k3s cluster through portainer-agent (one-click-installer/lib/portainer-agent.yaml) and,
# if docker is installed, this machine's docker. Run under the Infisical wrapper (one-click-installer/install.sh does).
#
# Access is by SSH tunnel only:  ssh -L 9443:localhost:9443 <user>@<host>   then https://localhost:9443
# HTTPS 9443 is reachable only from loopback and the k3s networks (systemd IPAddressAllow — see the unit); HTTP disabled; Edge
# tunnel 8000 on 127.0.0.1. Nothing depends on UFW.
#
# Admin: user "admin", password PORTAINER_ADMIN_PASSWORD in Infisical (/portainer; taken from SEED_ENV_FILE if given there, else
# generated on first run). Portainer must be initialised within minutes of first start or it locks itself; this script does it
# straight away through the API, then registers the "<envcode>-k3s" agent environment (and "local" docker, when docker exists).
# Idempotent. PORTAINER_VERSION (default 2.39.2) pins both server and agent; PORTAINER_SHA256 when changing it.
# An existing docker-run Portainer (container "portainer", volume portainer_data) is moved over once: data copied, container removed.
set -euo pipefail
ENVCODE="${1:?usage: portainer.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
VER="${PORTAINER_VERSION:-2.39.2}"
KUBECTL="${KUBECTL:-k3s kubectl}"
API="https://127.0.0.1:9443/api"

. "$REPO/one-click-installer/lib/infisical-secret-helpers.sh"
infisical_resolve_project "$ENVCODE"
infisical_login
# A PORTAINER_ADMIN_PASSWORD given in the seed file lands in /platform (the seed's catch-all) and reaches us through the wrapper's
# environment: on first install, adopt it as /portainer's value instead of generating one. Later changes: one-click-installer/lib/set-admin-passwords.sh.
if [ -z "$(infisical_get /portainer PORTAINER_ADMIN_PASSWORD "$PROJECT_ID" "$INFISICAL_ENV_SLUG")" ] && [ -n "${PORTAINER_ADMIN_PASSWORD:-}" ]; then
  infisical_set /portainer PORTAINER_ADMIN_PASSWORD "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "$PORTAINER_ADMIN_PASSWORD"
  echo "  admin password: taken from the seed file"
fi
PW="$(infisical_get_or_generate /portainer PORTAINER_ADMIN_PASSWORD "$PROJECT_ID" "$INFISICAL_ENV_SLUG")"
[ "${#PW}" -ge 12 ] || { echo "  ✗ PORTAINER_ADMIN_PASSWORD must be at least 12 characters (Portainer's minimum)"; exit 1; }

# 1) agent in k3s
export PORTAINER_VERSION="$VER"
envsubst '${PORTAINER_VERSION}' < "$HERE/portainer-agent.yaml" | $KUBECTL apply -f - >/dev/null
$KUBECTL -n portainer rollout status deploy/portainer-agent --timeout=180s >/dev/null
AGENT_IP="$($KUBECTL -n portainer get svc portainer-agent -o jsonpath='{.spec.clusterIP}')"
echo "  agent: portainer/agent:$VER at $AGENT_IP:9001 (ClusterIP, not published)"

# 2) server: the release binary as a systemd service (cce-portainer), no container. PORTAINER_SHA256 overrides the pinned checksum
#    (from the release's own -checksum.txt) when PORTAINER_VERSION changes.
SHA="${PORTAINER_SHA256:-}"
[ -n "$SHA" ] || [ "$VER" != 2.39.2 ] || SHA=9db6fb861d4f232b9ff583ff2ba83aee94c6178f45390ad719d985a45de0f3cd
[ -n "$SHA" ] || SHA="$(curl -fsSL --max-time 60 "https://github.com/portainer/portainer/releases/download/$VER/portainer-$VER-linux-amd64-checksum.txt" | grep -oE '[0-9a-f]{64}')"
DIR="/opt/portainer-$VER"; DATA=/var/lib/portainer
if [ ! -x "$DIR/portainer" ]; then
  T="$(mktemp -d)"; curl -fsSL --retry 3 --max-time 600 -o "$T/p.tgz" "https://github.com/portainer/portainer/releases/download/$VER/portainer-$VER-linux-amd64.tar.gz"
  echo "$SHA  $T/p.tgz" | sha256sum -c --quiet - || { echo "  ✗ checksum mismatch for portainer $VER"; rm -rf "$T"; exit 1; }
  install -d "$DIR"; tar xzf "$T/p.tgz" -C "$DIR" --strip-components=1; rm -rf "$T"
  [ -x "$DIR/portainer" ] || { echo "  ✗ no portainer binary in the $VER release archive"; exit 1; }
  echo "  server: installed portainer $VER -> $DIR (sha256 verified)"
fi
ln -sfn "$DIR" /opt/portainer
install -d -m 700 "$DATA"
# Moving from the docker server of an earlier install: stop it, take its data (admin, environments) once, remove the container.
if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -Fx portainer >/dev/null; then
  docker stop portainer >/dev/null 2>&1 || true
  SRC="$(docker volume inspect portainer_data --format '{{.Mountpoint}}' 2>/dev/null || true)"
  if [ -n "$SRC" ] && [ -z "$(ls -A "$DATA")" ]; then cp -a "$SRC/." "$DATA/"; echo "  server: data copied from the docker volume portainer_data (kept as a rollback copy)"; fi
  docker rm portainer >/dev/null && echo "  server: docker container removed"
fi
cat > /etc/systemd/system/cce-portainer.service <<UNIT
[Unit]
Description=Portainer CE $VER (one-click-installer/lib/portainer.sh) — 127.0.0.1 only, reach it through an SSH tunnel
After=network-online.target docker.service k3s.service
Wants=network-online.target

[Service]
WorkingDirectory=/opt/portainer
# --bind-https must be ":9443": Portainer builds its own Kubernetes-proxy URL as "https://localhost" + this value, so "127.0.0.1:9443"
# became https://localhost127.0.0.1:9443 and every namespace view failed. Network reach is limited here instead, in the kernel:
# only loopback and the k3s pod/service networks (the agent is a ClusterIP) may talk to this process — the internet cannot,
# whatever UFW does. Edge tunnel 8000 stays bound to 127.0.0.1.
ExecStart=/opt/portainer/portainer --data $DATA --assets /opt/portainer --bind-https :9443 --http-disabled --tunnel-addr 127.0.0.1
IPAddressDeny=any
IPAddressAllow=localhost ${K3S_CLUSTER_CIDR:-10.42.0.0/16} ${K3S_SERVICE_CIDR:-10.43.0.0/16}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload; systemctl enable cce-portainer >/dev/null 2>&1; systemctl restart cce-portainer
for _ in $(seq 1 30); do curl -skf "$API/system/status" >/dev/null 2>&1 && break; sleep 2; done
curl -skf "$API/system/status" >/dev/null || { echo "  ✗ Portainer not answering on 127.0.0.1:9443 — see: journalctl -u cce-portainer"; exit 1; }
echo "  server: cce-portainer.service $VER UP on $(ss -tlnp | awk '$4 ~ /:9443$/ {print $4}' | tr '\n' ' ')"

# 3) admin + environments (python: JSON + multipart, and the password never in argv)
PW="$PW" API="$API" AGENT="tcp://$AGENT_IP:9001" K3S_NAME="${ENVCODE}-k3s" python3 - <<'PY'
import json, os, ssl, sys, urllib.request, urllib.error, uuid
API, E = os.environ["API"], os.environ
ctx = ssl._create_unverified_context()          # Portainer's own self-signed cert, on 127.0.0.1
def call(method, path, body=None, token=None, form=None):
    headers, data = {}, None
    if token: headers["Authorization"] = "Bearer " + token
    if form is not None:
        b = uuid.uuid4().hex; parts = []
        for k, v in form.items():
            parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n')
        data = ("".join(parts) + f"--{b}--\r\n").encode(); headers["Content-Type"] = "multipart/form-data; boundary=" + b
    elif body is not None:
        data = json.dumps(body).encode(); headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
            raw = r.read(); return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, None
st, _ = call("POST", "/users/admin/init", {"Username": "admin", "Password": E["PW"]})
print("  admin: initialised" if st == 200 else "  admin: already initialised" if st == 409 else f"  admin: init HTTP {st}")
st, auth = call("POST", "/auth", {"Username": "admin", "Password": E["PW"]})
if st != 200:
    sys.exit("  ✗ cannot log in as admin with PORTAINER_ADMIN_PASSWORD — if the server was initialised by hand, set that password in Infisical /portainer")
T = auth["jwt"]
st, eps = call("GET", "/endpoints", token=T); names = {e["Name"] for e in (eps or [])}
want = [(E["K3S_NAME"], {"Name": E["K3S_NAME"], "EndpointCreationType": "2", "URL": E["AGENT"],
                         "TLS": "true", "TLSSkipVerify": "true", "TLSSkipClientVerify": "true"})]
if os.path.exists("/var/run/docker.sock"):   # a docker environment only where docker exists
    want.insert(0, ("local", {"Name": "local", "EndpointCreationType": "1", "URL": "unix:///var/run/docker.sock"}))
for name, form in want:
    if name in names:
        print(f"  environment {name}: present")
    else:
        st, _ = call("POST", "/endpoints", token=T, form=form)
        print(f"  environment {name}: {'added' if st == 200 else f'add failed HTTP {st}'}")
PY
