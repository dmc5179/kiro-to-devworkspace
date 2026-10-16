#!/usr/bin/env bash
#
# Verify the cluster can host a Kiro-connected DevWorkspace, and report the
# cluster-specific values the other scripts need.
#
# Checks:
#   1. oc is logged in
#   2. Dev Spaces is installed, and is >= 3.26 (Kiro editor tile)
#   3. The Kiro editor definition is actually present on this cluster
#   4. Known-issue conditions that break the SSH path
#
# Exit status is non-zero if anything would block provisioning.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools oc jq
_detect_yaml2json   # fails loudly if neither yq nor python3+PyYAML is present
require_login

failures=0
note_failure() { warn "$1"; failures=$((failures + 1)); }

info "Logged in as $(oc whoami) on $(oc whoami --show-server)"

# --- 1. Dev Spaces present --------------------------------------------------

ns=$(detect_devspaces_namespace)
ok "Dev Spaces namespace: $ns"

version=$(devspaces_version "$ns")
if [[ -z "$version" ]]; then
  note_failure "could not read Dev Spaces version from the CheCluster status."
elif version_gte "$version" "$MIN_DEVSPACES_VERSION"; then
  ok "Dev Spaces version: $version (>= $MIN_DEVSPACES_VERSION)"
else
  note_failure "Dev Spaces $version is older than $MIN_DEVSPACES_VERSION; the Kiro editor tile was introduced in 3.26 (CRW-9401)."
fi

dashboard=$(dashboard_url "$ns")
if [[ -n "$dashboard" ]]; then
  ok "Dashboard: $dashboard"
else
  note_failure "could not read the dashboard URL from the CheCluster status."
fi

# --- 2. Kiro editor definition ----------------------------------------------

if editor_id=$(detect_kiro_editor_id "$ns"); then
  ok "Kiro editor id: $editor_id"
else
  note_failure "no Kiro editor definition found in namespace $ns."
  info "Editors this cluster does offer:"
  list_editor_ids "$ns" | sed 's/^/      /' >&2 || true
  info "If Kiro is present under a different name, set KIRO_EDITOR_ID explicitly."
fi

# --- 3. Known issues --------------------------------------------------------
# Documented against Dev Spaces 3.26-3.28; see docs/findings.md.

# Nested containers break the SSH connection (3.28.1 / 3.28.2 known issues).
nested=$(oc get checluster -n "$ns" \
  -o jsonpath='{.items[0].spec.devEnvironments.security.containerSecurityContext}' 2>/dev/null || true)
disable_container_build=$(oc get checluster -n "$ns" \
  -o jsonpath='{.items[0].spec.devEnvironments.disableContainerBuildCapabilities}' 2>/dev/null || true)
if [[ "$disable_container_build" == "false" ]]; then
  warn "container build capabilities (nested containers) are enabled."
  warn "  Known issue: SSH connection to workspaces fails when nested containers are enabled."
  warn "  If the Kiro connection hangs, test with them disabled."
fi
[[ -n "$nested" ]] && info "containerSecurityContext is customised; review if SSH misbehaves."

# Airgapped clusters cannot install the Kiro remote extension host
# (3.27.1 / 3.28.1 / 3.28.2 known issues).
if oc get imagecontentsourcepolicy,imagedigestmirrorset -A -o name 2>/dev/null | grep -q .; then
  warn "cluster has image mirroring configured, suggesting a restricted/airgapped network."
  warn "  Known issue: the Kiro remote extension host does not install in airgapped clusters."
fi

# --- 4. Candidate workspace images ------------------------------------------
# The sample devfile needs a real Universal Developer Image tag. Rather than
# guess, surface what this cluster actually references.

info "Universal Developer Image tags referenced by this cluster:"
oc get checluster -n "$ns" -o json 2>/dev/null \
  | jq -r '.items[0] | [.spec, .status] | .. | strings | select(test("udi|universal-developer"))' 2>/dev/null \
  | sort -u | sed 's/^/      /' >&2 || true
oc get configmap -n "$ns" -o json 2>/dev/null \
  | jq -r '.. | strings | select(test("registry.redhat.io/devspaces/udi"))' 2>/dev/null \
  | sort -u | head -5 | sed 's/^/      /' >&2 || true

# --- summary ----------------------------------------------------------------

echo >&2
if (( failures > 0 )); then
  die "$failures blocking issue(s) found. Resolve them before running provision.sh."
fi
ok "Preflight passed. Next: scripts/provision.sh"

# Emit machine-readable values for the other scripts / CI.
cat <<EOF
DEVSPACES_NAMESPACE=$ns
DEVSPACES_VERSION=$version
DASHBOARD_URL=$dashboard
KIRO_EDITOR_ID=${editor_id:-}
EOF
