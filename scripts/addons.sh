#!/usr/bin/env bash
# misc-setup.sh - cluster add-ons, run on the CONTROL-PLANE after the worker has joined.
# More add-ons (MetalLB, Envoy Gateway, cert-manager, ...) can be added as new numbered sections.

set -Eeuo pipefail

# ==============================================================================
# 01. EDIT THESE VALUES
# ==============================================================================

readonly HELM_BUILDKITE_APT_KEY_ID="DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6"
readonly METRICS_SERVER_CHART_VERSION=""

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKDIR="$(dirname "$SCRIPT_DIR")"
readonly METALLB_CONFIG="$WORKDIR/infra/metallb-config.yaml"
readonly METALLB_CHART_VERSION=""

readonly ENVOY_GATEWAY_VERSION=""
readonly WAF_FILE="$WORKDIR/app/waf.yaml"  

readonly CERT_MANAGER_VERSION="v1.21.3"
readonly ACME_EMAIL="www.cooldaki78@gmail.com"
readonly CF_TOKEN_FILE="$WORKDIR/secrets/cloudflare-api-token"     # contains ONLY the token; chmod 600
readonly ISSUERS_FILE="$WORKDIR/infra/clusterissuers.yaml"   

# ==============================================================================
# 02. Helpers: --dry-run support
# ==============================================================================
DRY_RUN=0
SKIP_METALLB="${SKIP_METALLB:-0}"

usage() { echo "Usage: $0 [--dry-run] [--cloud]" >&2; exit 2; }

for arg in "$@"; do
    case "$arg" in
        --dry-run)       DRY_RUN=1 ;;
        --cloud)  SKIP_METALLB=1 ;;
        -h|--help)       usage ;;
        *)               echo "Unknown argument: $arg" >&2; usage ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
# a problem stops a real run, but only warns in a dry run
problem() { if [[ $DRY_RUN -eq 1 ]]; then echo "  WARNING (dry-run): $*" >&2; else die "$*"; fi; }

# run CMD...      -> execute it, or only print it in dry-run mode
run() {
    if [[ $DRY_RUN -eq 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi
}

run_retry() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] $*"
    else
        local attempts=5
        local delay=5
        local n=1
        until "$@"; do
            if (( n >= attempts )); then
                echo "Failed after $attempts attempts: $*" >&2
                return 1
            fi
            echo "Attempt $n failed, retrying in ${delay}s: $*" >&2
            sleep "$delay"
            n=$((n + 1))
            delay=$((delay * 2))
        done
    fi
}

write_file() {
    local dest=$1
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] would write $dest:"
        sed 's/^/      | /'
    else
        cat > "$dest"
    fi
}

wait_until() {
    local timeout=$1 desc=$2; shift 2
    local end=$((SECONDS + timeout))
    until "$@" >/dev/null 2>&1; do
        (( SECONDS < end )) || { echo "Timed out waiting for: $desc" >&2; return 1; }
        sleep 5
    done
}

[[ $DRY_RUN -eq 1 ]] && echo "*** DRY RUN: nothing will be changed ***"
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then die "Run this script with sudo."; fi

# kubectl and helm talk to the cluster as admin
[[ -r /etc/kubernetes/admin.conf ]] && export KUBECONFIG=/etc/kubernetes/admin.conf

# ==============================================================================
# 03. Preflight checks
# ==============================================================================
echo "==> Preflight checks"

command -v kubectl >/dev/null || problem "kubectl not found. Run the node-prep script first."

if ! kubectl get nodes >/dev/null 2>&1; then
    problem "cannot talk to the cluster (is this the control-plane, and did control-plane-init.sh finish?)"
else
    ready_workers=$(kubectl get nodes --no-headers \
        -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,TAINTS:.spec.taints[*].key' \
        | awk '$2=="True" && $3 !~ /control-plane/ {n++} END {print n+0}')
    [[ "$ready_workers" -ge 1 ]] || problem "no Ready worker node found. Join the worker first: the control-plane is tainted, so metrics-server would stay Pending."
    echo "  Ready worker nodes: $ready_workers"
fi

[[ -r "$METALLB_CONFIG" ]] || problem "MetalLB config not found: $METALLB_CONFIG (set METALLB_CONFIG at the top of this script)"

[[ -r "$WAF_FILE" ]] || problem "WAF settings file not found: $WAF_FILE (set WAF_FILE at the top of this script)"

[[ "$ACME_EMAIL" != CHANGE-ME* ]] || problem "Set ACME_EMAIL at the top of this script."
if [[ -r "$CF_TOKEN_FILE" ]]; then
    [[ "$(stat -c %a "$CF_TOKEN_FILE")" == "600" ]] || problem "$CF_TOKEN_FILE holds a DNS API token: run chmod 600 on it."
else
    problem "Cloudflare token file not found: $CF_TOKEN_FILE (create it first; it must contain only the token)"
fi

# ==============================================================================
# 04. Helm
# ==============================================================================
echo "==> 1. Helm"
if command -v helm >/dev/null 2>&1; then
    echo "  helm already installed ($(helm version --short 2>/dev/null || echo unknown)), skipping install"
else
    run apt-get update -qq
    run apt-get install -y curl gpg

    HELM_KEY_TMP=$(mktemp)
    trap 'rm -f "$HELM_KEY_TMP"' EXIT
    run curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey -o "$HELM_KEY_TMP"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] would verify the downloaded key's fingerprint equals $HELM_BUILDKITE_APT_KEY_ID (stop if not)"
    else
        got=$(gpg --import --import-options=show-only --with-colons "$HELM_KEY_TMP" 2>/dev/null \
              | awk -F: '$1 == "fpr" {print $10}' | head -n 1)
        [[ "$got" == "$HELM_BUILDKITE_APT_KEY_ID" ]] \
            || die "Unexpected Helm APT key ID '$got' (expected $HELM_BUILDKITE_APT_KEY_ID): potential key compromise, or Helm rotated its key. Check Helm's install docs."
        echo "  Helm APT key fingerprint verified"
    fi

    run rm -f /etc/apt/sources.list.d/helm-stable-debian.list /usr/share/keyrings/helm.gpg
    run install -m 0644 -D "$HELM_KEY_TMP" /etc/apt/keyrings/helm.asc

    write_file /etc/apt/sources.list.d/helm-stable-debian.sources <<'EOF'
