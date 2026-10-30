#!/usr/bin/env bash

set -Eeuo pipefail

# ==============================================================================
# 01. EDIT THESE VALUES
# ==============================================================================
readonly CP_DOMAIN="$(hostname -f)"    # DNS name for the API server, e.g. k8s.lab.yourdomain.com
readonly CP_IP="$(hostname -I | awk '{print $1}')"                      # this node's static IP (must belong to THIS machine)
readonly POD_CIDR="10.244.0.0/16"                   # must not overlap your node network or MetalLB range
readonly SERVICE_CIDR="10.96.0.0/12"
readonly CALICO_VERSION="v3.33.0"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKDIR="$(dirname "$SCRIPT_DIR")"
readonly OUTPUT_DIR="$WORKDIR/outputs_files"
readonly KUBEADM_CONFIG="$OUTPUT_DIR/kubeadm-config.yaml"
readonly CALICO_DIR="$OUTPUT_DIR/calico-${CALICO_VERSION}"
readonly CALICO_BASE="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"
readonly JOIN_FILE="$OUTPUT_DIR/worker-join-command.txt"

# ==============================================================================
# 02. Helpers: --dry-run support
# ==============================================================================
DRY_RUN=0
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--dry-run]" >&2; exit 2; }

die() { echo "ERROR: $*" >&2; exit 1; }
# a problem stops a real run, but only warns in a dry run
problem() { if [[ $DRY_RUN -eq 1 ]]; then echo "  WARNING (dry-run): $*" >&2; else die "$*"; fi; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi
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

if [[ -t 1 ]]; then BOLD=$'\033[1m'; GREEN=$'\033[1;32m'; RESET=$'\033[0m'; else BOLD=""; GREEN=""; RESET=""; fi

[[ $DRY_RUN -eq 1 ]] && echo "*** DRY RUN: nothing will be changed ***"
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then die "Run this script with sudo."; fi

# ==============================================================================
# 03. Preflight checks
# ==============================================================================
echo "==> Preflight checks"

HOSTS_FIX_PENDING=0
DOM_RE=${CP_DOMAIN//./\\.}
LOOPBACK_RE="^127\.0\.1\.1[[:space:]]+([^#]*[[:space:]])?${DOM_RE}([[:space:]]|\$)"
if grep -qE "$LOOPBACK_RE" /etc/hosts; then
    echo "  /etc/hosts maps $CP_DOMAIN to 127.0.1.1; pointing it at $CP_IP instead. Current line:"
    grep -nE "$LOOPBACK_RE" /etc/hosts | sed 's/^/      /'
    run sed -i -E "s/^127\.0\.1\.1(([[:space:]]+[^#]*)?[[:space:]]${DOM_RE}([[:space:]]|\$))/${CP_IP}\1/" /etc/hosts
    HOSTS_FIX_PENDING=$DRY_RUN
fi

if [[ "$CP_DOMAIN" == CHANGE-ME* || "$CP_IP" == CHANGE-ME* ]]; then
    problem "Edit CP_DOMAIN and CP_IP at the top of this script first."
fi

command -v kubeadm >/dev/null || problem "kubeadm not found. Run the node-prep script first."

addrs=$(ip -4 -o addr show 2>/dev/null || true)
grep -q "inet ${CP_IP}/" <<<"$addrs" || problem "CP_IP ${CP_IP} is not assigned to any interface on this machine."

resolved=$(getent ahostsv4 "$CP_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
if ! grep -qx "$CP_IP" <<<"$resolved"; then
    problem "$CP_DOMAIN resolves to '${resolved:-nothing}', not $CP_IP. Fix DNS, or edit /etc/hosts."
fi

# ==============================================================================
# 04. kubeadm init (config file, not CLI flags)
# ==============================================================================
echo "==> Initialising the control plane"
run install -d -m 700 "$OUTPUT_DIR"
run install -d -m 700 "$WORKDIR"

if [[ -f /etc/kubernetes/admin.conf ]]; then
    echo "  /etc/kubernetes/admin.conf exists: cluster already initialised, skipping kubeadm init"
else
write_file "$KUBEADM_CONFIG" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${CP_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: "${CP_IP}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
controlPlaneEndpoint: "${CP_DOMAIN}:6443"
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
apiServer:
  certSANs:
    - ${CP_DOMAIN}
    - ${CP_IP}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true
EOF
    run kubeadm config validate --config "$KUBEADM_CONFIG"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] ctr -n k8s.io images pull <each image from 'kubeadm config images list'>"
    else
        echo "  Pulling control-plane images (progress per layer):"
        for img in $(kubeadm config images list --config "$KUBEADM_CONFIG"); do
            ctr -n k8s.io images pull "$img"
        done
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] kubeadm init --config $KUBEADM_CONFIG 2>&1 | tee $WORKDIR/kubeadm-init.log"
    else
        kubeadm init --config "$KUBEADM_CONFIG" 2>&1 | tee "$WORKDIR/kubeadm-init.log"
    fi
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

setup_kubeconfig() {
    install -d -m 700 /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        local home grp
        home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        grp=$(id -gn "$SUDO_USER")
        install -d -m 700 -o "$SUDO_USER" -g "$grp" "$home/.kube"
        install -m 600 -o "$SUDO_USER" -g "$grp" /etc/kubernetes/admin.conf "$home/.kube/config"
    fi
}
echo "==> Setting up kubeconfig for kubectl"
run setup_kubeconfig

approve_kubelet_serving_csrs() {
    local i names
    for ((i = 0; i < 12; i++)); do
        names=$(kubectl get csr --no-headers 2>/dev/null | awk '$3=="kubernetes.io/kubelet-serving" && $NF=="Pending" {print $1}' || true)
        if [[ -n "$names" ]]; then
            xargs -r kubectl certificate approve <<<"$names"
            return 0
        fi
        sleep 5
    done
    echo "  (no pending kubelet-serving CSR found yet; check later with: kubectl get csr)"
}
echo "==> Approving the kubelet serving certificate request(s)"
run approve_kubelet_serving_csrs

# ==============================================================================
# 05. Calico CNI (Tigera operator)
# ==============================================================================
echo "==> Installing Calico ${CALICO_VERSION} with the Tigera operator"
run install -d -m 700 "$CALICO_DIR"
for f in v3_projectcalico_org.yaml tigera-operator.yaml custom-resources.yaml; do
    run curl -fsSLo "$CALICO_DIR/$f" "$CALICO_BASE/$f"
done

if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] would set the ipPool cidr in custom-resources.yaml to $POD_CIDR"
else
    CR="$CALICO_DIR/custom-resources.yaml"
    n=$(grep -cE '^[[:space:]]*cidr:' "$CR" || true)
    [[ "$n" -eq 1 ]] || die "expected exactly one 'cidr:' line in $CR, found $n. Edit it by hand to $POD_CIDR."
    sed -i -E "s#^([[:space:]]*cidr:).*#\1 ${POD_CIDR}#" "$CR"
    echo "  custom-resources.yaml now uses: $(grep -E '^[[:space:]]*cidr:' "$CR" | tr -s ' ')"
fi

run kubectl apply --server-side --force-conflicts -f "$CALICO_DIR/v3_projectcalico_org.yaml"
run kubectl apply --server-side --force-conflicts -f "$CALICO_DIR/tigera-operator.yaml"
run kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=120s
run kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=300s
run kubectl apply --server-side --force-conflicts -f "$CALICO_DIR/custom-resources.yaml"

run kubectl patch installation default --type=merge \
    -p '{"spec":{"calicoNetwork":{"nodeAddressAutodetectionV4":{"kubernetes":"NodeInternalIP"}}}}'

echo "==> Waiting for Calico (a few minutes)"
run wait_until 500 "tigerastatus/calico to appear" kubectl get tigerastatus calico
run kubectl wait --for=condition=Available tigerastatus/calico --timeout=500s
run kubectl wait --for=condition=Ready node --all --timeout=500s

# ==============================================================================
# 06. Worker join command
# ==============================================================================
if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] kubeadm token create --print-join-command  (printed highlighted, saved to $JOIN_FILE)"
    echo "==> Dry run finished: nothing was changed."
    exit 0
fi

join_cmd=$(kubeadm token create --print-join-command)
( umask 077; printf '%s\n' "$join_cmd" > "$JOIN_FILE" )

echo
echo "${GREEN}=================== WORKER JOIN COMMAND (run as root on the worker) ===================${RESET}"
echo
echo "${BOLD}${join_cmd}${RESET}"
echo
echo "${GREEN}=======================================================================================${RESET}"
echo "Saved to: $JOIN_FILE   (the token is valid for 24h; make a new one with: kubeadm token create --print-join-command)"
echo
echo "Before joining, the worker needs: the node-prep script, $CP_DOMAIN resolving to $CP_IP,"
echo "and its own IP pinned, e.g. in /etc/default/kubelet:  KUBELET_EXTRA_ARGS=--node-ip=<worker-ip>"
echo
echo "Current state:"
kubectl get nodes -o wide
kubectl get tigerastatus
echo
