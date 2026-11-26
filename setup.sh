#!/bin/bash
#==============================================================================
# setup.sh — one-command, do-everything installer for chati
#==============================================================================
# Run this ONCE after cloning the repo. It brings a fresh Ubuntu box from
# "just cloned" to a FULLY WORKING system (CLI chat, the OpenWebUI browser
# app, and local web search via SearXNG), and is safe to re-run any time.
#
# Design goals (why this file exists):
#   * DO EVERYTHING by default — one command, no follow-up steps to remember.
#   * PATH-INDEPENDENT — resolved relative to this script; works from any dir.
#   * IDEMPOTENT — each step checks before acting; re-running is safe.
#   * FAIL-LOUD, FAIL-CLEAR — prerequisites checked with actionable messages.
#   * NEVER HANG — a slow OpenWebUI first boot is tolerated, not fatal.
#   * REVERSIBLE — `--remove-all` tears the whole install back down.
#
# It does NOT clone the repo or run `gh auth login` — those must happen first
# (you need the code before you can run this). See README "Quick Start".
#==============================================================================
set -euo pipefail

# ---- Configuration -----------------------------------------------------------
# The repo root is wherever THIS script lives — never assume ~/chati.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fallback chat model if hardware detection fails. Normally the model is chosen
# from GPU VRAM, else system memory (recommend_model). Override with --model NAME.
DEFAULT_CHAT_MODEL="gemma4:26b"
SEARXNG_LOCAL_URL="http://127.0.0.1:8890"

# Install everything by default; flags only subtract or tweak.
WANT_WEBUI=1
WANT_SEARXNG=1
WANT_PULL=1
REMOVE_ALL=0
REMOVE_WEBUI=0
REMOVE_SEARXNG=0
ASSUME_YES=0
UPDATE_MODE=0                    # 1 for --update: re-apply respecting the installed profile
FORCE_WEBUI=0                    # 1 for --force-webui: reinstall the OpenWebUI venv from scratch
MODEL_EXPLICIT=0                 # set to 1 when the user forces --model
CHAT_MODEL="$DEFAULT_CHAT_MODEL"
WANT_EXTRA_MODELS=1              # pull the big general models by default (--no-extra-models to skip)
FORCE_MODELS=0                   # 1 for --force-models: pull the big models even on a low-RAM box
SYSTEM_INSTALL=0                 # 1 for --system: link into /usr/local/bin for all users (Linux; uses sudo)

# Detect system memory (GB) as a fallback when there's no NVIDIA GPU. On a GPU
# box the model is sized to VRAM (detect_vram_gb); this is the no-GPU path.
detect_ram_gb() {
    # Linux: /proc/meminfo MemTotal is in kB.
    echo $(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1048576 ))
}
recommend_model() {
    local gb="$1"
    if   (( gb >= 32 )); then echo "gemma4:26b"                  # ~17 GB — the default target
    elif (( gb >= 16 )); then echo "llama3.1:8b-instruct-q8_0"   # ~8.5 GB — fast, fits comfortably
    elif (( gb >=  1 )); then echo "gemma3:4b"                   # ~3.3 GB — lightweight
    else                      echo "$DEFAULT_CHAT_MODEL"; fi     # detection failed → fallback
}

# Total NVIDIA VRAM in GB across ALL cards (0 if no nvidia-smi / no GPU). On
# Linux the model must fit VRAM, not system RAM: a 62 GB box with a 16 GB GPU
# should NOT default to a 17 GB model (it would spill to CPU and crawl). Works
# for any NVIDIA setup, no card-specific assumptions: nvidia-smi prints one line
# per GPU and we SUM them, because Ollama can split a model across several cards.
# (AMD/ROCm not handled yet, NVIDIA only per the request.)
detect_vram_gb() {
    command -v nvidia-smi >/dev/null 2>&1 || { echo 0; return; }
    local mib
    mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
          | tr -dc '0-9\n' | awk '{s+=$1} END{print s+0}')
    [[ -n "$mib" && "$mib" -gt 0 ]] && echo $(( mib / 1024 )) || echo 0
}

# Which models to ensure present BEYOND the RAM-selected chat model, given the
# machine's RAM and the flags. Pure (no ollama, no network) so it is unit-
# testable. Echoes a space-separated list.
#
#   bge-m3       — RAG embedding model. Always ensured: it is tiny (~1.2 GB) and
#                  broadly useful, so every install has it.
#   gemma4:31b   — dense, max-quality general model (the "judge").
#   gemma4:26b   — faster MoE alternative.
#
# The two gemma4 give every machine the SAME pair of general models, so a
# multi-host pool can route work to any box and get comparable output. They are
# ~37 GB together, on by default (want=1). They are skipped when opted out
# (want=0) OR when the box lacks the RAM to actually run a ~19 GB model
# (< BIG_MODELS_MIN_GB), unless forced. A model that can't load is pure wasted
# disk, so the RAM guard protects small boxes without changing the default on a
# machine that can run them.
#
# EXACT tags matter: gemma4:31b is NOT gemma4:31b-it-qat (a different, quantized
# model). Tooling that asks for `gemma4:31b` must get that exact tag.
BIG_MODELS_MIN_GB=24
select_extra_models() {  # $1=ram_gb  $2=want_big(0/1)  $3=force(0/1)
    local ram="$1" want="$2" force="$3" out="bge-m3"
    if [[ "$want" -eq 1 ]] && { (( ram >= BIG_MODELS_MIN_GB )) || [[ "$force" -eq 1 ]]; }; then
        out="$out gemma4:31b gemma4:26b"
    fi
    printf '%s' "$out"
}

