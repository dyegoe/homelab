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
    - [Rotating the ArgoCD repo credential](#rotating-the-argocd-repo-credential)
  - [Advanced Networking](#advanced-networking)
    - [Mikrotik BGP configuration](#mikrotik-bgp-configuration)
  - [1Password Operator](#1password-operator)
    - [Installation](#installation)
    - [How to use](#how-to-use)
    - [Creating a docker-registry (imagePullSecret) item](#creating-a-docker-registry-imagepullsecret-item)
    - [Migrating a bootstrap secret to 1Password](#migrating-a-bootstrap-secret-to-1password)
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

Now you can generate the TalOS config files by running the following command:

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

# Generate the TalOS secrets
talhelper gensecret > talsecret.sops.yaml

# Encrypt the TalOS secrets using sops
sops -e -i talsecret.sops.yaml

# Generate the TalOS config files
talhelper genconfig
```

Now you can boot TalOS on each node from the USB stick and run the following command:

```bash
talosctl apply-config --insecure --nodes 172.31.86.11 --file clusterconfig/k8s.nodes.ee-kihnu.nodes.ee.yaml
talosctl apply-config --insecure --nodes 172.31.86.12 --file clusterconfig/k8s.nodes.ee-muhu.nodes.ee.yaml
talosctl apply-config --insecure --nodes 172.31.86.13 --file clusterconfig/k8s.nodes.ee-ruhnu.nodes.ee.yaml
```

Copy TalOS config file to the `talosctl` config directory:

```bash
cp clusterconfig/talosconfig ~/.talos/config
```

Bootstrap the first node (kihnu.nodes.ee) and initialize the cluster:

```bash
talosctl bootstrap -n 172.31.86.11
```

Copy the Kubeconfig file to your local machine:

```bash
talosctl kubeconfig ~/.kube/config -n 172.31.86.11
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
`dev`/`prd` namespaces) — not for the cluster addons below; see [Kargo](#kargo). The platform is
up, but no Warehouse/Stage/Project exists yet — that comes once a standalone app needs it.

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
│   └── kustomization.yaml   # tracks the upstream install.yaml (pinned tag) as a remote resource
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
- Rename the default `website` field to `url`, value `https://github.com/dyegoe/homelab.git`
- Add a new `text` field named `type`, value `git`

The Login item's built-in `username`/`password` fields plus the two custom fields (`url`, `type`) map
1:1 onto the four keys ArgoCD's repo Secret needs below — and again later, unchanged, once this Secret
is handed off to the 1Password Operator (see
[Migrating a bootstrap secret to 1Password](#migrating-a-bootstrap-secret-to-1password)).

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
  project: default
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
`Application` delegates its sync authority to Kargo's matching `dev`/`prd` `Stage` (not yet
created — see [Kargo](#kargo)).

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
| `onepassword`                   | `-5`      | yes       |                                                                                                                                                                                  |
| `cert-manager`                  | `-4`      | yes       |                                                                                                                                                                                  |
| `cloudflared`                   | `-4`      | yes       |                                                                                                                                                                                  |
| `external-dns`                  | `-4`      | yes       |                                                                                                                                                                                  |
| `gateway`                       | `-3`      | yes       |                                                                                                                                                                                  |
| `longhorn`                      | `-2`      | yes       |                                                                                                                                                                                  |
| `kube-prometheus-stack`         | `-1`      | yes       | After `longhorn` - Prometheus/Grafana persistence needs a working storage class                                                                                                  |
| `loki`                          | `-1`      | yes       | Same storage dependency as above                                                                                                                                                 |
| `alloy`                         | `0`       | yes       | Log shipping - pods via the Kubernetes API, Talos's own logs via a LoadBalancer Service                                                                                          |
| `kargo`                         | `1`       | yes       | Platform only - no Warehouse/Stage/Project yet, see [Kargo](#kargo)                                                                                                              |

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
`onepassword`, `cert-manager`, and `gateway`, which it depends on); no Warehouse/Stage/Project
exists yet. Scope once the standalone website app is ready (built in a separate session): each such
app — starting with the personal website — gets a `dev` and `prd` namespace/Stage. A Warehouse
watches the app's image (or chart) source, Freight flows through a `dev` Stage, gets verified, then
promotes to `prd` via Kargo's `hydrateTo` + review-branch rendered-manifest diff. This is genuine
multi-environment promotion, since each app actually has separate dev/prd environments to promote
between.

**Not used for the cluster addons** in `argocd/addons/` — there's a single cluster and no dev/prd
split for infra, so there's nothing to promote between; a chart-version bump there already gets a
reviewable diff via a normal git PR, which is the same thing Kargo's rendered-manifest review would
add. Addon version bumps are automated via [Renovate](#renovate) instead, which opens that same
kind of reviewable PR.

**Chart:** `oci://ghcr.io/akuity/kargo-charts/kargo`, pinned in `argocd/addons/kargo.yaml`. CRDs
(`Warehouse`/`Stage`/`Project`/...) are bundled in the chart itself — unlike
`prometheus-operator-crds`, nothing else in this cluster needs them early, so no separate CRD-only
Application was needed.

**Admin login:** `api.secret.name: kargo-admin` in `addons/kargo/helm/values.yaml` points at a Secret
materialized by `addons/kargo/onepassword-kargo-admin.yaml` (same 1Password-operator pattern as
Grafana/cloudflared/the ArgoCD repo credential — see [1Password Operator](#1password-operator)),
rather than inlining `api.adminAccount.passwordHash`/`tokenSigningKey` in git. One-time setup, since
this repo never runs cluster-mutating or 1Password-mutating commands on your behalf:

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
   token item — see [1Password Operator](#1password-operator)):
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

`argocd/repo-homelab` holds the GitHub fine-grained PAT ArgoCD uses to read this repository. It started
as a plain imperative Secret at [Bootstrap ArgoCD](#bootstrap-from-zero) — the chicken-and-egg credential
that has to exist before ArgoCD can sync anything, including the 1Password Operator. Once the Operator
was up, it took over managing this Secret via a `OnePasswordItem` CR (see
[Migrating a bootstrap secret to 1Password](#migrating-a-bootstrap-secret-to-1password) for how that
migration was done) — rotation is no longer a manual `kubectl patch`.

**Source of truth:** 1Password item `homelab-gh-pat-argocd-homelab` (vault `Kubernetes`), field
`password`. Rotate roughly every 30-90 days as best practice.

**To rotate:** update the `password` field on that 1Password item with the new PAT. The 1Password
Operator reconciles the `repo-homelab` Secret from the item on its own polling interval (see the
[operator docs](https://developer.1password.com/docs/k8s/operator/)) — no `kubectl` required. Verify
once it's picked up:

```bash
argocd repo get --refresh hard https://github.com/dyegoe/homelab.git   # STATUS should be Successful
argocd app list | awk 'NR==1 || /Unknown|ComparisonError/'             # should be empty after a refresh
```

If apps are still showing stale `ComparisonError`, refresh them (`argocd app get <name> --refresh`) — the
auto-sync loop also picks up the new credential within a few minutes.

**Manual fallback**, if the Operator itself is down or hasn't picked up the change:

```bash
kubectl -n argocd patch secret repo-homelab \
  --type=merge \
  -p "{\"stringData\":{\"password\":\"$(op item get 'homelab-gh-pat-argocd-homelab' --fields password --reveal)\"}}"
```

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

## 1Password Operator

### Installation

Create the 1Password connect server. This will output a file `1password-credentials.json`.

```bash
op connect server create kubernetes-homelab --vaults Kubernetes
```

Create the 1Password connect token for the operator to use. Save the output token securely.

```bash
op connect token create kubernetes-operator --server kubernetes-homelab --vault Kubernetes
```

Create a sealed secret for the credentials file.

```bash
kubectl create secret generic onepassword-connect-credentials --from-file=1password-credentials.json=./1password-credentials.json --namespace onepassword --dry-run=client -o yaml > raw-credentials.yaml
kubeseal -o yaml < raw-credentials.yaml > sealedsecret-onepassword-connect-credentials.yaml
kubectl create secret generic onepassword-connect-token --from-literal=token="<your-token-here>" --namespace onepassword --dry-run=client -o yaml > raw-token.yaml
kubeseal -o yaml < raw-token.yaml > sealedsecret-onepassword-connect-token.yaml
```

Remove the raw files.

```bash
rm raw-*.yaml 1password-credentials.json
```

### How to use

You can create a OnePasswordItem resource to fetch secrets from 1Password. For example:

```yaml
---
apiVersion: onepassword.com/v1
kind: OnePasswordItem
metadata:
  name: SECRET_NAME
spec:
  itemPath: "vaults/VAULT/items/ITEM"
```

Or use the Deployment annotation to inject secrets directly into pods:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deployment-example
  annotations:
    operator.1password.io/item-path: "vaults/VAULT/items/ITEM"
    operator.1password.io/item-name: "SECRET_NAME"
```

For more information, refer to the [official documentation](https://developer.1password.com/docs/k8s/operator/).

### Creating a docker-registry (imagePullSecret) item

The Operator has no docker-registry-specific logic: it copies 1Password item field **labels**
straight into the generated Secret's `data` keys, verbatim — the same generic mechanism as [How to
use](#how-to-use) above. To get a working `kubernetes.io/dockerconfigjson` image pull secret out of
it, two things have to line up:

1. The `OnePasswordItem` needs a top-level `type: kubernetes.io/dockerconfigjson` (a real field on
   the CRD, sibling of `metadata`/`spec` — not a `spec` field), which the Operator copies onto the
   generated Secret's `type`. See `apps/website/dev/onepassword-ghcr-pull.yaml` for a real example.
2. Kubernetes requires that Secret type to carry exactly one data key, `.dockerconfigjson`,
   containing the full Docker config JSON. So the 1Password item itself needs a field **labeled
   exactly `.dockerconfigjson`** (the leading dot is a valid Secret data-key character, so it's
   preserved as-is) whose value is that JSON blob — not the individual username/password.

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

Kustomize/ArgoCD only ever render the `OnePasswordItem` pointer above — it carries no secret
material. The real Secret is materialized afterward, in-cluster, when the Operator reconciles that
CR against 1Password directly; there's no way for Kustomize itself to build a docker-registry Secret
from a 1Password item (it has no 1Password awareness, and its generators only read literals/files
already present in the repo at render time).

### Migrating a bootstrap secret to 1Password

Worked example: the ArgoCD repo credential (`argocd/repo-homelab`, see
[Bootstrap ArgoCD](#bootstrap-from-zero), including the 1Password item it's sourced from) started as a
plain imperative Secret, since it has to exist before ArgoCD — and therefore before the 1Password
Operator — can sync anything. Once the Operator is up, it can take over managing that Secret:

1. Add the `OnePasswordItem` manifest (`argocd/install/onepassword-github-dyegoe-homelab.yaml`), pointing
   at the same 1Password item created during bootstrap:

   ```yaml
   apiVersion: onepassword.com/v1
   kind: OnePasswordItem
   metadata:
     name: repo-homelab-token
     labels:
       argocd.argoproj.io/secret-type: repository
   spec:
     itemPath: "vaults/Kubernetes/items/homelab-gh-pat-argocd-homelab"
   ```

2. Wire it into `argocd/install/kustomization.yaml`'s `resources`.

3. Commit and push. Once ArgoCD syncs, the Operator creates `repo-homelab` itself — delete the original
   imperative Secret:

   ```bash
   kubectl -n argocd delete secret repo-homelab
   ```

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

`https://grafana.nodes.ee`. Credentials come from the `homelab-grafana` 1Password item (`username`/
`confirmNew` fields), wired in via `grafana.podAnnotations` in
`addons/kube-prometheus-stack/helm/values.yaml` (same 1Password-operator annotation pattern as
`cloudflared`/`external-dns` — see [1Password Operator](#1password-operator)).

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

Talos's own logs (kernel + service, from all 3 nodes, shipped via `machine.logging.destinations` +
`KmsgLogConfig` in `talos/talconfig.yaml`):

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
bot token, `chat_id` is the target chat) via the same `operator.1password.io/item-path` annotation pattern
used for Grafana/cloudflared — see [1Password Operator](#1password-operator) — injected as a Secret
mounted into the Alertmanager pod at `/etc/alertmanager/secrets/telegram-bot-token/`.
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
confirmed shipped as of this writing. This cluster runs `v1.36.2` (`kubernetesVersion` in
`talos/talconfig.yaml`), so it isn't fixed yet.

**Recheck when**: `kubernetesVersion` in `talos/talconfig.yaml` is bumped past `1.36.2` — see if this
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
16. Patch `talos/talconfig.yaml` for `kube-scheduler`/`kube-controller-manager`
    `bind-address: 0.0.0.0` (needed for Prometheus to scrape them) and
    `machine.logging.destinations`/`KmsgLogConfig` (ships Talos's own logs to Alloy), then
    `talhelper genconfig` and `talosctl apply-config`