Types: deb
URIs: https://packages.buildkite.com/helm-linux/helm-debian/any/
Suites: any
Components: main
Signed-By: /etc/apt/keyrings/helm.asc
EOF

    run apt-get update -qq
    run apt-get install -y helm
fi

# ==============================================================================
# 05. metrics-server (via Helm)
# ==============================================================================
echo "==> 2. metrics-server"
run install -d -m 700 "$WORKDIR"

approve_pending_kubelet_csrs() {
    local names
    names=$(kubectl get csr --no-headers 2>/dev/null \
            | awk '$3=="kubernetes.io/kubelet-serving" && $NF=="Pending" {print $1}' || true)
    if [[ -n "$names" ]]; then
        echo "  approving pending kubelet-serving CSRs: $(echo $names)"
        xargs -r kubectl certificate approve <<<"$names"
    else
        echo "  no pending kubelet-serving CSRs"
    fi
}
run approve_pending_kubelet_csrs

run_retry helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
run_retry helm repo update metrics-server

ms_version_args=()
[[ -n "$METRICS_SERVER_CHART_VERSION" ]] && ms_version_args=(--version "$METRICS_SERVER_CHART_VERSION")

run helm upgrade --install metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    "${ms_version_args[@]}" \
    --wait --timeout 5m

# ==============================================================================
# 06. MetalLB (via Helm), then the pool + L2 advertisement from your own file
# ==============================================================================
if [[ "$SKIP_METALLB" -eq 1 ]]; then
    : # does nothing
else
    echo "==> 3. MetalLB"

    if [[ -r "$METALLB_CONFIG" ]]; then
        echo "  addresses in your config : $(grep -oE '[0-9]+(\.[0-9]+){3}(/[0-9]+|-[0-9]+(\.[0-9]+){3})?' "$METALLB_CONFIG" | sort -u | tr '\n' ' ')"
    fi
    echo "  node IPs                 : $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"

    run_retry helm repo add metallb https://metallb.github.io/metallb --force-update
    run_retry helm repo update metallb

    metallb_version_args=()
    [[ -n "$METALLB_CHART_VERSION" ]] && metallb_version_args=(--version "$METALLB_CHART_VERSION")

    run helm upgrade --install metallb metallb/metallb \
        --namespace metallb-system --create-namespace \
        "${metallb_version_args[@]}" \
        --wait --timeout 5m

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] kubectl apply -f $METALLB_CONFIG   (retried for up to 2 minutes until MetalLB's webhook is ready). File contents:"
        [[ -r "$METALLB_CONFIG" ]] && sed 's/^/      | /' "$METALLB_CONFIG"
    else
        if ! wait_until 1000 "MetalLB webhook to accept $METALLB_CONFIG" kubectl apply -f "$METALLB_CONFIG"; then
            kubectl apply -f "$METALLB_CONFIG"    
        fi
        echo "  applied $METALLB_CONFIG"
    fi
fi
# ==============================================================================
# 07. Envoy Gateway (via Helm) + the Coraza proxy settings
# ==============================================================================
echo "==> 4. Envoy Gateway ${ENVOY_GATEWAY_VERSION}"

run_retry helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "$ENVOY_GATEWAY_VERSION" \
    --namespace envoy-gateway-system --create-namespace \
    --wait --timeout 5m
run kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
run kubectl wait --timeout=2m --for=condition=Established \
    crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io \
    crd/envoyproxies.gateway.envoyproxy.io crd/envoyextensionpolicies.gateway.envoyproxy.io

run kubectl apply -f "$WAF_FILE"
run kubectl get envoyproxy -n envoy-gateway-system

# ==============================================================================
# 08. cert-manager (via Helm) + Let's Encrypt ClusterIssuers (DNS-01 through Cloudflare)
# ==============================================================================
echo "==> 5. cert-manager ${CERT_MANAGER_VERSION}"

run_retry helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version "$CERT_MANAGER_VERSION" \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --set config.gatewayAPI.enabled=true \
    --wait --timeout 5m
run kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s

apply_cloudflare_secret() {
    local tok
    tok=$(tr -d '[:space:]' < "$CF_TOKEN_FILE")
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: "${tok}"
EOF
}
if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] would create Secret cloudflare-api-token in namespace cert-manager from $CF_TOKEN_FILE"
else
    apply_cloudflare_secret
