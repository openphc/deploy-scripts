#!/usr/bin/env bash
# one-click-installer/lib/beckn/beckn-lib.sh — SOURCE me. Shared by install-beckn.sh and the lib/beckn scripts.
#
# The Beckn add-on puts up to three Beckn network participants on a machine that install.sh has already set up:
#
#   component   namespace                       what it deploys (k8s/beckn/<component>)
#   cce         cce-<envcode> (exists)          cce-beckn-service + CCE's ONIX adapter
#   openhim     BECKN_OPENHIM_NAMESPACE         OpenHIM (MongoDB, Core, console) + the Beckn build of the emitter adaptor + ONIX
#   openmrs     BECKN_OPENMRS_NAMESPACE         OpenMRS O3 + the emitter and receiver adaptors (Beckn builds) + ONIX
#
# A participant is described by BECKN_<P>_* keys in the installer config (P = CCE, OPENHIM, OPENMRS): its public host and
# the subscriber ids / key ids / public keys of its BAP and BPP records in the network registry. The same keys describe a
# participant that runs on ANOTHER machine — CCE's settings name the HIE, the HIE's name CCE, and so on — so they are needed
# for every participant in the flow, hosted here or not. Private keys, passwords and the contract ids are in Infisical /beckn
# (beckn-seed.sh).
#
#   beckn_defaults                 fill every derived / defaulted variable (idempotent)
#   beckn_validate                 print what is missing in the config; non-zero if anything is
#   beckn_component_ns <c>         the namespace of a component
#   beckn_hosted <c>               true if this machine hosts the component
#   beckn_kubectl                  sets KUBECTL

BECKN_ALL_COMPONENTS="cce openhim openmrs"

beckn_kubectl() {
  [ -n "${KUBECTL:-}" ] && return 0
  if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"
  elif command -v k3s >/dev/null 2>&1; then KUBECTL="k3s kubectl"
  else echo "ERROR: no kubectl / k3s found" >&2; return 1; fi
}

beckn_hosted() { case " ${BECKN_COMPONENTS:-} " in *" $1 "*) return 0;; *) return 1;; esac; }

beckn_component_ns() {
  case "$1" in
    cce)     printf 'cce-%s' "${ENVCODE:?ENVCODE not set}";;
    openhim) printf '%s' "${BECKN_OPENHIM_NAMESPACE:-openhim}";;
    openmrs) printf '%s' "${BECKN_OPENMRS_NAMESPACE:-openmrs}";;
    *) echo "ERROR: unknown Beckn component '$1' (one of: $BECKN_ALL_COMPONENTS)" >&2; return 1;;
  esac
}

# name default — set + export only when empty
_beckn_default() { if [ -z "${!1:-}" ]; then export "$1=$2"; else export "$1"; fi; }

