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

1. I had used this script for one control-plane and one worker-node setup. Might have to modify the scripts little bit if you are planing to go with some other architecture type.
2. **Step 1:** run the [prepare.sh](./scripts/prepare.sh) on both nodes.
3. **Step 2:** run the [init-cp.sh](./scripts/init-cp.sh) on the control plane.
	- After the script has finished running, copy the contents of `worker-join-command.txt` form the data-plane.
	- Then create a new file called `worker-join-command.txt` in the worker node and paste the contents here.
4. **Step 3:** run the [connect-wn.sh](./scripts/connect-wn.sh).
5. **Step 4:** run the [addons.sh](./scripts/addons.sh)
6. **Step 5:** When you are ready deploy the vulnerable app by running the commands shown [below](#deploy-owasp-juice-shop).

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

## License

This repository contains software and educational documentation released under different licenses.

- **Code and scripts:** MIT License
    
- **Documentation and educational notes:** [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)
    

Unless otherwise stated, original software code and scripts are released under the MIT License, while original documentation and educational notes are released under CC BY 4.0.

Third-party content remains subject to its respective license. These licenses apply only to material I have the right to license.