#!/usr/bin/env bash
# Shared helpers for the Kiro <-> OpenShift Dev Spaces scripts.
# Source this; do not execute it directly.

set -euo pipefail

# --- output -----------------------------------------------------------------

if [[ -t 2 ]]; then
  _red=$'\033[31m'; _yellow=$'\033[33m'; _green=$'\033[32m'; _dim=$'\033[2m'; _off=$'\033[0m'
else
  _red=''; _yellow=''; _green=''; _dim=''; _off=''
fi

info() { printf '%s==>%s %s\n' "$_dim" "$_off" "$*" >&2; }
ok()   { printf '%s ok %s %s\n' "$_green" "$_off" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$_yellow" "$_off" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$_red" "$_off" "$*" >&2; exit 1; }

# --- configuration ----------------------------------------------------------

# Consumed by the scripts that source this file, not by lib.sh itself.
# shellcheck disable=SC2034

# Minimum Dev Spaces version carrying the Kiro editor definition tile.
# Source: Dev Spaces 3.26 release notes, Technology Preview section 4.1
# "Kiro SSH local-to-remote support" (CRW-9401).
readonly MIN_DEVSPACES_VERSION="3.26"

# Port the Dev Spaces remote-SSH landing page is served on inside the workspace.
# shellcheck disable=SC2034
readonly SSH_LANDING_PORT="3400"

: "${DEVSPACES_NAMESPACE:=}"   # autodetected if empty
: "${WORKSPACE_NAME:=kiro-workspace}"
: "${KIRO_EDITOR_ID:=}"        # autodetected if empty

# --- preconditions ----------------------------------------------------------

require_tools() {
  local missing=()
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  (( ${#missing[@]} == 0 )) || die "missing required tool(s): ${missing[*]}"
}

# --- YAML ------------------------------------------------------------------
#
# Two incompatible tools answer to the name `yq`: mikefarah's Go version
# (-o=json) and kislyuk's Python jq wrapper (JSON by default). Either may be
# installed, or neither. Everything downstream works in JSON -- `oc apply`
# accepts it -- so a single YAML-to-JSON helper is all we need.

_YAML2JSON_IMPL=""

_detect_yaml2json() {
  [[ -z "$_YAML2JSON_IMPL" ]] || return 0
  if command -v yq >/dev/null 2>&1; then
    if printf 'a: 1\n' | yq -o=json '.' >/dev/null 2>&1; then
      _YAML2JSON_IMPL=go_yq
    elif printf 'a: 1\n' | yq '.' >/dev/null 2>&1; then
      _YAML2JSON_IMPL=py_yq
    fi
  fi
  if [[ -z "$_YAML2JSON_IMPL" ]] \
     && python3 -c 'import yaml' >/dev/null 2>&1; then
    _YAML2JSON_IMPL=python
  fi
  [[ -n "$_YAML2JSON_IMPL" ]] \
    || die "need one of: yq (either implementation), or python3 with PyYAML."
}

# yaml2json [file]   -- reads stdin when no file is given
# shellcheck disable=SC2120  # callers in other scripts do pass a path
yaml2json() {
  _detect_yaml2json
  case "$_YAML2JSON_IMPL" in
    go_yq)  yq -o=json '.' "${1:--}" ;;
    py_yq)  if [[ -n "${1:-}" ]]; then yq '.' "$1"; else yq '.'; fi ;;
    python) python3 -I -c '
import json, sys, yaml
src = open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin
json.dump(yaml.safe_load(src), sys.stdout)
' ${1:+"$1"} ;;
  esac
}

require_login() {
  oc whoami >/dev/null 2>&1 \
    || die "not logged in to OpenShift. Run: oc login <cluster-api-url>"
}

# --- cluster discovery ------------------------------------------------------

# Namespace the Dev Spaces CheCluster lives in (commonly openshift-devspaces).
detect_devspaces_namespace() {
  if [[ -n "$DEVSPACES_NAMESPACE" ]]; then
    printf '%s' "$DEVSPACES_NAMESPACE"; return
  fi
  local ns
  ns=$(oc get checluster --all-namespaces \
         -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null) \
    || die "no CheCluster found. Is OpenShift Dev Spaces installed, and can you read it?"
  [[ -n "$ns" ]] || die "no CheCluster found in any namespace."
  printf '%s' "$ns"
}

devspaces_version() {
  local ns="$1"
  oc get checluster -n "$ns" -o jsonpath='{.items[0].status.cheVersion}' 2>/dev/null
}

dashboard_url() {
  local ns="$1"
  oc get checluster -n "$ns" -o jsonpath='{.items[0].status.cheURL}' 2>/dev/null
}

