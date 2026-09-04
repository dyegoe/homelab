# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo sets up a homelab Kubernetes cluster running on Talos Linux. The cluster itself was
bootstrapped manually (see README.md note on the pre-GitOps bootstrap process). GitOps via ArgoCD
is live — ArgoCD manages its own installation plus an addon App-of-Apps (see "GitOps architecture"
below and README.md's `GitOps` section for the full runbook). [Kargo](https://kargo.io/) is live too,
scoped to standalone applications this cluster hosts (the personal website is the first, and the
reference example — see README.md's `Kargo` section) where it does real multi-environment
promotion — not the cluster addons, which have no dev/prd split and get automated version-bump PRs
from [Renovate](https://docs.renovatebot.com/) (see `renovate.json`).

## Architecture

- `talos/topf.yaml` — the single source of truth for cluster topology, consumed by
  [`topf`](https://github.com/postfinance/topf) to render and apply per-node Talos machine configs.
  Defines the cluster name/endpoint, Talos/Kubernetes versions, the image schematic reference
  (`talos/schematic.yaml`, hashed locally into `schematicId`), and the three physical nodes
  (`host`/`ip`/`role: control-plane`).
- `talos/secrets.yaml` — SOPS-encrypted Talos secrets bundle (cluster CA/tokens/keys). Never
  regenerate this for an existing cluster — it holds the cluster's actual cryptographic identity;
  losing/replacing it breaks trust for every existing node, Secret, and credential.
- `talos/all/`, `talos/control-plane/` — topf patch directories, one file per document, applied in
  filename order (`01-`, `02-`, … prefixes control ordering). `all/` applies to every node,
  `control-plane/` to control-plane-role nodes only (this cluster has no `worker/` — all 3 nodes are
  control-plane). A `.tpl` suffix enables Go templating (`{{ .Node.Host }}`, `{{ .KubernetesVersion }}`,
  etc.) — see `topf`'s own `configuration-model.md` docs for the full template context.
  `$patch: delete` on a document (or a specific map key, e.g. one taint) removes something `topf`
  auto-generates by default — used here for `UnattendedInstallConfig` (keeping the legacy
  `machine.install` form, since the disk/image/wipe fields still work and this cluster predates the
  newer typed doc) and `KubeletConfig` (keeping legacy `machine.kubelet`, since the typed doc has no
  equivalent for `extraMounts`, needed for Longhorn's bind mount).
- There is no generated-output directory to gitignore — `topf render -o <dir>` writes to whatever
  directory you point it at (for local inspection only, never commit it), and `topf apply` talks to
  the live nodes directly without an intermediate generated-file step.
- The cluster is a 3-node, all-control-plane topology (no legacy `allowSchedulingOnMasters` field —
  handled via `all/02-scheduling.yaml` deleting the default control-plane `NoSchedule` taint) on
  VLAN 86 (`172.31.86.0/24`), fronted by a Talos VIP at `172.31.86.10` for the Kubernetes API.

## Common commands

Run from the `talos/` directory. Per the mutating-actions rule below, `apply`/`upgrade` are for the
user to run — Claude renders/dry-runs for review, never applies.

```bash
# Render machine configs locally for inspection (no cluster contact) — the day-to-day way to review
# a patch change before applying it
topf render -o /tmp/topf-check --redact=false

# Preview what a real apply would change against the live cluster (read-only, never mutates)
topf apply --dry-run --nodes-filter '<hostname>' --confirm=false

# Apply a reviewed change to the live cluster (mutating — user runs this)
topf apply --nodes-filter '<hostname>'
```

**Changing a config**: edit the relevant file under `all/`/`control-plane/` (or `topf.yaml` itself),
`render` to inspect the generated output, `apply --dry-run` against the live cluster to confirm the
diff is exactly what you expect, then `apply` for real. One node at a time for anything riskier than
a label/log-destination tweak — this cluster's own migration surfaced real footguns (a taint that
would have made every node unschedulable, a kubelet-config conflict) that only showed up in the
`apply --dry-run` diff, not in a local `render`.

Applying config to a freshly-booted (insecure/maintenance-mode) node — `topf` detects maintenance
mode automatically, no `--insecure` flag needed:

```bash
topf apply --auto-bootstrap
```

Use `topf talosconfig > talosconfig` (then `export TALOSCONFIG=$(pwd)/talosconfig`, or copy to
`~/.talos/config`) for subsequent authenticated `talosctl` operations. `topf kubeconfig` generates a
12-hour admin kubeconfig — fine for ad-hoc access, but not a substitute for whatever
longer-lived/GitOps-managed kubeconfig normally drives `kubectl`.

## GitOps architecture

Full runbook (bootstrap from zero, the Application template, how to add a new addon) lives in
README.md's `GitOps` section — that's the canonical reference. Summary for quick orientation:

- `argocd/kustomization.yaml` is a **flat list** of top-level Applications, applied once
  (`kubectl apply -k argocd/ --server-side`) to bootstrap. There is no separate "root" Application.
- `argocd/argocd.yaml` — ArgoCD manages its **own installation** (source: `argocd/install/`, which
  tracks the upstream `install.yaml` at a pinned tag via a Kustomize remote resource). Upgrading
  ArgoCD is a git change (bump the tag), never a manual `kubectl apply` again after bootstrap.
- `argocd/addons.yaml` — the addon **App-of-Apps** (source: `argocd/addons/`, listing one `Application`
  per addon, e.g. `cilium.yaml`, `gateway-crds.yaml`). App-of-Apps, not ApplicationSet — this is a
  single 3-node cluster with a small, deliberate addon list, not a dynamic multi-cluster/
  multi-tenant fleet.
- Addon Helm values live in `addons/<name>/helm/values.yaml` — real, standalone YAML, one `helm/`
  subdirectory per app. This is **not** because inline `valuesObject` is undiffable — it's equally
  visible in `git diff`/PR review, since the `Application` object is itself git-tracked. The actual
  hard rule is never a wall of imperative `helm --set` flags, which get no diff at all (this was the
  real cause of a real incident on this cluster: a wrong `k8sServiceHost` value shipped via `--set`
  and took an hour to diagnose, because nothing rendered a reviewable diff before it reached the
  cluster). A standalone values file is still worth it on its own merits: local tooling (`helm
template`/`lint`/`diff` work directly against it) and review signal (a values change and
  `Application`-plumbing change don't get bundled in the same file/diff) — also what makes
  Renovate's automated version-bump PRs (see `renovate.json`) produce a clean, reviewable diff.
  Extra plain manifests an addon needs
  beyond its Helm chart (e.g. Cilium's BGP/LoadBalancerIPPool/HTTPRoute config) go in a sibling
  `addons/<name>/kustomization.yaml` (app-level, not under `helm/`), added as a third, non-`ref`
  source on the same `Application` — see `gateway-crds.yaml` for the same idea applied to a
  no-Helm-chart addon (sourced straight from the upstream repo's manifest directory).
- **Adopting a resource already running from a manual `helm install`** (as Cilium was): leave
  `syncPolicy.automated` off on first commit, sync once manually, confirm the diff is clean, only
  then enable `automated: {prune: true, selfHeal: true}` in a follow-up commit.
- Everything lives in this same repo — no separate `homelab-gitops` repo.
- **Kargo**: scoped to standalone applications hosted on this cluster, each with its own `dev`/`prd`
  namespaces — a real Warehouse → Stage → Stage promotion chain with verification gates, which is
  what Kargo is actually built for. Provisioned per app via the reusable `charts/tenant` Helm chart
  (one `apps/<name>/config.json` per app); the website app (`apps/website/`) is live end-to-end and
  is the reference example — see README.md's `Kargo` section for the add-a-new-app steps and the
  accumulated gotchas (numeric-looking tags, shared-branch health checks, image tag selection).
  **Not** used for the cluster addons in `argocd/addons/` — there's no dev/prd split for infra, and
  a git PR already gives the same rendered-diff review Kargo's `hydrateTo` would add. Addon version
  bumps come via Renovate-opened PRs (see `renovate.json`) — don't wire addons into Kargo
  Warehouses/Stages.

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
  item when its trigger condition is met (e.g. a `kubernetesVersion` bump in `topf.yaml`) rather
  than waiting to be asked. When closing out a similar investigation in the future, add a same-shaped
  entry (root cause, upstream link, explicit recheck trigger) instead of only reporting it in chat.
- Node hardware/network details (hostnames, static IPs, disk device names) are documented in
  README.md — keep `topf.yaml` and README.md in sync when nodes change.
- `installDisk` per node is `/dev/nvme0n1`; verify this matches actual hardware before applying to
  a new/replaced node.
- `origin` is `git@github.com:dyegoe/homelab.git`, branch `main`. ArgoCD's repo-access secret uses
  the HTTPS form of the same URL (`https://github.com/dyegoe/homelab.git`) — keep that in mind if
  the remote or credential type ever changes, since ArgoCD matches credentials by URL.
