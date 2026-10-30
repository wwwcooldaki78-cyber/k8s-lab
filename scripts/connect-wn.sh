#!/usr/bin/env bash

# The join command comes from the control plane, which will be inside /root/lab/worker-join-command.txt
#
# Create a file called "worker-join-command.txt" and paste the from the control-plane's "worker-join-command.txt" here.
#
# nano worker-join-command.txt

set -Eeuo pipefail

# ==============================================================================
# 01. EDIT THIS VALUE
# ==============================================================================
readonly WORKER_IP="$(hostname -I | awk '{print $1}')"              # this worker's static IP (must belong to THIS machine)
readonly WORKER_HOSTNAME="$(hostname -s)"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKDIR="$(dirname "$SCRIPT_DIR")"
JOIN_FILE="$WORKDIR/worker-join-command.txt"
readonly JOIN_CONFIG="$WORKDIR/kubeadm-join-config.yaml"

# ==============================================================================
# 02. Helpers: --dry-run support
# ==============================================================================
DRY_RUN=0
usage() { echo "Usage: $0 [--dry-run] [--join-file PATH]" >&2; exit "${1:-2}"; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --join-file) [[ $# -ge 2 ]] || usage; JOIN_FILE="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        *)           usage ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
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
        ( umask 077; cat > "$dest" )   # contains the join token: owner-only
    fi
}

if [[ -t 1 ]]; then BOLD=$'\033[1m'; GREEN=$'\033[1;32m'; RESET=$'\033[0m'; else BOLD=""; GREEN=""; RESET=""; fi
trap 'rm -f "$JOIN_CONFIG"' EXIT       # never leave the token-bearing config behind

[[ $DRY_RUN -eq 1 ]] && echo "*** DRY RUN: nothing will be changed ***"
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then die "Run this script with sudo."; fi

# ==============================================================================
# 03. Preflight checks (this machine)
# ==============================================================================
echo "==> Preflight checks"

[[ "$WORKER_IP" != CHANGE-ME* ]] || problem "Edit WORKER_IP at the top of this script first."

command -v kubeadm >/dev/null || problem "kubeadm not found. Run the node-prep script first."
command -v kubelet >/dev/null || problem "kubelet not found. Run the node-prep script first."
systemctl is-active --quiet containerd || problem "containerd is not running. Run the node-prep script first."
[[ -z "$(swapon --show --noheadings 2>/dev/null)" ]] || problem "swap is still active. Run the node-prep script first."

# multi-NIC guard: the IP must really be on this machine
addrs=$(ip -4 -o addr show 2>/dev/null || true)
grep -q "inet ${WORKER_IP}/" <<<"$addrs" || problem "WORKER_IP ${WORKER_IP} is not assigned to any interface on this machine."

# ==============================================================================
# 04. Read and validate the join command (parsed, never executed as-is)
# ==============================================================================
echo "==> Reading the join command from $JOIN_FILE"
ENDPOINT="<control-plane-domain>:6443"; TOKEN="<token>"; HASH="sha256:<hash>"

if [[ -r "$JOIN_FILE" ]]; then
    join_cmd=$(tr -d '\\' < "$JOIN_FILE" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
    re='^kubeadm join ([^ ]+) --token ([a-z0-9]{6}\.[a-z0-9]{16}) --discovery-token-ca-cert-hash (sha256:[0-9a-f]{64})$'
    if [[ "$join_cmd" =~ $re ]]; then
        ENDPOINT=${BASH_REMATCH[1]}; TOKEN=${BASH_REMATCH[2]}; HASH=${BASH_REMATCH[3]}
        echo "  control plane endpoint: $ENDPOINT"
    else
        problem "$JOIN_FILE does not look like 'kubeadm token create --print-join-command' output."
    fi
else
    problem "Join file not found: $JOIN_FILE (copy it from the control plane, or pass --join-file PATH)"
fi

if [[ "$ENDPOINT" != "<"* ]]; then
    cp_host=${ENDPOINT%:*}; cp_port=${ENDPOINT##*:}
    cp_ips=$(getent ahostsv4 "$cp_host" 2>/dev/null | awk '{print $1}' | sort -u || true)
    if [[ -z "$cp_ips" ]]; then
        problem "$cp_host does not resolve. Add a DNS A record, or: echo '<control-plane-ip> $cp_host' >> /etc/hosts"
    else
        echo "  $cp_host resolves to: $(echo $cp_ips)"
        timeout 5 bash -c "exec 3<>/dev/tcp/${cp_host}/${cp_port}" 2>/dev/null \
            || problem "cannot reach $cp_host:$cp_port (firewall? control plane down?)"
    fi
fi

# ==============================================================================
# 05. kubeadm join (config file, so the node IP is pinned just like on the control plane)
# ==============================================================================
echo "==> Joining the cluster"
run install -d -m 700 "$WORKDIR"

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    echo "  /etc/kubernetes/kubelet.conf exists: this node already joined, skipping kubeadm join"
else
    if [[ $DRY_RUN -eq 1 ]]; then TOKEN_OUT="${TOKEN%%.*}.<hidden>"; else TOKEN_OUT="$TOKEN"; fi

write_file "$JOIN_CONFIG" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${ENDPOINT}"
    token: "${TOKEN_OUT}"
    caCertHashes:
      - "${HASH}"
nodeRegistration:
  name: "${WORKER_HOSTNAME}"
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: "${WORKER_IP}"
EOF
    run kubeadm join --config "$JOIN_CONFIG"
    run rm -f "$JOIN_CONFIG"
fi

# ==============================================================================
# 06. Local check and what to do next
# ==============================================================================
if [[ $DRY_RUN -eq 1 ]]; then
    echo "==> Dry run finished: nothing was changed."
    exit 0
fi

echo "==> Local check"
systemctl is-active --quiet kubelet && echo "OK: kubelet running" || die "kubelet is not running (see: journalctl -u kubelet -e)"

node_name=(hostname)
echo
echo "${GREEN}============ NOW RUN THESE ON THE CONTROL-PLANE (this worker cannot do it) ============${RESET}"
echo
echo "${BOLD}# 1. approve this worker's kubelet serving-cert request (appears a few seconds after the join; repeat if empty)${RESET}"
echo "kubectl get csr --no-headers | awk '\$3==\"kubernetes.io/kubelet-serving\" && \$NF==\"Pending\" {print \$1}' | xargs -r kubectl certificate approve"
echo
echo "${BOLD}# 2. give the node a worker role label (cosmetic) and check it${RESET}"
echo "kubectl label node ${node_name} node-role.kubernetes.io/worker="
echo "kubectl get nodes -o wide"
echo
echo "${GREEN}=======================================================================================${RESET}"
echo "The worker becomes Ready once Calico has started on it (1-3 minutes)."
