#!/usr/bin/env bash
# Shadowsocks-Rust Docker 部署脚本（交互式）
# 功能：安装、卸载、更新、启动、停止、重启
# 不依赖本地 load 镜像，直接使用 docker pull

set -e

# ---------- 按架构选择镜像 (arm64 / amd64) -----------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  DOCKER_ARCH="amd64" ;;
  aarch64|arm64) DOCKER_ARCH="arm64" ;;
  *)             echo "不支持的架构: $ARCH，仅支持 x86_64/amd64 或 aarch64/arm64"; exit 1 ;;
esac
echo ">>> 检测到架构: $ARCH，使用镜像标签: latest-${DOCKER_ARCH}"

# ---------- 固定配置 -----------
SERVER_IMAGE="yuyu8868/ssserver-rust:latest-${DOCKER_ARCH}"
CLIENT_IMAGE="yuyu8868/sslocal-rust:latest-${DOCKER_ARCH}"
SERVER_CONTAINER="ssr-server-rust"
CLIENT_CONTAINER="ssr-local-rust"
RUN_USER="65534:65534"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.ssr-deploy"
SERVER_STATE="${STATE_DIR}/server.state"
CLIENT_STATE="${STATE_DIR}/client.state"

# ---------- 安装时交互输入的配置（安装后从 state 文件读取）----------
CONF_DIR=""
LOG_DIR=""
SERVER_PORT=""
CLIENT_PORT=""
SS_METHOD=""
SS_PASSWORD=""

# ---------- 当前模式：server / client ----------
MODE="${MODE:-}"

need_root() {
  if [[ $EUID -ne 0 ]] && ! docker info &>/dev/null; then
    echo "请使用 sudo 运行此脚本，或确保当前用户有 Docker 权限。"
    exit 1
  fi
}

# 拉取镜像（若本地已有则跳过；否则带重试，避免 ghcr.io 连接超时）
PULL_RETRIES="${PULL_RETRIES:-3}"
PULL_RETRY_DELAY="${PULL_RETRY_DELAY:-5}"
safe_pull() {
  local img="$1" i=1
  if docker image inspect "$img" &>/dev/null; then
    echo ">>> 镜像已存在，跳过拉取: $img"
    return 0
  fi
  while true; do
    echo ">>> 拉取镜像 (尝试 $i/$PULL_RETRIES): $img"
    if docker pull "$img"; then
      return 0
    fi
    if [[ $i -ge PULL_RETRIES ]]; then
      echo ""
      echo "拉取失败（多为网络无法访问 ghcr.io 或超时）。可尝试："
      echo "  1) 配置系统或 Docker 代理后再执行本脚本"
      echo "  2) 在 /etc/docker/daemon.json 中增加: \"max-concurrent-downloads\": 1，然后 systemctl restart docker"
      echo "  3) 在能访问 ghcr.io 的机器上执行: docker pull $img && docker save -o xxx.tar $img"
      echo "     拷贝 xxx.tar 到本机后: docker load -i xxx.tar，再重新执行安装（安装时不会再次拉取）"
      exit 1
    fi
    echo ">>> 等待 ${PULL_RETRY_DELAY} 秒后重试..."
    sleep "$PULL_RETRY_DELAY"
    i=$((i + 1))
  done
}

ensure_dirs() {
  mkdir -p "$CONF_DIR" "$LOG_DIR"
  chown "$RUN_USER" "$LOG_DIR" 2>/dev/null || true
}

# 随机生成密码（约 24 字符，URL 安全）
gen_password() {
  openssl rand -base64 18 | tr -d '\n/+=' | head -c 24
}

