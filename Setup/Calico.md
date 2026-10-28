## Why Calico?

1. Kubernetes has a lot of network policies like every pod must have its own unique IP and every pod should be able to talk to each other.
2. But kubernetes doesn't comes with the software that applies all those polices.
3. It manages pod-to-pod communication, network security policies, & high performance routing. These are its core purpose.

## Installation

1. I decided to install calico using an "operator".
2. This operator manages installation, upgrades, & life cycle of the calico pods.
3. I felt like this was the recommended method while looking through the [doc](https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises).
```bash

kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/v3_projectcalico_org.yaml

kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/tigera-operator.yaml

curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/custom-resources.yaml

kubectl create -f custom-resources.yaml

watch kubectl get tigerastatus

```