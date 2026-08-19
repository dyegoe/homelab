# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo sets up a homelab Kubernetes cluster running on Talos Linux. The cluster itself was
bootstrapped manually (see README.md note on the pre-GitOps bootstrap process). GitOps via ArgoCD
is live — ArgoCD manages its own installation plus an addon App-of-Apps (see "GitOps architecture"
below and README.md's `GitOps` section for the full runbook). [Kargo](https://kargo.io/) is planned
but not yet implemented, scoped to standalone applications this cluster will host (e.g. a personal
website with `dev`/`prd` namespaces) where it does real multi-environment promotion — not the
cluster addons, which have no dev/prd split and bump versions via a plain git PR (manually, or later
via Renovate).

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

## GitOps architecture

Full runbook (bootstrap from zero, the Application template, how to add a new addon) lives in
README.md's `GitOps` section — that's the canonical reference. Summary for quick orientation:

- `argocd/kustomization.yaml` is a **flat list** of top-level Applications, applied once
  (`kubectl apply -k argocd/ --server-side`) to bootstrap. There is no separate "root" Application.
- `argocd/argocd.yaml` — ArgoCD manages its **own installation** (source: `argocd/install/`, which
  tracks the upstream `install.yaml` at a pinned tag via a Kustomize remote resource). Upgrading
  ArgoCD is a git change (bump the tag), never a manual `kubectl apply` again after bootstrap.
- `argocd/apps.yaml` — the addon **App-of-Apps** (source: `argocd/apps/`, listing one `Application`
  per addon, e.g. `cilium.yaml`, `gateway-crds.yaml`). App-of-Apps, not ApplicationSet — this is a
  single 3-node cluster with a small, deliberate addon list, not a dynamic multi-cluster/
  multi-tenant fleet.
- Addon Helm values live in `apps/<name>/helm/values.yaml` — real, standalone YAML, one `helm/`
  subdirectory per app. This is **not** because inline `valuesObject` is undiffable — it's equally
  visible in `git diff`/PR review, since the `Application` object is itself git-tracked. The actual
  hard rule is never a wall of imperative `helm --set` flags, which get no diff at all (this was the
  real cause of a real incident on this cluster: a wrong `k8sServiceHost` value shipped via `--set`
  and took an hour to diagnose, because nothing rendered a reviewable diff before it reached the
  cluster). A standalone values file is still worth it on its own merits: local tooling (`helm
template`/`lint`/`diff` work directly against it) and review signal (a values change and
  `Application`-plumbing change don't get bundled in the same file/diff) — also what would make an
  automated version-bump tool (e.g. Renovate) produce a clean, reviewable diff if one is added
  later. Extra plain manifests an addon needs
  beyond its Helm chart (e.g. Cilium's BGP/LoadBalancerIPPool/HTTPRoute config) go in a sibling
  `apps/<name>/kustomization.yaml` (app-level, not under `helm/`), added as a third, non-`ref`
  source on the same `Application` — see `gateway-crds.yaml` for the same idea applied to a
  no-Helm-chart addon (sourced straight from the upstream repo's manifest directory).
- **Adopting a resource already running from a manual `helm install`** (as Cilium was): leave
  `syncPolicy.automated` off on first commit, sync once manually, confirm the diff is clean, only
  then enable `automated: {prune: true, selfHeal: true}` in a follow-up commit.
- Everything lives in this same repo — no separate `homelab-gitops` repo.
- **Kargo** (not yet implemented): scoped to standalone applications hosted on this cluster (e.g. a
  personal website), each with its own `dev`/`prd` namespaces — a real Warehouse → Stage → Stage
  promotion chain with verification gates, which is what Kargo is actually built for. **Not** used
  for the cluster addons in `argocd/apps/` — there's no dev/prd split for infra, and a git PR
  already gives the same rendered-diff review Kargo's `hydrateTo` would add. Addon version bumps
  stay a manual git PR, or later via Renovate if that becomes worth adding — don't wire addons into
  Kargo Warehouses/Stages.

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

- README.md is the source of truth for known issues and deferred items, not just setup steps —
  e.g. the `Observability` section's "Known log noise" entry tracks a `kube-apiserver`/etcd log-noise
  issue with an explicit recheck trigger (bump `kubernetesVersion` past a given version). Skim the
  relevant README section before starting related work, and proactively suggest rechecking a tracked
  item when its trigger condition is met (e.g. a `kubernetesVersion` bump in `talconfig.yaml`) rather
  than waiting to be asked. When closing out a similar investigation in the future, add a same-shaped
  entry (root cause, upstream link, explicit recheck trigger) instead of only reporting it in chat.
- Node hardware/network details (hostnames, static IPs, disk device names) are documented in
  README.md — keep `talconfig.yaml` and README.md in sync when nodes change.
- `installDisk` per node is `/dev/nvme0n1`; verify this matches actual hardware before applying to
  a new/replaced node.
- `origin` is `git@github.com:dyegoe/homelab.git`, branch `main`. ArgoCD's repo-access secret uses
  the HTTPS form of the same URL (`https://github.com/dyegoe/homelab.git`) — keep that in mind if
  the remote or credential type ever changes, since ArgoCD matches credentials by URL.
