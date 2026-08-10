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
    - [ArgoCD Bootstrap](#argocd-bootstrap)

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

> **Note**: Bootstrap steps will be documented here once implemented. Direction decided so far:

- **ArgoCD** for reconciliation, **Kargo** for promotion and rendered-manifest review — not ArgoCD alone.
- **App-of-Apps** for the platform/addon bundle (Cilium, CoreDNS, observability, etc.) — a small,
  deliberate list. Not ApplicationSet, which is for dynamic multi-cluster fleets this isn't.
- Manifests are **rendered** (via Kargo's `hydrateTo` + a PR-gated review branch) rather than
  inlining full Helm values blocks into `Application` CRDs, so config changes show up as an actual
  Kubernetes-resource diff before reaching the cluster.
- **Single Warehouse → single Stage** (this one cluster) — Kargo is used for its promotion-review
  safety net here, not multi-environment promotion.
- Everything lives in this repo — no separate `homelab-gitops` repo.

### ArgoCD Bootstrap

```bash
# Create the argocd namespace
kubectl create namespace argocd
```
