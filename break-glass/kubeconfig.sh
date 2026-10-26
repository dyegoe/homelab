#!/usr/bin/env bash
# Prints a break-glass kubeconfig (token from break-glass/, server = the Talos VIP) to
# stdout. Run it once while Omni works (e.g. with the Omni context); the result must already be on
# disk before an outage, since generating it needs a working context.
#
#   break-glass/kubeconfig.sh > /tmp/break-glass.kubeconfig
#   KUBECONFIG=/tmp/break-glass.kubeconfig kubectl get nodes  # test
#   KUBECONFIG=~/.kube/config:/tmp/break-glass.kubeconfig kubectl config view --flatten \
#     > /tmp/merged && mv /tmp/merged ~/.kube/config            # keep it locally (works offline)
#   # second copy in 1Password (offline access enabled), then: rm /tmp/break-glass.kubeconfig
set -euo pipefail

server="https://172.31.86.10:6443"
secret="break-glass-admin-token"

token=$(kubectl -n kube-system get secret "${secret}" -o jsonpath='{.data.token}' | base64 -d)
ca=$(kubectl -n kube-system get secret "${secret}" -o jsonpath='{.data.ca\.crt}')

if [[ -z "${token}" || -z "${ca}" ]]; then
  echo "secret kube-system/${secret} has no token/ca.crt yet; apply break-glass/ first (kubectl apply -k break-glass/)" >&2
  exit 1
fi

cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: k8s-nodes-ee-break-glass
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
users:
  - name: break-glass-admin
    user:
      token: ${token}
contexts:
  - name: k8s-nodes-ee-break-glass
    context:
      cluster: k8s-nodes-ee-break-glass
      user: break-glass-admin
current-context: k8s-nodes-ee-break-glass
EOF
