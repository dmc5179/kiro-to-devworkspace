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
#
# sshd runs in the *development* container, not in the editor's own
# che-code-sshd-kiro-page container -- the editor container only serves the
# :3400 landing page. Rather than guess which container is which, search for
# the log the release notes point at.

containers=$(oc get pod "$pod" -n "$user_ns" \
  -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')

dev_container=""
for c in $containers; do
  if oc exec "$pod" -n "$user_ns" -c "$c" -- test -f /tmp/sshd.log 2>/dev/null; then
    dev_container="$c"; break
  fi
done

if [[ -n "$dev_container" ]]; then
  ok "sshd log found in container '$dev_container'"
  if oc exec "$pod" -n "$user_ns" -c "$dev_container" -- \
       grep -qiE 'error|fail' /tmp/sshd.log 2>/dev/null; then
    warn "sshd.log contains error lines:"
    oc exec "$pod" -n "$user_ns" -c "$dev_container" -- \
      sh -c 'grep -iE "error|fail" /tmp/sshd.log | tail -5' >&2 || true
  else
    oc exec "$pod" -n "$user_ns" -c "$dev_container" -- \
      grep -i 'listening' /tmp/sshd.log 2>/dev/null | sed 's/^/      /' >&2 || true
  fi
else
  warn "no /tmp/sshd.log in any container (${containers//$'\n'/, })."
  warn "  The editor contribution may not have been applied. Confirm the workspace"
  warn "  was created with the Kiro editor and not a browser editor."
fi

# The gateway sidecar is what makes the editor reachable from outside the pod.
if grep -q '^che-gateway$' <<<"$containers"; then
  ok "che-gateway sidecar present (routingClass=che applied correctly)"
else
  warn "no che-gateway sidecar in the pod."
  warn "  The DevWorkspace probably has routingClass 'basic' instead of 'che'."
  warn "  The editor binds :3400 to loopback, so without the gateway nothing"
  warn "  outside the pod can reach it and the health check never passes."
fi

# --- 3. The :3400 landing page ----------------------------------------------
#
# Take the URL from the DevWorkspace's own status rather than assembling one.
# The AWS blog gives the format as /${USER}/${DEVWORKSPACE_NAME}/3400/, but
# what Dev Spaces 3.30 actually publishes is
# /<workspace-id>/<endpoint-name>/3400/. status.mainUrl is authoritative and
# survives both forms.

connect_url=$(oc get devworkspace "$name" -n "$user_ns" \
  -o jsonpath='{.status.mainUrl}' 2>/dev/null || true)

if [[ -z "$connect_url" ]]; then
  warn "DevWorkspace has no status.mainUrl; falling back to a constructed URL."
  dashboard=$(dashboard_url "$ds_ns")
  [[ -n "$dashboard" ]] || die "could not read the dashboard URL from the CheCluster."
  cluster_host="${dashboard#https://}"; cluster_host="${cluster_host%%/*}"
  connect_url="https://${cluster_host}/$(oc whoami)/${name}/${SSH_LANDING_PORT}/"
fi

info "Probing $connect_url"
token=$(oc whoami -t 2>/dev/null || true)
[[ -n "$token" ]] \
  || info "no OAuth token for this session (certificate-based login); probing unauthenticated"

# Capture body and status in a single request so the two always agree.
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
if [[ -n "$token" ]]; then
  code=$(curl -sk -o "$body_file" -w '%{http_code}' --max-time 15 \
           -H "Authorization: Bearer $token" "$connect_url" 2>/dev/null) || code="000"
else
  code=$(curl -sk -o "$body_file" -w '%{http_code}' --max-time 15 "$connect_url" 2>/dev/null) || code="000"
fi

case "$code" in
  200)
    ok "Remote SSH landing page responded (HTTP 200)"
    ;;
  301|302)
    ok "landing page redirected (HTTP $code) -- OAuth login, as expected"
    ;;
  401|403)
    # oauth-proxy answers unauthenticated requests with its own login page.
    # Seeing that page means the gateway is healthy and routing correctly; it
    # simply wants an interactive browser session, which is what Kiro does.
    # A bearer token cannot satisfy it, so this is a pass, not a failure.
    if grep -qi '<title>Log In</title>' "$body_file" 2>/dev/null; then
      ok "gateway healthy: serving the OAuth login page (HTTP $code)"
      info "a bearer token cannot complete this flow; Kiro logs in via the browser"
    else
      warn "landing page returned HTTP $code without an OAuth login page."
      warn "  Check that the workspace namespace is annotated che.eclipse.org/username"
      warn "  with the user you expect to connect as."
    fi
    ;;
  000)
    warn "could not reach the landing page. Check network access from this host to the cluster."
    ;;
  *)
    warn "landing page returned HTTP $code."
    ;;
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
