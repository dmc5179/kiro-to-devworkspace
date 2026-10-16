#!/usr/bin/env bash
#
# Verify a running DevWorkspace is actually reachable by Kiro, and print the
# Cluster URL to paste into Kiro's Remote Explorer.
#
#   scripts/connect.sh [--name NAME]
#
# Verification covers the things that have actually been observed to fail:
#   - workspace is Running and its pod is Ready
#   - sshd came up inside the dev container (/tmp/sshd.log, per the 3.26
#     release notes, which direct you there for authentication failures)
#   - the :3400 remote-SSH landing page answers through the gateway

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

name="$WORKSPACE_NAME"
while (( $# )); do
  case "$1" in
    --name)    name="${2:?--name needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" >&2; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

require_tools oc curl jq
require_login

ds_ns=$(detect_devspaces_namespace)
user_ns=$(user_namespace)

# --- 1. Workspace state -----------------------------------------------------

phase=$(devworkspace_phase "$user_ns" "$name")
[[ -n "$phase" ]] || die "no DevWorkspace named '$name' in namespace $user_ns."
[[ "$phase" == "Running" ]] || die "workspace '$name' is in phase '$phase', not Running."
ok "DevWorkspace $name: Running"

pod=$(devworkspace_pod "$user_ns" "$name")
[[ -n "$pod" ]] || die "could not find the pod backing workspace '$name'."
ok "Pod: $pod"

# --- 2. sshd inside the dev container ---------------------------------------
# The dev container is the one mounting the project sources.

dev_container=$(oc get pod "$pod" -n "$user_ns" \
  -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' \
  | grep -v -E '^(che-gateway|che-machine-exec)' | head -1)
[[ -n "$dev_container" ]] || die "could not identify the development container in $pod."

if oc exec "$pod" -n "$user_ns" -c "$dev_container" -- \
     sh -c 'test -f /tmp/sshd.log' 2>/dev/null; then
  ok "sshd log present at /tmp/sshd.log in container '$dev_container'"
  if oc exec "$pod" -n "$user_ns" -c "$dev_container" -- \
       sh -c 'grep -qi "error\|fail" /tmp/sshd.log' 2>/dev/null; then
    warn "sshd.log contains error lines:"
    oc exec "$pod" -n "$user_ns" -c "$dev_container" -- \
      sh -c 'grep -i "error\|fail" /tmp/sshd.log | tail -5' >&2 || true
  fi
else
  warn "no /tmp/sshd.log in '$dev_container'."
  warn "  The editor contribution may not have been applied. Confirm the workspace"
  warn "  was created with the Kiro editor and not a browser editor."
fi

# --- 3. The :3400 landing page ----------------------------------------------

dashboard=$(dashboard_url "$ds_ns")
[[ -n "$dashboard" ]] || die "could not read the dashboard URL from the CheCluster."

cluster_host="${dashboard#https://}"; cluster_host="${cluster_host%%/*}"
username=$(oc whoami)
connect_url="https://${cluster_host}/${username}/${name}/${SSH_LANDING_PORT}/"

info "Probing $connect_url"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
         -H "Authorization: Bearer $(oc whoami -t)" "$connect_url" 2>/dev/null || echo 000)
case "$code" in
  200|301|302) ok "Remote SSH landing page responded (HTTP $code)" ;;
  401|403)     warn "landing page returned HTTP $code -- expected; Kiro performs its own OAuth login." ;;
  000)         warn "could not reach the landing page. Check network access from this host to the cluster." ;;
  *)           warn "landing page returned HTTP $code." ;;
esac

# --- 4. Hand off to the operator --------------------------------------------

cat <<EOF

  Paste this into Kiro's Remote Explorer -> DevSpaces Local/Remote Support ->
  Cluster URL field:

      $connect_url

  In Kiro you need both extensions installed:
      - DevSpaces Local/Remote Support
      - Open Remote SSH

  Sign in to Kiro with an AWS Builder ID, not a Google account. Google sign-in
  is a documented failure on Kiro 0.8.206 ("Too many authentication failures");
  see docs/findings.md.

  If the connection fails, the authoritative log is inside the workspace:
      oc exec $pod -n $user_ns -c $dev_container -- cat /tmp/sshd.log

EOF