# 交互选择加密方式，默认推荐 aes-256-gcm
choose_method() {
  echo "请选择加密方式（安全与速度均衡推荐选 1）:"
  echo "  1) aes-256-gcm      [推荐] 安全与速度均衡"
  echo "  2) aes-128-gcm      速度更快，安全性略低"
  echo "  3) chacha20-ietf-poly1305  无 AES 硬件加速时表现好"
  read -p "请输入 [1/2/3]，直接回车为 1: " m
  case "${m:-1}" in
    1) SS_METHOD="aes-256-gcm" ;;
    2) SS_METHOD="aes-128-gcm" ;;
    3) SS_METHOD="chacha20-ietf-poly1305" ;;
    *) echo "无效选择，使用 aes-256-gcm"; SS_METHOD="aes-256-gcm" ;;
  esac
  echo ">>> 加密方式: $SS_METHOD"
}

# 安装时交互输入：配置目录、日志目录、端口（服务端/客户端）
prompt_install_paths() {
  read -p "配置目录 (CONF_DIR) [/conf/ssr]: " CONF_DIR
  CONF_DIR="${CONF_DIR:-/conf/ssr}"
  read -p "日志目录 (LOG_DIR) [/logs/ssr]: " LOG_DIR
  LOG_DIR="${LOG_DIR:-/logs/ssr}"
  if [[ "$MODE" == "server" ]]; then
    read -p "服务端端口 (SERVER_PORT) [10026]: " SERVER_PORT
    SERVER_PORT="${SERVER_PORT:-10026}"
  else
    read -p "本地监听端口 (CLIENT_PORT) [1086]: " CLIENT_PORT
    CLIENT_PORT="${CLIENT_PORT:-1086}"
  fi
}

# 从 state 文件加载上次安装时的配置（用于 启动/停止/重启/更新/卸载）
load_state() {
  local f
  if [[ "$MODE" == "server" ]]; then f="$SERVER_STATE"; else f="$CLIENT_STATE"; fi
  if [[ -f "$f" ]]; then
    # shellcheck source=/dev/null
    source "$f"
  else
    echo "未找到安装记录 ($f)，请先执行安装。"
    exit 1
  fi
}

# 保存当前配置到 state 文件（对单引号转义以便 source 安全）
save_state() {
  mkdir -p "$STATE_DIR"
  _escape() { echo "${1//\'/\'\\\'\'}"; }
  if [[ "$MODE" == "server" ]]; then
    cat > "$SERVER_STATE" << EOF
CONF_DIR='$(_escape "$CONF_DIR")'
LOG_DIR='$(_escape "$LOG_DIR")'
SERVER_PORT='$(_escape "$SERVER_PORT")'
SS_METHOD='$(_escape "$SS_METHOD")'
SS_PASSWORD='$(_escape "$SS_PASSWORD")'
EOF
  else
    cat > "$CLIENT_STATE" << EOF
CONF_DIR='$(_escape "$CONF_DIR")'
LOG_DIR='$(_escape "$LOG_DIR")'
CLIENT_PORT='$(_escape "$CLIENT_PORT")'
EOF
  fi
}

