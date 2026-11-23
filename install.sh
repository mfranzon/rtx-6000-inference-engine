#!/usr/bin/env bash
# inkling-serve installer: Docker + NVIDIA Container Toolkit (if missing), then the Compose stack.
#
#   ./install.sh                      from a checkout
#   curl -fsSL https://raw.githubusercontent.com/mfranzon/rtx-6000-inference-engine/main/install.sh | bash
#                                     (clones INKLING_REPO into ~/inkling-serve first)
#
# Options (flags or environment):
#   --dir DIR            install location when not run from a checkout (default ~/inkling-serve)
#   --model-dir DIR      existing/target model folder (MODEL_DIR; default <dir>/models)
#   --concurrency N      1 = one client with speculative decoding (default), 4 = several clients
#   --port N             host port (default 9000)
#   --no-start           install and configure, don't start
#   --check              only report what is missing, change nothing
# Supported hosts: Ubuntu/Debian with an NVIDIA driver already installed (nvidia-smi works).
set -euo pipefail

INKLING_REPO=${INKLING_REPO:-https://github.com/mfranzon/rtx-6000-inference-engine.git}
DIR=${INKLING_DIR:-$HOME/inkling-serve}
MODEL_DIR=${MODEL_DIR:-}
CONCURRENCY=${MAX_CONCURRENCY:-1}
PORT=${PORT:-9000}
START=1 CHECK=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --dir) DIR=$2; shift 2 ;;
    --model-dir) MODEL_DIR=$2; shift 2 ;;
    --concurrency) CONCURRENCY=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --no-start) START=0; shift ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
SUDO=""; [[ $(id -u) -ne 0 ]] && SUDO="sudo"

# --- checks -------------------------------------------------------------------------------------
say "checking the host"
[[ $(uname -s) == Linux ]] || die "Linux only (found $(uname -s))"
[[ $(uname -m) == x86_64 || $(uname -m) == aarch64 ]] || die "unsupported CPU $(uname -m)"
. /etc/os-release
[[ ${ID:-} == ubuntu || ${ID:-} == debian || ${ID_LIKE:-} == *debian* ]] || die "Ubuntu/Debian only (found ${PRETTY_NAME:-unknown}); install Docker + NVIDIA Container Toolkit yourself and run: docker compose up -d"

command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1 ||
  die "no working NVIDIA driver. Install one first (Ubuntu: sudo ubuntu-drivers install && sudo reboot), then rerun."
gpu=$(nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version --format=csv,noheader | head -1)
IFS=, read -r gname gmem gcap gdrv <<<"$gpu"
gmem_mib=${gmem//[^0-9]/}
ok "GPU:${gname}, ${gmem_mib} MiB, compute ${gcap// /}, driver ${gdrv// /}"
case ${gcap// /} in 7.5|8.6|8.7|8.9|12.0) ;; *) die "compute capability ${gcap// /} is not supported by NInfer (7.5, 8.6, 8.9, 12.0)";; esac
(( gmem_mib >= 22000 )) || die "needs a 24 GB card (found ${gmem_mib} MiB)"
# "CUDA Version: 13.0" on older drivers, "CUDA UMD Version: 13.4" on newer ones.
cuda=$(nvidia-smi | sed -n 's/.*CUDA \(UMD \)\{0,1\}Version: *\([0-9]*\)\..*/\2/p' | head -1)
[[ -n $cuda && $cuda -ge 13 ]] || die "driver supports CUDA ${cuda:-?}; the engine needs a driver with CUDA 13+ (R580 or newer)"

need_docker=0 need_toolkit=0
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then ok "$(docker --version)"; else need_docker=1; echo "    missing: Docker Engine + Compose plugin"; fi
if command -v nvidia-ctk >/dev/null; then ok "NVIDIA Container Toolkit $(nvidia-ctk --version 2>/dev/null | head -1 | grep -o '[0-9.]*' | head -1)"; else need_toolkit=1; echo "    missing: NVIDIA Container Toolkit"; fi
free_gb=$(df -BG --output=avail "${MODEL_DIR:-$HOME}" 2>/dev/null | tail -1 | tr -dc 0-9)
[[ -z $free_gb || $free_gb -ge 18 ]] || echo "    warning: ${free_gb} GB free where the model goes; it needs ~17 GB"
(( CHECK )) && { say "check done"; exit 0; }

# --- install ------------------------------------------------------------------------------------
if (( need_docker )); then
  say "installing Docker (get.docker.com)"
  curl -fsSL https://get.docker.com | $SUDO sh
fi
if (( need_toolkit )); then
  say "installing the NVIDIA Container Toolkit"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
    $SUDO gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' |
    $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  $SUDO apt-get update -qq && $SUDO apt-get install -y -qq nvidia-container-toolkit
fi
if (( need_toolkit || need_docker )); then
  $SUDO nvidia-ctk runtime configure --runtime=docker >/dev/null
  $SUDO systemctl restart docker
fi
DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="$SUDO docker"   # user not (yet) in the docker group

say "checking GPU access from containers"
$DOCKER run --rm --gpus all ubuntu:24.04 nvidia-smi -L >/dev/null 2>&1 ||
  die "containers can't see the GPU; check: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
ok "GPU visible in containers"

# --- get the stack ------------------------------------------------------------------------------
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [[ -n $here && -f $here/compose.yaml ]]; then
  DIR=$here
elif [[ -f $DIR/compose.yaml ]]; then
  say "using existing $DIR"
else
  [[ -n $INKLING_REPO ]] || die "not run from a checkout: set INKLING_REPO=<git url> or clone the repo and run ./install.sh"
  command -v git >/dev/null || $SUDO apt-get install -y -qq git
  say "cloning $INKLING_REPO into $DIR"
  git clone --depth 1 "$INKLING_REPO" "$DIR"
fi
cd "$DIR"

# --- configure ----------------------------------------------------------------------------------
if [[ ! -f .env ]]; then
  say "writing .env"
  cp .env.example .env
  {
    echo "PORT=$PORT"
    echo "MAX_CONCURRENCY=$CONCURRENCY"
    (( CONCURRENCY > 1 )) && echo "MAX_CONTEXT=32768"
    [[ -n $MODEL_DIR ]] && echo "MODEL_DIR=$MODEL_DIR"
  } >>.env
else
  ok "keeping existing .env"
fi

(( START )) || { say "installed in $DIR; start with: cd $DIR && docker compose up -d --wait"; exit 0; }

if ss -ltn "sport = :$PORT" 2>/dev/null | grep -q LISTEN && ! $DOCKER compose ps -q ninfer 2>/dev/null | grep -q .; then
  die "port $PORT is in use by something else; pick another with --port or stop it"
fi

# --- start --------------------------------------------------------------------------------------
say "starting (first run downloads 16.5 GB; progress: docker compose -f $DIR/compose.yaml logs -f fetch)"
$DOCKER compose up -d --wait
model=$(curl -sf "http://127.0.0.1:$PORT/v1/models" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
say "smoke test"
curl -sf "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the word ready.\"}],\"max_tokens\":200}" |
  grep -q '"choices"' && ok "chat completion works" || die "the server is up but a chat request failed: docker compose logs ninfer"
cat <<EOF

  inkling-serve is running.
    API      http://127.0.0.1:$PORT/v1   (OpenAI-compatible; also /v1/messages)
    model    $model
    logs     cd $DIR && docker compose logs -f ninfer
    stop     cd $DIR && docker compose down
  From your laptop: ssh -N -L $PORT:127.0.0.1:$PORT $(id -un)@<this-host>
EOF
