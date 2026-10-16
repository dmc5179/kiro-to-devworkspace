#!/usr/bin/env bash
#
# Provision an Amazon WorkSpaces virtual desktop to run the Kiro client.
#
#   scripts/aws-workspace.sh --directory d-xxxx --user alice [--bundle wsb-xxxx]
#
# READ THIS FIRST
# ---------------
# This half is NOT part of the Red Hat / AWS integration. The published
# architecture runs Kiro on a local laptop; the AWS account exists only to
# activate Kiro (AWS Builder ID). Hosting Kiro on WorkSpaces is a deployment
# choice of yours, and nobody documents or supports it.
#
# The load-bearing constraint: Amazon WorkSpaces has no user-data or cloud-init
# hook. You cannot script software onto a WorkSpace at launch the way you can
# with EC2. There are exactly two ways to get Kiro onto these desktops:
#
#   A. Custom bundle (do this for more than one user)
#      Launch one WorkSpace from a stock bundle, install Kiro + both extensions
#      by hand, then create an image and bundle from it, and launch everyone
#      else from that bundle via --bundle. Amortises across the team and keeps
#      desktops identical -- the same argument Dev Spaces makes for devfiles.
#
#   B. Install per desktop (fine for a one-off trial)
#      Launch from a stock bundle and run the steps this script prints at the
#      end inside each desktop.
#
# This script automates provisioning and the readiness wait. It cannot automate
# the Kiro install itself.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools aws jq

directory=""
user=""
bundle=""
running_mode="AUTO_STOP"
timeout=1800

while (( $# )); do
  case "$1" in
    --directory) directory="${2:?--directory needs a value}"; shift 2 ;;
    --user)      user="${2:?--user needs a value}"; shift 2 ;;
    --bundle)    bundle="${2:?--bundle needs a value}"; shift 2 ;;
    --always-on) running_mode="ALWAYS_ON"; shift ;;
    --timeout)   timeout="${2:?--timeout needs a value}"; shift 2 ;;
    -h|--help)   sed -n '2,36p' "$0" >&2; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

[[ -n "$directory" ]] || die "--directory is required (the WorkSpaces registered directory id, d-xxxxxxxxxx)."
[[ -n "$user" ]]      || die "--user is required (a username in that directory)."

aws sts get-caller-identity >/dev/null 2>&1 \
  || die "AWS credentials are not configured or have expired."
ok "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"

# --- bundle selection -------------------------------------------------------

if [[ -z "$bundle" ]]; then
  warn "no --bundle given; selecting a stock Amazon Linux bundle."
  warn "  You will have to install Kiro by hand afterwards (option B above)."
  bundle=$(aws workspaces describe-workspace-bundles --owner AMAZON \
    --query 'Bundles[?contains(Name, `Standard`) && contains(to_string(ComputeType.Name), `STANDARD`)].BundleId | [0]' \
    --output text 2>/dev/null)
  [[ -n "$bundle" && "$bundle" != "None" ]] \
    || die "could not auto-select a bundle. Pass --bundle explicitly; list them with:
       aws workspaces describe-workspace-bundles --owner AMAZON"
fi
ok "Bundle: $bundle"

# Fail early rather than after a 20-minute provision.
if aws workspaces describe-workspaces \
     --directory-id "$directory" --user-name "$user" \
     --query 'Workspaces[0].WorkspaceId' --output text 2>/dev/null | grep -qv '^None$'; then
  die "a WorkSpace already exists for user '$user' in directory '$directory'."
fi

# --- provision --------------------------------------------------------------

info "Requesting WorkSpace for '$user'"
workspace_id=$(aws workspaces create-workspaces --workspaces "$(jq -nc \
  --arg d "$directory" --arg u "$user" --arg b "$bundle" --arg m "$running_mode" \
  '[{DirectoryId: $d, UserName: $u, BundleId: $b,
     WorkspaceProperties: {RunningMode: $m},
     Tags: [{Key: "Purpose", Value: "kiro-devspaces-client"}]}]')" \
  --query 'PendingRequests[0].WorkspaceId' --output text)

