# Resolve WSL interop for login shells through the canonical wrapper. The
# outer timeout bounds startup even if every known socket is stale.
export BASH_ENV="$HOME/.config/hermes/wsl-interop-profile.sh"
_hermes_runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
_hermes_cache=$_hermes_runtime_dir/hermes-wsl-interop.socket
_hermes_login_shell=false
if [ -n "${BASH_VERSION:-}" ] && shopt -q login_shell 2>/dev/null; then
    _hermes_login_shell=true
fi

if [ "$_hermes_login_shell" = false ] && [ -r "$_hermes_cache" ]; then
    IFS= read -r _hermes_wsl_interop <"$_hermes_cache" || true
    if [ -S "${_hermes_wsl_interop:-}" ]; then
        export WSL_INTEROP=$_hermes_wsl_interop
    fi
fi

if { [ "$_hermes_login_shell" = true ] || [ -z "${WSL_INTEROP:-}" ]; } &&
    [ -x "$HOME/.local/bin/with-wsl-interop" ] && command -v timeout >/dev/null 2>&1; then
    _hermes_wsl_interop=$(timeout 2 "$HOME/.local/bin/with-wsl-interop" --print-socket 2>/dev/null) || true
    if [ -n "$_hermes_wsl_interop" ]; then
        export WSL_INTEROP=$_hermes_wsl_interop
    fi
    unset _hermes_wsl_interop
fi
unset _hermes_runtime_dir _hermes_cache _hermes_login_shell
