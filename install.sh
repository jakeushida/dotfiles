#!/bin/bash
set -euo pipefail
USAGE=$(cat <<-END
    Usage: ./install.sh [OPTION]
    Install dotfile dependencies on mac or linux

    OPTIONS:
        --tmux       install tmux
        --zsh        install zsh (Linux only; macOS already has it)
        --force      overwrite existing oh-my-zsh

    On a Mac it also installs Homebrew, everything in Brewfile
    and Brewfile.extra, and the LaTeX packages in tex-packages.txt.
    If OPTIONS are passed they will be installed
    with apt if on linux or brew if on OSX
END
)

zsh=false
tmux=false
force=false
while (( "$#" )); do
    case "$1" in
        -h|--help)
            echo "$USAGE" && exit 1 ;;
        --zsh)
            zsh=true && shift ;;
        --tmux)
            tmux=true && shift ;;
        --force)
            force=true && shift ;;
        --) # end argument parsing
            shift && break ;;
        -*|--*=) # unsupported flags
            echo "Error: Unsupported flag $1" >&2 && exit 1 ;;
        *) # unexpected positional arguments
            echo "Error: Unexpected argument $1" >&2 && exit 1 ;;
    esac
done

operating_system="$(uname -s)"
case "${operating_system}" in
    Linux*)     machine=Linux;;
    Darwin*)    machine=Mac;;
    *)          machine="UNKNOWN:${operating_system}"
                echo "Error: Unsupported operating system ${operating_system}" && exit 1
esac

# Installing on linux with apt
if [ $machine == "Linux" ]; then
    DOT_DIR=$(dirname $(realpath $0))
    sudo apt-get update -y
    [ $zsh == true ] && sudo apt-get install -y zsh
    [ $tmux == true ] && sudo apt-get install -y tmux
    sudo apt-get install -y less nano

    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    else
        echo "uv already installed, skipping..."
    fi
# Installing on mac with homebrew
elif [ $machine == "Mac" ]; then
    DOT_DIR=$(cd "$(dirname "$0")" && pwd)

    # 1. Homebrew (only if missing)
    if ! command -v brew &> /dev/null; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    # 2. Apps and tools from both Brewfiles (sign in to the App Store first for the mas apps)
    brew bundle --no-upgrade --file="$DOT_DIR/Brewfile"       || echo "⚠️  some Brewfile items failed (see above)"
    brew bundle --no-upgrade --file="$DOT_DIR/Brewfile.extra" || echo "⚠️  some Brewfile.extra items failed (see above)"

    # 3. LaTeX packages on top of BasicTeX
    eval "$(/usr/libexec/path_helper)"    # puts the just-installed TeX on PATH
    sudo tlmgr update --self
    sudo tlmgr install $(cat "$DOT_DIR/tex-packages.txt")

    [ $tmux == true ] && brew install tmux
fi

# Setting up oh my zsh
ZSH=~/.oh-my-zsh
if [ -d $ZSH ] && [ "$force" = "false" ]; then
    echo "Skipping download of oh-my-zsh, pass --force to force redownload"
else
    echo " --------- INSTALLING OH MY ZSH ⏳ ----------- "
    rm -rf $ZSH
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    echo " --------- INSTALLED SUCCESSFULLY ✅ ----------- "
    echo " --------- NOW RUN ./deploy.sh [OPTION] -------- "
fi