[[ -n "$workspace_id" && "$workspace_id" != "None" ]] || {
  aws workspaces create-workspaces --workspaces "$(jq -nc \
    --arg d "$directory" --arg u "$user" --arg b "$bundle" \
    '[{DirectoryId: $d, UserName: $u, BundleId: $b}]')" \
    --query 'FailedRequests' --output json >&2 || true
  die "WorkSpace creation was rejected."
}
ok "WorkSpace id: $workspace_id"

info "Waiting up to ${timeout}s for AVAILABLE (first launch typically 20+ minutes)"
deadline=$(( SECONDS + timeout ))
state=""
while (( SECONDS < deadline )); do
  state=$(aws workspaces describe-workspaces --workspace-ids "$workspace_id" \
            --query 'Workspaces[0].State' --output text 2>/dev/null || echo UNKNOWN)
  case "$state" in
    AVAILABLE) break ;;
    ERROR|FAILED|TERMINATED|UNHEALTHY)
      die "WorkSpace entered state '$state'." ;;
  esac
  printf '.' >&2
  sleep 30
done
printf '\n' >&2
[[ "$state" == "AVAILABLE" ]] || die "timed out after ${timeout}s in state '$state'."
ok "WorkSpace is AVAILABLE"

reg_code=$(aws workspaces describe-workspace-directories --directory-ids "$directory" \
  --query 'Directories[0].RegistrationCode' --output text 2>/dev/null || true)

# --- network reachability ---------------------------------------------------

cluster_host=""
if oc whoami >/dev/null 2>&1; then
  ds_ns=$(detect_devspaces_namespace 2>/dev/null || true)
  if [[ -n "$ds_ns" ]]; then
    cluster_host=$(dashboard_url "$ds_ns"); cluster_host="${cluster_host#https://}"
    cluster_host="${cluster_host%%/*}"
  fi
fi

cat <<EOF

  WorkSpace $workspace_id is ready for $user.
  Registration code for the WorkSpaces client: ${reg_code:-<run: aws workspaces describe-workspace-directories>}

  Inside the desktop, once logged in:

    1. Install Kiro            https://kiro.dev  (Windows, macOS, Linux)
    2. Sign in with an AWS Builder ID. Not Google -- Google sign-in is a
       documented failure mode (see docs/findings.md).
    3. Install both Kiro extensions:
         - DevSpaces Local/Remote Support
         - Open Remote SSH
    4. Run scripts/connect.sh against your cluster to get the Cluster URL,
       and paste it into Kiro's Remote Explorer.

  Still to confirm on your side:

    - Network path. The desktop sits in the WorkSpaces VPC and needs HTTPS to
EOF

if [[ -n "$cluster_host" ]]; then
  cat <<EOF
      ${cluster_host} and to your cluster's wildcard apps domain. If OpenShift
      is on-prem, that means VPN, Direct Connect, or a Transit Gateway; if it is
      ROSA, VPC peering is usually enough.
EOF
else
  cat <<EOF
      your Dev Spaces dashboard host and the cluster's wildcard apps domain. If
      OpenShift is on-prem, that means VPN, Direct Connect, or a Transit
      Gateway; if it is ROSA, VPC peering is usually enough.
EOF
fi

cat <<EOF
    - Egress to kiro.dev and the AWS Builder ID endpoints, or Kiro cannot
      activate and the extension host cannot download.
    - Kiro licensing, which is separate from both your OpenShift and your AWS
      spend.

  To build a reusable bundle from this desktop once Kiro is installed:

      aws workspaces create-workspace-image \\
        --name kiro-client --description "Kiro + Dev Spaces extensions" \\
        --workspace-id $workspace_id
      # then: aws workspaces create-workspace-bundle ...
      # and launch future desktops with --bundle <new-bundle-id>

EOF
