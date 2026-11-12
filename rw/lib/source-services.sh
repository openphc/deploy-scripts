#!/usr/bin/env bash
# rw/lib/source-services.sh — SOURCE me. The repositories rw/one-click-install.sh builds from source, and how each one is built.
#
# Each repo's REPO/BRANCH come from the config as SRC_<KEY>_REPO / SRC_<KEY>_BRANCH, KEY = name upper-cased, '-' -> '_'.
# Recipes mirror each repo's own CI workflow (.github/workflows/BuildAndPush*.yml), so the image is the one RW PROD runs from GHCR:
#   lib        shared Gradle library, no image (the 2.0 services include it as ../cce-common-util)
#   pipeline   SQL + connector config, no image (deployed by the installer's data-pipeline step)
#   boot       ./gradlew bootBuildImage (Paketo buildpacks)
#   boot-util  bootBuildImage of a service that includeBuild's ../cce-common-util
#   docker-ws  docker build -f <repo>/Dockerfile <workspace> — the Dockerfile COPYs cce-common-util/ too, so the context is the
#              directory holding both repos (protocol + matcher; their CI uses the Dockerfile, not buildpacks)
#   docker-ui  docker build with the INSIGHTS_UI_VITE_* build args (Vite inlines them into the bundle)
# The third field is extra Gradle arguments (insights-service skips jOOQ generation in CI: it needs a live database).
RW_SOURCES=(
  "cce-common-util|lib|"
  "cce-data-pipeline|pipeline|"
  "cce-collector-service|boot-util|"
  "cce-protocol-service|docker-ws|"
  "cce-matcher-service|docker-ws|"
  "cce-step-sla-service|boot-util|"
  "cce-intelligence-service|boot|"
  "cce-insights-service|boot|-x generateJooq"
  "cce-insights-ui|docker-ui|"
  "gateway-service|boot|"
  "openhim-cce-emitter-adaptor|boot|"
)

rw_src_key() { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }

# Config keys this layer adds on top of one-click-installer/lib/load-config.sh's list.
rw_config_keys() {
  local e name
  printf ' GIT_TOKEN_FILE SOURCE_DIR LOCAL_IMAGE_REGISTRY FORCE_REBUILD HPA_REPLICAS CPU_LIMIT_OVERRIDES'
  printf ' INSIGHTS_UI_VITE_AUTH_ENABLED INSIGHTS_UI_VITE_KEYCLOAK_URL INSIGHTS_UI_VITE_KEYCLOAK_REALM'
  printf ' INSIGHTS_UI_VITE_KEYCLOAK_CLIENT_ID INSIGHTS_UI_VITE_ROUTER_BASE INSIGHTS_UI_VITE_TIMEZONE'
  for e in "${RW_SOURCES[@]}"; do name="${e%%|*}"; printf ' SRC_%s_REPO SRC_%s_BRANCH' "$(rw_src_key "$name")" "$(rw_src_key "$name")"; done
  printf ' '
}
