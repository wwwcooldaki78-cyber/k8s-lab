## Why Containerd?

1. I don't know I just picked one. I think its the popular choice!
2. Therefor Containerd is the container runtime I chose. There is total four different options you could chose from, I think, after looking through kubernetes [doc](https://kubernetes.io/docs/setup/production-environment/container-runtimes/). This is cause the CN needs to be Container Runtime Interface (CRI) complaient.
3. Containerd executes, manages, and lifecycle-tracks the actual containers running on a host machine.
## Installation

> After setting up the docker's apt repo, we only need to install the `containerd.io` package only cause that is all we need for kubernetes.

1. The installation page on kubernetes docs point me to [this](https://github.com/containerd/containerd/blob/main/docs/getting-started.md) github page of containerd repo.
2. I decided to install this CN from `apt-get`.
3. From there I'm redirected to [dockerdocs](https://docs.docker.com/engine/install/debian/) page.
4. And according to it first I had to set up Docker's `apt` repository.
```bash

sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update

sudo apt install containerd.io

containerd config default > /etc/containerd/config.toml

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd

sudo systemctl enable containerd

```
5. So after adding the repo I installed `containerd.io`. Then I had to make a small change to the configuration file, which is to change `SystemdCgroup = true`.