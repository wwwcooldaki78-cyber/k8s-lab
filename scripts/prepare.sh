#!/usr/bin/env bash
set -Eeuo pipefail

# readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# readonly WORKDIR="$(dirname "$SCRIPT_DIR")"
# readonly SSH_CONFIG_DIR="$WORKDIR/ssh_configs"
# SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
# SSHD_MAIN_CONF="/etc/ssh/sshd_config"

TARGET_USER=daki

DRY_RUN=0
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--dry-run]" >&2; exit 2; }

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

# ==============================================================================
# 01. Configuring the repo
# ==============================================================================

readonly LEGACY_SOURCES="/etc/apt/sources.list"
readonly SOURCES_FILE="/etc/apt/sources.list.d/debian.sources"
readonly KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

[[ $DRY_RUN -eq 1 ]] && echo "*** DRY RUN: nothing will be changed ***"

if [[ ! -r /etc/os-release ]]; then
    echo "Cannot identify the operating system."
    exit 1
fi

. /etc/os-release

if [[ "${ID:-}" != "debian" ||
      "${VERSION_CODENAME:-}" != "trixie" ]]; then
    echo "This script is intended for Debian 13 (Trixie)."
    echo "Detected: ${PRETTY_NAME:-unknown}"
    exit 1
fi

if [[ ! -f "$KEYRING" ]]; then
    echo "Debian archive keyring not found: $KEYRING"
    exit 1
fi

run rm -f "$LEGACY_SOURCES"

run mkdir -p /etc/apt/sources.list.d

write_file "$SOURCES_FILE" <<'EOF'
# Debian 13 (Trixie): main repositories
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# Debian 13 (Trixie): security updates
Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

echo "Debian repositories configured."

# ==============================================================================
# 02. Updating the machine
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive

echo "Updating package lists..."
run apt-get update

echo "Upgrading installed packages..."
run apt-get upgrade -y -o Dpkg::Options::=--force-confold

echo "Package updates completed."


# ==============================================================================
# 03. Making changes on the node that k8s needs
# ==============================================================================

echo "==> 1. Disabling swap"
run swapoff -a

run sed -i -E '/^[[:space:]]*[^#[:space:]].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab

systemctl list-units --type=swap --no-legend 2>/dev/null | awk '{print $1}' | while read -r unit; do
  [[ -n "$unit" ]] && run systemctl mask "$unit" || true
done

echo "==> 2. Loading kernel modules"
write_file /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

run modprobe overlay
run modprobe br_netfilter

echo "==> 3. Applying sysctl settings"
write_file /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
EOF
if [[ $DRY_RUN -eq 1 ]]; then echo "  [dry-run] sysctl --system"; else sysctl --system >/dev/null; fi

# ==============================================================================
# 04. Installing Containerd as Container Runtime
# ==============================================================================

echo "==> 4. Installing containerd (from Docker's apt repo, containerd.io only)"
run apt-get update -qq
run apt-get install -y ca-certificates curl
run install -m 0755 -d /etc/apt/keyrings

run curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
run chmod a+r /etc/apt/keyrings/docker.asc

write_file /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

run apt-get update -qq
run apt-get install -y containerd.io
run apt-mark hold containerd.io

if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] containerd config default > /etc/containerd/config.toml"
else
    containerd config default > /etc/containerd/config.toml
fi

run sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
run systemctl enable containerd
run systemctl restart containerd

# ==============================================================================
# 05. Setting up Kubernetes repo
# ==============================================================================

readonly K8S_MINOR="v1.37"

echo "==> 5. Adding the Kubernetes ${K8S_MINOR} apt repository"
run curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" -o /etc/apt/keyrings/kubernetes.asc
run chmod a+r /etc/apt/keyrings/kubernetes.asc

write_file /etc/apt/sources.list.d/kubernetes.sources <<EOF
Types: deb
URIs: https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/
Suites: /
Signed-By: /etc/apt/keyrings/kubernetes.asc
EOF

echo "==> 6. Installing kubelet, kubeadm, kubectl"
run apt-get update -qq
run apt-get install -y kubelet kubeadm kubectl
run apt-mark hold kubelet kubeadm kubectl
run systemctl enable --now kubelet

write_file /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF

# ==============================================================================
# 06. Modification for ease-of-use
# ==============================================================================

append_block() {
    local dest=$1 marker=$2 content
    content=$(cat)
    if [[ -f $dest ]] && grep -qF -- "$marker" "$dest"; then
        echo "  already present in $dest, skipping"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] would append to $dest:"
        printf '%s\n' "$content" | sed 's/^/      | /'
        return 0
    fi
    printf '\n%s\n' "$content" >> "$dest"
    echo "  appended to $dest"
}

