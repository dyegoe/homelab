# Homelab

A three-node bare-metal Kubernetes cluster on [Talos Linux](https://www.talos.dev/), managed end to
end from this repository: the Talos machine configs, every cluster addon, and multi-environment
promotion for the applications it hosts. After the one-time bootstrap, a cluster change is a git
commit — Talos machine-config changes are the main thing still pushed from a workstation
(`topf apply`), and those come from files in this repo too.

I run it to learn, and to have somewhere real to break things. It hosts my personal website and a
couple of side projects, and this README doubles as the runbook I actually operate from, so it is
long and specific on purpose: incidents, gotchas, and the reasoning behind each decision are
written down next to the thing they apply to.

## Stack at a glance

| Layer         | What                                                                                             | Notes                                                                                                                                                    |
| ------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OS            | Talos Linux, SecureBoot, all three nodes control-plane                                           | Machine configs rendered and applied with [`topf`](https://github.com/postfinance/topf) from `talos/topf.yaml`; the secrets bundle is SOPS/age-encrypted |
| Networking    | Cilium (kube-proxy replacement, native routing), Gateway API, BGP peering with a Mikrotik router | LoadBalancer IPs are advertised over BGP, not L2                                                                                                         |
| GitOps        | ArgoCD (self-managed), App-of-Apps for addons, ApplicationSet + `charts/tenant` for hosted apps  | [Renovate](https://docs.renovatebot.com/) opens the version-bump PRs                                                                                     |
| Delivery      | Kargo + Argo Rollouts                                                                            | Warehouse → `dev` (automatic) → `prd` (manual approval), provisioned per app from one `config.json`                                                      |
| Secrets       | External Secrets Operator backed by 1Password; Sealed Secrets for the single bootstrap token     | Reloader restarts consumers on rotation                                                                                                                  |
| Edge          | cert-manager (Let's Encrypt, Cloudflare DNS-01), external-dns, Cloudflare Tunnel                 | Internal services share one wildcard cert, terminated at the Gateway                                                                                     |
| Storage       | Longhorn, CloudNativePG                                                                          |                                                                                                                                                          |
| Observability | kube-prometheus-stack, Loki, Alloy (pod logs + Talos host logs), Alertmanager → Telegram         | Addons with a live Prometheus target ship their own Grafana dashboard as a `ConfigMap`                                                                   |

Versions are pinned where ArgoCD and `topf` read them (`argocd/addons/*.yaml`,
`argocd/install/kustomization.yaml`, `talos/topf.yaml`), not repeated here — Renovate keeps those
moving, and a version table in a README only rots.

## Worth reading

If you are here to see how things are done rather than to operate the cluster, start with:

- [GitOps](#gitops) — why Helm values are always files and never `--set` flags: the incident that
  made it a rule, and how the same structure is what makes Renovate's PRs reviewable.
- [Bootstrap (from zero)](#bootstrap-from-zero) — the imperative day-0 minimum, and the handover
  after which nothing is applied by hand again.
- [Kargo](#kargo) and the [gotchas accumulated building the first app](#adding-a-new-standalone-app-via-kargo)
  — real multi-environment promotion, including the failures that only showed up live: a CI
  feedback loop, a health check that flipped Stages unhealthy, and an RBAC watch that could never
  succeed.
- [External Secrets Operator](#external-secrets-operator) — the migration off the 1Password
  Operator, and the silent-field gotcha that took ArgoCD's own repo access down mid-migration.
- [Observability](#observability) — the CRD split that avoids a sync-order deadlock, and which
  upstream dashboards were rebuilt rather than ported, and why.
- [Known log noise](#known-log-noise-resolved-in-kubernetes-v137) (closed) and the
  [ESO known issue](#known-issue-sdk-wasm-instance-wedges-after-a-network-error-recheck-when-onepassword-sdk-go-moves-past-v041)
  (open) — tracked issues with an explicit recheck trigger, the pattern this repo uses for deferred
  items.

## Repository layout

```text
talos/            # topf topology (topf.yaml), image schematic, SOPS-encrypted secrets, per-node patches
argocd/           # ArgoCD bootstrap: its own install, the addon App-of-Apps, the tenant ApplicationSet
addons/<name>/    # one directory per addon: helm/values.yaml, extra manifests, Grafana dashboards
apps/<name>/      # one config.json per hosted application, consumed by charts/tenant
charts/tenant/    # Helm chart provisioning a tenant app: ArgoCD Applications + Kargo Project/Warehouse/Stages
scripts/          # pre-commit helper (kustomize build + kubeconform validation)
renovate.json     # automated version bumps for charts, images, and the ArgoCD install tag
ROADMAP.md        # deferred and considered changes
```

## Table of Contents

- [Homelab](#homelab)
  - [Stack at a glance](#stack-at-a-glance)
  - [Worth reading](#worth-reading)
  - [Repository layout](#repository-layout)
  - [Table of Contents](#table-of-contents)
  - [Initial Cluster Setup](#initial-cluster-setup)
    - [Hardware Specifications](#hardware-specifications)
    - [Network configuration](#network-configuration)
    - [Talos Linux installation](#talos-linux-installation)
    - [Network CNI](#network-cni)
  - [GitOps](#gitops)
    - [Architecture](#architecture)
    - [Bootstrap (from zero)](#bootstrap-from-zero)
    - [Adding a new Application (the pattern)](#adding-a-new-application-the-pattern)
    - [Adopting existing (non-GitOps) resources](#adopting-existing-non-gitops-resources)
    - [Standalone apps (ApplicationSet)](#standalone-apps-applicationset)
    - [Current Applications](#current-applications)
    - [Renovate](#renovate)
    - [Kargo](#kargo)
    - [Adding a new standalone app via Kargo](#adding-a-new-standalone-app-via-kargo)
    - [Rotating the ArgoCD repo credential](#rotating-the-argocd-repo-credential)
    - [Forcing an immediate refresh (GitHub webhook)](#forcing-an-immediate-refresh-github-webhook)
  - [Advanced Networking](#advanced-networking)
    - [Mikrotik BGP configuration](#mikrotik-bgp-configuration)
  - [External Secrets Operator](#external-secrets-operator)
    - [Installation](#installation)
    - [How to use](#how-to-use)
    - [Known gotcha: URLs, Notes, and Sections aren't extracted](#known-gotcha-urls-notes-and-sections-arent-extracted)
    - [Creating a docker-registry (imagePullSecret) item](#creating-a-docker-registry-imagepullsecret-item)
    - [Migrating a bootstrap secret to External Secrets Operator](#migrating-a-bootstrap-secret-to-external-secrets-operator)
    - [Known issue: SDK WASM instance wedges after a network error (recheck when onepassword-sdk-go moves past v0.4.1)](#known-issue-sdk-wasm-instance-wedges-after-a-network-error-recheck-when-onepassword-sdk-go-moves-past-v041)
  - [Observability](#observability)
    - [Architecture](#architecture-1)
    - [Accessing Grafana](#accessing-grafana)
    - [Viewing logs](#viewing-logs)
    - [Alerting (Telegram)](#alerting-telegram)
    - [Metrics dashboards](#metrics-dashboards)
    - [Known log noise (resolved in Kubernetes v1.37)](#known-log-noise-resolved-in-kubernetes-v137)
  - [Bootstrap sequence summary](#bootstrap-sequence-summary)
  - [Development (pre-commit hooks)](#development-pre-commit-hooks)

## Initial Cluster Setup

> **Note**: This section documents the manual bootstrap process performed before GitOps is established.

### Hardware Specifications

- `kihnu.nodes.ee`: HP EliteDesk 800 G2
  - CPU: i5-6500 4 CPUs @ 3.20GHz
  - RAM: 32 GB
  - NVMe SSD: 1 TB (`/dev/nvme0n1`) SAMSUNG MZVLB1T0HALR-000H2
- `muhu.nodes.ee`: HP EliteDesk 800 G2
  - CPU: i5-6500T 4 CPUs @ 2.50GHz
  - RAM: 32 GB
  - NVMe SSD: 1 TB (`/dev/nvme0n1`) SAMSUNG MZVLB1T0HALR-000H2
- `ruhnu.nodes.ee`: Lenovo ThinkCentre M910q
  - CPU: i5-6500T 4 CPUs @ 2.50GHz
  - RAM: 32 GB
  - NVMe SSD: 1 TB (`/dev/nvme0n1`) KINGSTON SNV2S1000G

### Network configuration

- Network gateway: Mikrotik Chateau 5G AX, Router OS 7.23.3
- Network switch: Mikrotik CSS336-24G-RM, SwOS v2.18
- VLAN 86 CIDR: 172.31.86.0/24
  - Gateway: 172.31.86.1
- VIP for API server: 172.31.86.10 (k8s.nodes.ee)
- Static DHCP lease for nodes
  - 172.31.86.11 (kihnu.nodes.ee)
  - 172.31.86.12 (muhu.nodes.ee)
  - 172.31.86.13 (ruhnu.nodes.ee)
- Cilium BGP peering with Mikrotik router — see [Advanced Networking](#advanced-networking)

### Talos Linux installation

The installer image comes from the [Talos Image Factory](https://factory.talos.dev/), built from
`talos/schematic.yaml`: bare-metal, `amd64`, SecureBoot, plus the `siderolabs/iscsi-tools` and
`siderolabs/util-linux-tools` system extensions Longhorn needs. `topf` hashes that file into the
schematic ID itself (`schematicId: "@schematic.yaml"` in `talos/topf.yaml`), so the ID never has to
be copied around by hand; the Talos release to pair it with is `talosVersion` in the same file.

To get a bootable installer, open the factory, choose the same options (platform `bare-metal`, the
`talosVersion` from `topf.yaml`, `amd64` with SecureBoot on, the two extensions above), and download
the SecureBoot ISO. Write it to a USB stick:

```bash
sudo dd if=metal-amd64-secureboot.iso of=/dev/sdX bs=4M status=progress && sync
```

Workstation tooling: [`talosctl`](https://www.talos.dev/latest/introduction/getting-started/)
(`curl -sL https://talos.dev/install | sudo sh`), [`topf`](https://github.com/postfinance/topf),
[`age`](https://github.com/FiloSottile/age), and [`sops`](https://github.com/getsops/sops/releases).

`talos/.sops.yaml` is tracked and carries the age **public** key `talos/secrets.yaml` is encrypted
to. The matching private key lives only in `$XDG_CONFIG_HOME/sops/age/keys.txt` on the operator's
workstation — back it up: without it `secrets.yaml` can't be decrypted and no further machine
configs can be rendered for this cluster. When forking this repo for a cluster of your own, generate
a new key pair and swap the recipient in `.sops.yaml` before generating secrets:

```bash
mkdir -p $XDG_CONFIG_HOME/sops/age
age-keygen -o $XDG_CONFIG_HOME/sops/age/keys.txt   # prints the public key - put it in talos/.sops.yaml
```

Generate and encrypt the secrets bundle **once per cluster**. Never regenerate it for an existing
cluster: it holds the cluster CA and the tokens every node, Secret, and credential trusts.

```bash
cd talos
topf secrets --confirm=false > secrets.yaml   # prompts before overwriting an existing bundle
sops -e -i secrets.yaml
```

Now you can boot Talos on each node from the USB stick. `topf` detects maintenance-mode
(insecure/unconfigured) nodes automatically — no `--insecure` flag needed — and folds config
generation, apply, and cluster bootstrap into one step:

```bash
topf apply --auto-bootstrap
```

Save a `talosconfig` for subsequent authenticated `talosctl` operations:

```bash
topf talosconfig > talosconfig
export TALOSCONFIG=$(pwd)/talosconfig
# or: cp talosconfig ~/.talos/config
```

Generate an admin kubeconfig (valid 12 hours — regenerate as needed, or hand off to whatever
longer-lived/GitOps-managed kubeconfig normally drives `kubectl` from here on):

```bash
topf kubeconfig > ~/.kube/config
```

> **Why `topf`, not `talhelper`**: this cluster originally used
> [`talhelper`](https://github.com/budimanjojo/talhelper) to generate Talos configs. It was archived
> and abandoned upstream on 2026-08-26, and its pinned `v3.1.17` vendors a pre-release
> `siderolabs/talos/pkg/machinery` missing an upstream fix — which generated `KubeEtcdEncryptionConfig`
> with the wrong secretbox key name (`key1` instead of the historically-correct `key2`) during the
> Talos v1.14.0 multi-doc config migration, breaking `kube-apiserver`'s ability to decrypt existing
> etcd Secrets on one node until manually patched. `topf` depends on the released `machinery v1.14.0`
> (fix included) and is actively maintained — see `ROADMAP.md`'s history for the migration.

You can follow the cluster initialization progress by running the following commands:

```bash
# Check the status of the nodes
talosctl get nodestatuses

# Check the status of the members and their versions, roles, etc.
talosctl get members

# Check the status of the cluster
talosctl dashboard

# You should be able to call kubectl commands now
kubectl get nodes
```

### Network CNI

Talos comes up with no CNI here — `talos/control-plane/02-kubeflannel-delete.yaml` removes the
default Flannel and `03-kubeproxy.yaml` disables kube-proxy, since Cilium replaces both — so nodes
stay `NotReady` until Cilium is installed. ArgoCD can't do that first install: its own pods need a
working pod network. Cilium is therefore the one addon that gets an imperative first install, which
ArgoCD then adopts once it is running (see
[Adopting existing (non-GitOps) resources](#adopting-existing-non-gitops-resources)).

Install it from the **same values file ArgoCD will use**, `addons/cilium/helm/values.yaml`, at the
chart version pinned in `argocd/addons/cilium.yaml` — never from a hand-typed list of `--set`
flags; the [GitOps](#gitops) section explains the incident behind that rule. The only overrides are
the four `ServiceMonitor` toggles: those CRDs don't exist until `prometheus-operator-crds` syncs,
so the chart would fail to apply them on a fresh cluster. ArgoCD switches them back on when it
adopts the release.

```bash
# Gateway API CRDs first - Cilium's Gateway API support needs them present at install time.
GATEWAY_API_TAG=$(grep -m1 targetRevision argocd/addons/gateway-crds.yaml | awk '{print $2}')
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_TAG}/experimental-install.yaml

# Cilium, from the repo's values file at the pinned chart version.
CILIUM_VERSION=$(grep -m1 targetRevision argocd/addons/cilium.yaml | awk '{print $2}')
helm repo add cilium https://helm.cilium.io/ && helm repo update
helm install cilium cilium/cilium \
  --namespace kube-system \
  --version "${CILIUM_VERSION}" \
  -f addons/cilium/helm/values.yaml \
  --set prometheus.serviceMonitor.enabled=false \
  --set envoy.prometheus.serviceMonitor.enabled=false \
  --set operator.prometheus.serviceMonitor.enabled=false \
  --set hubble.metrics.serviceMonitor.enabled=false

cilium status --wait
```

BGP peering with the router, the LoadBalancer IP pool, and the Hubble UI route are plain manifests
under `addons/cilium/` and arrive with the `cilium` `Application` — see
[Advanced Networking](#advanced-networking).

## GitOps

This cluster is managed via [ArgoCD](https://argo-cd.readthedocs.io/), including its own
installation — ArgoCD manages itself. [Kargo](https://kargo.io/) is installed on top of this for
multi-environment promotion of standalone applications hosted here (e.g. a personal website with
`dev`/`prd` namespaces) — not for the cluster addons below; see [Kargo](#kargo). The website app is
live end-to-end (Warehouse → `dev` auto-promotion → manual `prd` promotion) and is the reference
example for adding further standalone apps.

Principles:

- **App-of-Apps** for the addon bundle (Cilium, observability, etc.) — a small, deliberate
  list. Addons don't need an ApplicationSet generator: there's no per-addon matrix (no dev/prd,
  no per-cluster variance) to expand, just a fixed list a human edits.
- **ApplicationSet** (`argocd/apps-applicationset/applicationset.yaml`, kept in sync from git by
  the `apps-applicationset` `Application` that wraps it — see the table below) for standalone
  hosted apps (the personal website, a couple of side projects). Its git generator turns each
  `apps/<name>/config.json` into one `Application` that installs `charts/tenant`, which in turn
  renders the app's `dev`/`prd` `Application`s plus its Kargo Project/Warehouse/Stages. This _is_
  the dynamic-expansion case ApplicationSet is for: every app needs the same shape, and Kargo
  promotes Freight between the generated `Application`s — see
  [Standalone apps (ApplicationSet)](#standalone-apps-applicationset) below.
- Helm values live in `addons/<app>/helm/values.yaml` — real, standalone YAML — rather than inlined
  as `valuesObject` in the `Application` CRD. Both are equally visible in `git diff`/PR review,
  since the `Application` object is itself git-tracked; the actual hard requirement is **never** a
  wall of imperative `helm --set` flags, which get no diff at all. A standalone file still earns
  its keep on tooling (`helm template`/`helm lint`/`helm diff` work directly against it, no
  extraction needed) and review signal (a values change and `Application`-plumbing change — sync
  policy, `ignoreDifferences`, sync-wave — don't get bundled into the same file/diff) — the same
  structure is also what makes [Renovate](https://docs.renovatebot.com/)'s automated version-bump
  PRs (see `renovate.json`, and [Renovate](#renovate) below) produce a clean, reviewable diff.
- Everything — including ArgoCD's own install — lives in this one repo. No separate
  `homelab-gitops` repo.

### Architecture

```text
argocd/
├── kustomization.yaml       # flat list of top-level Applications, applied once to bootstrap
├── argocd.yaml              # Application: ArgoCD's own installation (self-managed)
├── install/
│   ├── kustomization.yaml      # tracks the upstream install.yaml (pinned tag) as a remote resource
│   ├── appproject-addons.yaml  # AppProject: addons (wildcard-permissive by design)
│   └── appproject-apps.yaml    # AppProject: apps (least-privilege resource whitelist)
├── addons.yaml               # Application: the addon App-of-Apps
├── apps-applicationset.yaml  # Application: self-syncs apps-applicationset/ below
├── apps-applicationset/
│   ├── kustomization.yaml
│   └── applicationset.yaml  # ApplicationSet: one charts/tenant Application per apps/*/config.json
└── addons/
    ├── kustomization.yaml   # lists every addon Application
    ├── cilium.yaml          # Application: Cilium (multi-source: Helm chart + this repo's values)
    └── gateway-crds.yaml    # Application: Gateway API CRDs, sourced directly from the upstream repo

addons/
└── cilium/
    └── helm/
        └── values.yaml      # Cilium Helm values (source of truth, never inlined)

apps/
└── website/                 # one dir per standalone app
    └── config.json          # appName/repoURL/imageURL/onepassword.* - charts/tenant's values, found by the git generator

charts/
└── tenant/                  # Helm chart: <app>-dev/<app>-prd Applications + Kargo Project/Warehouse/Stages
```

Each addon gets an `addons/<app>/helm/values.yaml` — one `helm/` subdirectory per app. That leaves
room for a sibling `addons/<app>/kustomization.yaml` (app-level, not under `helm/`) for any extra
plain manifests the addon needs beyond what the Helm chart renders, combined into the same
`Application` as a third source (see [Adding a new Application](#adding-a-new-application-the-pattern)).

Two `AppProject`s (`argocd/install/appproject-addons.yaml`, `argocd/install/appproject-apps.yaml`,
synced as part of ArgoCD's own self-managed install) separate cluster infra from tenant workloads:

| AppProject | Used by                                                                                                                  | Scope                                                                                                                                                                                                                                                                                                                                                                                           |
| ---------- | ------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `addons`   | every `Application` under `argocd/addons/`                                                                               | Wildcard-permissive (`sourceRepos`/`destinations`/resource whitelists all `'*'`) — deliberate: addons legitimately need broad CRD/cluster access and pull from a dozen+ external chart repos, so restricting `sourceRepos` would buy little for real maintenance cost.                                                                                                                          |
| `apps`     | the `apps` `ApplicationSet`'s generated `Application`s, and `charts/tenant`'s own `<app>-dev`/`<app>-prd` `Application`s | Least-privilege: `sourceRepos` stays `'*'` (one repo per app — enumerating would fight the data-driven `config.json` flow; the real protection boundary is each app's own Kargo git-write credential), but `destinations`/`clusterResourceWhitelist`/`namespaceResourceWhitelist` are a real allowlist, derived from what's actually synced and verified against the live cluster, not guessed. |

`argocd`, `addons`, and `apps-applicationset` (the three top-level Applications in the table below)
deliberately stay on the built-in `default` project — they're foundational bootstrap scaffolding,
not an addon or a tenant app themselves.

There is no separate "root" `Application`. `argocd/kustomization.yaml` is applied directly, once,
and produces three top-level, self-syncing `Application`s:

| Resource                            | Sync wave | Source                       | Purpose                                                                                                                                                                                         |
| ----------------------------------- | --------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `argocd` (Application)              | `-10`     | `argocd/install`             | ArgoCD manages its own installation/upgrades                                                                                                                                                    |
| `addons` (Application)              | `-9`      | `argocd/addons`              | App-of-Apps: owns every addon `Application` (e.g. `cilium`)                                                                                                                                     |
| `apps-applicationset` (Application) | `-9`      | `argocd/apps-applicationset` | Self-syncs the `apps` `ApplicationSet` object itself, so edits to its matrix/template (not just new `apps/*/config.json` files) reconcile from git without a manual `kubectl apply` — see below |

All three run with `syncPolicy.automated: {prune: true, selfHeal: true}` — once bootstrapped,
upgrading ArgoCD, adding/changing an addon, or changing how standalone apps are generated is a git
commit, not a `kubectl`/`helm` command.

`apps-applicationset` in turn manages one `ApplicationSet` named `apps`
(`argocd/apps-applicationset/applicationset.yaml`), which generates one `Application` per
standalone app (`website`, `helloworld`, ...) — the outer, `charts/tenant`-sourced one that renders
that app's `-dev`/`-prd` pair — see
[Standalone apps (ApplicationSet)](#standalone-apps-applicationset) below. This wrapper exists
because the `ApplicationSet`'s **git generator** only refreshes the _parameters_ it iterates over
(new `apps/*/config.json` files) — the generator polls GitHub on its own. The `ApplicationSet`'s
own template/spec is a separate concern: it's whatever was last applied to the live object, so
without `apps-applicationset` wrapping it, changing the template itself (its `sources`,
`destination`, `syncPolicy`, etc.) would silently do nothing until someone thought to re-run
`kubectl apply -k argocd/ --server-side` by hand.

### Bootstrap (from zero)

Two phases: a one-time **imperative** install to get ArgoCD running at all (it has to exist before
it can manage itself), then handing over to GitOps.

**Day 0 — imperative, one-time:**

Before any of this, create the 1Password item the repo credential is sourced from — vault `Kubernetes`:

- Type: **Login**
- Name: `homelab-gh-pat-argocd-homelab`
- Username: `dyegoe`
- Password: a GitHub fine-grained PAT, scoped read-only to this repo
- Add a new `text` field named `url`, value `https://github.com/dyegoe/homelab.git`
- Add a new `text` field named `type`, value `git`

**Do not** rename/reuse the item's built-in `website` field for `url` — add `url` as a genuine new
`text` field instead. External Secrets Operator's `onepasswordSDK` provider (see
[External Secrets Operator](#external-secrets-operator)) only reads an item's custom `Fields[]`; it
silently ignores the built-in URLs/Notes/Sections blocks, so a value stored in the built-in website
widget never reaches the generated Secret at all. This exact mistake broke ArgoCD's own repo
credential for real on 2026-08-29 during the 1Password-Operator→ESO migration — see
[Known gotcha: URLs, Notes, and Sections aren't extracted](#known-gotcha-urls-notes-and-sections-arent-extracted).

The Login item's built-in `username`/`password` fields plus the two custom fields (`url`, `type`) map
1:1 onto the four keys ArgoCD's repo Secret needs below — and again later, unchanged, once this Secret
is handed off to External Secrets Operator (see
[Migrating a bootstrap secret to External Secrets Operator](#migrating-a-bootstrap-secret-to-external-secrets-operator)).

```bash
# Namespace for ArgoCD
kubectl create namespace argocd

# Repo access credentials (used by ArgoCD's repo-server; scope the PAT to this repo, read-only)
kubectl -n argocd create secret generic repo-homelab \
  --from-literal=type=git \
  --from-literal=url=https://github.com/dyegoe/homelab.git \
  --from-literal=username=dyegoe \
  --from-literal=password=$(op item get "homelab-gh-pat-argocd-homelab" --fields password --reveal)
kubectl -n argocd label secret repo-homelab argocd.argoproj.io/secret-type=repository

# Install ArgoCD at the tag pinned in argocd/install/kustomization.yaml (Renovate keeps that pin current)
ARGOCD_TAG=$(grep -o 'argo-cd/v[0-9.]*' argocd/install/kustomization.yaml | cut -d/ -f2)
kubectl -n argocd apply -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_TAG}/manifests/install.yaml --server-side --force-conflicts
kubectl -n argocd rollout status deployment argocd-server

# Initial admin password — delete the argocd-initial-admin-secret once access/SSO is confirmed
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# UI access
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

**Day 1 — hand over to GitOps:**

```bash
kubectl apply -k argocd/ --server-side
```

This applies the three top-level `Application` objects described above. From this point on:

- **Never re-run the imperative `install.yaml` apply again.** Upgrading ArgoCD is done by bumping
  the pinned tag in `argocd/install/kustomization.yaml` and pushing.
- **Never `helm install`/`helm upgrade` an addon by hand again** once it's under an `Application` —
  edit its values file and push instead.
- The first sync of `argocd.yaml` may show a field-manager conflict — the running install was
  applied imperatively with `kubectl --server-side --force-conflicts`, a different field manager
  than ArgoCD's own controller takes over with. Expected on this first handover, not a bug.

### Adding a new Application (the pattern)

Every addon follows the same shape:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "<wave>" # negative = earlier; foundational addons (CNI, CSI) go first
  finalizers:
    - resources-finalizer.argocd.argoproj.io # cascade-delete on Application deletion
spec:
  project: addons
  sources:
    - repoURL: <helm-repo-or-oci-url>
      chart: <chart-name>
      targetRevision: <pinned-chart-version> # always pin — never `*` or a floating tag
      helm:
        releaseName: <app-name>
        valueFiles:
          - $values/addons/<app-name>/helm/values.yaml
    # Source to provide references for Helm values
    - repoURL: https://github.com/dyegoe/homelab.git
      targetRevision: main
      ref: values
    # Source to provide references for Kustomize bases
    - repoURL: https://github.com/dyegoe/homelab.git
      targetRevision: main
      path: addons/<app-name>
  destination:
    server: https://kubernetes.default.svc
    namespace: <target-namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jsonPointers:
        - /spec/conversion/webhook/clientConfig/caBundle
```

Steps:

1. `addons/<app-name>/helm/values.yaml` — the Helm values, as real YAML.
2. `argocd/addons/<app-name>.yaml` — the `Application`, from the template above.
3. Add `<app-name>.yaml` to `argocd/addons/kustomization.yaml`'s `resources`.
4. Commit and push. `addons` (wave `-9`) picks up the new child `Application` automatically.

For a plain-manifest addition (no Helm chart involved, or extra manifests alongside a chart — e.g.
`gateway-crds`, or Cilium's BGP/LoadBalancerIPPool/HTTPRoute resources), point a source straight at
the upstream repo's manifest directory when one exists (`gateway-crds.yaml` sources
`kubernetes-sigs/gateway-api`'s `config/crd/experimental` path directly — no local mirror needed),
or add an `addons/<app-name>/kustomization.yaml` in this repo for manifests you own yourself. Either
way it's just another entry in the same `Application`'s `sources` list — no `ref`, since only the
values-reference source needs that.

### Adopting existing (non-GitOps) resources

If software is already running from a manual `helm install`/`kubectl apply` (as Cilium was, before
this pattern existed): **do not** set `syncPolicy.automated` on its first commit. Push it with
automation off, sync once manually (`argocd app sync <name>`, or via the UI), and confirm the diff
is empty or exactly what's expected — _before_ enabling `automated: {prune: true, selfHeal: true}`
in a follow-up commit. This is the guardrail that would have caught the incident that motivated
this whole approach: a wrong Cilium value shipped via a raw `--set` flag and took an hour to
diagnose, because nothing rendered a reviewable diff before it reached the cluster.

### Standalone apps (ApplicationSet)

`argocd/apps-applicationset/applicationset.yaml` is an `ApplicationSet` named `apps` with a single
Git **`files`** generator globbing `apps/*/config.json`. Each matching file becomes one set of
template parameters, so apps are discovered from the repo tree instead of being hardcoded in the
`ApplicationSet` — adding an app never means editing it.

Each generated `Application` is named after the app (`website`, `helloworld`, ...) and installs
**`charts/tenant`** from this repo, passing the `config.json` contents through as Helm values. That
chart is where the per-environment shape lives: it renders the `<app>-dev`/`<app>-prd` ArgoCD
`Application`s (each sourced from `deploy/overlays/<env>` in the app's own repo — this repo owns no
manifests on the app's behalf), the Kargo `Project`/`Warehouse`/`Stage`s that promote between them,
and the `ExternalSecret`s for the credentials involved. Environments are a platform concept, fixed
to `dev` and `prd` inside the chart, not something an app chooses.
`kargo.akuity.io/authorized-stage` on each per-env `Application` delegates its sync authority to
the matching Kargo `Stage` — see [Kargo](#kargo).

Two deliberate deviations from the addon pattern:

- The generated `Application` sets `CreateNamespace=false`: the app's namespaces are owned by its
  Kargo `Project`, so ArgoCD must not race it.
- Helm values are passed inline via `valuesObject` — the one place in this repo that does so.
  They aren't hand-written values, they're `config.json` mechanically forwarded, so the
  "values live in a reviewable file" rule is still satisfied by `config.json` itself.

The `ApplicationSet` object itself is kept in sync from git by the self-syncing
`apps-applicationset` `Application` (source: `argocd/apps-applicationset/`) — see the table in
[Architecture](#architecture) above. Without that wrapper, editing this `ApplicationSet`'s
generator/template would require a manual `kubectl apply -k argocd/ --server-side` to take
effect, since the git generator only refreshes the _parameters_ it iterates over, not the
`ApplicationSet`'s own spec.

Adding an app is one `config.json` plus the 1Password items it references — the full steps are under
[Adding a new standalone app via Kargo](#adding-a-new-standalone-app-via-kargo).

### Current Applications

| Application                     | Sync wave | Automated | Notes                                                                                                                                                                            |
| ------------------------------- | --------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `argocd`                        | `-10`     | yes       | Self-managed ArgoCD install                                                                                                                                                      |
| `addons`                        | `-9`      | yes       | App-of-Apps parent                                                                                                                                                               |
| `apps-applicationset`           | `-9`      | yes       | Self-syncs the `apps` `ApplicationSet` object — see [Standalone apps (ApplicationSet)](#standalone-apps-applicationset)                                                          |
| `gateway-crds`                  | `-8`      | yes       | Gateway API CRDs, sourced directly from `kubernetes-sigs/gateway-api`'s `config/crd/experimental` path                                                                           |
| `snapshot-crds`                 | `-8`      | yes       | CSI volume snapshot CRDs                                                                                                                                                         |
| `prometheus-operator-crds`      | `-8`      | yes       | Prometheus Operator CRDs only, split from `kube-prometheus-stack` so every other addon's `ServiceMonitor` renders regardless of sync order (see [Observability](#observability)) |
| `cilium`                        | `-7`      | yes       | Adopted from the manual install described above (see [Adopting existing (non-GitOps) resources](#adopting-existing-non-gitops-resources))                                        |
| `kubelet-serving-cert-approver` | `-6`      | yes       |                                                                                                                                                                                  |
| `metrics-server`                | `-6`      | yes       |                                                                                                                                                                                  |
| `sealed-secrets`                | `-6`      | yes       |                                                                                                                                                                                  |
| `reloader`                      | `-5`      | yes       | Restarts Deployments annotated `reloader.stakater.com/auto: "true"` when a referenced Secret/ConfigMap changes — see [External Secrets Operator](#external-secrets-operator)     |
| `external-secrets`              | `-5`      | yes       | See [External Secrets Operator](#external-secrets-operator)                                                                                                                      |
| `cert-manager`                  | `-4`      | yes       |                                                                                                                                                                                  |
| `cloudflared`                   | `-4`      | yes       |                                                                                                                                                                                  |
| `external-dns`                  | `-4`      | yes       |                                                                                                                                                                                  |
| `gateway`                       | `-3`      | yes       |                                                                                                                                                                                  |
| `longhorn`                      | `-2`      | yes       |                                                                                                                                                                                  |
| `kube-prometheus-stack`         | `-1`      | yes       | After `longhorn` - Prometheus/Grafana persistence needs a working storage class                                                                                                  |
| `loki`                          | `-1`      | yes       | Same storage dependency as above                                                                                                                                                 |
| `argo-rollouts`                 | `-1`      | yes       | Progressive-delivery controller for tenant apps' `Rollout` resources — see the `rollouts-pod-template-hash` `ignoreDifferences` note under [Kargo](#kargo)                       |
| `alloy`                         | `0`       | yes       | Log shipping - pods via the Kubernetes API, Talos's own logs via a LoadBalancer Service                                                                                          |
| `cloudnative-pg`                | `0`       | yes       | CloudNativePG Postgres operator (`cnpg-system` namespace) - webhook `caBundle` is self-managed by the operator at runtime, so it's excluded via `ignoreDifferences`              |
| `kargo`                         | `1`       | yes       | Platform; the hosted apps (`website`, `helloworld`, `catering-calculator`) are provisioned via `charts/tenant` — see [Kargo](#kargo)                                             |

### Renovate

Installed (as the [Renovate GitHub App](https://github.com/apps/renovate) on this repo — no
in-repo workflow needed) and configured via `renovate.json` at the repo root. It opens PRs for:

- Addon chart bumps — Renovate's built-in `argocd` manager reads `targetRevision` out of the
  `Application` manifests under `argocd/`.
- The pinned ArgoCD install tag in `argocd/install/kustomization.yaml` — a `customManagers` regex
  rule tracks the `argoproj/argo-cd` GitHub releases and bumps the `raw.githubusercontent.com`
  tag in the remote-resource URL.
- Plain-manifest image tags (an addon with no Helm chart at all, e.g. `cloudflared`'s
  `addons/cloudflared/deployment-cloudflared.yaml`) — the `kubernetes` manager, scoped to
  `addons/**/deployment*.yaml`. It ships with no default file match, so each such addon needs its
  path added explicitly (see `renovate.json`).

`extends: ["config:recommended"]` — no automerge, so every bump still lands as a normal PR to
review and merge by hand, same as the manual bumps this replaces.

**Dashboard:** [developer.mend.io/github/dyegoe/homelab](https://developer.mend.io/github/dyegoe/homelab)
— Mend's view of open/pending updates, independent of digging through PRs or branches in GitHub.

### Kargo

The platform itself is installed as an addon (`argocd/addons/kargo.yaml`, sync-wave `1` — after
`external-secrets`, `cert-manager`, and `gateway`, which it depends on). Each standalone app hosted on
this cluster gets a `dev` and `prd` namespace/Stage, provisioned from the reusable `charts/tenant`
Helm chart (see [Adding a new standalone app via Kargo](#adding-a-new-standalone-app-via-kargo)
below) — the personal website (`apps/website/`) was the first app and is the reference example, live
end-to-end since 2026-08-25; `helloworld` and `catering-calculator` followed through the same chart. A Warehouse watches the app's image tags, Freight flows through a `dev`
Stage automatically, then a deliberate, manual approval (Kargo dashboard or `kargo promote`)
promotes the same Freight to `prd`. Promotion itself is a direct git commit + push to the app repo's
`main` (a `kustomize-set-image` step rewriting `deploy/overlays/{dev,prd}/kustomization.yaml`,
followed by an ArgoCD sync trigger) — not `hydrateTo`/a review-branch PR flow. This is genuine
multi-environment promotion, since each app actually has separate dev/prd environments to promote
between.

**Not used for the cluster addons** in `argocd/addons/` — there's a single cluster and no dev/prd
split for infra, so there's nothing to promote between; a chart-version bump there already gets a
reviewable diff via a normal git PR, which is the same thing Kargo's rendered-manifest review would
add. Addon version bumps are automated via [Renovate](#renovate) instead, which opens that same
kind of reviewable PR.

### Adding a new standalone app via Kargo

`charts/tenant` is the reusable Helm chart — it creates the app's Kargo `Project`/`ProjectConfig`,
its `dev`/`prd` `Warehouse`/`Stage`s, the `kargo-repo-auth`/`kargo-image-auth` `ExternalSecret`s,
an `argocd-repo-auth` `ExternalSecret` if the app's own repo is private, and (mirroring what
`apps-applicationset` would otherwise generate per app — see
[Standalone apps (ApplicationSet)](#standalone-apps-applicationset)) the `<app>-dev`/`<app>-prd`
ArgoCD `Application`s themselves — all governed by the `apps` `AppProject` by default (see
[Architecture](#architecture)). `apps/website/` is the reference instance; treat it as the example
to copy.

**In this repo:**

1. `apps/<app-name>/config.json` — `appName`, `repoURL`, `imageURL`, and `onepassword.gitItem`
   (+ `imageItem` if the image registry is private, `argocdRepoItem` if the app's own repo
   is private, and `argocdProject` if this app should land in an ArgoCD `AppProject` other than
   `apps` — see [Architecture](#architecture)). Each `*Item` value is a 1Password item **title**
   (not a full `vaults/.../items/...` path — the vault is already fixed on the cluster-wide
   `ClusterSecretStore`, see [External Secrets Operator](#external-secrets-operator)). See
   `charts/tenant/values.schema.json` for the full shape and `apps/website/config.json` for a real
   example.
2. Create the 1Password items the config references — same External-Secrets-Operator pattern as
   everywhere else in this repo, see [External Secrets Operator](#external-secrets-operator):
   - `gitItem` — git read/write credential for Kargo's promotion commits.
   - `imageItem` — image-registry pull credential, if the image is private.
   - `argocdRepoItem` — git read credential for ArgoCD's repo-server to read
     `deploy/overlays/{dev,prd}` from the app's own repo, if that repo is private. Needs the same
     field shape as the ArgoCD repo secret described in
     [Rotating the ArgoCD repo credential](#rotating-the-argocd-repo-credential): `type` (`git`),
     `url` (matching `repoURL`), `username`, `password` — `url` **must** be a genuine custom `text`
     field, not the item's built-in website widget, or it silently won't sync (see
     [Known gotcha: URLs, Notes, and Sections aren't extracted](#known-gotcha-urls-notes-and-sections-arent-extracted)).
3. Commit and push — `charts/tenant` (surfaced the same way as any other app-of-apps child) picks it
   up and provisions everything above.

**Skip `argocdRepoItem` entirely for a public app repo** — `apps/helloworld/` is the reference
example of that case.

**In the app's own repo** (see `dyegoe/website`'s `deploy/README.md` and `RELEASING.md` for the
fully-worked example):

1. `deploy/base/` (Deployment/Service/whatever the app needs) + `deploy/overlays/{dev,prd}/`
   (Kustomize overlays — Kargo's promotion step rewrites each overlay's `kustomization.yaml`
   `images:` block, so don't hand-maintain comments/formatting there, they won't survive).
2. A release pipeline that publishes a **semver image tag**, optionally `v`-prefixed (e.g. `0.3.0`
   or `v0.3.0`), no other characters, on every real release — see the Warehouse gotcha below for
   why the tag shape matters. Conventional Commits + commitizen (as `dyegoe/website` does) is one
   way to get this for free; any pipeline that produces a clean semver tag works.
3. **Scope that pipeline's build trigger away from `deploy/overlays/**`.** Kargo's own promotion
   commits land on the same `main` branch the app's CI watches — without a path filter excluding
   `deploy/overlays/**`, every promotion commit triggers a new build → new image → new promotion,
   forever. This happened for real building the website app (2026-08-25) — see `ci.yaml`'s `paths:`
   filter there for the fix.

**Gotchas accumulated building the website app** — read before touching `charts/tenant/templates/`:

- **Numeric-looking image tags need `quote()`.** `stages.yaml`'s `kustomize-set-image` step sets
  `tag: ${{ quote(imageFrom(vars.imageURL).Tag) }}`, not a bare `${{ imageFrom(...).Tag }}`. A tag
  like `0.1` is valid YAML float syntax — without `quote()`, Kargo's expression engine hands the
  `kustomize-set-image` step a JSON number instead of a string, and it fails with
  `images.0.tag: Invalid type. Expected: string, given: number`.
- **`argocd-update`'s `desiredRevision` is intentionally omitted** from `stages.yaml`'s promotion
  steps. Setting it (e.g. `${{ outputs.push.commit }}`) registers a Stage health check that requires
  the app's ArgoCD `Application` to be observably synced to that _exact_ commit. Since `dev` and
  `prd` both write to the _same_ `main` branch (in their own distinct overlay paths, so no merge
  conflicts — just a shared ref), a promotion to either Stage advances `main` out from under the
  other Stage's already-recorded exact-commit expectation, flipping it `Unhealthy` until it next
  promotes. Leaving `desiredRevision` unset makes the health check a no-op (an empty desired
  revision is skipped, confirmed against Kargo `v1.11.2` source — the docs text about it being
  "determined by Freight" doesn't hold for a git-write-back promotion like this one). Don't add it
  back without first giving `dev`/`prd` separate branches or otherwise decoupling what each
  `Application`'s `targetRevision` tracks.
- **Warehouse image selection: `SemVer`, not `NewestBuild`.** `NewestBuild` picks whichever tag the
  registry lists first for the newest-pushed digest, with no preference for a semver tag over a
  `main`/`sha-<sha>` CI tag sharing the same digest — it was effectively arbitrary which tag won.
  `warehouse.yaml` uses `imageSelectionStrategy: SemVer` with `strictSemvers: true` and
  `allowTagsRegexes: ["^v?\d+\.\d+\.\d+$"]` so only a release tag (`X.Y.Z`, optionally `v`-prefixed)
  is ever considered. Kargo's underlying semver library treats the `v` prefix as optional, so
  `strictSemvers` applies the same either way — no special-casing needed per app.
- **CI publishing multiple tags per image is fine** (e.g. `main`, `sha-<sha>`, and the semver tag all
  on the same digest, as `dyegoe/website`'s `ci.yaml` does) as long as the Warehouse's
  `allowTagsRegexes` excludes everything but the one you want Kargo to track.
- **The `kargo.akuity.io/authorized-stage` annotation (`charts/tenant/templates/application.yaml`)
  is not Kubernetes RBAC** — it's a check Kargo's own controller code makes in-process before
  patching an ArgoCD `Application`, layered on top of whatever raw RBAC the `kargo-controller`
  ServiceAccount holds (see [Kargo's ArgoCD integration
  docs](https://docs.kargo.io/user-guide/how-to-guides/argo-cd-integration)). By default the
  chart's `kargo-controller-argocd` `ClusterRole`/`ClusterRoleBinding` grants
  `get/list/patch/watch` on `argoproj.io/Application` **cluster-wide** because the controller's
  Application cache watches every namespace by default (`cache.Options{}` in
  `cmd/controlplane/controller.go`). `addons/kargo/helm/values.yaml` sets
  `controller.argocd.watchArgocdNamespaceOnly: true`, which switches that cache to
  `DefaultNamespaces: {argocd: {}}` — a genuinely namespaced watch — and the chart automatically
  swaps in a namespace-scoped `Role`/`RoleBinding` (`charts/kargo/templates/argocd/role.yaml`) in
  place of the `ClusterRole`. **A hand-written namespaced `Role` alone does NOT work** without this
  flag: Kubernetes RBAC can never authorize a cluster-scoped `LIST`/`WATCH` call via any `Role`, no
  matter the `RoleBinding` — this exact mistake broke the `website` `dev` promotion for freight
  `0.6.0` on 2026-08-26 (the `argocd-update` step's `client.Get()` blocked on a cache that could
  never finish its initial sync, timing out after 5m). The chart's own doc note on this flag
  ("should usually be left false") is about older Argo CD versions / Applications living outside
  Argo CD's own namespace — every `Application` in this cluster lives in the `argocd` namespace by
  design (see [Architecture](#architecture)), so that caveat doesn't apply here.

**Chart:** `oci://ghcr.io/akuity/kargo-charts/kargo`, pinned in `argocd/addons/kargo.yaml`. CRDs
(`Warehouse`/`Stage`/`Project`/...) are bundled in the chart itself — unlike
`prometheus-operator-crds`, nothing else in this cluster needs them early, so no separate CRD-only
Application was needed.

**Admin login:** `api.secret.name: kargo-admin` in `addons/kargo/helm/values.yaml` points at a Secret
materialized by `addons/kargo/externalsecret-kargo-admin.yaml` (same External-Secrets-Operator
pattern as Grafana/cloudflared/the ArgoCD repo credential — see
[External Secrets Operator](#external-secrets-operator)), rather than inlining
`api.adminAccount.passwordHash`/`tokenSigningKey` in git. One-time setup, since this repo never runs
cluster-mutating or 1Password-mutating commands on your behalf:

1. Generate a password, its bcrypt hash, and a token signing key (same recipe as
   [Kargo's own install docs](https://docs.kargo.io/operator-guide/basic-installation)):

   ```bash
   pass=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
   hashed_pass=$(htpasswd -bnBC 10 "" "$pass" | tr -d ':\n')
   signing_key=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
   echo "password: $pass"
   echo "hash: $hashed_pass"
   echo "signing key: $signing_key"
   ```

2. Create a 1Password item at vault `Kubernetes`, named `homelab-kargo-admin`, with three custom
   `text`/`password` fields (field **labels** become Secret keys verbatim, same as the Telegram bot
   token item — see [External Secrets Operator](#external-secrets-operator)):
   - `ADMIN_ACCOUNT_PASSWORD_HASH` → `$hashed_pass`
   - `ADMIN_ACCOUNT_TOKEN_SIGNING_KEY` → `$signing_key`
   - a field for the plaintext `$pass` too (e.g. `admin-password-plaintext`) — only Kargo's UI login
     needs it, but Kargo itself never sees the plaintext, so it has to be saved somewhere or it's
     lost.

3. Sync `kargo` in ArgoCD (or wait for auto-sync) and log in to `https://kargo.nodes.ee` with
   username `admin` and the plaintext password from step 2.

**UI access:** `addons/kargo/httproute-kargo.yaml` (+ `httproute-kargo-redirect.yaml` for the
`http→https` redirect) route `kargo.nodes.ee` through the same central Gateway (`addons/gateway`) as
Grafana/Prometheus — `api.tls.enabled: false` + `api.tls.terminatedUpstream: true` in
`addons/kargo/helm/values.yaml` because the Gateway terminates TLS with the shared `*.nodes.ee`
wildcard cert, not Kargo's own self-signed one. Confirmed via `helm template` before committing:
the `kargo-api` Service listens on port `80`, matching the HTTPRoute's `backendRefs`.

**Metrics/dashboard:** `controller`/`managementController`/`webhooksServer` have Prometheus metrics

- `ServiceMonitor` enabled in `addons/kargo/helm/values.yaml` (`api`/`garbageCollector` have no metrics
  support in the chart). See [Metrics dashboards](#metrics-dashboards) for what
  `addons/kargo/dashboards/kargo-controllers.json` covers and the gap around business-level metrics.

### Rotating the ArgoCD repo credential

`argocd/repo-gh-dyegoe-homelab` holds the GitHub fine-grained PAT ArgoCD uses to read this repository.
It started as a plain imperative Secret at [Bootstrap ArgoCD](#bootstrap-from-zero) — the
chicken-and-egg credential that has to exist before ArgoCD can sync anything, including External
Secrets Operator itself. Once ESO was up, it took over managing this Secret via an `ExternalSecret`
(`argocd/install/externalsecret-github-dyegoe-homelab.yaml`; see
[Migrating a bootstrap secret to External Secrets Operator](#migrating-a-bootstrap-secret-to-external-secrets-operator)
for how that migration was done) — rotation is no longer a manual `kubectl patch`.

**Source of truth:** 1Password item `homelab-gh-pat-argocd-homelab` (vault `Kubernetes`), field
`password`. Rotate roughly every 30-90 days as best practice.

**To rotate:** update the `password` field on that 1Password item with the new PAT. ESO reconciles the
`repo-gh-dyegoe-homelab` Secret from the item on its `refreshInterval` (`1h` on this `ExternalSecret`)
— no `kubectl` required, but to force it immediately instead of waiting:

```bash
kubectl -n argocd annotate externalsecret repo-gh-dyegoe-homelab force-sync=$(date +%s) --overwrite
argocd repo get --refresh hard https://github.com/dyegoe/homelab.git   # STATUS should be Successful
argocd app list | awk 'NR==1 || /Unknown|ComparisonError/'             # should be empty after a refresh
```

If apps are still showing stale `ComparisonError`, refresh them (`argocd app get <name> --refresh`) — the
auto-sync loop also picks up the new credential within a few minutes.

**Manual fallback only works if ESO itself is down** (controller crash-looping, `ClusterSecretStore`
not `Valid`, etc.) — confirmed the hard way on 2026-08-29: if ESO is up but reconciling, it watches
Secrets it owns and reverts a manual edit almost immediately (well inside a minute, not on the
`refreshInterval`), so a plain `kubectl patch`/`edit` against a healthy ESO does nothing useful. Check
`kubectl get clustersecretstore onepassword` and `kubectl -n external-secrets get pods` first. If ESO
really is down:

```bash
kubectl -n argocd patch secret repo-gh-dyegoe-homelab \
  --type=merge \
  -p "{\"stringData\":{\"password\":\"$(op item get 'homelab-gh-pat-argocd-homelab' --fields password --reveal)\"}}"
```

### Forcing an immediate refresh (GitHub webhook)

Both the `apps` `ApplicationSet`'s git generator (`argocd/apps-applicationset/applicationset.yaml`,
globbing `apps/*/config.json`) and ArgoCD's normal `Application` polling only notice a repo change
on the controller's default poll interval (~3 min). Rather than wait on that, ArgoCD accepts a
GitHub push webhook at `/api/webhook` that triggers an immediate refresh for any
`Application`/`ApplicationSet` whose `repoURL` matches the payload — without exposing the rest of
ArgoCD: the UI stays reachable only via the internal `argocd.nodes.ee` route
([Bootstrap](#bootstrap-from-zero)), never tunneled to the internet.

**Cloudflare Tunnel (manual, dashboard-only — not tracked in git):** in the Cloudflare Zero Trust
dashboard, on the existing homelab tunnel (`addons/cloudflared`), add a new **Public Hostname**:

- Hostname: `maya.nodes.ee`
- Path: `/api/webhook`
- Service: `http://argocd-server.argocd.svc.cluster.local:80`

This targets the `argocd-server` Service directly, bypassing the internal Gateway/HTTPRoute
entirely — any other path requested on `maya.nodes.ee` falls through to the tunnel's catch-all and
never reaches ArgoCD.

**Webhook secret** — lives only in the live `argocd-secret` (key `webhook.github.secret`), never in
git. This is a live plaintext value used to verify GitHub's HMAC signature, the same category as
ArgoCD's own admin password/signing key which also never appear in the repo, so it's patched
directly:

```bash
WEBHOOK_SECRET=$(openssl rand -hex 20)
kubectl -n argocd patch secret argocd-secret \
  --type merge \
  -p "{\"stringData\":{\"webhook.github.secret\":\"$WEBHOOK_SECRET\"}}"
echo "$WEBHOOK_SECRET"   # copy for the GitHub webhook config below — not saved anywhere else
```

ArgoCD's settings manager watches `argocd-secret` and picks this up live, no restart required. If
it ever needs re-establishing (secret rotated, cluster rebuilt), just repeat this step with a new
value and update the GitHub webhook's secret to match.

**GitHub webhook** (repo → Settings → Webhooks → Add webhook):

- Payload URL: `https://maya.nodes.ee/api/webhook`
- Content type: `application/json`
- Secret: the value generated above
- Events: "Just the push event"

**Verify:** push a change to `apps/*/config.json` (or any tracked path) and confirm the
corresponding `Application`/`ApplicationSet` reconciles within seconds instead of minutes.

## Advanced Networking

Cilium's BGP control plane (`CiliumBGPClusterConfig`/`CiliumBGPPeerConfig`/`CiliumBGPAdvertisement` in
`addons/cilium/`) peers with the Mikrotik router below to advertise `CiliumLoadBalancerIPPool` IPs directly,
instead of relying on L2 announcements. Confirmed live and working — see the **Cilium BGP** Grafana
dashboard ([Metrics dashboards](#metrics-dashboards)) for session state, advertised/received routes per
node.

### Mikrotik BGP configuration

```routeros
/routing/bgp/instance/add name=k8s as=64512 router-id=172.31.86.1
/routing/bgp/template/add name=k8s as=64512 afi=ip
/routing/bgp/connection/add name=k8s instance=k8s remote.address=172.31.86.0/24 remote.as=64512 local.address=172.31.86.1 local.role=ibgp listen=yes routing-table=main templates=k8s as=64512 afi=ip
```

## External Secrets Operator

Migrated from a dedicated 1Password Operator (native `OnePasswordItem` CRD + a self-hosted 1Password
Connect server) on 2026-08-28/29 — the driver was learning value, not a functional gap. The Operator
(`addons/onepassword/`, its Connect server, and the `onepassworditems.onepassword.com` CRD) is fully
removed as of 2026-08-29; every secret in this cluster, including the `ghcr-pull` image-pull secrets
in the `dyegoe/website`/`dyegoe/catering-calculator` app repos, now goes through ESO.
[External Secrets Operator](https://external-secrets.io/) (ESO) is the vendor-neutral,
`ExternalSecret`/`SecretStore` CRD-based standard for this problem, and the `onepasswordSDK` provider
talks to 1Password directly via a service-account token — no Connect server to run at all.

### Installation

Create a 1Password service account, scoped to read-only access on the `Kubernetes` vault (a service
account can never be granted the built-in Personal/Private/Employee vaults or the default Shared
vault, so a named vault like `Kubernetes` is required):

```bash
op service-account create k8s-eso --vault Kubernetes:read_items
```

Seal the resulting token the same way every other bootstrap secret in this repo is sealed (see
[Migrating a bootstrap secret to External Secrets Operator](#migrating-a-bootstrap-secret-to-external-secrets-operator)
for why this one specifically has to exist before ESO can sync anything else):

```bash
kubectl create secret generic onepassword-sa-token \
  --from-literal=token='<service-account-token>' \
  --namespace external-secrets --dry-run=client -o yaml > raw-sa-token.yaml
kubeseal -o yaml < raw-sa-token.yaml > sealedsecret-onepassword-sa-token.yaml
rm raw-sa-token.yaml
```

The ciphertext is bound to the `sealed-secrets` controller's current key pair. Back that key up
somewhere outside the cluster (1Password works) — a rebuilt cluster gets a new pair and can't decrypt
this file otherwise; see [Bootstrap sequence summary](#bootstrap-sequence-summary):

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml > sealed-secrets-key.yaml
```

One cluster-wide `ClusterSecretStore` (`addons/external-secrets/clustersecretstore-onepassword.yaml`)
wires that token to the `Kubernetes` vault — every `ExternalSecret` in this cluster references it by
name, regardless of namespace:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: onepassword
spec:
  provider:
    onepasswordSDK:
      vault: Kubernetes
      auth:
        serviceAccountSecretRef:
          name: onepassword-sa-token
          key: token
          namespace: external-secrets
      cache:
        ttl: 5m
        maxSize: 100
```

Pod restarts on secret rotation (the old Operator's `autoRestart`) are covered by a separate addon,
[stakater/reloader](https://github.com/stakater/Reloader) — annotate a Deployment with
`reloader.stakater.com/auto: "true"` and it restarts automatically when a Secret/ConfigMap it
references changes. Every workload consuming an ESO-managed Secret via an env var or non-Kargo/-Grafana
credential should carry this annotation; `cloudflared`, `external-dns`, and `kube-prometheus-stack`'s
Grafana are the current examples.

### How to use

Create an `ExternalSecret` to fetch a whole 1Password item's fields into a Secret. `remoteRef.key`
(or `extract.key`) is the item's **title**, not a full `vaults/.../items/...` path — the vault is
already fixed on the `ClusterSecretStore` above:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: SECRET_NAME
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: SECRET_NAME
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: ITEM_TITLE
```

Every field **label** on the item becomes a Secret data key, verbatim — same generic mechanism the
old Operator used. To pull a single field instead of the whole item (useful when the item carries
built-in fields beyond the one you need — see the gotcha below), add `property: FIELD_LABEL` under
`extract`, or use `data:`/`remoteRef` instead of `dataFrom:`/`extract` for an explicit per-key list.
To add labels or a Secret `type` without touching what's fetched, use `target.template.metadata` (see
`argocd-repo-auth.yaml`'s `argocd.argoproj.io/secret-type: repository` label in `charts/tenant`) — and
if you also need `target.template.data`, set `mergePolicy: Merge` or every fetched field not
explicitly re-listed there gets silently dropped.

There is no annotation-based auto-inject equivalent to the old Operator's
`operator.1password.io/item-path`/`item-name` Deployment annotations — every consumer gets an
explicit `ExternalSecret` resource instead, which is more verbose but fully reviewable in a diff
(the same tradeoff this repo already made for Helm values vs `--set`, see
[Architecture](#architecture)).

### Known gotcha: URLs, Notes, and Sections aren't extracted

The `onepasswordSDK` provider's `extract`/`property` only reads an item's custom `Fields[]`. It
silently ignores 1Password's built-in structural blocks — the item's URLs/website widget, its Notes
section, and any field living inside a named Section — even though the old Connect-based Operator
surfaced some of these (flattened under whatever label they had, e.g. a URL field labeled `website`
or a renamed label like `url`). There is no error: the field is just absent from the generated
Secret, same shape as a field that was never created.

This broke ArgoCD's own repo credential for real on 2026-08-29, mid-migration: the `homelab-gh-pat-argocd-homelab`
item had its `url` value stored in the built-in website widget (renamed from the default `website`
label), so `extract` produced a Secret with `type`/`username`/`password` but no `url` — and ArgoCD
indexes repo credentials by `url`, so it lost the ability to read this repository entirely until the
field was recreated as a genuine custom `text` field. It also (harmlessly, since nothing reads them)
dropped `kargo-admin`'s and `grafana-admin-password`'s built-in `website` field, and
`kargo-image-auth`'s built-in Notes field.

**When creating or auditing any 1Password item an `ExternalSecret` reads:** every field the Secret
needs must be a genuine custom `text`/`password` field, never the item's built-in website/Notes/Section
UI widgets, even if 1Password lets you rename that widget's label to look like a normal field.

### Creating a docker-registry (imagePullSecret) item

ESO has no docker-registry-specific logic: `extract` copies 1Password item field **labels** straight
into the generated Secret's `data` keys, verbatim — the same generic mechanism as [How to
use](#how-to-use) above. To get a working `kubernetes.io/dockerconfigjson` image pull secret out of
it, two things have to line up:

1. The `ExternalSecret` needs `target.template.type: kubernetes.io/dockerconfigjson` (with
   `mergePolicy: Merge` if `template.data` is also set, so the extracted fields still pass through).
2. Kubernetes requires that Secret type to carry exactly one data key, `.dockerconfigjson`,
   containing the full Docker config JSON. So the 1Password item itself needs a field **labeled
   exactly `.dockerconfigjson`** (the leading dot is a valid Secret data-key character, so it's
   preserved as-is) whose value is that JSON blob — not the individual username/password. See
   `charts/tenant/templates/kargo-image-auth.yaml` / the `kargo-image-auth` `ExternalSecret` for a
   real example already using this pattern (extracting the whole item, `.dockerconfigjson` field
   included).

Generate that JSON blob with `kubectl` (`--dry-run=client` never touches the cluster) and a PAT
pulled straight from the same 1Password item, then paste the output into the `.dockerconfigjson`
field on that item:

```bash
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=$(op item get "homelab-gh-pat-registry-ghcr" --fields username) \
  --docker-password=$(op item get "homelab-gh-pat-registry-ghcr" --fields password --reveal) \
  --dry-run=client -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Kustomize/ArgoCD only ever render the `ExternalSecret` pointer above — it carries no secret material.
The real Secret is materialized afterward, in-cluster, when ESO reconciles that resource against
1Password directly; there's no way for Kustomize itself to build a docker-registry Secret from a
1Password item (it has no 1Password awareness, and its generators only read literals/files already
present in the repo at render time).

### Migrating a bootstrap secret to External Secrets Operator

Worked example: the ArgoCD repo credential (`argocd/repo-gh-dyegoe-homelab`, see
[Bootstrap ArgoCD](#bootstrap-from-zero), including the 1Password item it's sourced from) started as a
plain imperative Secret, since it has to exist before ArgoCD — and therefore before ESO — can sync
anything. Once ESO is up, it can take over managing that Secret:

1. Add the `ExternalSecret` manifest (`argocd/install/externalsecret-github-dyegoe-homelab.yaml`),
   pointing at the same 1Password item created during bootstrap:

   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: repo-gh-dyegoe-homelab
     namespace: argocd
   spec:
     refreshInterval: 1h
     secretStoreRef:
       kind: ClusterSecretStore
       name: onepassword
     target:
       name: repo-gh-dyegoe-homelab
       creationPolicy: Owner
       template:
         metadata:
           labels:
             argocd.argoproj.io/secret-type: repository
     dataFrom:
       - extract:
           key: homelab-gh-pat-argocd-homelab
   ```

2. Wire it into `argocd/install/kustomization.yaml`'s `resources`.

3. Commit and push. Once ArgoCD syncs, it prunes the previous resource pointing at this Secret
   (whatever mechanism owned it before — a `OnePasswordItem` CR, or nothing at all for a truly
   imperative bootstrap Secret). **If the Secret already exists and is owned by something else**
   (an `ownerReference` to a CR, or no owner at all), ESO's `creationPolicy: Owner` won't adopt it —
   delete it by hand once the `ExternalSecret` is `Ready`, and ESO recreates it under its own
   ownership:

   ```bash
   kubectl -n argocd delete secret repo-gh-dyegoe-homelab
   ```

   Note this can also happen automatically and by surprise: if the Secret's _previous_ owner was a
   CR that ArgoCD prunes in the same sync as this change (as happened here — the old
   `OnePasswordItem`), Kubernetes garbage-collects the Secret the instant the CR is pruned, before
   ESO gets a chance to react. ESO recreates it right away, but until it does there's a real gap
   where the credential doesn't exist — for a credential ArgoCD itself depends on to sync (like this
   one), that gap can look like a full repo-access outage. Watch `argocd repo list` after this kind
   of change, not just the `ExternalSecret`'s own `Ready` condition.

4. Verify:

   ```bash
   argocd repo get --refresh hard https://github.com/dyegoe/homelab.git
   ```

From this point on, rotating the PAT is just updating the `password` field on the 1Password item — see
[Rotating the ArgoCD repo credential](#rotating-the-argocd-repo-credential).

### Known issue: SDK WASM instance wedges after a network error (recheck when onepassword-sdk-go moves past v0.4.1)

**Status: open, mitigated by alerting.** On 2026-09-08 every `ExternalSecret` in the cluster went
`Ready=False` at once and stayed that way for ~30 hours, with every ArgoCD `Application` that owns
one showing `Degraded`. The `ClusterSecretStore` stayed `Valid` the whole time and nothing in
1Password had changed. Every reconcile failed with:

```text
error processing spec.dataFrom[0].extract, err: failed to list items: failed to list items:
wasm error: out of bounds memory access
wasm stack trace:
        op_extism_core.wasm._ZN8dlmalloc8dlmalloc17Dlmalloc$LT$A$GT$6malloc17h44b8dc71ab434912E(i32) i32
        op_extism_core.wasm._ZN10extism_pdk6extism10load_input17h1fed4249c383a9e7E(i32)
        op_extism_core.wasm.invoke() i32
```

**Root cause**, from the controller's logs in Loki: between 05:15:29 and 05:15:53 UTC CoreDNS
returned `SERVFAIL` for `my.1password.com` (a sub-minute resolver blip, visible in CoreDNS's own logs
for other external names too), and all 20 `ExternalSecret`s happened to refresh inside that window.
Each failed lookup surfaced inside the
[1Password Go SDK](https://github.com/1Password/onepassword-sdk-go) (`v0.4.1`, pinned by ESO
`v2.10.0`'s `providers/v1/onepasswordsdk/go.mod`) as a Go panic in its `extism`/`wazero` WASM host
call, "recovered by wazero". The very next call, 40 ms after the last of those, failed with
`out of bounds memory access` at memory allocation, and every SDK call since failed the same way —
the recovered panics evidently left the WASM instance's heap corrupted. ESO's
`onepasswordsdk` provider caches the SDK client, keyed on the `ClusterSecretStore`'s
`resourceVersion`, and never recreates it on error, so the wedged instance was reused until the pod
was restarted. The controller also has no liveness probe and no memory limit, so nothing self-healed;
its working set climbed from a flat ~207 MiB to 440 MiB over the following day while stuck in the
error loop.

**Fix** (mutating — run it yourself): restart the controller, which creates a fresh SDK client and
WASM instance. Every `ExternalSecret` went `Ready` after the restart on 2026-09-09:

```bash
kubectl -n external-secrets rollout restart deploy/external-secrets
kubectl get externalsecrets -A
```

Bumping the `ClusterSecretStore`'s `resourceVersion` (any annotation change) also forces a new
cached client, but leaves the broken one and its memory behind — the restart is cleaner.

**Alerting** so this can never sit unnoticed for 30 hours again:
`addons/external-secrets/prometheusrule-external-secrets.yaml` fires `ExternalSecretNotReady`
(warning, per object, 15m) and `ExternalSecretsMostlyNotReady` (critical, half or more of all
`ExternalSecret`s, 10m — the store/controller-level signature of this bug) to Telegram via the
default route. Note the metric's namespace label for the `ExternalSecret` itself is
`exported_namespace`; `namespace` is the scrape target's (`external-secrets`).

**Upstream**: both filed 2026-09-09 —
[1Password/onepassword-sdk-go#288](https://github.com/1Password/onepassword-sdk-go/issues/288) (the
root cause: a recovered host-function panic leaves the WASM instance unusable) and
[external-secrets/external-secrets#6941](https://github.com/external-secrets/external-secrets/issues/6941)
(the provider never drops a cached client after an unrecoverable WASM error). Either fix alone would
have bounded this to one failed reconcile.

**Recheck when**: an ESO release bumps `github.com/1password/onepassword-sdk-go` past `v0.4.1` in
`providers/v1/onepasswordsdk/go.mod` (Renovate's ESO PR is the trigger — check that file at the new
tag), or the provider's client-caching behaviour changes. Until then, `ExternalSecretsMostlyNotReady`
plus the restart above is the runbook.

## Observability

Metrics and logs for the cluster, replacing an earlier split Prometheus/Grafana/Loki/Alloy-operator setup
from a previous iteration of this homelab.

### Architecture

Four addons:

- `prometheus-operator-crds` (sync-wave `-8`) — just the Prometheus Operator CRDs (`ServiceMonitor`,
  `PodMonitor`, `PrometheusRule`, ...), split out from the main chart and sync'd early so every other
  addon's `ServiceMonitor` can render regardless of how early it syncs. `kube-prometheus-stack` itself
  can't sync that early — its Prometheus/Grafana persistence needs Longhorn, which lands much later — so
  without this split there'd be a chicken-and-egg deadlock between Cilium's `ServiceMonitor` (wave `-7`)
  and the CRD that defines it.
- `kube-prometheus-stack` (sync-wave `-1`, after `longhorn`) — Prometheus, Grafana, Alertmanager,
  kube-state-metrics, node-exporter.
- `loki` (sync-wave `-1`) — log storage, SingleBinary mode on a Longhorn-backed PVC.
- `alloy` (sync-wave `0`, DaemonSet) — log shipping only, not metrics: tails every pod's logs via
  `loki.source.kubernetes`, and receives Talos's own kernel/service logs over TCP
  (`otelcol.receiver.tcplog`) via a dedicated LoadBalancer Service.

Resource requests/limits, Grafana's `Recreate` deployment strategy, and Loki's PVC auto-delete guard in
`addons/kube-prometheus-stack/helm/values.yaml` and `addons/loki/helm/values.yaml` are carried over from
concrete incidents on this same hardware in the previous iteration of this stack (unbounded resources
exhausting the 3-node cluster, Grafana stuck on redeploy behind a single RWO PVC, Loki losing history on
StatefulSet recreation) — see the comments in those files for specifics.

### Accessing Grafana

`https://grafana.nodes.ee`. Credentials come from the `homelab-grafana` 1Password item, materialized by
`addons/kube-prometheus-stack/externalsecret-grafana-admin-password.yaml` (an `ExternalSecret` —
see [External Secrets Operator](#external-secrets-operator)) into the `grafana-admin-password` Secret,
which `grafana.admin.existingSecret`/`userKey: username`/`passwordKey: password` in
`addons/kube-prometheus-stack/helm/values.yaml` point at. Note the Secret key is `password`, not the
1Password item's `confirmNew` field label — the SDK provider surfaces this item's built-in password
field under the key `password` regardless of what custom label the field itself carries in 1Password.

### Viewing logs

Logs live in Loki, browsed from Grafana's **Explore** tab (compass icon) with the **Loki** datasource
selected. There's no bundled log dashboard — Explore is the primary way to browse logs today.

Pod logs (every namespace, tailed by Alloy via the Kubernetes API — no `hostPath` mount needed):

```logql
{namespace="cert-manager"}
{namespace="monitoring", pod="grafana-864965887b-pkrdl", container="grafana"}
{namespace="cert-manager"} |= "error"
```

Available labels: `namespace`, `pod`, `container`, `node`, `job`, `service_name`.

Talos's own logs (kernel + service, from all 3 nodes, shipped via `machine.logging.destinations` in
`talos/control-plane/01-base.yaml.tpl` + `KmsgLogConfig` in `talos/control-plane/06-kmsg-log.yaml`):

```logql
{job="talos"}
{job="talos"} | json | talos_service="machined"
{job="talos"} | json | facility="kern"
```

The log line itself is the raw `json_lines` text Talos sends — it isn't parsed at ingest (standard Loki
practice: index less, parse at query time), so use LogQL's `| json` pipeline stage to pull out fields.
Service logs carry `talos-service`/`talos-level`/`msg`/`talos-time`; kernel logs carry
`facility`/`priority`/`msg`/`clock` instead — no `talos-service` field, since they don't come from a
Talos service.

### Alerting (Telegram)

Alertmanager routes to a `telegram` receiver by default (`addons/kube-prometheus-stack/helm/values.yaml`'s
`alertmanager.config`), ported from the old homelab-gitops repo's setup. The bot token/chat ID come from
the existing `homelab-telegram-bot-token` 1Password item (API Credential type: `credential` field is the
bot token, `chat_id` is the target chat) via `addons/kube-prometheus-stack/externalsecret-telegram-bot-token.yaml`
(an `ExternalSecret` extracting the whole item — see [External Secrets Operator](#external-secrets-operator))
— injected as a Secret mounted into the Alertmanager pod at `/etc/alertmanager/secrets/telegram-bot-token/`.
Alertmanager's StatefulSet-owned pod isn't covered by the Reloader annotation pattern used for
Grafana/cloudflared/external-dns, but since the Secret is file-mounted (not an env var), the kubelet
propagates a rotated value into the running pod on its own — no restart needed either way.
kube-prometheus-stack's own default `inhibit_rules`/`templates` are left untouched (only `route`/
`receivers` are overridden), so Helm's map merge keeps the chart's severity-based inhibition.

`Watchdog` — kube-prometheus-stack's bundled always-firing heartbeat alert (`vector(1)`, confirmed live
via `ALERTS{alertname="Watchdog"}`) — is explicitly routed to the built-in `null` receiver so it doesn't
spam Telegram every `repeat_interval`. Everything else routes to `telegram`, grouped by
`alertname`/`namespace`/`job`.

To verify the pipeline end-to-end without waiting for a real alert, temporarily route `Watchdog` to
`telegram` instead of `null` in the config above and sync — a message should arrive within a few minutes
(`group_wait: 30s`) — then revert.

**Custom alert rules** live next to the addon they watch, as a `PrometheusRule` in
`addons/<name>/prometheusrule-<name>.yaml` (added to that addon's `kustomization.yaml`), not in
`kube-prometheus-stack`'s values. Prometheus picks them up from any namespace and without a
`release:` label because `ruleSelectorNilUsesHelmValues: false` is set — the same reason every
addon's unlabeled `ServiceMonitor` works. The first one is
`addons/external-secrets/prometheusrule-external-secrets.yaml` (see
[Known issue: SDK WASM instance wedges after a network error](#known-issue-sdk-wasm-instance-wedges-after-a-network-error-recheck-when-onepassword-sdk-go-moves-past-v041)
for what it guards against). The Alertmanager route above doesn't match on `severity`: everything
not explicitly sent to `null` reaches Telegram, so `severity` is informational.

### Metrics dashboards

Grafana comes with kube-prometheus-stack's bundled dashboards (Kubernetes cluster/node/pod views,
CoreDNS, etc.) under **Dashboards**. Three known gaps, not bugs to chase if rediscovered:

- The Alertmanager Grafana datasource plugin ships with `autoEnabled: false`, so it 500s with
  `plugin.unavailable` when viewed through Grafana. Alertmanager's own UI works fine standalone.
- The bundled "kubernetes-mixin" dashboards (Compute Resources: Namespace/Pod/Workload) key off a
  `cluster` label that a standalone, non-federated Prometheus like this one never sets on locally-queried
  series (`externalLabels` only affects federation/remote-write/Alertmanager metadata, not local
  queries) — accepted as a known gap rather than adding `metricRelabelings` to every `ServiceMonitor`
  across every addon.
- etcd has no metrics or dashboard at all — it's a native Talos host service, not a Kubernetes workload,
  so there's no pod/Service for a `ServiceMonitor` to target. Wiring it up would need Talos-level exposure
  of etcd's metrics endpoint plus a scrape config, which hasn't been done. Accepted as a known gap, not
  planned unless a concrete need for etcd visibility comes up.

Every addon with a live Prometheus target also ships its own dashboard(s), as a `ConfigMap` labeled
`grafana_dashboard: "1"` in `addons/<name>/dashboards/` (auto-discovered by Grafana's sidecar, which has
`searchNamespace: ALL`) — see each addon's `kustomization.yaml` for the list and provenance (ported from
upstream vs. hand-built). Loki's and Alloy's are hand-built rather than ported verbatim from their
official upstream mixins (`grafana/loki`'s `loki-mixin`, `grafana/alloy`'s `alloy-mixin`):

- Loki's mixin dashboards (reads/writes/chunks/etc.) are written for a microservices-split deployment
  (per-component jobs like `loki-ingester`/`loki-querier`) and key panels off recording rules
  (`cluster_job_route:*:sum_rate`) this cluster doesn't deploy — irrelevant here since Loki runs as
  `deploymentMode: SingleBinary`. `addons/loki/dashboards/loki.json` covers the same operational signals
  (request rate/latency, ingestion, discards, chunk flush, query latency) with plain PromQL instead.
- Alloy's mixin dashboards were kept close to upstream (`addons/alloy/dashboards/*.json`) but had their
  multi-cluster `cluster`/`namespace`/`job` template variables collapsed to a single `pod` selector,
  since this Prometheus never sets a `cluster` label on Alloy's series — same underlying gap as the
  kubernetes-mixin one above, just resolved per-dashboard here instead of left as a gap.
- Kargo has no official Grafana dashboard/mixin at all, and — as of chart `1.11.2` — no
  business-level metrics either (no per-Promotion/Stage/Warehouse counters); only `controller`,
  `managementController`, and `webhooksServer` expose metrics, and only generic
  controller-runtime/workqueue/Go-runtime instrumentation (`api` and `garbageCollector` have no
  metrics support in the chart at all). `addons/kargo/dashboards/kargo-controllers.json` covers
  reconcile rate/errors/latency and workqueue depth/latency **per Kargo resource type** — the
  generic reconciler metrics' `controller` label is still set to the real resource name
  (`promotion`/`stage`/`warehouse`/`control_flow_stage`/`project`/...), so this is a genuine signal,
  just not promotion counts or verification outcomes. Recheck once real Warehouses/Stages exist and
  if a newer Kargo version ever adds business metrics.

Every panel's PromQL was checked against live Prometheus metric names before writing, not assumed.

### Known log noise (resolved in Kubernetes v1.37)

**Status: resolved.** Rechecked 2026-09-09 on Kubernetes `v1.37.0` / Talos `v1.14.0`: a 7-day Loki
query for `{namespace="kube-system", container="kube-apiserver"} |= "createTransport"` returns
nothing. Kept as the record of how the issue was tracked.

Between 2026-08-16 and the `v1.37.0` upgrade, `{namespace="kube-system"} |= "2379"` showed recurring
`kube-apiserver` warnings on all 3 nodes, every ~10-30s, e.g.:

```text
W0816 19:53:07.904157       1 logging.go:55] [core] [Channel #32593 SubChannel #32594] grpc:
addrConn.createTransport failed to connect to {Addr: "127.0.0.1:2379", ServerName: "127.0.0.1:2379", }.
Err: connection error: desc = "transport: authentication handshake failed: context canceled"
```

Root cause, confirmed upstream in [kubernetes/kubernetes#134080](https://github.com/kubernetes/kubernetes/issues/134080):
`kube-apiserver` was recreating its etcd client on every metrics scrape instead of reusing a cached
connection — harmless log churn, not an actual etcd/apiserver problem (cluster health was unaffected).
Fixed by [kubernetes/kubernetes#138075](https://github.com/kubernetes/kubernetes/pull/138075), merged
2026-04-22, targeting Kubernetes v1.37. This cluster was on `v1.36.2` when the entry was opened,
with an explicit recheck trigger (bump `kubernetesVersion` in `talos/topf.yaml` past `1.36.2`); the
trigger fired with the upgrade to `v1.37.0` and the recheck confirmed the fix.

## Bootstrap sequence summary

The order things have to happen in when building this cluster from nothing. After step 5,
cluster changes are git commits; step 6 lists the deliberate exceptions that live outside git.

1. **Talos** — boot each node from the SecureBoot USB image and run `topf apply --auto-bootstrap`
   from `talos/`. That one step applies every machine config in this repo — including the
   control-plane patches Prometheus and Alloy depend on later (`bind-address: 0.0.0.0` for
   `kube-scheduler`/`kube-controller-manager`, `machine.logging.destinations`, `KmsgLogConfig`) —
   and bootstraps etcd on the first node. See [Talos Linux installation](#talos-linux-installation).
2. **Gateway API CRDs + Cilium** — imperative, from the repo's values file. Nodes go `Ready` here.
   See [Network CNI](#network-cni).
3. **ArgoCD** — imperative, one-time: the repo credential and the pinned upstream `install.yaml`.
   See [Bootstrap (from zero)](#bootstrap-from-zero).
4. **Sealed Secrets key (rebuild only)** — the one piece of secret material in git,
   `addons/external-secrets/sealedsecret-onepassword-sa-token.yaml`, is encrypted to the
   `sealed-secrets` controller's key pair, and the controller generates a fresh pair the first time
   it starts. On a genuine rebuild that new pair can't decrypt the committed file, so **before**
   handing over to GitOps either restore the previous controller's key `Secret` into `kube-system`
   from the backup taken as described under [Installation](#installation), or re-seal the 1Password
   service-account token with the new controller's key. Everything else ESO-managed follows once
   that one Secret decrypts.
5. **Hand over to GitOps** — `kubectl apply -k argocd/ --server-side`. ArgoCD takes over its own
   install, adopts the Cilium release (same chart version and values, so the only diff is the
   `ServiceMonitor`s it now enables), and syncs every other addon in sync-wave order — see the
   [Current Applications](#current-applications) table: CRDs, then `sealed-secrets`/
   `metrics-server`/`kubelet-serving-cert-approver`, `external-secrets`/`reloader`,
   `cert-manager`/`external-dns`/`cloudflared`, `gateway`, `longhorn`, the observability stack,
   `cloudnative-pg`, and finally `kargo` and the hosted apps.
6. **Out-of-band, by design** — what lives outside git: the 1Password items every `ExternalSecret`
   reads, the Cloudflare Tunnel public hostnames, and the ArgoCD GitHub webhook secret (see
   [Forcing an immediate refresh (GitHub webhook)](#forcing-an-immediate-refresh-github-webhook)).

## Development (pre-commit hooks)

This repo uses [pre-commit](https://pre-commit.com/) to catch formatting/lint/schema issues before they
land - install once per clone, then it runs automatically on every commit:

```bash
pre-commit install
```

Check everything now (useful right after cloning, or after pulling changes):

```bash
pre-commit run --all-files
```

The same command runs in CI on every pull request and push to `main`
(`.github/workflows/common.yml`, job `check-pull-request`), and `main`'s branch protection requires
that check to pass before a PR can merge — so a Renovate bump can't land with a manifest that fails
`kubeconform` or values that fail `yamllint`. Admins can bypass the rule, which is how direct pushes
to `main` still work.

What's checked (`.pre-commit-config.yaml`):

- General hygiene - trailing whitespace, end-of-file newlines, merge conflict markers, large files.
- YAML - syntax (`check-yaml`) and style (`yamllint`, config in `.yamllint.yaml`).
- Markdown - auto-formatted with `prettier` (table alignment, etc.), then linted with
  `markdownlint-cli2` (config in `.markdownlint-cli2.yaml`).
- Secrets - `gitleaks` scans staged changes for accidentally committed credentials.
- Kubernetes manifests - every `kustomization.yaml` in the repo gets built (`kubectl kustomize`) and
  validated against the Kubernetes API + CRD schemas with `kubeconform`
  (`scripts/kustomize-validate.sh`). Needs network access (schema/CRD lookups); results are cached in
  `.kubeconform-cache/` (gitignored) after the first run.
