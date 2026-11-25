#!/bin/bash
# chati — one-command installer for a Linux server (all users).
#
# Downloads chati, places it in a shared prefix, installs its dependencies,
# and links `chati` onto every user's PATH. Run as root:
#
#     curl -fsSL https://raw.githubusercontent.com/cdamken/chati-linux/main/install.sh | sudo bash
#
# Options go AFTER `bash -s --` (env vars don't survive `curl | sudo bash`: the
# var would attach to curl, and sudo scrubs the environment anyway):
#     --full              install the full stack (OpenWebUI/SearXNG), pull models
#     --branch NAME       branch to install                 (default: main)
#     --prefix PATH       where the repo lives, readable     (default: /opt/chati-linux)
#     --repo-url URL      clone URL                          (default: the public GitHub repo)
#     --setup-args "..."  raw args for setup.sh --system     (overrides --full)
#
# Defaults install the terminal chat only (no OpenWebUI/SearXNG services) and
# pull no models, so it is safe on a server already running Ollama. For the full
# stack:
#     curl -fsSL <url> | sudo bash -s -- --full
#
# The matching env vars (CHATI_BRANCH, CHATI_SYSTEM_PREFIX, CHATI_SETUP_ARGS,
# CHATI_REPO_URL) still work when you export them and keep them, e.g. with
# `sudo -E`, but the flags above are the supported path for `curl | sudo bash`.
set -euo pipefail

REPO_URL="${CHATI_REPO_URL:-https://github.com/cdamken/chati-linux.git}"
PREFIX="${CHATI_SYSTEM_PREFIX:-/opt/chati-linux}"
BRANCH="${CHATI_BRANCH:-main}"
# Empty string is a meaningful value (full stack), so honor it if the var is SET,
# even to empty; fall back to the safe minimal default only when it is unset.
SETUP_ARGS="${CHATI_SETUP_ARGS---minimal --no-pull}"
SETUP_ARGS_SET="${CHATI_SETUP_ARGS+yes}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mchati install:\033[0m %s\n' "$*" >&2; exit 1; }

# Flags (after `bash -s --`) take priority over the env vars, because they are
# the ones that actually reach this script through `curl | sudo bash`.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)        SETUP_ARGS=""; SETUP_ARGS_SET="yes" ;;
        --branch)      BRANCH="${2:?--branch needs a value}"; shift ;;
        --branch=*)    BRANCH="${1#*=}" ;;
        --prefix)      PREFIX="${2:?--prefix needs a value}"; shift ;;
        --prefix=*)    PREFIX="${1#*=}" ;;
        --repo-url)    REPO_URL="${2:?--repo-url needs a value}"; shift ;;
        --repo-url=*)  REPO_URL="${1#*=}" ;;
        --setup-args)  SETUP_ARGS="${2:?--setup-args needs a value}"; SETUP_ARGS_SET="yes"; shift ;;
        --setup-args=*) SETUP_ARGS="${1#*=}"; SETUP_ARGS_SET="yes" ;;
        -h|--help)
            # Can't read "$0" here: under `curl | sudo bash` it is "bash", not this
            # script. Embed the usage so --help works through the pipe too.
            cat <<'USAGE'
chati installer — run as root:
    curl -fsSL https://raw.githubusercontent.com/cdamken/chati-linux/main/install.sh | sudo bash

Options go AFTER `bash -s --`:
    --full              install the full stack (OpenWebUI/SearXNG), pull models
    --branch NAME       branch to install                 (default: main)
    --prefix PATH       where the repo lives, readable     (default: /opt/chati-linux)
    --repo-url URL      clone URL                          (default: public GitHub repo)
    --setup-args "..."  raw args for setup.sh --system     (overrides --full)

Full stack:
    curl -fsSL <url> | sudo bash -s -- --full
USAGE
            exit 0 ;;
        *) die "unknown option: $1  (see --help)" ;;
    esac
    shift
done
: "${SETUP_ARGS_SET:=}"   # silence set -u if never assigned

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
    # A shallow `fetch origin BRANCH` doesn't create a refs/remotes/origin/BRANCH,
    # so `checkout origin/$BRANCH` would fail. FETCH_HEAD is what the fetch wrote.
    git -C "$PREFIX" checkout -B "$BRANCH" FETCH_HEAD
else
    # NEVER delete $PREFIX recursively without checking: a stray --prefix /opt (or
    # CHATI_SYSTEM_PREFIX=/opt) would wipe the whole directory. Only clear it when
    # it is empty; refuse anything that isn't our checkout so we never delete data.
    if [[ -e "$PREFIX" ]]; then
        if [[ -n "$(ls -A "$PREFIX" 2>/dev/null)" ]]; then
            die "$PREFIX exists and isn't a chati checkout — refusing to delete it. Remove it yourself or pass --prefix PATH."
        fi
        rmdir "$PREFIX" 2>/dev/null || true
    fi
    say "Cloning chati into $PREFIX ($BRANCH)"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$PREFIX"
fi
chown -R root:root "$PREFIX"

say "Running setup.sh --system $SETUP_ARGS"
cd "$PREFIX"
# shellcheck disable=SC2086  # SETUP_ARGS is an intentional word-split arg list
exec ./setup.sh --system $SETUP_ARGS