beckn_defaults() {
  local p host img reg
  # commas or spaces: "cce,openhim" and "cce openhim" are both accepted
  BECKN_COMPONENTS="$(printf '%s' "${BECKN_COMPONENTS:-$BECKN_ALL_COMPONENTS}" | tr ',' ' ' | tr -s ' ')"; export BECKN_COMPONENTS
  _beckn_default BECKN_OPENHIM_NAMESPACE openhim
  _beckn_default BECKN_OPENMRS_NAMESPACE openmrs
  _beckn_default BECKN_OPENMRS_HOST_DIR /opt/openmrs
  # A participant's two registered addresses follow from its host, unless the registry record says otherwise.
  for p in CCE OPENHIM OPENMRS; do
    host="BECKN_${p}_HOST"
    if [ -n "${!host:-}" ]; then
      _beckn_default "BECKN_${p}_BAP_URI" "https://${!host}/bap/receiver"
      _beckn_default "BECKN_${p}_BPP_URI" "https://${!host}/bpp/receiver"
    fi
  done
  # The start of the @context address inside every message. It only has to be the SAME for all participants: each adapter
  # finds its local copy of the schema by name (ConfigMap onix-schema), so the address itself need not be reachable.
  _beckn_default BECKN_SCHEMA_BASE_URL "https://raw.githubusercontent.com/openphc/cce-beckn-service/main/schema"
  _beckn_default BECKN_SCHEMA_REPO "https://github.com/openphc/cce-beckn-service.git"
  _beckn_default BECKN_SCHEMA_REF demo
  _beckn_default BECKN_CORE_SCHEMA_URL "https://raw.githubusercontent.com/beckn/protocol-specifications-v2/refs/tags/core-v2.0.0-lts/api/v2.0.0/beckn.yaml"
  _beckn_default BECKN_SCHEMA_ALLOWED_DOMAINS "beckn.org,raw.githubusercontent.com,schema.beckn.io"
  _beckn_default BECKN_ONIX_LOG_LEVEL info
  _beckn_default BECKN_REFERRALS_ENABLED false
  # The network this deployment belongs to: <namespace>/<registry> of the network's membership registry. It is sent as
  # context.networkId by every service, and each adapter accepts only subscribers that are members of it (allowedNetworkIDs;
  # BECKN_ALLOWED_NETWORK_IDS, comma-separated, to accept more than one network). Empty = no networkId, no membership check.
  export BECKN_NETWORK_ID="${BECKN_NETWORK_ID:-}" BECKN_OPENHIM_FACILITY_FILTER_IDS="${BECKN_OPENHIM_FACILITY_FILTER_IDS:-}"
  export BECKN_ALLOWED_NETWORK_IDS="${BECKN_ALLOWED_NETWORK_IDS:-$BECKN_NETWORK_ID}"
  # Images. IMAGE_REGISTRY (installer config) replaces the registry/owner, as for the CCE services.
  reg="${IMAGE_REGISTRY:-ghcr.io/openphc}"
  _beckn_default BECKN_CCE_SERVICE_IMAGE      "$reg/cce-beckn-service:${IMAGE_CCE_BECKN_SERVICE:-latest}"
  _beckn_default BECKN_OPENHIM_ADAPTOR_IMAGE  "$reg/openhim-cce-emitter-adaptor:${IMAGE_OPENHIM_BECKN_EMITTER_ADAPTOR:-demo-beckn-latest}"
  _beckn_default BECKN_OPENMRS_EMITTER_IMAGE  "$reg/openmrs-cce-emitter-adaptor:${IMAGE_OPENMRS_CCE_EMITTER_ADAPTOR:-demo-beckn-latest}"
  _beckn_default BECKN_OPENMRS_RECEIVER_IMAGE "$reg/openmrs-cce-receiver-adaptor:${IMAGE_OPENMRS_CCE_RECEIVER_ADAPTOR:-demo-beckn-latest}"
  for img in BECKN_CCE_SERVICE_IMAGE BECKN_OPENHIM_ADAPTOR_IMAGE BECKN_OPENMRS_EMITTER_IMAGE BECKN_OPENMRS_RECEIVER_IMAGE; do
    case "${!img}" in *:sha256:*) export "$img=${!img/:sha256:/@sha256:}";; esac     # IMAGE_*=sha256:… pins a digest
  done
  # IfNotPresent: the cce-beckn-service package on GHCR is private today, so the image is imported into k3s by hand
  # (docs/beckn.md) and must not be pulled again. Set Always once the package can be pulled.
  _beckn_default BECKN_CCE_IMAGE_PULL_POLICY IfNotPresent
  # Spice, the one HMIS peer of OpenMRS (referrals) and a second sender to the HIE. Until its ids are known the OpenMRS
  # receiver still needs SOMETHING to start with: .invalid is a reserved TLD, so nothing can ever be sent there.
  # This function runs more than once per install (install-beckn.sh, then each script): the placeholder set by an earlier
  # call must not count as a configured Spice, or the HIE would list bap.spice.invalid among the senders it accepts.
  case "${BECKN_SPICE_BAP_ID:-}" in
    ""|*.invalid) export BECKN_SPICE_CONFIGURED=false BECKN_SPICE_BAP_ID="bap.spice.invalid" BECKN_SPICE_BAP_URI="https://spice.invalid/bap/receiver";;
    *)            export BECKN_SPICE_CONFIGURED=true;;
  esac
  export BECKN_SPICE_BAP_URI="${BECKN_SPICE_BAP_URI:-}" BECKN_SPICE_BPP_ID="${BECKN_SPICE_BPP_ID:-}" \
         BECKN_SPICE_BPP_URI="${BECKN_SPICE_BPP_URI:-}" BECKN_SPICE_FACILITY_CODES="${BECKN_SPICE_FACILITY_CODES:-}"
}

