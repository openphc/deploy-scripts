#!/usr/bin/env bash
# one-click-installer/lib/beckn/beckn-lib.sh — SOURCE me. Shared by install-beckn.sh and the lib/beckn scripts.
#
# The Beckn add-on puts up to three network participants on a machine that install.sh has already set up. The CCE flows
# use Sygnal (the CCE profile): sygnal/event/report OpenMRS -> HIE -> CCE, and sygnal/signal/emit CCE -> OpenMRS, each
# participant through its Sygnal adapter (onix-sygnal). The Spice <-> OpenMRS health referrals stay on standard Beckn
# (select / init / confirm / status / update), through OpenMRS's Beckn adapter pair (onix-bap / onix-bpp) as before.
#
#   component   namespace                       what it deploys (k8s/beckn/<component>)
#   cce         cce-<envcode> (exists)          cce-beckn-service + CCE's ONIX adapter
#   openhim     BECKN_OPENHIM_NAMESPACE         OpenHIM (MongoDB, Core, console) + the Beckn build of the emitter adaptor + ONIX
#   openmrs     BECKN_OPENMRS_NAMESPACE         OpenMRS O3 + the emitter and receiver adaptors (Beckn builds) + ONIX
#
# For the CCE flows a participant has ONE identity (one subscriber record in the network registry) and one Sygnal adapter.
# OpenMRS keeps its BAP and BPP records for the referral pair too. A participant is described by BECKN_<P>_* keys in the installer config (P = CCE, OPENHIM, OPENMRS): its public host, its subscriber id and key id, and
# its public keys. The same keys describe a participant that runs on ANOTHER machine — CCE's settings name OpenMRS, the HIE's
# name CCE, and so on — so they are needed for every participant in the flow, hosted here or not. Private keys and
# passwords are in Infisical /beckn (beckn-seed.sh).
#
# Identity of a participant (beckn_defaults): BECKN_<P>_ID and BECKN_<P>_KEY_ID. Unset, they are taken from the record the
# participant used before the Sygnal switch, so an older config keeps working:
#   CCE      BECKN_CCE_BPP_ID / BECKN_CCE_BPP_KEY_ID          (CCE was a provider)
#   OPENHIM  BECKN_OPENHIM_BAP_ID / BECKN_OPENHIM_BAP_KEY_ID  (the HIE sends to CCE)
#   OPENMRS  BECKN_OPENMRS_BAP_ID / BECKN_OPENMRS_BAP_KEY_ID  (OpenMRS sends to the HIE)
# Keys follow the same rule (beckn-deploy.sh): BECKN_<P>_<ROLE>_<KIND>_KEY, then BECKN_<P>_<KIND>_KEY, then the shared
# BECKN_<KIND>_KEY, where ROLE is the one above. BECKN_<P>_URI (the public Sygnal address, https://<host>/sygnal/receiver) is
# what peers put in context.receiverUri (delivery never uses the registry record's url). OpenMRS's referral pair keeps
# BECKN_OPENMRS_BAP_* / BECKN_OPENMRS_BPP_* (addresses https://<host>/bap/receiver and /bpp/receiver).
#
#   beckn_defaults                 fill every derived / defaulted variable (idempotent)
#   beckn_validate                 print what is missing in the config; non-zero if anything is
#   beckn_component_ns <c>         the namespace of a component
#   beckn_hosted <c>               true if this machine hosts the component
#   beckn_role <P>                 BAP or BPP: the registry record a participant used before the Sygnal switch
#   beckn_kubectl                  sets KUBECTL
#   beckn_profile_hint <schema>    what to do when the CCE profile is not in a schema folder (for an error message)
#   beckn_schema_set <schema> <setting> <list>   the files of the listed <Type>/<version> schema folders; fails if one is missing

BECKN_ALL_COMPONENTS="cce openhim openmrs"

