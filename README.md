# Kiro to OpenShift Dev Spaces

Scripts to provision an OpenShift DevWorkspace wired to the **Kiro (desktop)
(SSH)** editor, and optionally an Amazon WorkSpaces desktop to run the Kiro
client from.

The OpenShift half follows a real, shipped Dev Spaces feature — Technology
Preview since 3.26. The AWS half does not; see
[docs/findings.md](docs/findings.md) for exactly which parts Red Hat stands
behind.

## Architecture

```
  Kiro desktop client                      OpenShift cluster
  ┌────────────────────┐                   ┌──────────────────────────────┐
  │ Kiro               │                   │  Dev Spaces gateway          │
  │  + DevSpaces       │   HTTPS :3400     │    │                         │
  │    Local/Remote    │══════════════════▶│    ▼                         │
  │  + Open Remote SSH │   (SSH tunnelled) │  DevWorkspace pod            │
  │                    │                   │   ├─ dev container (UDI)     │
  │ AWS Builder ID     │                   │   │   └─ sshd ──▶ /tmp/sshd.log
  └────────────────────┘                   │   └─ editor contribution     │
   local laptop, or an                     └──────────────────────────────┘
   Amazon WorkSpaces desktop
```

Kiro runs **on a desktop**, never in the cluster. The workspace needs no sshd
sidecar — Dev Spaces injects one when the Kiro editor definition is applied as
a contribution.

## Prerequisites

| | |
|---|---|
| OpenShift Dev Spaces | **3.26+** (editor tile introduced in 3.26) |
| Local tooling | `oc`, `jq`, `yq`; plus `aws` for the WorkSpaces script |
| Kiro | Installed on the desktop, signed in with an **AWS Builder ID** |
| Kiro extensions | DevSpaces Local/Remote Support, Open Remote SSH |
| Licensing | Dev Spaces is included with OpenShift; Kiro is licensed separately |

## Usage

```bash
oc login https://api.your-cluster.example.com:6443

# 1. Check the cluster can host this, and report cluster-specific values
scripts/preflight.sh

# 2. Provision the workspace and wait for it to come up
scripts/provision.sh --repo https://github.com/org/repo.git --name my-workspace

# 3. Re-print the connection URL and re-run verification at any time
scripts/connect.sh --name my-workspace
```

`provision.sh` chains into `connect.sh` on success, so step 3 is only needed
when reconnecting later.

Pin a real image before first use: `devfile/kiro-workspace.devfile.yaml` ships
a placeholder UDI tag, and `preflight.sh` prints the tags your cluster actually
references.

### Optional: Kiro on Amazon WorkSpaces

```bash
scripts/aws-workspace.sh --directory d-1234567890 --user alice
```

Read the header of that script first. Amazon WorkSpaces has **no user-data
hook**, so Kiro cannot be installed at launch. For more than one user, install
Kiro on one desktop by hand, build a custom bundle from it, and launch the rest
with `--bundle`.

## Configuration

Environment variables, all optional:

| Variable | Default | Purpose |
|---|---|---|
| `DEVSPACES_NAMESPACE` | autodetected from the CheCluster | Where Dev Spaces is installed |
| `WORKSPACE_NAME` | `kiro-workspace` | Default `--name` |
| `KIRO_EDITOR_ID` | discovered from the cluster | Override if discovery picks wrong |

## Cluster prerequisites

Beyond Dev Spaces 3.26+, two cluster-side settings are required. `preflight.sh`
checks both.

```bash
# 1. Container build capabilities must be off, or workspace pods are rejected
#    by SCC admission (SETUID/SETGID/allowPrivilegeEscalation under restricted-v2).
oc patch checluster devspaces -n openshift-devspaces --type=merge \
  -p '{"spec":{"devEnvironments":{"disableContainerBuildCapabilities":true}}}'

# 2. The workspace namespace must be owned by the connecting user, or the
#    friendly /<user>/<workspace>/3400/ URL is not generated.
oc annotate namespace <ns> che.eclipse.org/username=<user>
```

> **Known limitation.** `preflight.sh` and `provision.sh` read the CheCluster
> to discover the Dev Spaces namespace, version, and dashboard URL. Ordinary
> developers do not have that permission, so today these scripts assume
> elevated access. Fixing this means accepting `DEVSPACES_NAMESPACE` and the
> dashboard URL as plain configuration and skipping CheCluster entirely.

## Troubleshooting

**"Too many authentication failures" after sign-in.** You signed into Kiro with
a Google account. Use an AWS Builder ID — this is a documented defect, not a
misconfiguration.

**Connection hangs.** Check whether nested containers are enabled; there is a
documented incompatibility with the SSH path. `preflight.sh` warns about this.

**Extension host never installs.** Documented as broken on airgapped clusters,
with no published workaround.

**Anything else.** The authoritative log lives inside the workspace:

```bash
oc exec <pod> -c <dev-container> -- cat /tmp/sshd.log
```

**Provisioning breaks after a Dev Spaces upgrade.** Likely the editor
contribution wiring, which is inferred rather than documented. Fall back to
creating the workspace from the dashboard Editor Selector and then running
`connect.sh`.

## Layout

```
devfile/kiro-workspace.devfile.yaml   workspace definition (no sshd sidecar)
scripts/lib.sh                        shared helpers, cluster discovery
scripts/preflight.sh                  version + editor + known-issue checks
scripts/provision.sh                  create DevWorkspace, attach editor, wait
scripts/connect.sh                    verify and print the Cluster URL
scripts/aws-workspace.sh              optional Amazon WorkSpaces desktop
docs/findings.md                      what Red Hat documents, and what it doesn't
```
