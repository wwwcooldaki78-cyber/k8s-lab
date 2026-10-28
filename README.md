## Steps Involved

1. Disable Swap
2. Load Essential Kernel Modules
3. Configure critical sysctl parameters
4. Install container runtime, [Containerd](Setup/Containerd.md) is what is chose
5. Setting Up the Kubernetes Repositories
6. Install kubelet [kubeadm](./Setup/Installing%20kubeadm.md) kubectl
7. Initialize the Cluster
8. Install [Calico](./Setup/Calico.md) CNI
9. Join the Worker Node
10. Install [Helm](./Setup/Helm.md)
11. Install [Metrics-server](./Setup/Metrics-server.md)
12. Install [MetalLB](./Setup/MetalLB.md)
13. Install [Envoy Gateway](./Setup/Envoy%20Gateway.md) + apply the Corza proxy settings.
14. Install [Cert-Manager](./Setup/Cert-Manager.md)
15. Setup [Splunk](./Setup/Splunk.md) otel
16. Verify Cluster Health
17. Test Pod Scheduling
18. Deploy the vulnerable web app ([Juice-shop](./Setup/Juice-shop.md))

### Install using scripts

1. These is the easiest way to setup nodes.
2. I would recommend reading and understanding the components involved in the installation process.
3. The steps involved with in the script is similar. But I have made some updates to the installation process compared to the manual way.

> The script doesn't install Splunk otel. I made it that way because I wanted the freedom to install it when I decide to play with Splunk.

> The script also doesn't deploy the OWASP Juice Shop. I have to apply it manually.

#### Deploy Owasp Juice Shop

```bash

kubectl apply -f juice-shop.yaml

kubectl apply -f gateway.yaml -f httproute.yaml

watch -n 1 kubectl get gateway -A

kubectl apply -f waf-policy.yaml

kubectl get envoyextensionpolicy -n juice-shop

```

#### Source the bashrc files

1. First, run source `/etc/bash.bashrc` then source `~/.bashrc`.
2. Even if we did that on the script it will not reflect.