# ---------- 安装 ----------
install_server() {
  need_root
  prompt_install_paths
  choose_method
  SS_PASSWORD="$(gen_password)"
  echo ">>> 已随机生成密钥，安装完成后会显示，请妥善保存。"

  safe_pull "$SERVER_IMAGE"
  ensure_dirs
  mkdir -p "$CONF_DIR"
  cat > "${CONF_DIR}/config.json" << EOF
{
    "server": "0.0.0.0",
    "server_port": ${SERVER_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "mode": "tcp_and_udp",
    "timeout": 86400
}
EOF
  chown "$RUN_USER" "${CONF_DIR}/config.json" 2>/dev/null || true

  docker run \
    --name "$SERVER_CONTAINER" \
    --restart always \
    -p "${SERVER_PORT}:${SERVER_PORT}" \
    -p "${SERVER_PORT}:${SERVER_PORT}/udp" \
    -v "${CONF_DIR}:/etc/shadowsocks-rust" \
    -v "${LOG_DIR}:/var/log/shadowsocks-rust" \
    -dit "$SERVER_IMAGE"
  save_state
  echo ""
  echo ">>> 服务端已安装并启动。配置目录: $CONF_DIR"
  echo ">>> 请保存以下信息，客户端连接时需要："
  echo ">>>   加密方式: $SS_METHOD"
  echo ">>>   密钥:     $SS_PASSWORD"
  echo ">>>   端口:     $SERVER_PORT"
}

install_client() {
  need_root
  prompt_install_paths
  ensure_dirs
  if [[ ! -f "${CONF_DIR}/config.json" ]]; then
    read -p "服务端地址 (server): " SS_SERVER
    read -p "服务端端口 (server_port) [10026]: " SS_PORT
    SS_PORT="${SS_PORT:-10026}"
    read -p "密钥 (password，与服务端一致): " SS_PASSWORD
    choose_method
    mkdir -p "$CONF_DIR"
    cat > "${CONF_DIR}/config.json" << EOF
{
    "server": "${SS_SERVER}",
    "local_port": ${CLIENT_PORT},
    "local_address": "0.0.0.0",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "mode": "tcp_and_udp",
    "timeout": 86400,
    "method": "${SS_METHOD}"
}
EOF
    echo ">>> 已生成 ${CONF_DIR}/config.json"
  fi
  safe_pull "$CLIENT_IMAGE"
  docker run \
    --name "$CLIENT_CONTAINER" \
    --restart always \
    -p "${CLIENT_PORT}:${CLIENT_PORT}/tcp" \
    -p "${CLIENT_PORT}:${CLIENT_PORT}/udp" \
    -v "${CONF_DIR}:/etc/shadowsocks-rust" \
    -v "${LOG_DIR}:/var/log/shadowsocks-rust" \
    -dit "$CLIENT_IMAGE"
  save_state
  echo ">>> 客户端已安装并启动。本地端口: $CLIENT_PORT，配置: $CONF_DIR"
}

do_install() {
  choose_mode
  if [[ "$MODE" == "server" ]]; then
    if docker ps -a --format '{{.Names}}' | grep -q "^${SERVER_CONTAINER}$"; then
      echo "容器 $SERVER_CONTAINER 已存在。请先卸载或选择更新。"
      return 1
    fi
    install_server
  else
    if docker ps -a --format '{{.Names}}' | grep -q "^${CLIENT_CONTAINER}$"; then
      echo "容器 $CLIENT_CONTAINER 已存在。请先卸载或选择更新。"
      return 1
    fi
    install_client
  fi
}

# ---------- 卸载 ----------
do_uninstall() {
  need_root
  choose_mode
  load_state
  local name
  if [[ "$MODE" == "server" ]]; then name="$SERVER_CONTAINER"; else name="$CLIENT_CONTAINER"; fi
  if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
    docker stop "$name" 2>/dev/null || true
    docker rm "$name"
    echo ">>> 已删除容器: $name"
  else
    echo "容器 $name 不存在。"
  fi
  read -p "是否删除镜像? [y/N]: " del_img
  if [[ "$del_img" == "y" || "$del_img" == "Y" ]]; then
    if [[ "$MODE" == "server" ]]; then docker rmi "$SERVER_IMAGE" 2>/dev/null || true; else docker rmi "$CLIENT_IMAGE" 2>/dev/null || true; fi
    echo ">>> 镜像已删除。"
  fi
  rm -f "$( [[ "$MODE" == "server" ]] && echo "$SERVER_STATE" || echo "$CLIENT_STATE" )"
  echo ">>> 已清除该模式的安装记录。"
}

# ---------- 更新 ----------
do_update() {
  need_root
  choose_mode
  load_state
  if [[ "$MODE" == "server" ]]; then
    safe_pull "$SERVER_IMAGE"
    docker stop "$SERVER_CONTAINER" 2>/dev/null || true
    docker rm "$SERVER_CONTAINER" 2>/dev/null || true
    ensure_dirs
    docker run \
      --name "$SERVER_CONTAINER" \
      --restart always \
      -p "${SERVER_PORT}:${SERVER_PORT}" \
      -p "${SERVER_PORT}:${SERVER_PORT}/udp" \
      -v "${CONF_DIR}:/etc/shadowsocks-rust" \
      -v "${LOG_DIR}:/var/log/shadowsocks-rust" \
      -dit "$SERVER_IMAGE"
    echo ">>> 服务端已更新并启动。"
  else
    safe_pull "$CLIENT_IMAGE"
    docker stop "$CLIENT_CONTAINER" 2>/dev/null || true
    docker rm "$CLIENT_CONTAINER" 2>/dev/null || true
    ensure_dirs
    docker run \
      --name "$CLIENT_CONTAINER" \
      --restart always \
      -p "${CLIENT_PORT}:${CLIENT_PORT}/tcp" \
      -p "${CLIENT_PORT}:${CLIENT_PORT}/udp" \
      -v "${CONF_DIR}:/etc/shadowsocks-rust" \
      -v "${LOG_DIR}:/var/log/shadowsocks-rust" \
      -dit "$CLIENT_IMAGE"
    echo ">>> 客户端已更新并启动。"
  fi
}

# ---------- 启动 / 停止 / 重启 ----------
do_start() {
  choose_mode
  load_state
  local name
  if [[ "$MODE" == "server" ]]; then name="$SERVER_CONTAINER"; else name="$CLIENT_CONTAINER"; fi
  if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
    docker start "$name"
    echo ">>> 已启动: $name"
  else
    echo "容器 $name 不存在，请先执行安装。"
    return 1
  fi
}

do_stop() {
  choose_mode
  load_state
  local name
  if [[ "$MODE" == "server" ]]; then name="$SERVER_CONTAINER"; else name="$CLIENT_CONTAINER"; fi
  if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
    docker stop "$name"
    echo ">>> 已停止: $name"
  else
    echo "容器 $name 不存在。"
  fi
}

do_restart() {
  choose_mode
  load_state
  local name
  if [[ "$MODE" == "server" ]]; then name="$SERVER_CONTAINER"; else name="$CLIENT_CONTAINER"; fi
  if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
    docker stop "$name" && docker start "$name"
    echo ">>> 已重启: $name"
  else
    echo "容器 $name 不存在，请先执行安装。"
    return 1
  fi
}

choose_mode() {
  if [[ -n "$MODE" ]]; then return; fi
  echo "请选择模式:"
  echo "  1) server  - 服务端 (ssserver)"
  echo "  2) client  - 客户端 (sslocal)"
  read -p "请输入 [1/2]: " m
  case "$m" in
    1) MODE="server" ;;
    2) MODE="client" ;;
    *) echo "无效选择"; exit 1 ;;
  esac
}

