## Why Envoy Gateway?

1. I initially had traefik.
2. I wanted to write detection rules for when someone is attacking the website.
3. If I take SQLi for example, there are different ways we can write SQLi payload and its inefficient for me create a blacklist of all known payloads that an attacker might use.
4. The solution I found to solve this issue was to install a waf and it will detect when someone attacks and logs it. I can access that in splunk.
5. Traefik had a waf plugin. But its not maintained actively anymore. Therefore I had to ditch traefik. I could've installed a standalone waf but didn't want to make the networking complex.
6. Then, I came upon Envoy Gateway. I can integrate Coraza (engine) and OWASP Core Rule Set to it.

## Installation

1. The [docs](https://gateway.envoyproxy.io/docs/install/install-helm/#install-with-helm) to install using helm.
2. We need to prepare the manifests. The `gateway.yaml` & `httproute.yaml`.
3. Apply them.
```bash

kubectl apply -f gateway.yaml

kubectl apply -f httproute.yaml

```

## Configured so far

1. Can route traffic to pods on a specific namespace based on host header.
2. Enabled HTTPS using [[Cert-Manager]].
3. Enabled **`HSTS`**.
4. Envoy gateway require TLS 1.2 or newer.
5. Attached [[Coraza]] to Envoy Gateway.