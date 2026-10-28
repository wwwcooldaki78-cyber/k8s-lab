## Why Coraza?

1. Coraza is a waf engine.
2. I needed Coraza to solve a particular problem initially.
3. I wanted see in the SIEM when someone is enumerating or attacking my website, regardless of successful or not.
4. So I decided to implement Coroza into [[Envoy Gateway]].

## Installation

1. The route I gone with was the __Dynamic module__.
	1. This is a native Envoy extension loaded from a file inside the proxy container.
	2. Envoy Gateway’s current docs use it to load Coraza.
2. I created a `EnvoyExtensionPolicy` targeting `juice-gateway`.
3. Apply the `waf.yaml`.
```bash

kubectl apply -f waf.yaml

kubectl get envoyproxy my-proxy -n envoy-gateway-system -o yaml

```
4. Then created a waf policy, which is in detection mode and apply it.
```bash

kubectl apply -f waf-policy.yaml

kubectl get envoyextensionpolicy -n juice-shop

```
5. I'm using `OWASP Core Rule Set`.
6. Check if the detection is working or not.
```bash

curl -ik --resolve juice.local:443:10.209.57.80 "https://juice.local/?id=1'+OR+'1'%3D'1"

kubectl logs -n envoy-gateway-system deploy/<my-envoy-deployment> -c envoy --tail=50

```
