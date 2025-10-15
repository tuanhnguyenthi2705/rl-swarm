#!/usr/bin/env bash
set -euo pipefail

ROOT=$PWD

export CONNECT_TO_TESTNET=true
export HF_HUB_DOWNLOAD_TIMEOUT=120
export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
export PRG_CONTRACT="0x51D4db531ae706a6eC732458825465058fA23a35"
export HUGGINGFACE_ACCESS_TOKEN="None"
export PRG_GAME=true
export MODEL_NAME="Gensyn/Qwen2.5-0.5B-Instruct"

GREEN_TEXT="\033[32m"; BLUE_TEXT="\033[34m"; RED_TEXT="\033[31m"; RESET_TEXT="\033[0m"
echo_green(){ echo -e "$GREEN_TEXT$1$RESET_TEXT"; }
echo_blue(){  echo -e "$BLUE_TEXT$1$RESET_TEXT"; }
echo_red(){   echo -e "$RED_TEXT$1$RESET_TEXT"; }

mkdir -p "$ROOT/logs"

# Bảo đảm port 3000 rảnh và không còn yarn cũ
pkill -f "yarn start" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k 3000/tcp || true
else
  PIDS=$(lsof -t -i:3000 2>/dev/null || true)
  [ -n "${PIDS:-}" ] && kill -9 $PIDS || true
fi

if [ "$CONNECT_TO_TESTNET" = true ]; then
  cd modal-login

  # Không để immutable & fix viem 2.29.2 (đồng bộ với run_first.sh)
  if [ ! -f ".yarnrc.yml" ]; then
    printf "enableImmutableInstalls: false\nnodeLinker: node-modules\n" > .yarnrc.yml
  else
    grep -q '^enableImmutableInstalls:' .yarnrc.yml || echo "enableImmutableInstalls: false" >> .yarnrc.yml
    grep -q '^nodeLinker:' .yarnrc.yml || echo "nodeLinker: node-modules" >> .yarnrc.yml
  fi
  yarn config set enableImmutableInstalls false
  unset CI; export YARN_ENABLE_IMMUTABLE_INSTALLS=0

  if command -v jq >/dev/null 2>&1; then
    tmp_pkg=$(mktemp)
    jq '. + {"resolutions":{"viem":"2.29.2"}}' package.json > "$tmp_pkg" && mv "$tmp_pkg" package.json
  else
    yarn add viem@2.29.2
  fi

  # Sửa .env theo KEY
  ENV_FILE="$ROOT/modal-login/.env"
  touch "$ENV_FILE"
  tmpenv="$ENV_FILE.tmp"
  grep -v '^SWARM_CONTRACT_ADDRESS=' "$ENV_FILE" | grep -v '^PRG_CONTRACT_ADDRESS=' > "$tmpenv" || true
  {
    echo "SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT"
    echo "PRG_CONTRACT_ADDRESS=$PRG_CONTRACT"
  } >> "$tmpenv"
  mv "$tmpenv" "$ENV_FILE"

  # Bắt buộc có userData.json (đã login từ lần đầu)
  [ -f "temp-data/userData.json" ] || { echo_red "userData.json not found! Run run_first.sh first."; exit 1; }

  # Start server
  echo_green ">> Starting backend server (modal-login)"
  yarn start >> "$ROOT/logs/yarn.log" 2>&1 &
  trap 'pkill -f "yarn start" 2>/dev/null || true' EXIT INT TERM
  sleep 3

  cd "$ROOT"

  # Lấy ORG_ID kiểu đơn giản bằng awk (giống bản bạn đang chạy OK)
  ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' \
    "modal-login/temp-data/userData.json" || true)
  if [ -z "${ORG_ID:-}" ]; then
    echo "CANH BAO: Khong tim thay orgId trong userData.json -> bo qua buoc doi kich hoat API key."
  else
    echo "ORG_ID: $ORG_ID"
    # Kiểm tra API key (timeout ngắn hơn)
    echo "Checking API key status..."
    MAX_TRIES=60  # ~5 phút
    try=0
    while :; do
      STATUS=$(curl -m 3 -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID" || echo "error")
      [ "$STATUS" = "activated" ] && { echo_green "API key activated!"; break; }
      try=$((try+1)); [ $try -ge $MAX_TRIES ] && { echo "CANH BAO: Timeout doi API key, tiep tuc."; break; }
      sleep 5
    done
  fi
fi

# Đảm bảo có configs
mkdir -p "$ROOT/configs"
cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml" 2>/dev/null || true

echo_green ">> Using model: $MODEL_NAME"
echo_green ">> Starting rl-swarm..."
python3 -m rgym_exp.runner.swarm_launcher \
  --config-path "$ROOT/rgym_exp/config" \
  --config-name "rg-swarm.yaml"
