#!/bin/bash
set -euo pipefail
USAGE=$(cat <<-END
    Usage: ./deploy.sh [--aliases=<alias1,alias2,...>]
    Creates ~/.zshrc with location specific config
    On a Mac it also installs the daily macOS/iOS update reminder

    OPTIONS:
        --aliases=<names>       source config/aliases_<name>.sh in .zshrc for each name, separated by commas
END
)

export DOT_DIR=$(dirname $(realpath $0))

while (( "$#" )); do
    case "$1" in
        -h|--help)
            echo "$USAGE" && exit 1 ;;
        --aliases=*)
            IFS=',' read -r -a ALIASES <<< "${1#*=}" && shift ;;
        --) # end argument parsing
            shift && break ;;
        -*|--*=) # unsupported flags
            echo "Error: Unsupported flag $1" >&2 && exit 1 ;;
        *) # unexpected positional arguments
            echo "Error: Unexpected argument $1" >&2 && exit 1 ;;
    esac
done

# zshrc setup
ZSHRC_LINE="source $DOT_DIR/config/zshrc.sh"
# Back up an existing ~/.zshrc unless a previous deploy wrote it
if [ -f "$HOME/.zshrc" ] && [ "$(head -n 1 "$HOME/.zshrc")" != "$ZSHRC_LINE" ]; then
    cp "$HOME/.zshrc" "$HOME/.zshrc.bak"
    echo "backed up existing ~/.zshrc to ~/.zshrc.bak"
fi
echo "$ZSHRC_LINE" > "$HOME/.zshrc"
if [ -n "${ALIASES+x}" ]; then
    for alias in "${ALIASES[@]}"; do
        echo "source $DOT_DIR/config/aliases_${alias}.sh" >> "$HOME/.zshrc"
    done
fi

# Daily macOS/iOS update reminder (Mac only; emails via Apple Mail, so sign in to Mail first)
# The schedule runs ~/Scripts/update-check.sh, a COPY of the one in this repo.
# (Not a link: macOS blocks background jobs from reading ~/Documents, where this
# repo may live.) After editing or pulling macos/update-check.sh, re-run deploy.sh.
# Its state and log files stay in ~/Scripts and never enter the repo.
if [ "$(uname -s)" == "Darwin" ]; then
    mkdir -p "$HOME/Scripts" "$HOME/Library/LaunchAgents"
    rm -f "$HOME/Scripts/update-check.sh"    # remove first, in case it's an old link
    cp "$DOT_DIR/macos/update-check.sh" "$HOME/Scripts/update-check.sh"
    chmod +x "$HOME/Scripts/update-check.sh"
    AGENT="$HOME/Library/LaunchAgents/com.jake.update-check.plist"
    cp "$DOT_DIR/macos/com.jake.update-check.plist" "$AGENT"
    launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT" || echo "⚠️  couldn't start the update reminder (see above)"
fi