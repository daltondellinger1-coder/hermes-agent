# WSL interop discovery

`with-wsl-interop` is the canonical socket-discovery implementation used by
ACP services and agent shells. `--print-socket` prints only a socket proven
with a real Windows command. Print mode bounds each candidate to 400 ms; the
login hook delegates with a two-second outer timeout and exports itself as `BASH_ENV`, covering non-login,
non-interactive Bash descendants. The `buzz-acp@.service` template drop-in
wraps every current or future ACP instance instead of patching instances one
at a time.

Install from the repository:

```sh
./Install-WslInteropProfile.sh
```

The installer timestamp-backs up replaced files, adds one idempotent source
line to `~/.profile`, installs the ACP template drop-in, and daemon-reloads
systemd without restarting active agents.
