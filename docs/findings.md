# What is official, and what is not

Researched 2026-10-16 against the Red Hat Customer Portal (documentation,
solutions, errata) and the AWS blog post saved in the repository root.

## Officially documented by Red Hat

**The Kiro integration is a real, shipped Dev Spaces feature.** It is an
*editor definition*, selectable from the dashboard's Editor Selector — not
something you assemble yourself out of devfile components.

[Dev Spaces 3.26 release notes, §4.1 "Kiro SSH local-to-remote support"][rn326]
(Jira CRW-9401):

> Red Hat OpenShift Dev Spaces now includes native support for the Kiro editor
> as a local-to-remote SSH IDE. This update introduces a dedicated editor
> definition tile in the dashboard, allowing you to connect a local Kiro
> desktop application directly to running workspaces.

### Support status

**Technology Preview.** The release notes are explicit: not supported under
Red Hat production SLAs, may not be functionally complete, not recommended for
production use. See [Technology Preview Features Support Scope][tpscope].

For calibration, the identical mechanism for VS Code — `Visual Studio Code
(desktop) (SSH)` — entered Technology Preview in 3.24 and reached
[GA in 3.27][sol7133751]. Kiro is plausibly on the same trajectory, but has not
arrived there as of 3.30.

### Documented known issues

| Issue | Releases | Workaround |
|---|---|---|
| Kiro desktop 0.8.206 fails after Google sign-in: "Too many authentication failures" | 3.26 | **Sign in with an AWS Builder ID instead.** Logs at `/tmp/sshd.log` in the dev container |
| Kiro remote extension host does not install in airgapped clusters | 3.27.1, 3.28.1, 3.28.2 | None published |
| SSH connection to workspaces fails when nested containers are enabled | 3.28.1, 3.28.2 | None published; disable container build capabilities to test |

`scripts/preflight.sh` checks for the second and third conditions.

### Version floor

The release notes place the editor tile in **3.26**. The AWS blog says 3.25 or
later. Where they disagree, trust the release notes — `MIN_DEVSPACES_VERSION`
in `scripts/lib.sh` is set to 3.26.

## Documented by AWS, not by Red Hat

The step-by-step connection procedure appears only in the AWS blog,
[*Cloud development Meets Agentic AI: Kiro and Red Hat OpenShift Dev Spaces*][blog]
(27 Apr 2026). It is co-authored by Balaji Sivasubramanian, Senior Director of
Product at Red Hat for the Dev Spaces portfolio, so it is a joint announcement
rather than third-party speculation — but it is not product documentation and
carries no support commitment.

From the blog:

- Kiro extensions required: **DevSpaces Local/Remote Support** and **Open Remote SSH**
- Connection URL format: `https://${CLUSTER_URL}/${USER}/${DEVWORKSPACE_NAME}/3400/`
- Port forwarding is built into Kiro's SSH support; no extra networking setup
- Kiro is licensed separately from OpenShift

Red Hat's own IDE documentation (*Choose and configure your IDE*) covers only
VS Code and JetBrains. There is **no Red Hat procedure page for Kiro** in 3.30
— which is why the first pass of this research came back negative. The feature
is documented in release notes and known issues only.

## Verified on a live cluster (2026-10-16)

Tested against OpenShift 4.22.18 with Dev Spaces 3.30.2. The editor exists and
a scripted workspace reaches Running with Kiro attached.

```
che-incubator/che-code-sshd-kiro/latest   Kiro (desktop) (SSH)   ssh,CLI,vscode,Tech-Preview
```

Editor definition metadata corroborates the AWS blog: `displayName` is exactly
"Kiro (desktop) (SSH)", provider is "Provided by Amazon", repository is
`github.com/kirodotdev/Kiro`, and the main endpoint is port 3400 over HTTPS.

### Four requirements that are not obvious

1. **`spec.routingClass: che`** — not the DevWorkspace Operator default of
   `basic`. The editor's landing page binds to `127.0.0.1:3400`, so it is
   unreachable from outside the pod. Che's routing class injects the
   `che-gateway` sidecar that fronts it. Under `basic` the pod starts, both
   containers go Ready, and the workspace still fails after five minutes with
   *"failed to progress past step 'Waiting for workspace health check to
   become available'"*. Nothing in the symptom points at routing.

2. **Container build capabilities must be disabled.** With
   `disableContainerBuildCapabilities` unset (it defaults to *false*, meaning
   enabled), the pod requests `SETUID`, `SETGID` and
   `allowPrivilegeEscalation`, and admission rejects it under `restricted-v2`
   unless the workspace service account is bound to the `container-build` SCC.
   This is the concrete form of the documented 3.28 known issue *"SSH
   connection to workspaces fails when nested containers are enabled"*.

