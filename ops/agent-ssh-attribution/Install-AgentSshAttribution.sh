#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./Install-AgentSshAttribution.sh \
  --claude-public-key-file PATH --codex-public-key-file PATH \
  [--listen-address TAILSCALE_IPV4] [--port PORT]
EOF
}

claude_key_file=""
codex_key_file=""
listen_address=""
port="2222"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-public-key-file) claude_key_file="${2:?}"; shift 2 ;;
    --codex-public-key-file) codex_key_file="${2:?}"; shift 2 ;;
    --listen-address) listen_address="${2:?}"; shift 2 ;;
    --port) port="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "run this installer as root" >&2
  exit 77
fi
for required_command in auditctl augenrules visudo sshd ssh-keygen tailscale; do
  command -v "$required_command" >/dev/null || {
    echo "missing required command: $required_command (install the auditd and OpenSSH server packages first)" >&2
    exit 69
  }
done
if [[ -z "$claude_key_file" || -z "$codex_key_file" ]]; then
  usage >&2
  exit 64
fi
if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
  echo "port must be an integer from 1024 through 65535" >&2
  exit 64
fi
detected_tailnet_address="$(tailscale ip -4 | head -n 1)"
if [[ -z "$listen_address" ]]; then
  listen_address="$detected_tailnet_address"
fi
if [[ -z "$detected_tailnet_address" || "$listen_address" != "$detected_tailnet_address" ]]; then
  echo "listen address must equal this node's Tailscale IPv4 address ($detected_tailnet_address)" >&2
  exit 64
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for key_file in "$claude_key_file" "$codex_key_file"; do
  [[ -f "$key_file" ]] || { echo "missing public key file: $key_file" >&2; exit 66; }
  ssh-keygen -l -f "$key_file" >/dev/null
done

install -d -m 0755 /etc/ssh /usr/local/sbin /etc/systemd/system /etc/sudoers.d /etc/audit/rules.d
install -o root -g root -m 0755 "$script_dir/hermes-agent-session" /usr/local/sbin/hermes-agent-session

for identity in claude codex; do
  account="hermes-$identity"
  key_variable="${identity}_key_file"
  key_path="${!key_variable}"
  if ! id "$account" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --comment "Hermes $identity agent SSH identity" "$account"
  fi
  passwd --lock "$account" >/dev/null
  home_dir="$(getent passwd "$account" | cut -d: -f6)"
  install -d -o "$account" -g "$account" -m 0700 "$home_dir/.ssh"
  install -o "$account" -g "$account" -m 0600 "$key_path" "$home_dir/.ssh/authorized_keys"
done

claude_uid="$(id -u hermes-claude)"
codex_uid="$(id -u hermes-codex)"
sed -e "s/@CLAUDE_UID@/$claude_uid/g" -e "s/@CODEX_UID@/$codex_uid/g" \
  "$script_dir/hermes-agent-audit.rules.in" >/etc/audit/rules.d/hermes-agent.rules
chmod 0640 /etc/audit/rules.d/hermes-agent.rules
augenrules --load
systemctl enable auditd.service
systemctl start auditd.service

cat >/etc/sudoers.d/hermes-agent-ssh <<'EOF'
hermes-claude ALL=(dalton) NOPASSWD: /bin/bash -l, /bin/bash -lc *
hermes-codex ALL=(dalton) NOPASSWD: /bin/bash -l, /bin/bash -lc *
EOF
chmod 0440 /etc/sudoers.d/hermes-agent-ssh
visudo -cf /etc/sudoers.d/hermes-agent-ssh

sed -e "s/@PORT@/$port/g" -e "s/@LISTEN_ADDRESS@/$listen_address/g" \
  "$script_dir/hermes-agent-sshd_config.in" >/etc/ssh/hermes-agent-sshd_config
chmod 0600 /etc/ssh/hermes-agent-sshd_config
install -o root -g root -m 0644 "$script_dir/hermes-agent-sshd.service" \
  /etc/systemd/system/hermes-agent-sshd.service

/usr/sbin/sshd -t -f /etc/ssh/hermes-agent-sshd_config
systemctl daemon-reload
systemctl enable --now hermes-agent-sshd.service

echo "Hermes agent SSH endpoint active at ${listen_address}:${port}"
echo "Claude fingerprint: $(ssh-keygen -lf "$claude_key_file")"
echo "Codex fingerprint:  $(ssh-keygen -lf "$codex_key_file")"
echo "Audit identities: hermes-claude auid=$claude_uid; hermes-codex auid=$codex_uid"
