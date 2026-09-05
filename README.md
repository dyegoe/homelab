# Homelab

This is a repository to setup a homelab running Kubernetes on top of TalOS.

## Table of Contents

- [Homelab](#homelab)
  - [Table of Contents](#table-of-contents)
  - [Pre-commit hooks](#pre-commit-hooks)
  - [Initial Cluster Setup](#initial-cluster-setup)
    - [Hardware Specifications](#hardware-specifications)
    - [Network configuration](#network-configuration)
    - [TalOS installation](#talos-installation)
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
  - [Observability](#observability)
    - [Architecture](#architecture-1)
    - [Accessing Grafana](#accessing-grafana)
    - [Viewing logs](#viewing-logs)
    - [Alerting (Telegram)](#alerting-telegram)
    - [Metrics dashboards](#metrics-dashboards)
    - [Known log noise (recheck on next Kubernetes upgrade)](#known-log-noise-recheck-on-next-kubernetes-upgrade)
  - [Overall setup summary and sequence](#overall-setup-summary-and-sequence)

## Pre-commit hooks

This repo uses [pre-commit](https://pre-commit.com/) to catch formatting/lint/schema issues before they
land - install once per clone, then it runs automatically on every commit:

```bash
pre-commit install
```

Check everything now (useful right after cloning, or after pulling changes):

```bash
pre-commit run --all-files
```

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

## Initial Cluster Setup

> **Note**: This section documents the manual bootstrap process performed before GitOps is established.

### Hardware Specifications

- `kihnu.nodes.ee`: HP EliteDesk 800 G2
  - CPU: i5-6500 4 CPUs @ 3.20GHz
  - RAM: 32 GB
  - SATA SSD: 1 TB (nvme0n1) SAMSUNG MZVLB1T0HALR-000H2
- `muhu.nodes.ee`: HP EliteDesk 800 G2
  - CPU: i5-6500T 4 CPUs @ 2.50GHz
  - RAM: 32 GB
  - SATA SSD: 1 TB (nvme0n1) SAMSUNG MZVLB1T0HALR-000H2
- `ruhnu.nodes.ee`: Lenovo ThinkCentre M910q
  - CPU: i5-6500T 4 CPUs @ 2.50GHz
  - RAM: 32 GB
  - NVMe SSD: 1 TB (nvme01) KINGSTON SNV2S1000G

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

### TalOS installation

Visit [TalOS Image factory](https://factory.talos.dev/) (v1.3.3, latest at the time of writing) and select the following options:

1. **Platform**: bare-metal
2. **Version**: 1.13.9 (latest at the time of writing)
3. **Architecture**: amd64, turn secure boot on
4. **System extensions**: siderolabs/iscsi-tools, siderolabs/util-linux-tools
5. **Customization**: let as it is

Important outputs:

- Schematic Ready
  - Your image schematic ID is: 613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245
- SecureBoot ISO
  - [https://factory.talos.dev/image/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245/v1.13.9/metal-amd64-secureboot.iso]
- Initial Installation
  - `factory.talos.dev/metal-installer-secureboot/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.9`
- Upgrading Talos Linux
  - `factory.talos.dev/metal-installer-secureboot/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.9`

Download the SecureBoot ISO and "burn" it to a USB stick.

```bash
sudo dd if=/home/dyego/Downloads/metal-amd64-secureboot.iso of=/dev/sda bs=4M status=progress && sync
```

To generate the proper TalOS config files, you need to install `talosctl` on your local machine. You can do this by running the following command:

```bash
curl -sL https://talos.dev/install | sudo sh
```

Ensure that you have `age` installed on your local machine. You can install it by running the following command:

```bash
sudo dnf install age -y
```

You also need to install `sops` on your local machine. You can download the latest release from the [sops GitHub releases page](https://github.com/getsops/sops/releases)

```bash
# Create sops configuration dir to store the age key
mkdir -p $XDG_CONFIG_HOME/sops/age

# Generate an age key pair
age-keygen -o $XDG_CONFIG_HOME/sops/age/keys.txt

# The command above will output the public key, which you will need to add to the sops configuration file
```

Now you can generate the TalOS secrets by running the following command:

```bash
# From this repository root
cd talos

# Create .sops.yaml file with the age public key
cat <<EOF > .sops.yaml
---
creation_rules:
  - age: >-
      age1sse7e289gefyre7tdrv4g9hudldyypvhsvz23ph6t73zhd0uhf8sevp2v4
EOF

# Generate the TalOS secrets bundle (prompts for confirmation before generating a new one)
topf secrets --confirm=false > secrets.yaml

# Encrypt the TalOS secrets using sops
sops -e -i secrets.yaml
```

Now you can boot TalOS on each node from the USB stick. `topf` detects maintenance-mode
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

> **Why `topf`, not `talhelper`**: this cluster originally used
> [`talhelper`](https://github.com/budimanjojo/talhelper) to generate Talos configs. It was archived
> and abandoned upstream on 2026-08-26, and its pinned `v3.1.17` vendors a pre-release
> `siderolabs/talos/pkg/machinery` missing an upstream fix — which generated `KubeEtcdEncryptionConfig`
> with the wrong secretbox key name (`key1` instead of the historically-correct `key2`) during the
> Talos v1.14.0 multi-doc config migration, breaking `kube-apiserver`'s ability to decrypt existing
> etcd Secrets on one node until manually patched. `topf` depends on the released `machinery v1.14.0`
> (fix included) and is actively maintained — see `ROADMAP.md`'s history for the migration.

```bash
topf kubeconfig > ~/.kube/config
```

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

As you can see, the cluster is up and running. Now we need to install a CNI plugin. In this case, we will use Cilium.

We are going to install it via Helm.

```bash
# Add the Cilium Helm repository
helm repo add cilium https://helm.cilium.io/

# Update the Helm repository
helm repo update

# Check the latest version of Cilium
helm search repo cilium

# Since we will use Gateway API, we need to install the CRDs first
kubectl apply --server-side=true  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/experimental-install.yaml

# Install Cilium via Helm
helm install cilium cilium/cilium \
  --version 1.20.0 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=172.31.86.10 \
  --set k8sServicePort=6443 \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.0.0.0/8 \
  --set autoDirectNodeRoutes=true \
  --set endpointRoutes.enabled=true \
  --set bpf.masquerade=true \
  --set bpf.monitorAggregation=none \
  --set socketLB.enabled=true \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set securityContext.privileged=true \
  --set ipam.mode=kubernetes \
  --set gatewayAPI.enabled=true \
  --set gatewayAPI.enableAlpn=true \
  --set bgpControlPlane.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{dns,drop,flow,flows-to-world,httpV2,icmp,port-distribution,tcp}"

# Check Cilium status
cilium status --wait
```

For BGP configuration, refer to the [Advanced Networking](#advanced-networking) section below.

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
  hosted apps (e.g. the personal website) — each app gets one `Application` per environment,
  generated from an `{app} x {env}` matrix. This _is_ the dynamic-expansion case ApplicationSet is
  for: every app needs the same `dev`/`prd` shape, and Kargo promotes Freight between the generated
  `Application`s — see [Standalone apps (ApplicationSet)](#standalone-apps-applicationset) below.
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
│   └── applicationset.yaml  # ApplicationSet: generates one Application per app x env
└── addons/
    ├── kustomization.yaml   # lists every addon Application
    ├── cilium.yaml          # Application: Cilium (multi-source: Helm chart + this repo's values)
    └── gateway-crds.yaml    # Application: Gateway API CRDs, sourced directly from the upstream repo

addons/
└── cilium/
    └── helm/
        └── values.yaml      # Cilium Helm values (source of truth, never inlined)

apps/
└── website/                 # one dir per standalone app, matching the ApplicationSet's `app` element
    └── config.json           # {"app": "website", "repoURL": "..."} - discovered by the git generator
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
standalone app x env (e.g. `website-dev`, `website-prd`) — see
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

# Install ArgoCD (pin the version — check https://github.com/argoproj/argo-cd/releases for latest)
kubectl -n argocd apply -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.0/manifests/install.yaml --server-side --force-conflicts
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

`argocd/apps-applicationset/applicationset.yaml` is an `ApplicationSet` named `apps`, using a
**matrix generator** that cross-joins two very different kinds of generator:

- A `list` generator with two fixed elements, `env: dev` and `env: prd`. `env` is a platform
  concept, not a per-app one — every app gets the same two environments, and a `list` generator can
  only ever emit exactly these two values, so there's nothing to validate.
- A Git **`files`** generator globbing `apps/*/config.json`. Each matching file becomes one set of
  template parameters (`app`, `repoURL`), so apps are discovered from the repo tree instead of being
  hardcoded in the `ApplicationSet` — adding an app never means editing it.

`matrix` produces one generated `Application` per `{app, env}` pair (`website-dev`, `website-prd`,
...), sourced entirely from the app's own repo (`deploy/overlays/{{.env}}`) — this repo owns no
plain manifests on the app's behalf. `kargo.akuity.io/authorized-stage` on each generated
`Application` delegates its sync authority to Kargo's matching `dev`/`prd` `Stage`, provisioned by
`charts/tenant` — see [Kargo](#kargo).

The `ApplicationSet` object itself is kept in sync from git by the self-syncing
`apps-applicationset` `Application` (source: `argocd/apps-applicationset/`) — see the table in
[Architecture](#architecture) above. Without that wrapper, editing this `ApplicationSet`'s
generators/template would require a manual `kubectl apply -k argocd/ --server-side` to take
effect, since the git generator only refreshes the _parameters_ it iterates over, not the
`ApplicationSet`'s own spec.

**Adding a new standalone app:**

1. `apps/<app-name>/config.json` — `{"app": "<app-name>", "repoURL": "<app-repo-url>"}`. No `env`
   key: that comes from the `list` generator's fixed pair, not from the app.
2. Commit and push — the Git generator picks up the new `config.json` on its next refresh and the
   matrix expands it to `<app-name>-dev` and `<app-name>-prd` `Application`s automatically, no
   `ApplicationSet` edit and no new `Application` YAML to write by hand.

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
| `kargo`                         | `1`       | yes       | Platform, plus one live app (website) provisioned via `charts/tenant` — see [Kargo](#kargo)                                                                                      |
| `kubevirt`                      | `1`       | yes       | KubeVirt + CDI operators, sourced as remote-URL Kustomize resources — see [KubeVirt](#kubevirt)                                                                                  |

### KubeVirt

Study-only addon: runs real VMs on the cluster (via KVM — all 3 nodes have `/dev/kvm` and Intel VT-x)
so `kubeadm init`/`join` can be practiced on genuine hosts, without touching the Talos-managed
cluster itself. Not part of the cluster's core function — safe to delete and recreate at will.

- `addons/kubevirt/kustomization.yaml` pulls the `kubevirt-operator.yaml` and `cdi-operator.yaml`
  manifests directly from their upstream GitHub release URLs (pinned tags, same idea as
  `gateway-crds`'s remote source, just via Kustomize remote resources instead of an ArgoCD source
  block, since neither project publishes a Kustomize-friendly directory path) — plus two local files,
  `kubevirt-cr.yaml` and `cdi-cr.yaml`, for the operators' own custom resources.
- CDI's `scratchSpaceStorageClass` is set to `longhorn` — this cluster's existing default
  StorageClass — instead of the upstream guide's `local-path-provisioner`, since Longhorn already
  covers that role here.
- No Talos machine-config changes were needed: `/dev/kvm` already exists on all 3 nodes without any
  `machine.kernel.modules` patch (verified via `talosctl read`/`talosctl list` before adding this
  addon).

**Typical workflow** (all commands below are for the user to run, not GitOps-managed — these are
scratch VMs, not tracked infrastructure):

```bash
# import a cloud image into a DataVolume (backed by Longhorn)
cat <<EOF | kubectl apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: cka-node1-disk
  namespace: kubevirt-study
spec:
  source:
    http:
      url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  storage:
    resources:
      requests:
        storage: 20Gi
    storageClassName: longhorn
EOF

# create a VM from that disk, console in, install containerd + kubeadm, kubeadm init/join
virtctl console cka-node1

# tear down fast when done
kubectl delete namespace kubevirt-study
```

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
`onepassword`, `cert-manager`, and `gateway`, which it depends on). Each standalone app hosted on
this cluster gets a `dev` and `prd` namespace/Stage, provisioned from the reusable `charts/tenant`
Helm chart (see [Adding a new standalone app via Kargo](#adding-a-new-standalone-app-via-kargo)
below) — the personal website (`apps/website/`) is the first app and the reference example, live
end-to-end as of 2026-08-25. A Warehouse watches the app's image tags, Freight flows through a `dev`
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

### Metrics dashboards

Grafana comes with kube-prometheus-stack's bundled dashboards (Kubernetes cluster/node/pod views,
CoreDNS, etc.) under **Dashboards**. Two known gaps, not bugs to chase if rediscovered:

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

### Known log noise (recheck on next Kubernetes upgrade)

`{namespace="kube-system"} |= "2379"` shows recurring `kube-apiserver` warnings on all 3 nodes, every
~10-30s, e.g.:

```text
W0816 19:53:07.904157       1 logging.go:55] [core] [Channel #32593 SubChannel #32594] grpc:
addrConn.createTransport failed to connect to {Addr: "127.0.0.1:2379", ServerName: "127.0.0.1:2379", }.
Err: connection error: desc = "transport: authentication handshake failed: context canceled"
```

Root cause, confirmed upstream in [kubernetes/kubernetes#134080](https://github.com/kubernetes/kubernetes/issues/134080):
`kube-apiserver` was recreating its etcd client on every metrics scrape instead of reusing a cached
connection — harmless log churn, not an actual etcd/apiserver problem (cluster health is unaffected).
Fixed by [kubernetes/kubernetes#138075](https://github.com/kubernetes/kubernetes/pull/138075), merged
2026-04-22, targeting **Kubernetes v1.37**; a backport to 1.34-1.36 was discussed in the PR but not
confirmed shipped as of this writing. This cluster was on `v1.36.2` when this entry was written; it
has since been upgraded to `v1.37.0` (`kubernetesVersion` in `talos/topf.yaml`) but this entry has
not yet been rechecked against that fix.

**Recheck when**: `kubernetesVersion` in `talos/topf.yaml` is bumped past `1.36.2` — see if this
noise disappears; if not, check whether the 1.34-1.36 backport of #138075 ever landed.

## Overall setup summary and sequence

1. Boot TalOS on each node from the USB stick and apply the TalOS config files.
2. Bootstrap the first node (kihnu.nodes.ee) and initialize the cluster.
3. Apply Gateway API CRDs (imperative, one-time).
4. Install Cilium via Helm.
5. Install ArgoCD (imperative, one-time).
6. Hand over to GitOps by applying `argocd/` kustomization.
7. Apply Cilium BGP/LoadBalancerIPPool via GitOps
8. Apply Sealed Secrets, Metrics Server, and Kubelet Serving Cert Approver via GitOps
9. Apply 1Password Operator via GitOps
10. Apply Cert-manager, and External-DNS via GitOps
11. Apply Gateway API via GitOps
12. Apply Hubble Gateway API resources via GitOps
13. Apply ArgoCD Gateway API resources and patches via GitOps
14. Apply Longhorn via GitOps
15. Apply Prometheus Operator CRDs, kube-prometheus-stack, Loki, and Alloy via GitOps (see
    [Observability](#observability))
16. Patch `talos/control-plane/` for `kube-scheduler`/`kube-controller-manager`
    `bind-address: 0.0.0.0` (needed for Prometheus to scrape them) and
    `machine.logging.destinations`/`KmsgLogConfig` (ships Talos's own logs to Alloy), then
    `topf render` to review and `topf apply` to push it