append_block /etc/bash.bashrc "# setup: alias" <<'BASHRC_EOF'
# setup: ll alias
alias ll='ls -alpqhs --color'
alias less='less --use-color'
BASHRC_EOF

append_block /root/.bashrc "# setup: root prompt" <<'BASHRC_EOF'
# setup: root prompt
PS1='\[\e[1m\e[38;2;255;80;80m\]\u@\h:\[\e[0m\]\[\e[1m\]\[\e[38;2;229;231;235m\]\w\[\e[0m\]\[\e[38;2;255;80;80m\] # \[\e[0m\]'
BASHRC_EOF

[[ -n $TARGET_USER ]] || { echo "Set TARGET_USER to the non-root account name" >&2; exit 2; }
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n $USER_HOME && -d $USER_HOME ]] || { echo "Home directory for $TARGET_USER not found" >&2; exit 1; }

append_block "$USER_HOME/.bashrc" "# setup: welcome banner" <<'BASHRC_EOF'
# setup: welcome banner
if [ -n "$SSH_CONNECTION" ]; then
cat << "EOF"
      /\_/\
     ( o.o )
      > ^ <
EOF
echo "  Welcome back, $(whoami) — $(uptime -p)"
fi
BASHRC_EOF

# deploy_ssh_configs() {
#     [[ -d $SSH_CONFIG_DIR ]] || { echo "Missing directory: $SSH_CONFIG_DIR" >&2; return 1; }
# 
#     # Make sure the main config actually loads the drop-in directory
#     if ! grep -qE "^[[:space:]]*Include[[:space:]]+${SSHD_DROPIN_DIR}/\*\.conf" "$SSHD_MAIN_CONF"; then
#         echo "WARNING: $SSHD_MAIN_CONF does not include ${SSHD_DROPIN_DIR}/*.conf; the copied files would be ignored." >&2
#     fi
# 
#     run install -d -m 755 "$SSHD_DROPIN_DIR"
# 
#     local f name
#     for f in "$SSH_CONFIG_DIR"/*; do
#         [[ -f $f ]] || continue
#         name=$(basename "$f")
#         run install -m 644 -o root -g root "$f" "$SSHD_DROPIN_DIR/$name"
#         echo "  deployed $name"
#     done
# 
#     if [[ $DRY_RUN -eq 1 ]]; then
#         echo "  [dry-run] would run: sshd -t"
#     else
#         if ! sshd -t; then
#             echo "sshd config test failed; not reloading. Fix the files in $SSHD_DROPIN_DIR." >&2
#             return 1
#         fi
#     fi
# 
#     local svc="ssh"
#     systemctl list-unit-files sshd.service >/dev/null 2>&1 && svc="sshd"
#     run systemctl reload "$svc"
# }
# deploy_ssh_configs



# ==============================================================================
# 06. Verification
# ==============================================================================

if [[ $DRY_RUN -eq 1 ]]; then
    echo "==> Dry run finished: nothing was changed. Verification skipped."
    exit 0
fi

echo "==> 99. Verification"
fail=0

if [[ -n "$(swapon --show --noheadings)" ]]; then echo "FAIL: swap still active"; fail=1; else echo "OK: swap off"; fi
for m in overlay br_netfilter; do
    grep -q "^$m " /proc/modules && echo "OK: module $m loaded" || { echo "FAIL: module $m missing"; fail=1; }
done

for k in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
  v=$(sysctl -n "$k")
  [[ "$v" == "1" ]] && echo "OK: $k = 1" || { echo "FAIL: $k = $v"; fail=1; }
done

systemctl is-active --quiet containerd && echo "OK: containerd running" || { echo "FAIL: containerd not running"; fail=1; }
cfg=$(containerd config dump)
grep -q 'SystemdCgroup = true' <<<"$cfg" && echo "OK: SystemdCgroup = true" || { echo "FAIL: SystemdCgroup not enabled"; fail=1; }

for p in kubelet kubeadm kubectl; do
  command -v "$p" >/dev/null && echo "OK: $p installed" || { echo "FAIL: $p missing"; fail=1; }
done
held=$(apt-mark showhold)
for p in kubelet kubeadm kubectl containerd.io; do
  grep -qx "$p" <<<"$held" && echo "OK: $p held" || { echo "FAIL: $p not held"; fail=1; }
done

exit $fail
