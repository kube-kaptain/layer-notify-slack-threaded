#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# notify-slack-threaded-contribute.bash
#
# prePackagePrepare hook from layer-notify-slack-threaded. Adds the Slack
# threaded notify plugin to an environment's deploy image, with no files
# written to the consuming repo's src/:
#
#   1. Pulls the plugin's released image and extracts its /scripts and /fields
#      with the build tooling's extract-oci-image.
#   2. Contributes the scripts to <output>/run-package/bin/, which the build
#      copies into the deploy image's /kd/bin.
#   3. Contributes the entries /fields lists to
#      <output>/run-image-deploy-manifests/configmap/ and secret.template/,
#      which the build merges into the generated ConfigMap and Secret.
#   4. Contributes each optional entry's token default, the plugin's own
#      default from /fields/defaults/, to <output>/run-image-deploy-manifests/
#      defaults/, so only the required tokens need supplying.
#
# /fields has one file per entry, named for the entry, under configmap/ or
# secret.template/ and then:
#
#   required/  written as a token reference, the token must be supplied
#   optional/  written as a token reference, the token defaulting to the
#              plugin's default, deploy/ variant where it varies
#   context/   written as the literal deploy
#
# A required or optional file holds the entry's canonical token name, such as
# NOTIFY_SLACK_THREADED/CHANNEL_ID. The deploy manifests and their token
# defaults are supplied to the run-platform build alongside other
# environments', so the token is prefixed with this project's name, as the
# environment passphrase token is, and rendered in this project's
# TOKEN_DELIMITER_STYLE and TOKEN_NAME_STYLE. For run-stage with the default
# styles that is ${RunStage/NotifySlackThreaded/ChannelId}.
#
# Consumer config, all optional, under user-data.notify-slack-threaded in
# kaptainpm/final/KaptainPM.yaml:
#
#   image          Full plugin image reference, for a mirror, fork or other
#                  version (default below)
#
# Inputs (environment, set by the build for every hook):
#   PROJECT_NAME            - This environment's project name, prefixes tokens
#   BUILD_SCRIPTS_REPO_ROOT - Build scripts repo root
#   OUTPUT_SUB_PATH         - Build output dir
#   IMAGE_BUILD_COMMAND     - Container runtime for extract-oci-image
#   TOKEN_DELIMITER_STYLE   - Token delimiter style of the consuming project
#   TOKEN_NAME_STYLE        - Token name style of the consuming project
set -euo pipefail

DEFAULT_IMAGE="ghcr.io/kube-kaptain/notify/notify-slack-threaded:1.2@sha256:e4ac0794dadae7413425bd70a155a44530dbe4f6124514713f01bf8899b7b8df"
USER_DATA_KEY="notify-slack-threaded"

BUILD_SCRIPTS_DIR="${BUILD_SCRIPTS_REPO_ROOT:?BUILD_SCRIPTS_REPO_ROOT is required}/src/scripts"
# shellcheck source=/dev/null
source "${BUILD_SCRIPTS_DIR}/defaults/platform.bash"
# shellcheck source=/dev/null
source "${BUILD_SCRIPTS_DIR}/lib/log.bash"
# shellcheck source=/dev/null
source "${BUILD_SCRIPTS_DIR}/defaults/output-sub-path.bash"
# shellcheck source=/dev/null
source "${BUILD_SCRIPTS_DIR}/lib/token-format.bash"
# shellcheck source=/dev/null
source "${BUILD_SCRIPTS_DIR}/lib/run-image-deploy-manifests-paths.bash"

# Where kubernetes-run-package picks up contributed /kd/bin files
CONTRIBUTED_BIN_DIR="${OUTPUT_SUB_PATH}/run-package/bin"
WORK_DIR="${OUTPUT_SUB_PATH}/${USER_DATA_KEY}"
FIELDS_DIR="${WORK_DIR}/extract/fields"
FINAL_KPM="kaptainpm/final/KaptainPM.yaml"
# The canonical project prefix, run-stage becomes RUN_STAGE
PROJECT_TOKEN_PREFIX=$(printf '%s' "${PROJECT_NAME:?PROJECT_NAME is required}" | tr '[:lower:]-' '[:upper:]_')

# Print a user-data value, empty if unset
read_user_data() {
  yq ".user-data.${USER_DATA_KEY}.$1 // \"\"" "${FINAL_KPM}"
}

# Print the contribution dir for a fields manifest dir
contribution_dir() {
  case "$1" in
    configmap) printf '%s' "${RUN_IMAGE_DEPLOY_MANIFESTS_CONFIGMAP}" ;;
    secret.template) printf '%s' "${RUN_IMAGE_DEPLOY_MANIFESTS_SECRET_TEMPLATE}" ;;
  esac
}