# Which config keys the hosted components need. Prints every problem; non-zero if any.
beckn_validate() {
  local bad=0 c p k need=""
  for c in $BECKN_COMPONENTS; do
    case " $BECKN_ALL_COMPONENTS " in *" $c "*) ;; *) echo "CONFIG: BECKN_COMPONENTS: unknown component '$c' (one of: $BECKN_ALL_COMPONENTS)" >&2; bad=1;; esac
  done
  for k in BECKN_REGISTRY_URL BECKN_REGISTRY_NAME; do
    [ -n "${!k:-}" ] || { echo "CONFIG: $k is required (the Beckn network registry every adapter looks subscribers up in)" >&2; bad=1; }
  done
  # own identity: everything. A participant hosted elsewhere: only the ids and addresses its neighbours put in messages.
  for c in $BECKN_ALL_COMPONENTS; do
    p="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')"
    if beckn_hosted "$c"; then
      for k in HOST BAP_ID BAP_KEY_ID BPP_ID BPP_KEY_ID; do
        k="BECKN_${p}_${k}"; [ -n "${!k:-}" ] || { echo "CONFIG: $k is required ($c is in BECKN_COMPONENTS)" >&2; bad=1; }
      done
    fi
  done
  beckn_hosted cce     && need="$need BECKN_OPENHIM_BAP_ID BECKN_OPENHIM_BAP_URI"
  beckn_hosted openhim && need="$need BECKN_CCE_BPP_ID BECKN_CCE_BPP_URI BECKN_OPENMRS_BAP_ID BECKN_OPENMRS_BAP_URI"
  beckn_hosted openmrs && need="$need BECKN_OPENHIM_BPP_ID BECKN_OPENHIM_BPP_URI"
  for k in $need; do
    [ -n "${!k:-}" ] || { echo "CONFIG: $k is required (a neighbour of a component in BECKN_COMPONENTS; set it, or that participant's BECKN_*_HOST)" >&2; bad=1; }
  done
  case "${BECKN_REFERRALS_ENABLED:-false}" in true|false) ;; *) echo "CONFIG: BECKN_REFERRALS_ENABLED must be true or false" >&2; bad=1;; esac
  if [ "${BECKN_REFERRALS_ENABLED:-false}" = true ] && beckn_hosted openmrs; then
    for k in BECKN_SPICE_BAP_URI BECKN_SPICE_BPP_ID BECKN_SPICE_BPP_URI BECKN_SPICE_FACILITY_CODES; do
      [ -n "${!k:-}" ] || { echo "CONFIG: $k is required with BECKN_REFERRALS_ENABLED=true" >&2; bad=1; }
    done
    [ "${BECKN_SPICE_CONFIGURED:-false}" = true ] || { echo "CONFIG: BECKN_SPICE_BAP_ID is required with BECKN_REFERRALS_ENABLED=true" >&2; bad=1; }
  fi
  case "${BECKN_CCE_IMAGE_PULL_POLICY:-IfNotPresent}" in Always|IfNotPresent|Never) ;; *) echo "CONFIG: BECKN_CCE_IMAGE_PULL_POLICY must be Always, IfNotPresent or Never" >&2; bad=1;; esac
  return $bad
}
