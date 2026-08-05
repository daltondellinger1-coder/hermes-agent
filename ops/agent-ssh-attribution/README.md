# Attributable agent SSH endpoint

This package creates a second OpenSSH server for automated agents. It binds to
the WSL Tailscale IPv4 address only and does not change the existing port-22
listener. Tailscale SSH intercepts port 22, so a separate port is required for
ordinary OpenSSH public-key authentication.

Each launcher owns a distinct Ed25519 private key. Only its public key is
installed here. SSH authentication and the forced session wrapper provide two
independent audit records: `sshd` logs the account and SHA256 key fingerprint at
`VERBOSE` level, and `hermes-agent-session` logs the agent identity, kernel audit
login UID/session ID, session leader PID, and source. The PAM login UID survives
the subsequent `sudo` transition to Dalton, so audit rules on the Hermes runtime
and Buzz workspace attribute writes to the authenticating account even when two
agent sessions overlap. The wrapper preserves the access Hermes operations
require while keeping the authentication boundary distinct.
The dedicated SSH service requires `auditd.service`, so loss of the durable
audit path also closes the agent endpoint instead of silently degrading to
timestamp correlation.

## Install

Generate the private keys on the launcher and copy only their `.pub` files to a
temporary directory on B-Link. The `auditd` and OpenSSH server packages must be
installed first. Then run:

```bash
sudo ./Install-AgentSshAttribution.sh \
  --claude-public-key-file /path/to/claude.pub \
  --codex-public-key-file /path/to/codex.pub
```

The default port is 2222. The installer requires the listen address to exactly
match the address reported by `tailscale ip -4`, and validates both keys, the
sudo policy, and the isolated sshd configuration before enabling the service.

## Acceptance and rollback

From each launcher identity, create a different harmless file in a temporary
directory. On B-Link, use `journalctl -u hermes-agent-sshd` and
`journalctl -t hermes-agent-ssh` to attribute each session without asking the
actor. `ausearch -k hermes_agent_changes -i` must show different `auid` values
for the two writes, even when the sessions overlap. Verify the listener with
`ss -ltnp`: port 2222 must appear only on the Tailscale IPv4 address.

Rollback:

```bash
sudo systemctl disable --now hermes-agent-sshd.service
```

The dedicated accounts and keys can remain disabled for forensic continuity.
