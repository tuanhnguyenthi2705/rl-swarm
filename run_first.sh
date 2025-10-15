#!/usr/bin/env bash
set -euo pipefail

# ==== KILL PORT 3000 TRƯỚC KHI CHẠY ====
echo "Kiem tra port 3000..."
if command -v fuser >/dev/null 2>&1; then
  fuser -k 3000/tcp || true
else
  PIDS=$(lsof -t -i:3000 2>/dev/null || true)
  [ -n "${PIDS:-}" ] && kill -9 $PIDS || true
fi

ROOT=$PWD

# ==== Python venv ====
if [ ! -d "$ROOT/.venv" ]; then
  python3 -m venv "$ROOT/.venv"
fi
# shellcheck disable=SC1091
source "$ROOT/.venv/bin/activate"
python -m pip install --upgrade pip wheel setuptools

# GenRL Swarm version to use
GENRL_PIP_VERSION="0.1.9"

export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes
export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
export PRG_CONTRACT="0x51D4db531ae706a6eC732458825465058fA23a35"
export HUGGINGFACE_ACCESS_TOKEN="None"
export PRG_GAME=true

DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

DOCKER=${DOCKER:-""}
GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}
CPU_ONLY=true
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"; BLUE_TEXT="\033[34m"; RED_TEXT="\033[31m"; RESET_TEXT="\033[0m"
echo_green(){ echo -e "$GREEN_TEXT$1$RESET_TEXT"; }
echo_blue(){  echo -e "$BLUE_TEXT$1$RESET_TEXT"; }
echo_red(){   echo -e "$RED_TEXT$1$RESET_TEXT"; }

mkdir -p "$ROOT/logs"

# ========== modal-login & Yarn ==========
if [ "$CONNECT_TO_TESTNET" = true ]; then
  echo "Please login to create an Ethereum Server Wallet"
  cd modal-login

  # Node.js (nếu thiếu)
  if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js via NodeSource 22.x..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
  fi

  # Yarn (nếu thiếu)
  if ! command -v yarn >/dev/null 2>&1; then
    echo "Installing Yarn..."
    corepack enable || true
    npm i -g yarn || true
    command -v yarn >/dev/null 2>&1 || { echo "Yarn install failed"; exit 1; }
  fi

  # .yarnrc.yml – tắt immutable + dùng node-modules cho ổn định dưới systemd
  if [ ! -f ".yarnrc.yml" ]; then
    printf "enableImmutableInstalls: false\nnodeLinker: node-modules\n" > .yarnrc.yml
  else
    # đảm bảo 2 key tồn tại
    grep -q '^enableImmutableInstalls:' .yarnrc.yml || echo "enableImmutableInstalls: false" >> .yarnrc.yml
    grep -q '^nodeLinker:' .yarnrc.yml || echo "nodeLinker: node-modules" >> .yarnrc.yml
  fi
  yarn config set enableImmutableInstalls false
  unset CI; export YARN_ENABLE_IMMUTABLE_INSTALLS=0

  # Sửa .env theo KEY (không phụ thuộc số dòng)
  ENV_FILE="$ROOT/modal-login/.env"
  touch "$ENV_FILE"
  tmpenv="$ENV_FILE.tmp"
  grep -v '^SWARM_CONTRACT_ADDRESS=' "$ENV_FILE" | grep -v '^PRG_CONTRACT_ADDRESS=' > "$tmpenv" || true
  {
    echo "SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT"
    echo "PRG_CONTRACT_ADDRESS=$PRG_CONTRACT"
  } >> "$tmpenv"
  mv "$tmpenv" "$ENV_FILE"

  # Fix peer deps: ép viem=2.29.2
  if command -v jq >/dev/null 2>&1; then
    tmp_pkg=$(mktemp)
    jq '. + {"resolutions":{"viem":"2.29.2"}}' package.json > "$tmp_pkg" && mv "$tmp_pkg" package.json
  else
    yarn add viem@2.29.2
  fi

  # Cài deps & build
  if [ -z "$DOCKER" ]; then
    yarn install   # KHÔNG dùng --immutable
    echo "Building server"
    yarn build > "$ROOT/logs/yarn.log" 2>&1
  fi

  # Chạy server + trap dọn dẹp
  echo_green ">> Starting backend server (modal-login)"
  yarn start >> "$ROOT/logs/yarn.log" 2>&1 &
  SERVER_PID=$!
  cleanup(){ pkill -f "yarn start" 2>/dev/null || true; pkill -f "ngrok http 3000" 2>/dev/null || true; }
  trap cleanup EXIT INT TERM

  sleep 3

  # Nếu chưa có login, bật ngrok (tùy chọn)
  if ! ls "$ROOT"/modal-login/temp-data/user*.json 1>/dev/null 2>&1; then
    if ! command -v ngrok >/dev/null 2>&1; then
      echo "Installing ngrok..."
      curl -s https://ngrok-agent.s3.amazonaws.com/ngrok.asc | tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
      echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | tee /etc/apt/sources.list.d/ngrok.list >/dev/null
      apt-get update -y >/dev/null && apt-get install -y ngrok >/dev/null
    fi
    [ -f "$HOME/.config/ngrok/ngrok.yml" ] || { read -rp "Nhap ngrok token: " NGROK_TOKEN; ngrok config add-authtoken "$NGROK_TOKEN"; }
    nohup ngrok http 3000 >/dev/null 2>&1 &
  fi

  cd "$ROOT"
  echo_green ">> Dang cho tao file userData.json..."
  WAIT_JSON_TIMEOUT=300
  waited=0
  until [ -f "modal-login/temp-data/userData.json" ] || [ $waited -ge $WAIT_JSON_TIMEOUT ]; do
    sleep 5; waited=$((waited+5))
  done
  [ -f "modal-login/temp-data/userData.json" ] || { echo_red "Timeout doi userData.json"; exit 1; }

  # Lấy ORG_ID bằng jq
  if ! command -v jq >/dev/null 2>&1; then
    apt-get update && apt-get install -y jq >/dev/null 2>&1 || true
  fi
  ORG_ID=$(jq -r '.orgId // empty' "modal-login/temp-data/userData.json")
  [ -n "$ORG_ID" ] || { echo_red "Khong tim thay orgId trong userData.json"; exit 1; }
  echo "ORG_ID: $ORG_ID"

  # Chờ API key kích hoạt (timeout)
  echo "Cho kich hoat API key..."
  MAX_TRIES=120  # ~10 phút
  try=0
  while :; do
    STATUS=$(curl -m 3 -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID" || echo "error")
    if [[ "$STATUS" == "activated" ]]; then
      echo_green "API key da duoc kich hoat!"
      break
    fi
    try=$((try+1)); [ $try -ge $MAX_TRIES ] && { echo_red "Timeout doi API key"; exit 1; }
    sleep 5
  done
fi

# ==== Python deps (đúng version) ====
echo_green ">> Cai dat thu vien Python..."
python -m pip install "gensyn-genrl==${GENRL_PIP_VERSION}"
python -m pip install "reasoning-gym>=0.1.20"
python -m pip install "hivemind@git+https://github.com/gensyn-ai/hivemind@639c964a8019de63135a2594663b5bec8e5356dd"

# ==== Configs ====
mkdir -p "$ROOT/configs"
cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"

MODEL_NAME="Gensyn/Qwen2.5-0.5B-Instruct"
export MODEL_NAME PRG_GAME

echo_green ">> Khoi chay rl-swarm..."
python -m rgym_exp.runner.swarm_launcher \
  --config-path "$ROOT/rgym_exp/config" \
  --config-name "rg-swarm.yaml"