# ---------- 交互菜单 ----------
show_menu() {
  echo ""
  echo "=========================================="
  echo "  Shadowsocks-Rust Docker 部署脚本"
  echo "=========================================="
  echo "  1) 安装 (install)"
  echo "  2) 卸载 (uninstall)"
  echo "  3) 更新 (update)"
  echo "  4) 启动 (start)"
  echo "  5) 停止 (stop)"
  echo "  6) 重启 (restart)"
  echo "  0) 退出"
  echo "=========================================="
  read -p "请选择操作 [0-6]: " choice
  echo ""
  case "$choice" in
    1) do_install ;;
    2) do_uninstall ;;
    3) do_update ;;
    4) do_start ;;
    5) do_stop ;;
    6) do_restart ;;
    0) echo "退出。"; exit 0 ;;
    *) echo "无效选择。"; exit 1 ;;
  esac
}

# ---------- 支持命令行参数 ----------
run_by_arg() {
  case "$1" in
    install)   MODE=; do_install ;;
    uninstall) do_uninstall ;;
    update)    do_update ;;
    start)     do_start ;;
    stop)      do_stop ;;
    restart)   do_restart ;;
    *)         echo "未知参数: $1"; echo "用法: $0 [ install | uninstall | update | start | stop | restart ]"; exit 1 ;;
  esac
}

# ---------- 入口 ----------
main() {
  if [[ -n "$1" ]]; then
    run_by_arg "$1"
  else
    show_menu
  fi
}

main "$@"
