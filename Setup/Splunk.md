1. Using Splunk in a docker container for now(I'm testing things out in local environment, not cloud, for now).
```bash
docker pull splunk/splunk:latest

docker run -d --name splunk \
  -p 8000:8000 -p 8088:8088 -p 9997:9997 -p 8089:8089 \
  -e SPLUNK_GENERAL_TERMS='--accept-sgt-current-at-splunk-com' \
  -e SPLUNK_START_ARGS='--accept-license' \
  -e SPLUNK_PASSWORD='ChangeMe123!' \
  -e SPLUNK_HEC_TOKEN='lab-hec-token-1234' \
  -v splunk-etc:/opt/splunk/etc \
  -v splunk-var:/opt/splunk/var \
  splunk/splunk:latest

docker stop splunk

docker start splunk
```
1. Create two indexes `traefik` & `juiceshop`.
	1. I've set only a name and changed the value of "max size of entire index" to 5GB. The rest are default.
	2. In production environment you might want to give RBAC for indexes.
2. Go to HEC and add these two indexes to the token.

## Splunk OTEL

1. Install Splunk OTEL on k8s. I'm using helm.
```bash
helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart

helm repo update

helm install splunk-otel splunk-otel-collector-chart/splunk-otel-collector \
  -n splunk --create-namespace -f splunk-values.yaml
```
2. I've decided to collect logs from "traefik" & "juice-shop"
3. To collect those logs we need edit the `traefik-values.yaml` and `juice-shop.yaml` files.
4. To find out what are the configuration we need to do check [[__remove__Traefik]] and [[Juice-shop]]. 