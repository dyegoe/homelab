---
machine:
  logging:
    destinations:
      - endpoint: "tcp://172.31.100.2:5140/" # Alloy's alloy-talos-logs LoadBalancer Service
        format: "json_lines"
  kubelet:
    image: ghcr.io/siderolabs/kubelet:{{ .KubernetesVersion }}
    defaultRuntimeSeccompProfileEnabled: true
    disableManifestsDirectory: true
    extraArgs:
      rotate-server-certificates: "true"
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options:
          - bind
          - rshared
          - rw
  network:
    interfaces:
      - deviceSelector:
          physical: true
        dhcp: true
        vip:
          ip: 172.31.86.10 # Your native Talos VIP