# ---- Pretty output helpers ---------------------------------------------------
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32m✅ %s\033[0m\n' "$1"; }
warn() { printf '   \033[33m⚠️  %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m❌ %s\033[0m\n' "$1" >&2; exit 1; }

usage() {
    cat <<'USAGE'
setup.sh — one-command, do-everything installer for chati (Ubuntu/Debian)

By default it installs EVERYTHING: apt deps, Ollama + a chat model, the
OpenWebUI browser app, and a local SearXNG for /web — all started.

  ./setup.sh                apt deps + Ollama + model + OpenWebUI + SearXNG
  ./setup.sh --minimal      CLI only — skip OpenWebUI and SearXNG (still installs full deps)
  ./setup.sh --system       link 'chati' into /usr/local/bin for ALL users (uses
                             sudo). Each user still gets their own config and
                             history. On a shared server that already runs Ollama,
                             combine with --minimal --no-pull.
  ./setup.sh --no-webui     skip OpenWebUI only
  ./setup.sh --no-searxng   skip SearXNG only
  ./setup.sh --model NAME    force a chat model, skipping the hardware-based pick
  ./setup.sh --no-pull       do not pull a model (assume one already exists)
  ./setup.sh --no-extra-models  pull ONLY bge-m3 alongside the chat model; skip
                             the two big gemma4 models (~37 GB)
  ./setup.sh --force-models  pull the big gemma4 models even on a low-VRAM box
  ./setup.sh --update        re-apply over an existing install, respecting its
                             profile (touches OpenWebUI/SearXNG only if already
                             installed; no heavy reinstalls). Run by `chati --upgrade`.
  ./setup.sh --force-webui   force a clean OpenWebUI venv reinstall (repair)
  ./setup.sh --remove-all    UNINSTALL everything this script set up (asks first)
  ./setup.sh --remove-webui   uninstall ONLY OpenWebUI (wipes its data/DB; fixes a
                             wedged UI). Ollama, models, chati, SearXNG untouched.
  ./setup.sh --remove-searxng uninstall ONLY the local SearXNG. Everything else kept.

The chat model is sized to the hardware: on an NVIDIA GPU box, to total VRAM;
otherwise to system memory. >=32 GB -> gemma4:26b (~17 GB), 16-31 ->
llama3.1:8b-instruct-q8_0 (~8.5 GB), <16 -> gemma3:4b (~3.3 GB). By default setup
also ensures three shared models so every machine matches: gemma4:31b + gemma4:26b
(general models, ~37 GB total) and bge-m3 (RAG embeddings, ~1.2 GB). The two gemma4
are auto-skipped below 24 GB (a ~19 GB model needs headroom); bge-m3 is always
pulled. Use --no-extra-models for bge-m3 only, or --force-models to pull them on a
small box anyway. To point at a remote Ollama instead of running one here, set
OLLAMA_HOST in .env or switch with /host inside chati (no install flag needed).
  ./setup.sh --remove-all --yes   same, without the confirmation prompt
  ./setup.sh --help          show this help

--remove-all keeps the apt packages (shared with the rest of the system); it
removes OpenWebUI, SearXNG, the `chati` PATH link, logs, pulled Ollama
models, and this repo's local state (.env, sessions, active-model file).
USAGE
    exit 0
}

# ---- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --minimal)   WANT_WEBUI=0; WANT_SEARXNG=0 ;;
        --no-webui)  WANT_WEBUI=0 ;;
        --no-searxng) WANT_SEARXNG=0 ;;
        --webui)     WANT_WEBUI=1 ;;     # accepted for compatibility (now default)
        --searxng)   WANT_SEARXNG=1 ;;   # accepted for compatibility (now default)
        --no-pull)   WANT_PULL=0 ;;
        --no-extra-models) WANT_EXTRA_MODELS=0 ;; # skip the big gemma4 pair (still pulls bge-m3)
        --force-models)    FORCE_MODELS=1 ;;      # pull the big models even on a low-VRAM box
        --update)    UPDATE_MODE=1 ;;   # re-apply over an existing install (used by `chati --upgrade`)
        --force-webui) FORCE_WEBUI=1 ;; # force a clean OpenWebUI venv reinstall
        --system)    SYSTEM_INSTALL=1 ;; # link into /usr/local/bin for all users (uses sudo)
        --model)     CHAT_MODEL="${2:?--model needs a model name}"; MODEL_EXPLICIT=1; shift ;;
        --remove-all) REMOVE_ALL=1 ;;
        --remove-webui)   REMOVE_WEBUI=1 ;;
        --remove-searxng) REMOVE_SEARXNG=1 ;;
        --yes|-y)    ASSUME_YES=1 ;;
        -v|--version) echo "chati $(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo unknown)"; exit 0 ;;
        -h|--help)   usage ;;
        *)           die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ---- Re-apply mode (--update) ------------------------------------------------