# The CCE profile of Sygnal this add-on deploys, as a path inside cce-beckn-service's schema/ folder. The version folder is
# part of the contract (a version in use never changes; a change gets a new folder) and must be the one the four images
# were built for:
#   v3.0  the payloads are Sygnal's own types, opened and extended in CCE's copy of the schema (this profile; Sygnal's
#         published schema is not changed): sygnal/event/report carries one sygnal:CoordinationEvent with the fields of a
#         clinical event on it (patientId, fhirVersion, resource, …), sygnal/signal/emit a sygnal:Signal with the fields
#         of a care alert on it. No bag, no cce: type, and no "@context" on these objects — so the profile is ALL a
#         Sygnal adapter needs: it holds no payload schemas.
#         (v1.0 kept the CCE data in the eventAttributes / signalAttributes bags of the Sygnal types; v2.0 used
#         cce:CceClinicalEvent / cce:CceCareAlert as the payloads. Neither is deployed any more.)
# This is the one place that names it; BECKN_SYGNAL_PROFILE (a full file path) names another profile file.
# OpenMRS's Beckn referral pair does hold schemas; its version folders are a setting with a default,
# BECKN_REFERRAL_SCHEMAS (beckn_defaults).
BECKN_SYGNAL_PROFILE_REL="sygnal-profile/v3.0/cce-sygnal-apis.yaml"

# What to do when $1 (a schema folder) has no profile at BECKN_SYGNAL_PROFILE_REL: says which versions it does have.
beckn_profile_hint() {
  local found
  found="$(find "$1/sygnal-profile" -mindepth 2 -maxdepth 2 -name cce-sygnal-apis.yaml 2>/dev/null | sed "s#^$1/##" | sort | tr '\n' ' ')"
  echo "       This add-on deploys $BECKN_SYGNAL_PROFILE_REL (payloads: sygnal:CoordinationEvent / sygnal:Signal, extended in CCE's copy)."
  if [ -n "$found" ]; then
    echo "       $1 has: ${found% } — another version of the contract. Use a cce-beckn-service ref"
    echo "       or checkout that has the version above: BECKN_SCHEMA_REF=<branch or tag>, or BECKN_SCHEMA_DIR=<its schema/ folder>."
  else
    echo "       Use a cce-beckn-service ref that has schema/sygnal-profile/ (BECKN_SCHEMA_REF), a copy of its schema/"
    echo "       folder (BECKN_SCHEMA_DIR), or name the profile file with BECKN_SYGNAL_PROFILE."
  fi
}

