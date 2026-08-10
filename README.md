# Homelab

This is a repository to setup a homelab running Kubernetes on top of TalOS.

## Table of Contents

- [Homelab](#homelab)
  - [Table of Contents](#table-of-contents)
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
    - [Current Applications](#current-applications)
    - [Kargo (planned)](#kargo-planned)

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
- Cilium BGP peering with Mikrotik router (TODO: add BGP configuration)

### TalOS installation

Visit [TalOS Image factory](https://factory.talos.dev/) (v1.3.3, latest at the time of writing) and select the following options:

1. **Platform**: bare-metal
2. **Version**: 1.13.8 (latest at the time of writing)
3. **Architecture**: amd64, turn secure boot on
4. **System extensions**: siderolabs/iscsi-tools, siderolabs/util-linux-tools
5. **Customization**: let as it is

Important outputs:

- Schematic Ready
  - Your image schematic ID is: 613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245
- SecureBoot ISO
  - [https://factory.talos.dev/image/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245/v1.13.8/metal-amd64-secureboot.iso]
- Initial Installation
  - `factory.talos.dev/metal-installer-secureboot/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.8`
- Upgrading Talos Linux
  - `factory.talos.dev/metal-installer-secureboot/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.8`

Download the SecureBoot ISO and "burn" it to a USB stick.

```bash
sudo dd if=/home/dyego/Downloads/metal-amd64-secureboot.iso of=/dev/sda bs=4M status=progress && sync
```

To generate the proper TalOS config files, you need to install `talosctl` on your local machine. You can do this by running the following command:

```bash
curl -sL https://talos.dev/install | sudo sh
```

Now you can generate the TalOS config files by running the following command:

```bash
# From this repository root
cd talos
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

## GitOps

This cluster is managed via [ArgoCD](https://argo-cd.readthedocs.io/), including its own
installation — ArgoCD manages itself. [Kargo](https://kargo.io/) is planned on top of this for
promotion and rendered-manifest review; see [Kargo (planned)](#kargo-planned) — not implemented yet.

Principles:

- **App-of-Apps** for the addon bundle (Cilium, observability, etc.) — a small, deliberate
  list. Not ApplicationSet, which solves a different problem (dynamic multi-cluster/multi-tenant
  fleets) this single-cluster homelab doesn't have.
- Helm values live in `apps/<app>/helm/values.yaml` — real, standalone YAML — rather than inlined
  as `valuesObject` in the `Application` CRD. Both are equally visible in `git diff`/PR review,
  since the `Application` object is itself git-tracked; the actual hard requirement is **never** a
  wall of imperative `helm --set` flags, which get no diff at all. A standalone file still earns
  its keep on tooling (`helm template`/`helm lint`/`helm diff` work directly against it, no
  extraction needed), review signal (a values change and `Application`-plumbing change — sync
  policy, `ignoreDifferences`, sync-wave — don't get bundled into the same file/diff), and it's
  what keeps Kargo's rendering workflow (planned) clean to build on top of later.
- Everything — including ArgoCD's own install — lives in this one repo. No separate
  `homelab-gitops` repo.

### Architecture

```text
argocd/
├── kustomization.yaml       # flat list of top-level Applications, applied once to bootstrap
├── argocd.yaml              # Application: ArgoCD's own installation (self-managed)
├── install/
│   └── kustomization.yaml   # tracks the upstream install.yaml (pinned tag) as a remote resource
├── apps.yaml                # Application: the addon App-of-Apps
└── apps/
    ├── kustomization.yaml   # lists every addon Application
    ├── cilium.yaml          # Application: Cilium (multi-source: Helm chart + this repo's values)
    └── gateway-crds.yaml    # Application: Gateway API CRDs, sourced directly from the upstream repo

apps/
└── cilium/
    └── helm/
        └── values.yaml      # Cilium Helm values (source of truth, never inlined)
```

Each addon gets an `apps/<app>/helm/values.yaml` — one `helm/` subdirectory per app. That leaves
room for a sibling `apps/<app>/kustomization.yaml` (app-level, not under `helm/`) for any extra
plain manifests the addon needs beyond what the Helm chart renders, combined into the same
`Application` as a third source (see [Adding a new Application](#adding-a-new-application-the-pattern)).

There is no separate "root" `Application`. `argocd/kustomization.yaml` is applied directly, once,
and produces two top-level, self-syncing Applications:

| Application | Sync wave | Source           | Purpose                                                     |
| ----------- | --------- | ---------------- | ----------------------------------------------------------- |
| `argocd`    | `-10`     | `argocd/install` | ArgoCD manages its own installation/upgrades                |
| `apps`      | `-9`      | `argocd/apps`    | App-of-Apps: owns every addon `Application` (e.g. `cilium`) |

Both run with `syncPolicy.automated: {prune: true, selfHeal: true}` — once bootstrapped, upgrading
ArgoCD or adding/changing an addon is a git commit, not a `kubectl`/`helm` command.

### Bootstrap (from zero)

Two phases: a one-time **imperative** install to get ArgoCD running at all (it has to exist before
it can manage itself), then handing over to GitOps.

**Day 0 — imperative, one-time:**

```bash
# Namespace for ArgoCD
kubectl create namespace argocd

# Repo access credentials (used by ArgoCD's repo-server; scope the PAT to this repo, read-only)
kubectl -n argocd create secret generic repo-homelab \
  --from-literal=type=git \
  --from-literal=url=https://github.com/dyegoe/homelab.git \
  --from-literal=username=dyegoe \
  --from-literal=password=$(op item get "GitHub Personal Access Token argocd" --fields token --reveal)
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

This applies the two top-level `Application` objects described above. From this point on:

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
          - $values/apps/<app-name>/helm/values.yaml
    - repoURL: https://github.com/dyegoe/homelab.git
      targetRevision: main
      ref: values
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

1. `apps/<app-name>/helm/values.yaml` — the Helm values, as real YAML.
2. `argocd/apps/<app-name>.yaml` — the `Application`, from the template above.
3. Add `<app-name>.yaml` to `argocd/apps/kustomization.yaml`'s `resources`.
4. Commit and push. `apps` (wave `-9`) picks up the new child `Application` automatically.

For a plain-manifest addition (no Helm chart involved, or extra manifests alongside a chart — e.g.
`gateway-crds`, or Cilium's BGP/LoadBalancerIPPool/HTTPRoute resources), point a source straight at
the upstream repo's manifest directory when one exists (`gateway-crds.yaml` sources
`kubernetes-sigs/gateway-api`'s `config/crd/experimental` path directly — no local mirror needed),
or add an `apps/<app-name>/kustomization.yaml` in this repo for manifests you own yourself. Either
way it's just another entry in the same `Application`'s `sources` list — no `ref`, since only the
values-reference source needs that.

### Adopting existing (non-GitOps) resources

If software is already running from a manual `helm install`/`kubectl apply` (as Cilium was, before
this pattern existed): **do not** set `syncPolicy.automated` on its first commit. Push it with
automation off, sync once manually (`argocd app sync <name>`, or via the UI), and confirm the diff
is empty or exactly what's expected — *before* enabling `automated: {prune: true, selfHeal: true}`
in a follow-up commit. This is the guardrail that would have caught the incident that motivated
this whole approach: a wrong Cilium value shipped via a raw `--set` flag and took an hour to
diagnose, because nothing rendered a reviewable diff before it reached the cluster.

### Current Applications

| Application | Sync wave | Automated | Notes                                                                                                                                                                                            |
| ----------- | --------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `argocd`       | `-10` | ✅         | Self-managed ArgoCD install                                                                                                                                                                                             |
| `apps`         | `-9`  | ✅         | App-of-Apps parent                                                                                                                                                                                                       |
| `gateway-crds` | `-8`  | ✅         | Gateway API CRDs, sourced directly from `kubernetes-sigs/gateway-api`'s `config/crd/experimental` path                                                                                                                 |
| `cilium`       | `-7`  | ⏳ pending | Adopted from the manual install above — automation enabled once the first-sync diff (including the still-pending BGP/LoadBalancerIPPool/HTTPRoute addition) is confirmed clean (see [Adopting existing (non-GitOps) resources](#adopting-existing-non-gitops-resources)) |

### Kargo (planned)

Not yet implemented. Planned scope: a single Warehouse feeding a single Stage (this one cluster) —
used for its PR-gated rendered-manifest review (Kargo's `hydrateTo` + a review branch), not
multi-environment promotion. This section will be filled in once bootstrapped.