# Write one entry, failing rather than replacing one something else wrote
write_entry() {
  local dir="$1"
  local key="$2"
  local value="$3"
  mkdir -p "${dir}"
  if [[ -e "${dir}/${key}" ]]; then
    log_error "${dir}/${key} was already contributed by something else"
    exit 1
  fi
  printf '%s' "${value}" > "${dir}/${key}"
  log "  ${key}: ${value}"
}

# Write a token default, failing rather than replacing one something else
# wrote. The environment's own defaults and config still win over it.
write_token_default() {
  local canonical="$1"
  local value="$2"
  local file
  file="${RUN_IMAGE_DEPLOY_MANIFESTS_DEFAULTS}/$(convert_token_name "${TOKEN_NAME_STYLE}" "${PROJECT_TOKEN_PREFIX}/${canonical}" | tr -d '\n')"
  mkdir -p "$(dirname "${file}")"
  if [[ -e "${file}" ]]; then
    log_error "${file} was already contributed by something else"
    exit 1
  fi
  printf '%s' "${value}" > "${file}"
  log "  default ${file#"${RUN_IMAGE_DEPLOY_MANIFESTS_DEFAULTS}/"}: ${value}"
}

# Print the plugin's default for an optional entry, the deploy variant where it
# varies between deploy and build. Fails if the plugin ships none.
field_default() {
  local key="$1"
  local file
  for file in "${FIELDS_DIR}/defaults/${key}" "${FIELDS_DIR}/defaults/deploy/${key}"; do
    if [[ -f "${file}" ]]; then
      tr -d '\r\n' < "${file}"
      return 0
    fi
  done
  log_error "${image} /fields has no default for optional entry ${key}"
  exit 1
}

# Write the token reference for a field file, its canonical name rendered in
# this project's styles
write_token_entry() {
  local manifest="$1"
  local field_file="$2"
  local token
  token=$(format_canonical_token "${TOKEN_DELIMITER_STYLE}" "${TOKEN_NAME_STYLE}" "${PROJECT_TOKEN_PREFIX}/$(tr -d '\r\n' < "${field_file}")" | tr -d '\n')
  write_entry "$(contribution_dir "${manifest}")" "${field_file##*/}" "${token}"
}

validate_token_styles

log "=== ${USER_DATA_KEY}: contribute plugin to the deploy image ==="

image=$(read_user_data image)
image="${image:-${DEFAULT_IMAGE}}"

rm -rf "${WORK_DIR}"
"${BUILD_SCRIPTS_DIR}/util/extract-oci-image" "${image}" "${WORK_DIR}/extract" /scripts /fields
for part in scripts fields; do
  if [[ ! -d "${WORK_DIR}/extract/${part}" ]]; then
    log_error "${image} holds no /${part}"
    exit 1
  fi
done

# Scripts, modes kept so they stay executable, never replacing another's
mkdir -p "${CONTRIBUTED_BIN_DIR}"
bin_dir_absolute=$(cd "${CONTRIBUTED_BIN_DIR}" && pwd)
collisions=$(cd "${WORK_DIR}/extract/scripts" && find . -type f | while IFS= read -r file; do
  if [[ -e "${bin_dir_absolute}/${file}" ]]; then
    echo "${file#./}"
  fi
done)
if [[ -n "${collisions}" ]]; then
  log_error "Files in ${image} were already contributed to ${CONTRIBUTED_BIN_DIR} by something else:"
  while IFS= read -r file; do
    log_error "  ${file}"
  done <<< "${collisions}"
  exit 1
fi
cp -Rp "${WORK_DIR}/extract/scripts/." "${CONTRIBUTED_BIN_DIR}/"
log "Contributed $(find "${WORK_DIR}/extract/scripts" -type f | wc -l | tr -d ' ') file(s) from ${image} to ${CONTRIBUTED_BIN_DIR}"

log "Entries from ${image} /fields:"
shopt -s nullglob
for manifest in configmap secret.template; do
  for field_file in "${FIELDS_DIR}/${manifest}/context/"*; do
    if [[ " $(tr -d '\r\n' < "${field_file}") " != *" deploy "* ]]; then
      log_error "${field_file##*/} does not accept deploy as its context"
      exit 1
    fi
    write_entry "$(contribution_dir "${manifest}")" "${field_file##*/}" "deploy"
  done
  for field_file in "${FIELDS_DIR}/${manifest}/required/"*; do
    write_token_entry "${manifest}" "${field_file}"
  done
  for field_file in "${FIELDS_DIR}/${manifest}/optional/"*; do
    write_token_entry "${manifest}" "${field_file}"
    write_token_default "$(tr -d '\r\n' < "${field_file}")" "$(field_default "${field_file##*/}")"
  done
done
shopt -u nullglob
