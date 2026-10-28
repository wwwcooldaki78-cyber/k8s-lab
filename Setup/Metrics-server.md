## Why Metrics-server?

1. Each node's kubelet exposes information about the memory and CPU of the pods that are running.
2. The metrics-server reads it and exposes it via `metrics.k8s.io` kubernetes api.
3. Horizontal Pod Autoscaler (HPA) need this because it works from reading the above mentioned api.

> It's not a monitoring system like prometheus.

## Installation

>- Metrics-server collects CPU and memory numbers by calling every kubelet’s HTTPS endpoint (port 10250).
>- Since that’s TLS, it must decide whether to trust the certificate the kubelet presents.
>- The proper fix is given below too.


1. I decided to install metrics-server via helm.
```bash

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/

helm upgrade --install metrics-server metrics-server/metrics-server --namespace kube-system

```
2. With `serverTLSBootstrap: true`, each kubelet asks the cluster to issue it a serving cert by creating a **CertificateSigningRequest (CSR)** with `signerName: kubernetes.io/kubelet-serving`. The cluster CA signs it, so metrics-server trusts it.
3. Enable it on each node (control plane and worker).
```bash

grep serverTLSBootstrap /var/lib/kubelet/config.yaml

echo 'serverTLSBootstrap: true' | sudo tee -a /var/lib/kubelet/config.yaml

sudo systemctl restart kubelet

```
4. Make it permanent for future nodes (once, from the control plane). Add `serverTLSBootstrap: true`.
```bash

kubectl edit cm kubelet-config -n kube-system

```
5. See the pending CSRs.
```bash

kubectl get csr

```
6. Inspect before approving (good habit). Confirm the IP and DNS names match that node.
```bash

kubectl get csr <csr-name> -o jsonpath='{.spec.request}' | base64 -d | openssl req -noout -text | grep -A1 "Subject Alternative Name"

```
7. Approve. The controller manager signs them with the cluster CA, and the kubelets pick up the signed certs automatically.
```bash

kubectl certificate approve <csr-name>

kubectl get csr -o name | xargs kubectl certificate approve

```
8. Verify on a node. The issuer should be `kubernetes` (your cluster CA), not the node itself, and the SANs should list the node’s IP and hostname.
```bash

kubectl get csr

sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-server-current.pem -noout -issuer -ext subjectAltName

```
9. Kubelet serving certs expire (about a year by default). The kubelet requests a renewal CSR before then, and that one also needs manual approval.
10. Command for deleting all the pending csr (needed that cause of some issue).
```bash

kubectl get csr --no-headers | awk '$NF=="Pending"{print $1}' | xargs -r kubectl delete csr

```