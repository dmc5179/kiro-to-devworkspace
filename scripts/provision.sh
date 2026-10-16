#!/usr/bin/env bash
#
# Provision a DevWorkspace wired to the Kiro (desktop) (SSH) editor.
#
#   scripts/provision.sh --repo https://github.com/org/repo.git [--name NAME]
#
# How the editor gets attached
# ----------------------------
# Dev Spaces stores each selectable editor as a devfile inside a ConfigMap in
# the Dev Spaces namespace. The dashboard materialises the chosen editor as a
# DevWorkspaceTemplate in the user's namespace and references it from the
# DevWorkspace's spec.contributions. This script reproduces that sequence.
#
# That wiring is inferred from how the product behaves, not from a documented
# API -- Red Hat documents selecting Kiro through the dashboard tile, not
# through a CR. It may change between releases, particularly while the feature
# is Technology Preview. If provisioning breaks after an upgrade, fall back to
# the dashboard URL this script prints at the end.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo=""
name="$WORKSPACE_NAME"
timeout=600

while (( $# )); do
  case "$1" in
    --repo)    repo="${2:?--repo needs a value}"; shift 2 ;;
    --name)    name="${2:?--name needs a value}"; shift 2 ;;
    --timeout) timeout="${2:?--timeout needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" >&2; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

[[ -n "$repo" ]] || die "--repo is required (git URL to clone into the workspace)."

require_tools oc jq
_detect_yaml2json
require_login

ds_ns=$(detect_devspaces_namespace)
user_ns=$(user_namespace)
devfile="$(dirname "${BASH_SOURCE[0]}")/../devfile/kiro-workspace.devfile.yaml"
[[ -f "$devfile" ]] || die "devfile not found at $devfile"

version=$(devspaces_version "$ds_ns")
version_gte "$version" "$MIN_DEVSPACES_VERSION" \
  || die "Dev Spaces $version < $MIN_DEVSPACES_VERSION; no Kiro editor tile. Run preflight.sh."

editor_id=$(detect_kiro_editor_id "$ds_ns") \
  || die "no Kiro editor definition on this cluster. Run preflight.sh for the list of available editors."
info "Using editor: $editor_id"

# --- 1. Materialise the editor as a DevWorkspaceTemplate --------------------

template_name="${name}-kiro-editor"
info "Creating DevWorkspaceTemplate $template_name in $user_ns"

editor_devfile=$(get_editor_devfile "$ds_ns" "$editor_id") \
  || die "could not extract the devfile for editor '$editor_id' from $ds_ns."

# The editor devfile's components/commands/events become the template spec.
# oc accepts JSON, so there is no need to round-trip back to YAML.
yaml2json <<<"$editor_devfile" \
  | jq --arg tmpl "$template_name" '{
      apiVersion: "workspace.devfile.io/v1alpha2",
      kind: "DevWorkspaceTemplate",
      metadata: {name: $tmpl},
      spec: {
        components: (.components // []),
        commands:   (.commands // []),
        events:     (.events // {})
      }
    }' \
  | oc apply -n "$user_ns" -f - >&2 \
  || die "failed to create the editor template."

# --- 2. Create the DevWorkspace ---------------------------------------------

info "Creating DevWorkspace $name in $user_ns"

project_name=$(basename "${repo%.git}")

# routingClass MUST be "che", not the DevWorkspace Operator default of
# "basic". The editor's landing page binds to 127.0.0.1:3400, so it is only
# reachable from inside the pod; Che's routing class injects the per-workspace
# che-gateway sidecar that fronts it and terminates OAuth. Under "basic" the
# pod starts and both containers go Ready, but the workspace health check can
# never reach :3400 and the DevWorkspace fails after 5 minutes.
#
# devworkspace-config likewise points the workspace at the Che namespace's
# configuration rather than the operator defaults.
workspace=$(yaml2json "$devfile" | jq \
  --arg name "$name" \
  --arg tmpl "$template_name" \
  --arg editor "$editor_id" \
  --arg repo "$repo" \
  --arg project "$project_name" \
  --arg dsns "$ds_ns" '
  {
    apiVersion: "workspace.devfile.io/v1alpha2",
    kind: "DevWorkspace",
    metadata: {
      name: $name,
      labels: {"app.kubernetes.io/managed-by": "kiro-to-devworkspaces"}
    },
    spec: {
      started: true,
      routingClass: "che",
      contributions: [{name: "editor", kubernetes: {name: $tmpl}}],
      template: {
        attributes: {
          "che-editor": $editor,
          "controller.devfile.io/devworkspace-config": {
            name: "devworkspace-config",
            namespace: $dsns
          },
          "controller.devfile.io/storage-type": "per-user"
        },
        projects: [{
          name: $project,
          git: {remotes: {origin: $repo}}
        }],
        components: .components,
        commands: (.commands // [])
      }
    }
  }')

printf '%s' "$workspace" | oc apply -n "$user_ns" -f - >&2 \
  || die "failed to create the DevWorkspace."

# --- 3. Wait for it to come up ----------------------------------------------

info "Waiting up to ${timeout}s for $name to reach Running"

# Watch for Failed in the background so a doomed start aborts promptly instead
# of burning the full timeout; oc wait itself can only watch for one value.
( oc wait --for=jsonpath='{.status.phase}'=Failed "devworkspace/$name" \
    -n "$user_ns" --timeout="${timeout}s" >/dev/null 2>&1 \
    && kill -TERM $$ 2>/dev/null ) &
watcher=$!
trap 'kill "$watcher" 2>/dev/null || true' EXIT

if ! oc wait --for=jsonpath='{.status.phase}'=Running "devworkspace/$name" \
       -n "$user_ns" --timeout="${timeout}s" >/dev/null 2>&1; then
  phase=$(devworkspace_phase "$user_ns" "$name")
  oc get devworkspace "$name" -n "$user_ns" \
    -o jsonpath='{.status.message}{"\n"}' >&2 || true
  die "workspace did not reach Running (phase '${phase:-unknown}')."
fi

kill "$watcher" 2>/dev/null || true
ok "DevWorkspace $name is Running"

echo
exec "$(dirname "${BASH_SOURCE[0]}")/connect.sh" --name "$name"
