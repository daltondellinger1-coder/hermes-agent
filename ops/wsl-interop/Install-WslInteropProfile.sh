#!/bin/sh
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
wrapper_target="$HOME/.local/bin/with-wsl-interop"
profile_dir="$HOME/.config/hermes"
snippet_target="$profile_dir/wsl-interop-profile.sh"
login_profile="$HOME/.profile"
dropin_dir="$HOME/.config/systemd/user/buzz-acp@.service.d"
dropin_target="$dropin_dir/30-wsl-interop.conf"
source_line='[ -r "$HOME/.config/hermes/wsl-interop-profile.sh" ] && . "$HOME/.config/hermes/wsl-interop-profile.sh"'
stamp=$(date +%Y%m%d-%H%M%S)

mkdir -p "$(dirname -- "$wrapper_target")" "$profile_dir" "$dropin_dir"
for target in "$wrapper_target" "$snippet_target" "$dropin_target"; do
    if [ -e "$target" ]; then
        cp -p -- "$target" "$target.bak-$stamp"
    fi
done
cp -- "$source_dir/with-wsl-interop" "$wrapper_target"
cp -- "$source_dir/hermes-wsl-interop-profile.sh" "$snippet_target"
cp -- "$source_dir/30-wsl-interop.conf" "$dropin_target"
chmod 0755 "$wrapper_target"
chmod 0644 "$snippet_target"
chmod 0644 "$dropin_target"

touch "$login_profile"
if ! grep -Fqx -- "$source_line" "$login_profile"; then
    cp -p -- "$login_profile" "$login_profile.bak-$stamp"
    printf '\n%s\n' "$source_line" >>"$login_profile"
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload
fi

printf 'Installed WSL interop wrapper, shell hook, and ACP template drop-in.\n'