# beckn_schema_set <schema dir> <setting name> <"Type/version …">: print the files of the listed version folders, one per
# line. Used for the schema set of OpenMRS's referral pair (BECKN_REFERRAL_SCHEMAS). An adapter finds a local schema by
# its TYPE name and ignores the version folder, so a set holds one version of a type, named explicitly — never "whatever
# the folder has". Fails (message on stderr) when an entry is not <Type>/<version>, a type is listed twice, or a folder
# has no attributes.yaml.
beckn_schema_set() {
  local dir="$1" name="$2" e t seen=" "
  [ -n "${3// /}" ] || { echo "ERROR: $name is empty (expected <Type>/<version> folders of $dir, e.g. CceClinicalEvent/v1.0)" >&2; return 1; }
  for e in $3; do
    case "$e" in */*/*|/*|*/|*..*) echo "ERROR: $name: '$e' is not <Type>/<version>" >&2; return 1;; */*) ;; *) echo "ERROR: $name: '$e' is not <Type>/<version>" >&2; return 1;; esac
    t="${e%%/*}"
    case "$seen" in *" $t "*) echo "ERROR: $name lists schema type $t twice — an adapter holds one version of a type" >&2; return 1;; esac
    seen="$seen$t "
    [ -r "$dir/$e/attributes.yaml" ] || { echo "ERROR: $name: no $e/attributes.yaml in $dir (BECKN_SCHEMA_DIR, or BECKN_SCHEMA_REPO at BECKN_SCHEMA_REF)" >&2; return 1; }
    find "$dir/$e" -mindepth 1 -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.jsonld' -o -name '*.json' \) | sort
  done
}

beckn_kubectl() {
  [ -n "${KUBECTL:-}" ] && return 0
  if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"
  elif command -v k3s >/dev/null 2>&1; then KUBECTL="k3s kubectl"
  else echo "ERROR: no kubectl / k3s found" >&2; return 1; fi
}

beckn_role() { case "$1" in CCE) printf BPP;; *) printf BAP;; esac; }

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
  local p host img reg role v
  # commas or spaces: "cce,openhim" and "cce openhim" are both accepted
  BECKN_COMPONENTS="$(printf '%s' "${BECKN_COMPONENTS:-$BECKN_ALL_COMPONENTS}" | tr ',' ' ' | tr -s ' ')"; export BECKN_COMPONENTS
  _beckn_default BECKN_OPENHIM_NAMESPACE openhim
  _beckn_default BECKN_OPENMRS_NAMESPACE openmrs
  _beckn_default BECKN_OPENMRS_HOST_DIR /opt/openmrs
  # One Sygnal identity per participant, and its public Sygnal address (context.receiverUri of what its peers send it).
  for p in CCE OPENHIM OPENMRS; do
    role="$(beckn_role "$p")"
    v="BECKN_${p}_${role}_ID";     _beckn_default "BECKN_${p}_ID" "${!v:-}"
    v="BECKN_${p}_${role}_KEY_ID"; _beckn_default "BECKN_${p}_KEY_ID" "${!v:-}"
    host="BECKN_${p}_HOST"
    if [ -n "${!host:-}" ]; then _beckn_default "BECKN_${p}_URI" "https://${!host}/sygnal/receiver"; else _beckn_default "BECKN_${p}_URI" ""; fi
  done
  # OpenMRS's Beckn referral pair: its two registered addresses follow from its host, unless the registry records say otherwise.
  if [ -n "${BECKN_OPENMRS_HOST:-}" ]; then
    _beckn_default BECKN_OPENMRS_BAP_URI "https://${BECKN_OPENMRS_HOST}/bap/receiver"
    _beckn_default BECKN_OPENMRS_BPP_URI "https://${BECKN_OPENMRS_HOST}/bpp/receiver"
  fi
  # The DeDi registry every adapter looks senders up in (onix's dediregistry plugin: <url>/lookup/<subscriber id>/…/<key id>).
  # BECKN_REGISTRY_NAME: the registry name OpenMRS's referral pair (onix 1.6.1) puts in that lookup; the Sygnal adapters
  # (onix 1.9.4) search every registry and do not use it.
  _beckn_default BECKN_REGISTRY_URL "https://fabric.nfh.global/registry/dedi"
  # The start of the @context address of CCE's schemas (CceClinicalEvent, CceCareAlert), a setting of the three services.
  # It only has to be the SAME for all participants: an adapter that checks such an object (OpenMRS's referral pair) finds
  # its local copy of the schema by name (ConfigMap onix-schema), so the address itself need not be reachable. The Sygnal
  # messages (profile v3.0) carry no @context.
  _beckn_default BECKN_SCHEMA_BASE_URL "https://raw.githubusercontent.com/openphc/cce-beckn-service/main/schema"
  _beckn_default BECKN_SCHEMA_REPO "https://github.com/openphc/cce-beckn-service.git"
  _beckn_default BECKN_SCHEMA_REF demo
  # The schema version folders (under the schema folder) OpenMRS's Beckn referral pair holds a copy of (onix-bap /
  # onix-bpp; ConfigMap onix-schema, with the Health* pack), unchanged: the referral legs carry the CceClinicalEvent v1.0
  # box in performanceAttributes. Named explicitly, one version per type: an adapter finds a schema by its type name.
  # The Sygnal adapters (onix-sygnal) hold no schema set: the CCE profile is all they check a message against.
  _beckn_default BECKN_REFERRAL_SCHEMAS "CceClinicalEvent/v1.0 CceCareAlert/v1.0"
  # The domains the referral pair may fetch an unknown schema from (the Sygnal adapters fetch none).
  _beckn_default BECKN_SCHEMA_ALLOWED_DOMAINS "beckn.org,raw.githubusercontent.com,schema.beckn.io"
  # The Beckn core spec OpenMRS's referral pair checks messages against (the Sygnal adapters use the CCE profile instead).
  _beckn_default BECKN_CORE_SCHEMA_URL "https://raw.githubusercontent.com/beckn/protocol-specifications-v2/refs/tags/core-v2.0.0-lts/api/v2.0.0/beckn.yaml"
  _beckn_default BECKN_ONIX_LOG_LEVEL info
  _beckn_default BECKN_REFERRALS_ENABLED false
  # Health referrals from Spice (select / init / confirm): the OpenMRS identifier type for each patient health id system,
  # as SYSTEM=type pairs separated by ";". Default NID=national-id: Spice sends the patient's national id as system NID,
  # and stored as national-id it is the id the OpenMRS emitter puts on events to CCE (the patient id CCE knows from
  # Spice's own events). A system without a pair is used as the type name (OpenMRS creates it).
  _beckn_default BECKN_HEALTH_ID_TYPES "NID=national-id"
  # The HIE adaptor's clinical-data redaction (REDACTION_ENABLED). Off by default: the protocol triggers read free text
  # that redaction removes (the RMNCH referral steps read ServiceRequest.patientInstruction / orderDetail and the
  # Encounter source-referral-order extension), so full payloads, patient data included, go to CCE. true removes
  # clinical content (values, free text, Encounter extensions, ...) before an event goes to CCE.
  _beckn_default BECKN_OPENHIM_REDACTION_ENABLED false
  # The Sygnal network the CCE flows belong to: <namespace>/<registry> of its membership registry. Every service sends it
  # as context.networkId of a Sygnal message — the registry refuses a sender that is not a member of it — and each Sygnal
  # adapter accepts only subscribers that are members of it (allowedNetworkIDs; BECKN_SYGNAL_ALLOWED_NETWORK_IDS,
  # comma-separated, to accept more than one network). Default: the network of the CCE demo; all three demo ids are members.
  _beckn_default BECKN_SYGNAL_NETWORK_ID "sygnal.nextsteps.mdtlabs.org/sygnal_demo_network_registry"
  export BECKN_SYGNAL_ALLOWED_NETWORK_IDS="${BECKN_SYGNAL_ALLOWED_NETWORK_IDS:-$BECKN_SYGNAL_NETWORK_ID}"
  # The network of the Spice <-> OpenMRS referrals (standard Beckn, unchanged): context.networkId of the referral messages
  # and allowedNetworkIDs of OpenMRS's onix-bap / onix-bpp (BECKN_ALLOWED_NETWORK_IDS for more than one). Empty = no
  # networkId, no membership check.
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
  # Spice, an external HMIS, in two roles:
  #  - Sygnal (CCE flows): a sender of events to the HIE (a subscriber of the HIE adaptor) and a recipient of CCE's care
  #    alerts (an HMIS of cce-beckn-service). One id, BECKN_SPICE_ID (BECKN_SPICE_BAP_ID when unset), and, for the alerts,
  #    its Sygnal address BECKN_SPICE_URI. BECKN_SPICE_CONFIGURED=true once the id is set.
  #  - standard Beckn (referrals with OpenMRS): BECKN_SPICE_BAP_ID / _BAP_URI / _BPP_ID / _BPP_URI / _FACILITY_CODES.
  _beckn_default BECKN_SPICE_ID "${BECKN_SPICE_BAP_ID:-}"
  case "$BECKN_SPICE_ID" in
    ""|*.invalid) export BECKN_SPICE_CONFIGURED=false BECKN_SPICE_ID="";;
    *)            export BECKN_SPICE_CONFIGURED=true;;
  esac
  export BECKN_SPICE_URI="${BECKN_SPICE_URI:-}"
  # Until Spice's BAP id is known the OpenMRS receiver still needs SOMETHING to start with: .invalid is a reserved TLD, so
  # nothing can ever be sent there. This function runs more than once per install (install-beckn.sh, then each script):
  # the placeholder set by an earlier call must not count as a configured Spice (the case above).
  case "${BECKN_SPICE_BAP_ID:-}" in
    ""|*.invalid) export BECKN_SPICE_BAP_ID="bap.spice.invalid" BECKN_SPICE_BAP_URI="https://spice.invalid/bap/receiver" BECKN_SPICE_REFERRALS_CONFIGURED=false;;
    *)            export BECKN_SPICE_REFERRALS_CONFIGURED=true;;
  esac
  export BECKN_SPICE_BAP_URI="${BECKN_SPICE_BAP_URI:-}" BECKN_SPICE_BPP_ID="${BECKN_SPICE_BPP_ID:-}" \
         BECKN_SPICE_BPP_URI="${BECKN_SPICE_BPP_URI:-}" BECKN_SPICE_FACILITY_CODES="${BECKN_SPICE_FACILITY_CODES:-}"
}

# Which config keys the hosted components need. Prints every problem; non-zero if any.
beckn_validate() {
  local bad=0 c p k need="" role
  for c in $BECKN_COMPONENTS; do
    case " $BECKN_ALL_COMPONENTS " in *" $c "*) ;; *) echo "CONFIG: BECKN_COMPONENTS: unknown component '$c' (one of: $BECKN_ALL_COMPONENTS)" >&2; bad=1;; esac
  done
  [ -n "${BECKN_REGISTRY_URL:-}" ] || { echo "CONFIG: BECKN_REGISTRY_URL is required (the DeDi registry every adapter looks senders up in)" >&2; bad=1; }
  [ -n "${BECKN_SYGNAL_NETWORK_ID:-}" ] || { echo "CONFIG: BECKN_SYGNAL_NETWORK_ID is required (context.networkId of Sygnal messages; the registry refuses senders that are not members of it)" >&2; bad=1; }
  # own identity: everything. A participant hosted elsewhere: only the id and address its neighbours put in messages.
  for c in $BECKN_ALL_COMPONENTS; do
    p="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')"; role="$(beckn_role "$p")"
    if beckn_hosted "$c"; then
      k="BECKN_${p}_HOST"; [ -n "${!k:-}" ] || { echo "CONFIG: $k is required ($c is in BECKN_COMPONENTS)" >&2; bad=1; }
      for k in ID KEY_ID; do
        k="BECKN_${p}_${k}"; [ -n "${!k:-}" ] || { echo "CONFIG: $k is required ($c is in BECKN_COMPONENTS; an older config's ${k/_${p}_/_${p}_${role}_} is used when it is unset)" >&2; bad=1; }
      done
    fi
  done
  # OpenMRS's Beckn referral pair: its two records, and the registry name the 1.6.1 adapter's lookup needs.
  if beckn_hosted openmrs; then
    for k in BECKN_OPENMRS_BAP_ID BECKN_OPENMRS_BAP_KEY_ID BECKN_OPENMRS_BPP_ID BECKN_OPENMRS_BPP_KEY_ID BECKN_REGISTRY_NAME; do
      [ -n "${!k:-}" ] || { echo "CONFIG: $k is required (openmrs is in BECKN_COMPONENTS: its Beckn adapter pair for the Spice referrals)" >&2; bad=1; }
    done
  fi
  beckn_hosted openhim && need="$need BECKN_CCE_ID BECKN_CCE_URI BECKN_OPENMRS_ID"
  beckn_hosted openmrs && need="$need BECKN_OPENHIM_ID BECKN_OPENHIM_URI BECKN_CCE_ID"
  for k in $need; do
    [ -n "${!k:-}" ] || { echo "CONFIG: $k is required (a neighbour of a component in BECKN_COMPONENTS; for an address, set it or that participant's BECKN_*_HOST)" >&2; bad=1; }
  done
  if beckn_hosted cce && [ "${BECKN_SPICE_CONFIGURED:-false}" = true ] && [ -z "${BECKN_SPICE_URI:-}" ]; then
    echo "WARNING: BECKN_SPICE_ID is set but BECKN_SPICE_URI is not: CCE sends Spice no care alerts until it is (Spice's https://<host>/sygnal/receiver)" >&2
  fi
  case "${BECKN_REFERRALS_ENABLED:-false}" in true|false) ;; *) echo "CONFIG: BECKN_REFERRALS_ENABLED must be true or false" >&2; bad=1;; esac
  if [ "${BECKN_REFERRALS_ENABLED:-false}" = true ] && beckn_hosted openmrs; then
    for k in BECKN_SPICE_BAP_URI BECKN_SPICE_BPP_ID BECKN_SPICE_BPP_URI BECKN_SPICE_FACILITY_CODES; do
      [ -n "${!k:-}" ] || { echo "CONFIG: $k is required with BECKN_REFERRALS_ENABLED=true" >&2; bad=1; }
    done
    [ "${BECKN_SPICE_REFERRALS_CONFIGURED:-false}" = true ] || { echo "CONFIG: BECKN_SPICE_BAP_ID is required with BECKN_REFERRALS_ENABLED=true" >&2; bad=1; }
  fi
  case "${BECKN_OPENHIM_REDACTION_ENABLED:-false}" in true|false) ;; *) echo "CONFIG: BECKN_OPENHIM_REDACTION_ENABLED must be true or false" >&2; bad=1;; esac
  case "${BECKN_CCE_IMAGE_PULL_POLICY:-IfNotPresent}" in Always|IfNotPresent|Never) ;; *) echo "CONFIG: BECKN_CCE_IMAGE_PULL_POLICY must be Always, IfNotPresent or Never" >&2; bad=1;; esac
  return $bad
}
