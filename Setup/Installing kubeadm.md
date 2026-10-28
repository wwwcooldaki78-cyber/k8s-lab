## Installation
1. The kubernetes [docs](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) was the thing I used at the time of building this lab.
```bash
   
   sudo apt-get install -y apt-transport-https ca-certificates curl gpg
   
 sudo mkdir -p -m 755 /etc/apt/keyrings
 
 curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update

sudo apt-get install -y kubelet kubeadm kubectl

sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet

```