3. **The namespace must be annotated `che.eclipse.org/username`.** In a
   namespace without it, Che falls back to a URL of the form
   `/<workspace-id>/<endpoint-name>/3400/`. In a properly owned namespace it
   produces the `/<user>/<workspace>/3400/` form the blog documents. Read
   `.status.mainUrl` rather than constructing either.

4. **sshd runs in the development container, not the editor container.**
   `/tmp/sshd.log` lives in `tooling`, listening on `0.0.0.0:2022`;
   `che-code-sshd-kiro-page` only serves the `:3400` landing page on loopback.
   The release notes are right to send you to the dev container.

### Pod composition when it works

| Container | Image | Role |
|---|---|---|
| `tooling` | `udi-rhel9` | dev container; runs sshd on 2022 |
| `che-code-sshd-kiro-page` | `code-sshd-rhel9` | serves `127.0.0.1:3400` |
| `che-gateway` | traefik + oauth-proxy | fronts 3400, enforces OAuth |

### What could not be verified from a CLI

The `:3400` endpoint returns **HTTP 403 with an oauth-proxy "Log In" page** to
any non-browser caller, including the workspace owner's bearer token. That is
correct behaviour, not a defect: the gateway wants an interactive browser OAuth
session, which is precisely what Kiro performs. Completing the handshake
requires the actual Kiro desktop client.

Also unverified: the workspace must be reachable by a user who can read the
CheCluster. An ordinary developer cannot, so `preflight.sh` and `provision.sh`
currently assume more privilege than a real developer has. See the TODO in
`README.md`.

## Not documented anywhere

Treat these as this repository's own engineering, and expect to own breakage:

1. **Creating a Kiro-attached workspace from a CR instead of the dashboard.**
   `scripts/provision.sh` reads the editor definition ConfigMap, materialises a
   `DevWorkspaceTemplate`, and references it from `spec.contributions`. That
   sequence is inferred from product behaviour. It has no API stability
   guarantee, least of all while the feature is Technology Preview.

2. **The Kiro editor id string.** Not published. The scripts discover it at
   runtime from the cluster rather than hardcoding a guess. Override with
   `KIRO_EDITOR_ID` if discovery picks the wrong one.

3. **Running Kiro on Amazon WorkSpaces.** Entirely outside the published
   architecture, which assumes a local desktop. See `scripts/aws-workspace.sh`.

4. **MCP servers over the SSH session.** `kiro-mcp.md` describes Kiro's own
   `mcp.json` mechanics accurately, and stdio MCP servers will run inside the
   remote container like any other process. Red Hat documents MCP only for
   [Red Hat Developer Hub][rhdh], a different product.

## Corrections to the original files

`kiro-openshift-workspace.yaml`, as drafted, would not have worked:

- **`kiro-agent-runtime` sidecar** — delete. Kiro runs on the desktop. An
  `amazonlinux:2023` container running `sleep 30` in a loop does nothing but
  consume 2Gi of your memory quota.
- **`targetPort: 2222`, `protocol: tcp`, `exposure: internal`** — delete. Dev
  Spaces injects its own sshd when the editor contribution is applied; that is
  the `/tmp/sshd.log` the release notes point you at. `exposure: internal` is
  cluster-local anyway and the gateway routes HTTP, so nothing outside the
  cluster could have reached port 2222.
- **`registry.redhat.io/devspaces/ubi9-tooling:latest`** — not a Dev Spaces
  image name. The workspace base image is the Universal Developer Image (UDI).
  `scripts/preflight.sh` prints the tags your cluster actually references; pin
  one rather than tracking `latest`.
- **`schemaVersion: 2.2.0`** — correct, keep.

[rn326]: https://access.redhat.com/documentation/en-us/red_hat_openshift_dev_spaces/3.26/html-single/release_notes_and_known_issues/index
[sol7133751]: https://access.redhat.com/solutions/7133751
[tpscope]: https://access.redhat.com/support/offerings/techpreview
[rhdh]: https://access.redhat.com/documentation/en-us/red_hat_developer_hub/1.10/html-single/interacting_with_model_context_protocol_tools_for_red_hat_developer_hub/index
[blog]: https://aws.amazon.com/blogs/ibm-redhat/cloud-development-meets-agentic-ai-kiro-and-red-hat-openshift-dev-spaces/
