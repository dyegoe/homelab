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

- **Omni manages Talos** (SaaS, cluster `k8s-nodes-ee`, imported 2026-10-20; see README.md's
  `Omni (cluster management)`). `talos/cluster.yaml` is an Omni **cluster template** and the
  source of truth: Talos/Kubernetes versions, system extensions, the three machines, config patches
  and upgrade healthchecks. It references `talos/patches/` (raw Talos strategic-merge patches;
  multi-document files are fine, and `idOverride` keeps the ConfigPatch IDs stable),
  `talos/healthchecks/` (Jobs that gate each node of a Talos upgrade) and `talos/manifests/`
  (Kubernetes objects Omni syncs for those Jobs). File paths resolve against `talos/`.
- Don't edit the cluster in the Omni UI or with `omnictl apply`: `sync` creates, updates and deletes
  what the template owns, so out-of-band changes get overwritten.
- The topf era (`talos/topf.yaml`, `talos/all/`, `talos/control-plane/`, SOPS `talos/secrets.yaml`)
  was removed; it lives at commit `473d3cf`. Never run `topf apply` against this cluster. That
  commit's `secrets.yaml` still holds the etcd secretbox key in use: never regenerate it.
- `$patch: delete` on a document (or a map key, e.g. the `taints` list) removes something Talos
  generates by default: used for `KubeFlannelCNIConfig` (Cilium is the CNI) and the control-plane
  `NoSchedule` taint.
- Kubernetes components use the Talos 1.14 typed documents, never the legacy v1alpha1 fields
  (`machine.kubelet`, `cluster.apiServer`, ...): Omni's Kubernetes upgrades patch the typed docs, and
  Talos rejects a typed doc next to its legacy block (see #173). The kubelet is a typed
  `KubeletConfig` with no image pin, and Longhorn's `/var/mnt/longhorn` is a `directory`
  `UserVolumeConfig` (the kubelet already sees `/var/mnt`, so no `extraMounts`).
- The cluster is a 3-node, all-control-plane topology on VLAN 86 (`172.31.86.0/24`), fronted by a
  Talos VIP at `172.31.86.10` for the Kubernetes API.

## Common commands

`omnictl` reads `~/.talos/omni/config`; the first call after the auth key expires opens a browser to
re-authenticate. Per the mutating-actions rule below, `sync` is for the user to run: Claude
validates and diffs.

```bash
omnictl cluster template validate -f talos/cluster.yaml   # offline schema check
omnictl cluster template diff -f talos/cluster.yaml       # read-only diff against live Omni state
omnictl cluster template sync -f talos/cluster.yaml       # mutating: user runs this
omnictl cluster template export -c k8s-nodes-ee           # read-only: live state as a template
omnictl get talosupgradestatus k8s-nodes-ee -o yaml       # upgrade progress / healthcheck holds
```

**Changing a config**: edit `talos/cluster.yaml` or a file it references, `validate`, then `diff`
and check it shows exactly the intended change before handing over `sync`. Control planes can't be
locked, so a patch change rolls across all 3 nodes one at a time. Never put a change to
`talos/patches/no-kexec.yaml` in the same sync as a Talos upgrade (Omni applies the upgrade first).

**Upgrading Talos or Kubernetes**: full runbook in README.md's `Cluster Upgrades` section. Summary:
`talos.version` / `kubernetes.version` in `talos/cluster.yaml` upgrade independently; Renovate opens
the bump PRs, and the upgrade happens on `sync`, not on merge. Check the Talos support matrix
before a Kubernetes bump.

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
`kubectl` via Bash. The default context is `nodes-k8s-nodes-ee` (Omni's OIDC proxy; pass
`context: nodes-k8s-nodes-ee` to the MCP tools if their configured default differs). The old VIP
admin context died with the 2026-10-26 CA rotation; the break-glass kubeconfig in 1Password (see
README's `Omni` section, `break-glass/`) is for Omni outages only. Fall back to `talosctl`/`kubectl`
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

- **Deferred work, known issues and accepted gaps live in GitHub issues**
  (`gh issue list -R dyegoe/homelab`), not in repo files: there is no `ROADMAP.md`/`TODO.md`, so
  don't create one. Issues labelled `known-issue` carry an explicit recheck trigger (e.g. "the next
  Talos upgrade", "a Longhorn chart bump", "ESO bumps onepassword-sdk-go past v0.4.1"). Before
  starting related work (an upgrade, a Renovate PR for an addon), check the open issues for that
  area (labels `talos`, `longhorn`, `observability`, `external-secrets`, `kargo`) and proactively
  suggest rechecking an item whose trigger has fired, rather than waiting to be asked. When an
  investigation ends with "nothing to do until X", open (or update) an issue with symptom, root
  cause, upstream links and the recheck trigger instead of only reporting it in chat.
  Decided-against items are closed as _not planned_.
- README.md still holds the long-form write-ups (root cause, evidence, runbook) for known issues,
  e.g. the Longhorn snapshot and ESO WASM entries. Each links to its tracking issue; keep both in
  sync when an issue's status changes.
- Pushing changes: `main` is protected (1 approval + the `check-pull-request` check), so always
  create a branch, push it, and open a PR; never push to `main` directly.
- Node hardware/network details (hostnames, static IPs, disk device names) are documented in
  README.md — keep `talos/cluster.yaml` and README.md in sync when nodes change.
- A new or replaced node's `Machine` document gets `install.disk: /dev/nvme0n1`; verify this
  matches the actual hardware before the sync.
- `origin` is `git@github.com:dyegoe/homelab.git`, branch `main`. ArgoCD's repo-access secret uses
  the HTTPS form of the same URL (`https://github.com/dyegoe/homelab.git`) — keep that in mind if
  the remote or credential type ever changes, since ArgoCD matches credentials by URL.
