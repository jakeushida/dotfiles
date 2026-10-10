#!/bin/bash
set -euo pipefail
USAGE=$(cat <<-END
    Usage: ./deploy.sh [--aliases=<alias1,alias2,...>]
    Creates ~/.zshrc with location specific config

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