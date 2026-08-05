# WSL interop discovery

`with-wsl-interop` is the canonical socket-discovery implementation used by
Hermes services and login shells. `--print-socket` prints only a socket proven
with a real Windows command. The login hook delegates to that mode with a
one-second outer timeout, so stale sockets cannot block shell startup.

Install from the repository:

```sh
./Install-WslInteropProfile.sh
```

The installer timestamp-backs up replaced files and adds one idempotent source
line to `~/.profile`.
