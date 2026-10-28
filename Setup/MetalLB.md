## Why MetalLB?

1. It does two jobs: **it hands out IP addresses, and it announces them to your network.**
2. **Pods don’t stay put.** Pods can be rescheduled to another node. If clients are pointed at `worker-node`’s IP and the pod moves, or the node dies, the app becomes unreachable. Your IP is tied to a machine, whereas MetalLB’s IP belongs to the Service and moves between nodes.
3. **Port 80/443 is awkward in Kubernetes.** NodePort Services only allow ports 30000-32767 by default, so you can’t just say “node port 80 → pods.” You’d need `hostPort` or `hostNetwork`, which bind directly on the node and conflict if two pods want the same port.

> ### How it’s done in the real world
> 
DNS points to **one stable address that isn’t tied to any particular node**, and something behind that address spreads traffic over healthy nodes.

## Installation

> - **`*-values.yaml`** (like `traefik-values.yaml`, `splunk-values.yaml`) holds Helm chart settings. You pass it with `helm install ... -f file`.
> - **`metallb-config.yaml`** holds Kubernetes custom resources (`IPAddressPool` and `L2Advertisement`). You apply it with `kubectl apply -f`, not Helm.

1. I have decided to install metalLB using helm ([Installation doc](https://metallb.universe.tf/installation/#installation-with-helm) ). 

```bash

helm repo add metallb https://metallb.github.io/metallb

helm repo update

helm install metallb metallb/metallb -n metallb-system --create-namespace

```