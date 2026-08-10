# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo sets up a homelab Kubernetes cluster running on Talos Linux. The cluster itself was
bootstrapped manually (see README.md note on the pre-GitOps bootstrap process). GitOps via ArgoCD
+ Kargo is the active next phase — see "GitOps direction" below for what's been decided so far.

## Architecture

- `talos/talconfig.yaml` — the single source of truth for cluster topology, consumed by
  [`talhelper`](https://github.com/budimanjojo/talhelper) to render per-node Talos machine configs.
  It defines the cluster name/endpoint, the shared control-plane patch (disables the default CNI
  in favor of Cilium, disables kube-proxy for strict kube-proxy-less mode, and configures a Talos
  VIP), and the three physical nodes.
- `talos/clusterconfig/` — generated output directory (gitignored, mode 700). Contains the
  per-node YAML configs and `talosconfig` produced by `talhelper genconfig`. Never hand-edit files
  here or commit them — regenerate from `talconfig.yaml` instead.
- The cluster is a 3-node, all-control-plane (`allowSchedulingOnMasters: true`) topology on VLAN 86
  (`172.31.86.0/24`), fronted by a Talos VIP at `172.31.86.10` for the Kubernetes API.

## Common commands

Run from the `talos/` directory:

```bash
# Regenerate per-node Talos configs from talconfig.yaml
talhelper genconfig
```

Applying config to a freshly-booted (insecure) node:

```bash
talosctl apply-config --insecure --nodes <node-ip> --file clusterconfig/k8s.nodes.ee-<hostname>.yaml
```

Use the generated `talosconfig` (copy to `~/.talos/config`) for subsequent authenticated
`talosctl`/`kubectl` operations against the cluster.

## GitOps direction

Decided so far (as of the ArgoCD/Kargo planning discussion):

- **Tooling**: ArgoCD for reconciliation, Kargo for promotion — not plain ArgoCD alone.
- **Bootstrap pattern**: App-of-Apps (a root Application generating child Applications from a
  `kustomization.yaml`) for the platform/addon bundle. This is a single 3-node cluster with a
  small, deliberate addon list, so ApplicationSet is not needed here — it's meant for dynamic,
  multi-cluster/multi-tenant fleets, which this isn't.
- **Manifest rendering**: moving away from inlining full Helm `valuesObject` blocks directly in
  `Application` CRDs (the previous repo's pattern) — that makes changes hard to diff/review and
  was a contributing factor in a real incident on this cluster (a wrong `k8sServiceHost` value
  buried in a `helm install --set` flag list took an hour to diagnose). Prefer Kargo's rendered
  manifest workflow (`hydrateTo` + a review branch gated by PR) so config changes show up as an
  actual Kubernetes-resource diff in a pull request before they reach the cluster.
- **Repo layout**: GitOps manifests live in this same repo (not a separate `homelab-gitops` repo
  like the previous setup) — everything for this cluster stays in one place.
- **Kargo scope**: single Warehouse feeding a single Stage for now — used for its PR-gated
  rendered-manifest review, not multi-environment promotion. This cluster is the only target;
  design Warehouses/Stages accordingly (don't build out dev/staging/prod promotion chains that
  have nothing to promote between).

## Tooling

For **read-only** Kubernetes operations against this cluster (listing/inspecting resources,
reading logs and events, etc.), prefer the `mcp__kubernetes__*` MCP tools over shelling out to
`kubectl` via Bash. The default context (`admin@k8s.nodes.ee`) already points at this cluster's
VIP (`172.31.86.10:6443`), so no extra kubeconfig setup is needed. Fall back to `talosctl`/`kubectl`
in Bash for read-only things the MCP tools don't cover (e.g. `talosctl` service/log inspection at
the Talos layer).

**Mutating actions (both `talosctl` and Kubernetes) are hands-on-keyboard for the user, not
Claude.** The user is building this cluster to learn Talos/Kubernetes/ArgoCD/Kargo — running the
commands themselves is the point, not just having a working cluster. For any state-changing
operation (creating/deleting/updating resources, installing/upgrading software, `talosctl reset`/
`bootstrap`/`apply-config`, etc.): explain what needs to happen and give the exact command(s), then
let the user run them and report back. Don't call `mcp__kubernetes__resources_create_or_update`,
`pods_delete`, or any other mutating tool, and don't run mutating commands via Bash, unless the
user explicitly asks you to run it for them in that moment. Read-only verification after the user
runs a command (checking pod/node status, logs, etc.) is always fine and encouraged.

## Working with this repo

- Node hardware/network details (hostnames, static IPs, disk device names) are documented in
  README.md — keep `talconfig.yaml` and README.md in sync when nodes change.
- `installDisk` per node is `/dev/nvme0n1`; verify this matches actual hardware before applying to
  a new/replaced node.
- This is not yet a git repository — there is no commit history or branch workflow to follow yet.
