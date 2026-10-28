## Why Cert-Manager?

1. If you need `https`?
2. It automates the process.

## Installation

1. I decided to install using helm.
2. The [documentation](https://cert-manager.io/docs/installation/helm/) for installing.
3. For now, I decided to go with a self signed CA.
4. So in-order for that create a `tls.yaml` file and apply it using the below command.
```bash

kubectl apply -f tls.yaml

kubectl get certificate -n juice-shop

```
