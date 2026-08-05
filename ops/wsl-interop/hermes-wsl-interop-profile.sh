# Resolve WSL interop for login shells through the canonical wrapper. The
# outer timeout bounds startup even if every known socket is stale.
if [ -x "$HOME/.local/bin/with-wsl-interop" ] && command -v timeout >/dev/null 2>&1; then
    _hermes_wsl_interop=$(timeout 1 "$HOME/.local/bin/with-wsl-interop" --print-socket 2>/dev/null) || true
    if [ -n "$_hermes_wsl_interop" ]; then
        export WSL_INTEROP=$_hermes_wsl_interop
    fi
    unset _hermes_wsl_interop
fi
