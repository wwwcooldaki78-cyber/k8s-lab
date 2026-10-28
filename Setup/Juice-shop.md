1. We are deploying this web-app as a deployment.
2. The deployment file is `juice-shop.yaml`.

## Logs

3. We'll have to set "annotations" in the deployment file.
4. The annotations must go under `spec.template.metadata`.
```bash
kubectl apply -f juice-shop.yaml

kubectl rollout status deploy/juice-shop -n juice-shop

kubectl get pod -n juice-shop -l app=juice-shop -o jsonpath='{.items[*].metadata.annotations}'
```