fi

# Two issuers: staging first (untrusted certs, but generous rate limits), prod once staging works
run install -d -m 755 "$(dirname "$ISSUERS_FILE")"
write_file "$ISSUERS_FILE" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF

# cert-manager checks new issuers through its admission webhook; retry until it accepts them
if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] kubectl apply -f $ISSUERS_FILE   (retried for up to 2 minutes until the webhook is ready)"
else
    if ! wait_until 120 "cert-manager webhook to accept the ClusterIssuers" kubectl apply -f "$ISSUERS_FILE"; then
        kubectl apply -f "$ISSUERS_FILE"    # run once more, visibly, to show the real error
    fi
fi

# ==============================================================================
# 99. Verification
# ==============================================================================
if [[ $DRY_RUN -eq 1 ]]; then
    echo "==> Dry run finished: nothing was changed. Verification skipped."
    exit 0
fi

echo "==> 99. Verification"
fail=0

command -v helm >/dev/null && echo "OK: $(helm version --short)" || { echo "FAIL: helm missing"; fail=1; }

kubectl -n kube-system rollout status deploy/metrics-server --timeout=120s >/dev/null \
    && echo "OK: metrics-server deployment is rolled out" || { echo "FAIL: metrics-server not ready"; fail=1; }

kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s >/dev/null 2>&1 \
    && echo "OK: metrics API (v1beta1.metrics.k8s.io) is Available" || { echo "FAIL: metrics API not Available"; fail=1; }

# the first scrape takes up to ~60s after start
echo "  waiting for the first metrics (up to 3 minutes)..."
if wait_until 180 "kubectl top nodes" kubectl top nodes; then
    echo "OK: kubectl top nodes works"
    kubectl top nodes
else
    echo "FAIL: kubectl top nodes returns nothing. Check:"
    echo "      kubectl -n kube-system logs deploy/metrics-server --tail=20   (x509 errors mean an unapproved kubelet CSR: kubectl get csr)"
    fail=1
fi

if [[ "$SKIP_METALLB" -eq 1 ]]; then
    : #Does nothing
else
    kubectl -n metallb-system rollout status deploy/metallb-controller --timeout=120s >/dev/null \
        && echo "OK: metallb-controller is rolled out" || { echo "FAIL: metallb-controller not ready"; fail=1; }
    kubectl -n metallb-system rollout status ds/metallb-speaker --timeout=120s >/dev/null \
        && echo "OK: metallb-speaker is rolled out (one pod per node)" || { echo "FAIL: metallb-speaker not ready"; fail=1; }
    for kind in ipaddresspools l2advertisements; do
        n=$(kubectl -n metallb-system get "$kind.metallb.io" --no-headers 2>/dev/null | wc -l)
        [[ "$n" -ge 1 ]] && echo "OK: $n $kind found" || { echo "FAIL: no $kind in metallb-system"; fail=1; }
    done
fi

kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=120s >/dev/null \
    && echo "OK: envoy-gateway controller is rolled out" || { echo "FAIL: envoy-gateway not ready"; fail=1; }
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io >/dev/null 2>&1 \
    && echo "OK: Gateway API CRDs present" || { echo "FAIL: Gateway API CRDs missing"; fail=1; }
[[ $(kubectl -n envoy-gateway-system get envoyproxy --no-headers 2>/dev/null | wc -l) -ge 1 ]] \
    && echo "OK: EnvoyProxy settings applied" || { echo "FAIL: no EnvoyProxy found in envoy-gateway-system"; fail=1; }

for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
    kubectl -n cert-manager rollout status "deploy/$d" --timeout=120s >/dev/null 2>&1 \
        && echo "OK: $d is rolled out" || { echo "FAIL: $d not ready"; fail=1; }
done

# Ready=True means the ACME account registered with Let's Encrypt (email + internet access are fine).
# It does NOT test the DNS token: that only gets exercised when a Certificate is requested.
for ci in letsencrypt-staging letsencrypt-prod; do
    kubectl wait --for=condition=Ready "clusterissuer/$ci" --timeout=120s >/dev/null 2>&1 \
        && echo "OK: ClusterIssuer $ci is Ready" || { echo "FAIL: ClusterIssuer $ci not Ready (kubectl describe clusterissuer $ci)"; fail=1; }
done

echo
echo "Installed chart: $(helm list -n kube-system -f '^metrics-server$' -o json 2>/dev/null | grep -o '"chart":"[^"]*"' || echo unknown)"
[[ -n "$METRICS_SERVER_CHART_VERSION" ]] || echo "Tip: pin it by setting METRICS_SERVER_CHART_VERSION at the top of this script to the version shown above."
exit $fail