# `chati --upgrade` runs `setup.sh --update` after pulling new code, so a code
# update actually gets applied instead of the user having to remember to re-run
# setup. A re-apply must NOT change the machine's profile: it re-applies config,
# wiring and permissions, and touches OpenWebUI / SearXNG ONLY if they are
# already installed, so it never turns a --minimal box into a full one. The
# initial install still honors the flags/defaults above.
if [[ "$UPDATE_MODE" -eq 1 ]]; then
    [[ -d "$HOME/openwebui" ]]            && WANT_WEBUI=1   || WANT_WEBUI=0
    [[ -f "$HOME/searxng/settings.yml" ]] && WANT_SEARXNG=1 || WANT_SEARXNG=0
    # A code re-apply must NOT pull models: the box already has the set it was
    # installed with. Without this, every `chati --upgrade` re-ran the model
    # section — re-verifying the extras each time, and on a --no-pull/--minimal
    # box it could download the full ~17 GB set it was installed WITHOUT. An
    # explicit `--update --model X` still pulls that one model.
    [[ "$MODEL_EXPLICIT" -eq 1 ]] || WANT_PULL=0
fi

# ---- Uninstall path (--remove-all) ------------------------------------------
# Tears down everything setup.sh creates, so an install can be tested and
# then cleanly removed. Deliberately does NOT touch the apt packages (jq, curl,
# ollama, …): those are shared with the rest of the system and removing them is
# out of scope for this project's installer.
remove_all() {
    local models=""
    command -v ollama >/dev/null 2>&1 && models="$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')"

    echo "🧹 --remove-all will DELETE the following (the apt packages are kept):"
    echo "     • OpenWebUI:        ~/openwebui"
    echo "     • Local SearXNG:    ~/searxng"
    echo "     • Logs:             ~/logs"
    echo "     • PATH link:        chati (~/.local/bin and /usr/local/bin; plus any old ailocal leftover)"
    echo "     • Autostart agent:  old pre-1.36 systemd user units, if any"
    echo "     • Repo state:       .env, .active_ollama_model.txt, .web_cache,"
    echo "                         conversation_histories/, ola_chat/instances/"
    echo "     • User data home:   ${CHATI_DATA_HOME:-$HOME/.local/share/chati}"
    echo "                         (saved sessions, active-session pointer, settings)"
    echo "     • Ollama models:    all pulled models${models:+ ($(printf '%s' "$models" | paste -sd, -))}"
    echo "   (The repo code and apt packages are NOT removed.)"

    if [[ "$ASSUME_YES" -ne 1 ]]; then
        printf '\nProceed? [y/N] '
        local reply; read -r reply
        [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || die "Aborted — nothing removed."
    fi

    # Remove models FIRST, while Ollama can still answer: `ollama rm` talks to
    # the running server, so stopping services before this would make every
    # removal silently fail. Start the server if it isn't up.
    step "Removing Ollama models"
    if command -v ollama >/dev/null 2>&1; then
        if ! curl -fsS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
            nohup ollama serve </dev/null >/dev/null 2>&1 &
            for _ in {1..10}; do
                curl -fsS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1 && break
                sleep 1
            done
        fi
        # Force the LOCAL server for list/rm. `ollama` obeys an exported
        # OLLAMA_HOST, so without this a user pointed at a remote (via /host or
        # .env) could have --remove-all delete models on that REMOTE box while
        # uninstalling locally. The health check above already targets localhost.
        local to_rm; to_rm="$(OLLAMA_HOST=localhost:11434 ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')"
        if [[ -n "$to_rm" ]]; then
            printf '%s\n' "$to_rm" | while read -r m; do [[ -n "$m" ]] && OLLAMA_HOST=localhost:11434 ollama rm "$m" >/dev/null 2>&1 || true; done
            ok "Models removed ($(printf '%s' "$to_rm" | paste -sd, -))"
        else
            ok "No models to remove"
        fi
    else
        ok "Ollama not installed — no models to remove"
    fi

    step "Stopping services"
    [[ -x "$REPO_ROOT/libexec/chati-stop" ]] && "$REPO_ROOT/libexec/chati-stop" >/dev/null 2>&1 || true
    pkill -f 'granian.*searx\.webapp' >/dev/null 2>&1 || true
    ok "Services stopped"

    step "Removing the 'chati' PATH link (and any old 'ailocal' leftover)"
    # Remove from wherever setup linked: ~/.local/bin, or /usr/local/bin for a
    # --system install (that one needs root).
    local _lb
    for _lb in "$HOME/.local/bin" /usr/local/bin; do
        local _sudo=""; [[ "$_lb" == /usr/local/bin && ! -w "$_lb" ]] && _sudo="sudo"
        [[ -L "$_lb/chati" ]] && $_sudo rm -f "$_lb/chati"
        [[ -L "$_lb/ailocal" ]] && $_sudo rm -f "$_lb/ailocal"
    done
    ok "Links removed"

    step "Removing the login autostart agent (if any)"
    # Linux: systemd user units (autostart + autoheal), pre-1.36 leftovers.
    systemctl --user disable --now chati-ailocal.service chati-ollama-heal.timer 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/chati-ailocal.service" \
          "$HOME/.config/systemd/user/chati-ollama-heal.service" \
          "$HOME/.config/systemd/user/chati-ollama-heal.timer"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "Autostart agent removed"

    step "Clearing chati config"
    rm -rf "$HOME/.config/chati"
    ok "chati config cleared"

    step "Removing installed apps and state"
    rm -rf "$HOME/openwebui" "$HOME/searxng" "$HOME/logs"
    rm -rf "$REPO_ROOT/.env" "$REPO_ROOT/.active_ollama_model.txt" \
           "$REPO_ROOT/.web_cache" "$REPO_ROOT/ola_chat/instances"
    rm -rf "$REPO_ROOT/conversation_histories"/* 2>/dev/null || true
    # Stable data home (1.10+): saved sessions, active-session pointer, settings.
    rm -rf "${CHATI_DATA_HOME:-$HOME/.local/share/chati}"
    ok "Apps and local state removed"

    printf '\n\033[1;32m✅ Removed. The apt packages were left intact.\033[0m\n'
    echo "Re-install anytime with: ./setup.sh"
    exit 0
}

# ---- Partial uninstall: OpenWebUI only (--remove-webui) ---------------------
# For when a pre-existing OpenWebUI DB (e.g. one created with auth/users) has
# the UI wedged and you just want a clean slate for the browser app without
# touching Ollama, your pulled models, chati or SearXNG (#6). Wipes ~/openwebui
# entirely — app venv AND its data/DB — so the next start comes up fresh and
# login-less.
remove_webui() {
    echo "🧹 --remove-webui will DELETE OpenWebUI only:"
    echo "     • App + venv + data/DB: ~/openwebui  (users & settings included)"
    echo "   Ollama, your pulled models, chati and SearXNG are NOT touched."
    if [[ "$ASSUME_YES" -ne 1 ]]; then
        printf '\nProceed? [y/N] '
        local reply; read -r reply
        [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || die "Aborted — nothing removed."
    fi
    step "Stopping OpenWebUI"
    pkill -f 'open-webui serve' >/dev/null 2>&1 || true
    step "Removing OpenWebUI app + data"
    rm -rf "$HOME/openwebui"
    ok "OpenWebUI removed (Ollama, models, chati and SearXNG left intact)"
    echo "Re-install just OpenWebUI with: ./setup.sh --no-searxng --no-pull"
    exit 0
}

# ---- Partial uninstall: SearXNG only (--remove-searxng) ---------------------
remove_searxng() {
    echo "🧹 --remove-searxng will DELETE the local SearXNG only:"
    echo "     • Source + venv + settings: ~/searxng"
    echo "   Ollama, your pulled models, chati and OpenWebUI are NOT touched."
    if [[ "$ASSUME_YES" -ne 1 ]]; then
        printf '\nProceed? [y/N] '
        local reply; read -r reply
        [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || die "Aborted — nothing removed."
    fi
    step "Stopping SearXNG"
    pkill -f 'granian.*searx\.webapp' >/dev/null 2>&1 || true
    step "Removing SearXNG"
    rm -rf "$HOME/searxng"
    ok "SearXNG removed (Ollama, models, chati and OpenWebUI left intact)"
    echo "Re-install just SearXNG with: ./setup.sh --no-webui --no-pull"
    exit 0
}

if [[ "$REMOVE_ALL"     -eq 1 ]]; then remove_all;     fi
if [[ "$REMOVE_WEBUI"   -eq 1 ]]; then remove_webui;   fi
if [[ "$REMOVE_SEARXNG" -eq 1 ]]; then remove_searxng; fi

# ---- Install transcript log --------------------------------------------------
# Capture the WHOLE install (every step, every `ollama pull`, every warning) to
# a timestamped logfile. The console scrolls and callers often pipe us through
# `tail`, so the early steps — including which models got pulled and by which
# step — used to be unrecoverable after the fact. The log keeps all of it.
# Uninstalls are intentionally NOT logged here (remove_all wipes ~/logs).
INSTALL_LOG="$HOME/logs/chati_install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$HOME/logs"
# Tee stdout+stderr to the log while still showing it on the console.
exec > >(tee -a "$INSTALL_LOG") 2>&1
echo "==> chati --install log — $(date)"
echo "    repo=$REPO_ROOT webui=$WANT_WEBUI searxng=$WANT_SEARXNG pull=$WANT_PULL model=$CHAT_MODEL"

echo "🚀 chati setup — repo at: $REPO_ROOT"

# ---- 1. Platform check -------------------------------------------------------
step "Checking platform"
case "$OSTYPE" in
    linux*)  ok "Linux detected" ;;
    *)       die "Unsupported platform: $OSTYPE (chati-linux targets Ubuntu/Debian; macOS uses the chati repo)" ;;
esac
command -v apt-get >/dev/null 2>&1 \
    || die "chati-linux expects apt-get (Ubuntu/Debian). On another distro, install by hand: curl jq lynx tesseract imagemagick ghostscript poppler-utils python3 python3-venv, then re-run with --no-pull."

# ---- 2-3. Dependencies (apt) -------------------------------------------------
step "Installing packages with apt"
# Only touch apt when something is actually missing. A re-run (every
# `chati --upgrade` re-runs setup) must not sudo + `apt-get update` + reinstall
# a box that already has everything: that was slow and noisy for a code-only
# upgrade, and prompted for a password each time for nothing.
APT_PKGS=(curl jq lynx tesseract-ocr tesseract-ocr-eng imagemagick ghostscript poppler-utils python3 python3-venv)
apt_missing=()
for _p in "${APT_PKGS[@]}"; do dpkg -s "$_p" >/dev/null 2>&1 || apt_missing+=("$_p"); done
if (( ${#apt_missing[@]} == 0 )); then
    ok "apt packages already present (nothing to install)"
else
    warn "Installing missing apt packages (you may be prompted for your password): ${apt_missing[*]}"
    sudo apt-get update -y
    sudo apt-get install -y "${apt_missing[@]}"
    ok "apt packages installed (${apt_missing[*]})"
fi
# uv drives the OpenWebUI and SearXNG Python venvs; skip it on a --minimal box
# that installs neither (nothing else uses it). Ollama via its official Linux
# installer if absent.
if [[ "$WANT_WEBUI" -eq 1 || "$WANT_SEARXNG" -eq 1 ]] && ! command -v uv >/dev/null 2>&1; then
    step "Installing uv"; curl -LsSf https://astral.sh/uv/install.sh | sh; ok "uv installed"
fi
if ! command -v ollama >/dev/null 2>&1; then
    step "Installing Ollama (official Linux installer)"
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installed"
fi

# ---- 4. Directories ----------------------------------------------------------
step "Creating local directories"
mkdir -p "$HOME/logs" "$REPO_ROOT/conversation_histories"
ok "logs/ and conversation_histories/ ready"

# ---- 5. Executable permissions ----------------------------------------------
# Only the real entry points — a stale name here would abort under set -e.
step "Setting executable permissions"
chmod +x "$REPO_ROOT/chati" \
         "$REPO_ROOT/docr/docr" \
         "$REPO_ROOT/ola_chat/ola" "$REPO_ROOT/ola_chat/mola" "$REPO_ROOT/ola_chat/ola_model" \
         "$REPO_ROOT/tests/run_tests.sh" \
         "$REPO_ROOT/installer/install_searxng.sh" 2>/dev/null || true
chmod +x "$REPO_ROOT"/libexec/chati-* 2>/dev/null || true
ok "Scripts are executable"

# ---- 5b. Make `chati` runnable from anywhere -------------------------------
# Symlink chati into ~/.local/bin (or /usr/local/bin with --system). chati
# resolves symlinks to locate its repo, so it works from any directory.
# Everything else is a `chati <subcommand>`.
step "Linking 'chati' onto your PATH"
# Default: ~/.local/bin for this user. With --system, link into /usr/local/bin
# for all users (needs root). chati resolves the symlink to find its repo, so
# with --system every user needs read access to $REPO_ROOT; a shared path like
# /opt/chati-linux is sturdier than a user home. link_run runs the symlink step
# with sudo for --system, plainly otherwise. A function (not a "$LINK_SUDO"
# variable) stays shellcheck-clean and safe under `set -u`.
SYSTEM_LINK=0
[[ "$SYSTEM_INSTALL" -eq 1 ]] && SYSTEM_LINK=1
link_run() { if [[ "$SYSTEM_LINK" -eq 1 ]]; then sudo "$@"; else "$@"; fi; }
if [[ "$SYSTEM_LINK" -eq 1 ]]; then
    # All-users install: the repo must live somewhere every user can read (a
    # /usr/local/bin symlink only points back to it). A user home is often 0750,
    # so relocate the checkout into a shared prefix (default /opt/chati-linux)
    # unless we are already running from one. This makes `--system` self-
    # contained: no manual cp/chown afterwards.
    # Pick the shared prefix. An explicit CHATI_SYSTEM_PREFIX always wins. Otherwise,
    # if we are ALREADY running from a shared (non-home) location — e.g. a
    # `chati --upgrade` that re-exec'd setup via sudo, which SCRUBS
    # CHATI_SYSTEM_PREFIX — stay there instead of forking a second copy into
    # /opt/chati-linux. Only a fresh install from a user home relocates to /opt (U5).
    SYSTEM_PREFIX="${CHATI_SYSTEM_PREFIX:-}"
    if [[ -z "$SYSTEM_PREFIX" ]]; then
        case "$REPO_ROOT" in
            "$HOME"/*|/home/*|/Users/*|/root/*) SYSTEM_PREFIX="/opt/chati-linux" ;;
            *)                                  SYSTEM_PREFIX="$REPO_ROOT" ;;
        esac
    fi
    if [[ "$REPO_ROOT" != "$SYSTEM_PREFIX" ]]; then
        step "Placing the repo in $SYSTEM_PREFIX (shared, readable by all users)"
        sudo mkdir -p "$SYSTEM_PREFIX"
        sudo cp -a "$REPO_ROOT/." "$SYSTEM_PREFIX/"   # copy contents (incl. .git); refreshes an existing prefix
        # NEVER expose the installing user's per-machine secrets or private state in
        # the SHARED prefix (world-readable /opt): .env holds credentials, and any
        # conversation history / per-instance state is personal. Strip them from the
        # copy — each user keeps their own under CHATI_DATA_HOME, and a shared .env
        # is for the admin to place deliberately (U5). .git stays (upgrades need it).
        sudo rm -rf "$SYSTEM_PREFIX/.env" "$SYSTEM_PREFIX/conversation_histories" \
                    "$SYSTEM_PREFIX/instances" "$SYSTEM_PREFIX/finetune" 2>/dev/null || true
        REPO_ROOT="$SYSTEM_PREFIX"
        ok "Repo available at $SYSTEM_PREFIX"
    fi
    sudo chown -R root:root "$SYSTEM_PREFIX"
    LINK_BIN="/usr/local/bin"
else
    LINK_BIN="$HOME/.local/bin"; mkdir -p "$LINK_BIN"
fi
# Clean up the old ailocal symlink from pre-1.36 installs (ailocal is gone).
[[ -L "$LINK_BIN/ailocal" ]] && link_run rm -f "$LINK_BIN/ailocal" 2>/dev/null
if link_run ln -sf "$REPO_ROOT/chati" "$LINK_BIN/chati" 2>/dev/null; then
    [[ "$SYSTEM_LINK" -eq 1 ]] && _scope=" (all users)" || _scope=""
    ok "Linked into $LINK_BIN — run 'chati' from anywhere${_scope}"
    case ":$PATH:" in
        *":$LINK_BIN:"*) : ;;
        *) warn "$LINK_BIN is not on your PATH. Add it (e.g. in ~/.bashrc): export PATH=\"$LINK_BIN:\$PATH\"" ;;
    esac
else
    warn "Couldn't link into $LINK_BIN — run it as ./chati, or add the repo to your PATH."
fi

# ---- 6. Start Ollama ---------------------------------------------------------
# A model pull (and chati itself) needs the server up. Start it in the
# background and wait until the API answers, so nothing downstream fails with
# "could not connect to ollama server".
step "Starting Ollama service"
# chati_start_ollama (from chati-common.sh) drives Ollama's systemd service
# (installed by the official Linux installer).
if ( CHATI_DIR="$REPO_ROOT"; source "$REPO_ROOT/chati-common.sh"; chati_start_ollama ); then
    ok "Ollama is ready"
else
    die "Ollama didn't come up. Check:  systemctl status ollama"
fi

# ---- 7. Ensure a chat model --------------------------------------------------
step "Ensuring a chat model is available"
installed_models() { ollama list 2>/dev/null | tail -n +2 | awk '{print $1}'; }
have_any_model() { [[ -n "$(installed_models)" ]]; }

# Pick a model sized for the machine, unless the user forced --model. With an
# NVIDIA GPU, size by VRAM (a model bigger than VRAM spills to CPU and crawls);
# otherwise size by system memory. The SAME figure (SIZE_GB) gates the big extra
# models below: a ~19 GB model must fit that budget.
if (( $(detect_vram_gb) > 0 )); then
    SIZE_GB=$(detect_vram_gb); SIZE_KIND="NVIDIA VRAM"
else
    SIZE_GB=$(detect_ram_gb);  SIZE_KIND="memory"
fi
if [[ "$MODEL_EXPLICIT" -ne 1 ]]; then
    CHAT_MODEL="$(recommend_model "$SIZE_GB")"
    # Only announce a freshly chosen model when we'll actually pull it. Under
    # --no-pull, CHAT_MODEL is just a suggestion for the "nothing installed" hint;
    # claiming it as "selected" when it isn't installed here (and won't be pulled)
    # was misleading. The --no-pull branch below reports what's really installed.
    if [[ "$WANT_PULL" -eq 1 ]]; then
        ok "Detected ${SIZE_GB} GB ${SIZE_KIND}, selected model: $CHAT_MODEL"
    else
        ok "Detected ${SIZE_GB} GB ${SIZE_KIND}"
    fi
fi
# Ensure the shared general models + the RAG embedder alongside the chat model,
# so every box in a multi-host pool runs the SAME models (see select_extra_models).
# The guard uses SIZE_GB (VRAM on a Linux GPU box, else RAM).
EXTRA_MODELS="$(select_extra_models "$SIZE_GB" "$WANT_EXTRA_MODELS" "$FORCE_MODELS")"
if [[ "$EXTRA_MODELS" == *gemma4* ]]; then
    warn "Will also ensure: $EXTRA_MODELS (the two gemma4 are ~37 GB together — skip with --no-extra-models)."
elif [[ "$WANT_EXTRA_MODELS" -eq 1 ]]; then
    warn "Only ${SIZE_GB} GB ${SIZE_KIND}: skipping the big gemma4 models (a ~19 GB model needs ≥ ${BIG_MODELS_MIN_GB} GB). Ensuring: $EXTRA_MODELS. Force with --force-models."
else
    ok "--no-extra-models: ensuring only $EXTRA_MODELS alongside the chat model."
fi

# Small helpers for /web, pulled alongside the chat model so web research is
# fast out of the box: llama3.2:3b decides SEARCH vs DIRECT (router), and
# llama3.1:8b rewrites the question into search queries (decompose). Both load
# and run far faster than a big answer model, so /web never cold-loads the big
# model just to triage or make keywords. If absent, /web still works but falls
# back to the chat model for those steps (slow — that is the delay to avoid).
WEB_HELPER_MODELS="llama3.2:3b llama3.1:8b"

if [[ "$WANT_PULL" -eq 0 ]]; then
    if have_any_model; then
        # Point chati at a model that actually exists here. --no-pull means we
        # install nothing, so if the saved active model isn't present, fall to the
        # first installed chat model (skip embedders, which can't chat). Without
        # this, chati started pointed at a model that was never pulled on this box.
        active_file="${CHATI_DATA_HOME:-$HOME/.local/share/chati}/.active_ollama_model.txt"
        mkdir -p "$(dirname "$active_file")" 2>/dev/null
        current="$(cat "$active_file" 2>/dev/null || true)"
        if ! installed_models | grep -qxF "$current"; then
            CHAT_MODEL="$(installed_models | grep -viE 'embed|^bge-' | head -n1)"
            if [[ -n "$CHAT_MODEL" ]]; then
                printf '%s\n' "$CHAT_MODEL" > "$active_file"
                ok "Set active model → $CHAT_MODEL (first installed chat model)"
            fi
        fi
        ok "Using existing model(s): $(installed_models | paste -sd, -)"
    else
        warn "--no-pull set but no chat model is installed. Pull one, e.g.: ollama pull $CHAT_MODEL"
    fi
else
    if installed_models | grep -qxF "$CHAT_MODEL"; then
        ok "Model '$CHAT_MODEL' already present"
    else
        warn "Pulling '$CHAT_MODEL' (first download can take a few minutes)…"
        ollama pull "$CHAT_MODEL"
        ok "Pulled '$CHAT_MODEL'"
    fi
    # Point chati at a model we know exists (only if unset or stale). This must be
    # the GLOBAL model file chati actually reads — $CHATI_DATA_HOME, not the repo
    # dir (data moved out of the checkout in 1.10). Writing it under $REPO_ROOT
    # made `setup.sh --model X` print "Set active model" while changing nothing.
    active_file="${CHATI_DATA_HOME:-$HOME/.local/share/chati}/.active_ollama_model.txt"
    mkdir -p "$(dirname "$active_file")" 2>/dev/null
    current="$(cat "$active_file" 2>/dev/null || true)"
    if ! installed_models | grep -qxF "$current"; then
        printf '%s\n' "$CHAT_MODEL" > "$active_file"
        ok "Set active model → $CHAT_MODEL"
    fi
    # Also ensure the extra models (kept available; active stays $CHAT_MODEL).
    for _m in $EXTRA_MODELS; do
        [[ "$_m" == "$CHAT_MODEL" ]] && { ok "Extra model '$_m' is the chat model already"; continue; }
        if installed_models | grep -qxF "$_m"; then
            ok "Extra model '$_m' already present"
        else
            warn "Pulling extra model '$_m' (first download can take a while)…"
            ollama pull "$_m" && ok "Pulled '$_m'" || warn "Could not pull '$_m' (skipped)"
        fi
    done
    # Pull the /web helper models (skip any that already is the chat model).
    for _m in $WEB_HELPER_MODELS; do
        [[ "$_m" == "$CHAT_MODEL" ]] && { ok "Web helper '$_m' is the chat model already"; continue; }
        if installed_models | grep -qxF "$_m"; then
            ok "Web helper '$_m' already present"
        else
            warn "Pulling /web helper '$_m'…"
            ollama pull "$_m" && ok "Pulled '$_m'" \
                || warn "Could not pull '$_m' (skipped; /web falls back to the chat model)"
        fi
    done
fi

# ---- 8. SearXNG web search (default; skip with --no-searxng/--minimal) -------
# Installed BEFORE OpenWebUI on purpose: OpenWebUI reads its web-search config
# from the environment at boot, so SearXNG must already be present when the UI
# starts for its "search via SearXNG" toggle to come up enabled. Wires chati's
# /web too. NON-FATAL throughout — web search is a bonus, never fails setup.
SEARXNG_STARTED=0
if [[ "$WANT_SEARXNG" -eq 1 ]]; then
    step "Installing local SearXNG (powers /web)"
    if "$REPO_ROOT/installer/install_searxng.sh"; then
        ok "SearXNG installed"
        # Point /web at the local instance — but never clobber an endpoint the
        # user already configured (e.g. a cloud SearXNG in .env).
        env_file="$REPO_ROOT/.env"
        if [[ ! -f "$env_file" ]]; then
            [[ -f "$REPO_ROOT/.env.example" ]] && cp "$REPO_ROOT/.env.example" "$env_file" || touch "$env_file"
        fi
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?SEARXNG_URLS?=' "$env_file"; then
            ok "SearXNG endpoint already set in .env (left as-is)"
        else
            printf '\nexport SEARXNG_URLS="%s"\n' "$SEARXNG_LOCAL_URL" >> "$env_file"
            ok "Wired /web to $SEARXNG_LOCAL_URL in .env"
        fi
        step "Starting SearXNG"
        if ( CHATI_DIR="$REPO_ROOT"; source "$REPO_ROOT/chati-common.sh"; chati_start_searxng ) >/dev/null 2>&1 \
           && curl -fsS --max-time 5 "$SEARXNG_LOCAL_URL/healthz" >/dev/null 2>&1; then
            SEARXNG_STARTED=1
            ok "SearXNG running at $SEARXNG_LOCAL_URL — toggle it in chati with /web"
        else
            warn "SearXNG didn't confirm startup — check ~/logs/searxng.log; it also comes up on demand when you use /web."
        fi
    else
        warn "SearXNG install failed (see output above) — /web stays off. Chat and OpenWebUI are unaffected."
    fi
fi

# ---- 9. OpenWebUI (default; skip with --minimal) ----------------------------
# Install the venv, then start it (with SearXNG already up from step 8, so its
# web search comes up enabled). The start is NON-FATAL: OpenWebUI's first boot
# migrates its DB and can be slow, so a timeout must not abort setup.
WEBUI_STARTED=0
if [[ "$WANT_WEBUI" -eq 1 ]]; then
    step "Installing OpenWebUI (browser UI)"
    # Idempotent by default: install_webui.sh runs `uv pip install --upgrade`,
    # which only downloads a new open-webui if PyPI has one and is a fast no-op
    # otherwise. This is what makes re-running setup (e.g. every `chati --upgrade`)
    # cheap. --force wipes and reinstalls the venv from scratch (repair a broken
    # install); opt in with `setup.sh --force-webui`.
    if [[ "$FORCE_WEBUI" -eq 1 ]]; then
        "$REPO_ROOT/installer/install_webui.sh" --force
    else
        "$REPO_ROOT/installer/install_webui.sh"
    fi
    ok "OpenWebUI installed"
    step "Starting OpenWebUI (first boot can take a minute)"
    if "$REPO_ROOT/libexec/chati-webui"; then
        WEBUI_STARTED=1
        ok "OpenWebUI running at http://127.0.0.1:8888"
    else
        warn "OpenWebUI didn't confirm startup in time (it may still be booting)."
        warn "Check ~/logs/webui.log, or just run: chati --webui"
    fi
fi

# ---- 10. Done ----------------------------------------------------------------
# Descriptions go BEFORE the command so every trailing token is a clean,
# copy-pasteable command (no trailing "# ..." to trip up zsh).
cat <<EOF

$(printf '\033[1;32m')✅ Setup complete!$(printf '\033[0m')
────────────────────────────────────────────
Start the CLI chat:      chati
EOF
if [[ "$WANT_WEBUI" -eq 1 ]]; then
    if [[ "$WEBUI_STARTED" -eq 1 ]]; then
        echo "Browser UI (running):    open http://127.0.0.1:8888"
    else
        echo "Browser UI (start it):   chati --webui"
    fi
fi
if [[ "$WANT_SEARXNG" -eq 1 && "$SEARXNG_STARTED" -eq 1 ]]; then
    echo "Web search (/web):       ready, toggle with /web inside chati"
fi
# Report the models that are ACTUALLY installed now, not a hardcoded wishlist:
# the old summary named the big gemma4 models and "auto-pulled" /web helpers even
# on a box that skipped the big models or ran with --no-pull.
INSTALLED_NOW="$(installed_models | paste -sd', ' -)"
cat <<EOF
Service status:          chati --status
Stop everything:         chati --stop
Models installed:        ${INSTALLED_NOW:-none yet}
Uninstall everything:    $REPO_ROOT/setup.sh --remove-all
EOF
echo "  (Ollama has no auth and stays on localhost. To reach it from your other machines,"
echo "   keep it on localhost and expose it over your tailnet:"
echo "     tailscale serve --bg --tcp 11434 tcp://127.0.0.1:11434"
echo "   Don't bind Ollama to 0.0.0.0 on a public server.)"
echo "Install log:             ${INSTALL_LOG:-$HOME/logs/chati_install_*.log}"
echo
