#!/bin/bash
# chati — one-command installer for a Linux server (all users).
#
# Downloads chati, places it in a shared prefix, installs its dependencies,
# and links `chati` onto every user's PATH. Run as root:
#
#     curl -fsSL https://raw.githubusercontent.com/cdamken/chati-linux/main/install.sh | sudo bash
#
# Optional environment overrides:
#     CHATI_BRANCH        branch to install                 (default: main)
#     CHATI_SYSTEM_PREFIX where the repo lives, readable    (default: /opt/chati-linux)
#     CHATI_SETUP_ARGS    args passed to setup.sh --system  (default: --minimal --no-pull)
#     CHATI_REPO_URL      clone URL                         (default: the public GitHub repo)
#
# Defaults install the terminal chat only (no OpenWebUI/SearXNG services) and
# pull no models, so it is safe on a server already running Ollama. For the full
# stack: CHATI_SETUP_ARGS="" curl ... | sudo bash
set -euo pipefail

REPO_URL="${CHATI_REPO_URL:-https://github.com/cdamken/chati-linux.git}"
PREFIX="${CHATI_SYSTEM_PREFIX:-/opt/chati-linux}"
BRANCH="${CHATI_BRANCH:-main}"
SETUP_ARGS="${CHATI_SETUP_ARGS:---minimal --no-pull}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mchati install:\033[0m %s\n' "$*" >&2; exit 1; }

# /opt, /usr/local/bin and apt all need root. Fail early with a clear hint.
[[ "$(id -u)" -eq 0 ]] || die "run as root, e.g.  curl -fsSL <url> | sudo bash"

# git is the only thing this bootstrap needs before setup.sh takes over.
if ! command -v git >/dev/null 2>&1; then
    say "Installing git"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y git
    else
        die "git not found and no apt-get; install git, then re-run."
    fi
fi

if [[ -d "$PREFIX/.git" ]]; then
    say "Updating existing checkout in $PREFIX ($BRANCH)"
    git -C "$PREFIX" fetch --depth 1 origin "$BRANCH"
    git -C "$PREFIX" checkout -B "$BRANCH" "origin/$BRANCH"
    git -C "$PREFIX" reset --hard "origin/$BRANCH"
else
    say "Cloning chati into $PREFIX ($BRANCH)"
    rm -rf "$PREFIX"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$PREFIX"
fi
chown -R root:root "$PREFIX"

say "Running setup.sh --system $SETUP_ARGS"
cd "$PREFIX"
# shellcheck disable=SC2086  # SETUP_ARGS is an intentional word-split arg list
exec ./setup.sh --system $SETUP_ARGS