# Compare dotted versions: returns 0 if $1 >= $2.
version_gte() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# --- editor definition ------------------------------------------------------
#
# Dev Spaces ships each selectable editor as a ConfigMap in the Dev Spaces
# namespace, labelled app.kubernetes.io/component=editor-definition. Each holds
# a devfile whose metadata.name/attributes carry the editor id used by the
# dashboard's che-editor URL parameter.
#
# We discover the Kiro id rather than hardcoding it: the exact string is not
# published in the Dev Spaces docs and has no stability guarantee while the
# feature is Technology Preview.

editor_definition_configmaps() {
  local ns="$1"
  oc get configmap -n "$ns" \
    -l app.kubernetes.io/component=editor-definition \
    -o name 2>/dev/null || true
}

# Print every editor the cluster offers, one per line, as:
#   publisher/name/version<TAB>displayName<TAB>tags
#
# A single ConfigMap (editors-definitions) holds one devfile per key -- twelve
# of them on a stock 3.30 install -- so each key must be parsed on its own.
# Concatenating them yields one unparseable document.
list_editors() {
  local ns="$1" cm key body
  while read -r cm; do
    [[ -n "$cm" ]] || continue
    while read -r key; do
      [[ -n "$key" ]] || continue
      body=$(oc get "$cm" -n "$ns" -o json 2>/dev/null \
               | jq -r --arg k "$key" '.data[$k]' 2>/dev/null) || continue
      [[ -n "$body" && "$body" != "null" ]] || continue
      yaml2json <<<"$body" 2>/dev/null | jq -r '
        (.metadata // {}) as $m
        | ($m.attributes // {}) as $a
        | select($m.name != null)
        | [ "\($a.publisher // "unknown")/\($m.name)/\($a.version // "latest")",
            ($m.displayName // $m.name),
            ((($m.tags // []) | join(",")) // "") ]
        | @tsv
      ' 2>/dev/null || true
    done < <(oc get "$cm" -n "$ns" -o json 2>/dev/null | jq -r '.data // {} | keys[]' 2>/dev/null)
  done < <(editor_definition_configmaps "$ns")
}

# Just the ids, for callers that do not want the detail.
list_editor_ids() {
  list_editors "$1" | cut -f1
}

detect_kiro_editor_id() {
  local ns="$1"
  if [[ -n "$KIRO_EDITOR_ID" ]]; then
    printf '%s' "$KIRO_EDITOR_ID"; return
  fi
  local id
  id=$(list_editor_ids "$ns" | grep -i kiro | head -1 || true)
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

# Print the raw editor devfile for a given editor id.
#   get_editor_devfile <namespace> <publisher/name/version>
# Matches on the devfile's own metadata.name, not on a substring of the body.
get_editor_devfile() {
  local ns="$1" want="$2" cm key body got
  while read -r cm; do
    [[ -n "$cm" ]] || continue
    while read -r key; do
      [[ -n "$key" ]] || continue
      body=$(oc get "$cm" -n "$ns" -o json 2>/dev/null \
               | jq -r --arg k "$key" '.data[$k]' 2>/dev/null) || continue
      [[ -n "$body" && "$body" != "null" ]] || continue
      got=$(yaml2json <<<"$body" 2>/dev/null | jq -r '
        (.metadata // {}) as $m | ($m.attributes // {}) as $a
        | select($m.name != null)
        | "\($a.publisher // "unknown")/\($m.name)/\($a.version // "latest")"
      ' 2>/dev/null) || continue
      if [[ "$got" == "$want" ]]; then printf '%s' "$body"; return 0; fi
    done < <(oc get "$cm" -n "$ns" -o json 2>/dev/null | jq -r '.data // {} | keys[]' 2>/dev/null)
  done < <(editor_definition_configmaps "$ns")
  return 1
}

# Universal Developer Image refs, read from the operator CSV's relatedImages
# (authoritative and digest-pinned) rather than scraped from the CheCluster.
list_udi_images() {
  oc get csv -n openshift-operators -o json 2>/dev/null \
    | jq -r '.items[]
             | select(.metadata.name | test("devspacesoperator"))
             | .spec.relatedImages[]?.image // empty' 2>/dev/null \
    | grep -E 'udi-rhel' | sort -u
}

# --- workspace --------------------------------------------------------------

devworkspace_phase() {
  local ns="$1" name="$2"
  oc get devworkspace "$name" -n "$ns" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true
}

# Resolve the pod backing a DevWorkspace.
devworkspace_pod() {
  local ns="$1" name="$2"
  oc get pod -n "$ns" \
    -l "controller.devfile.io/devworkspace_name=$name" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

user_namespace() {
  oc project -q 2>/dev/null || die "could not determine current project."
}
