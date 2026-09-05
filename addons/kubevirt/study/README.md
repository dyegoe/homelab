# CKA kubeadm practice on KubeVirt

Spin up real VMs on this cluster via the `kubevirt` addon, install containerd/kubeadm/kubelet by
hand, and run actual `kubeadm init`/`kubeadm join` for CKA practice - without touching the
Talos-managed cluster itself.

Everything here is **disposable and user-applied**, not GitOps-managed: `addons/kubevirt/kustomization.yaml`
only installs the KubeVirt/CDI operators, not these study VMs. Create/destroy this namespace as
often as you like.

## Sizing

Each node currently has ~4 allocatable vCPUs and ~32Gi allocatable memory, with roughly 1.5-2 free
vCPUs per node at typical cluster load. The template below requests 2 vCPU / 4Gi per VM - enough
for a kubeadm control-plane or worker node, and cheap enough to run 2-3 VMs across the 3 physical
nodes without starving the real cluster workloads.

## Prerequisites

- `virtctl` installed (`kubectl krew install virt`, or download the `v1.9.0` binary matching this
  cluster's KubeVirt version from the [kubevirt/kubevirt releases](https://github.com/kubevirt/kubevirt/releases)).
- The `kubevirt` addon synced and healthy (`kubectl get kubevirt -n kubevirt` shows `Deployed`).

## 1. Create the namespace and import a disk

```bash
kubectl create namespace kubevirt-study
kubectl apply -f addons/kubevirt/study/datavolume-node.yaml
kubectl get dv -n kubevirt-study -w   # wait for cka-node1-disk to say Succeeded
kubectl apply -f addons/kubevirt/study/vm-node.yaml
```

The `DataVolume` triggers a CDI importer pod (`importer-cka-node1-disk-...`) that downloads the
Ubuntu cloud image straight into a Longhorn-backed PVC - first import takes a few minutes depending
on your internet connection. `kubectl logs -n kubevirt-study importer-cka-node1-disk-<suffix>`
shows download progress if you want to watch.

For a multi-node practice cluster, copy both `datavolume-node.yaml` and `vm-node.yaml` and replace
every `cka-node1` with `cka-node2`, `cka-node3`, etc., then `kubectl apply` each pair.

## 2. Start the VM and log in

```bash
virtctl start cka-node1 -n kubevirt-study
virtctl console cka-node1 -n kubevirt-study   # Ctrl+] to exit
```

Cloud-init takes 30-60s on first boot. Log in as `ubuntu` / `kubevirt` (set in the VM's
`cloudInitNoCloud` userData - change it there before applying if you want a different password).

Confirm networking and note the VM's pod-network IP (needed for `kubeadm join` across VMs):

```bash
ip -4 addr show eth0
ping -c1 8.8.8.8
```

## 3. Install containerd + kubeadm (repeat per VM)

Inside each VM console:

```bash
sudo swapoff -a
sudo modprobe overlay br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

(Match the `v1.31` repo to whatever Kubernetes version you're practicing against.)

## 4. Bootstrap the cluster

On `cka-node1` (control-plane):

```bash
sudo kubeadm init --pod-network-cidr=192.168.0.0/16
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

Copy the `kubeadm join ...` command it prints, and run it (with `sudo`) on `cka-node2`/`cka-node3`.

## 5. Tear down

```bash
kubectl delete namespace kubevirt-study
```

Deletes the VMs, their `DataVolume`s, and the backing Longhorn PVCs in one shot. The `kubevirt`/`cdi`
addon itself is untouched - only your practice VMs are gone.
