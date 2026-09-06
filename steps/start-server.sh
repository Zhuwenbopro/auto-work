#!/usr/bin/env bash
# ============================================================================
# start-server.sh —— step: 启动 SGLang 服务(单一职责)
#
# 职责:在候选 GPU 上把给定 server 命令部署到"服务健康就绪"。
#   成功 -> exit 0, 打印 STEP_RESULT=OK, 写 started.json(PID/PGID/端口/GPU/日志)
#          服务进程组与锁由服务自身持有(其继承了锁 fd),交接给下游 run-* / release;
#   失败 -> 非 0 退出 + STEP_RESULT 行 + failed.json, 并自行清理本次占用。
#
# 结果码(退出码):
#   0  OK        服务健康就绪
#   2  输入/配置/用法错误(未碰资源)
#   3  RETRYABLE 无可用端口等可重试失败(已清理)
#   4  FATAL     命令非法 / 服务启动即失败(进程退出,日志有错)
#   5  TIMEOUT   等卡超时 或 服务存活但超时未健康
#   本 step 只做一次尝试;重试策略归上层。
#
# 用法:
#   bash start-server.sh --server-command server_command.sh [选项]
#   选项:
#     --server-command PATH  必填。规范化启动命令文件(export/unset + sglang serve)
#     --config PATH          可选 config.env(默认仅用内置默认值)
#     --result-root PATH     可选,RUN_DIR 父目录(默认 ./start_runs)
#     --gpu-allowlist CSV    可选,只在这些 GPU 内等待/锁定
#     --parser PATH          可选,server_command_parser.py 路径(默认自动探测)
#     -h, --help
#
# 环境:依赖 python3 curl rocm-smi setsid flock tail grep;由 config 控制:
#   HOST/HEALTH_HOST/START_PORT/END_PORT/SERVER_START_TIMEOUT/HEALTH_CHECK_INTERVAL/
#   GPU_VRAM_MAX_PERCENT/GPU_HCU_MAX_PERCENT/GPU_POLL_INTERVAL/GPU_CONFIRM_SECONDS/
#   GPU_WAIT_TIMEOUT(0=无限)/SHUTDOWN_TIMEOUT/FAILURE_LOG_LINES/
#   GPU_LOCK_DIR/PORT_LOCK_DIR
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# ---------------- 参数解析 ----------------
CONFIG_FILE=""
SERVER_COMMAND=""
RESULT_ROOT=""
GPU_ALLOWLIST=""
PARSER_FILE=""

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' >&2
}

while (($#)); do
  case "$1" in
    --server-command)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--server-command 需要路径" >&2; exit 2; }
      SERVER_COMMAND=$2; shift 2 ;;
    --config)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--config 需要路径" >&2; exit 2; }
      CONFIG_FILE=$2; shift 2 ;;
    --result-root)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--result-root 需要路径" >&2; exit 2; }
      RESULT_ROOT=$2; shift 2 ;;
    --gpu-allowlist)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--gpu-allowlist 需要逗号分隔 GPU 编号" >&2; exit 2; }
      GPU_ALLOWLIST=$2; shift 2 ;;
    --parser)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--parser 需要路径" >&2; exit 2; }
      PARSER_FILE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误:未知参数:$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$SERVER_COMMAND" ]] || { echo "错误:必须提供 --server-command" >&2; exit 2; }
[[ -f "$SERVER_COMMAND" ]] || { echo "错误:服务命令文件不存在:$SERVER_COMMAND" >&2; exit 2; }

# 可选配置文件(不存在即用默认值)
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || { echo "错误:配置文件不存在:$CONFIG_FILE" >&2; exit 2; }
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# ---------------- 默认值 ----------------
: "${HOST:=127.0.0.1}"
: "${HEALTH_HOST:=127.0.0.1}"
: "${RESULT_ROOT:=./start_runs}"
: "${START_PORT:=30000}"
: "${END_PORT:=35000}"
: "${SERVER_START_TIMEOUT:=3600}"   # 启动健康等待上限(1h;超时即 TIMEOUT)
: "${HEALTH_CHECK_INTERVAL:=2}"
: "${GPU_VRAM_MAX_PERCENT:=5}"
: "${GPU_HCU_MAX_PERCENT:=0}"
: "${GPU_POLL_INTERVAL:=30}"
: "${GPU_CONFIRM_SECONDS:=3}"
: "${GPU_WAIT_TIMEOUT:=0}"        # 秒;0 = 无限等卡
: "${SHUTDOWN_TIMEOUT:=15}"
: "${FAILURE_LOG_LINES:=100}"
: "${GPU_LOCK_DIR:=/tmp/start_server_gpu_locks}"
: "${PORT_LOCK_DIR:=/tmp/start_server_port_locks}"
: "${GPU_ALLOWLIST:=}"
[[ -n "$RESULT_ROOT" ]] || RESULT_ROOT=./start_runs

# ---------------- 工具与校验函数 ----------------
log() { printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*"; }
die() { log "错误:$*"; exit 2; }

is_nonnegative_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# 探测 parser 位置:env/显式 -> 脚本旁 -> lib 旁 -> 本地仓库(eval skill)
find_parser() {
  local cand
  if [[ -n "${SERVER_PARSER:-}" && -f "${SERVER_PARSER}" ]]; then
    PARSER_FILE=${SERVER_PARSER}; return 0
  fi
  if [[ -n "$PARSER_FILE" && -f "$PARSER_FILE" ]]; then
    return 0
  fi
  for cand in \
    "$SCRIPT_DIR/lib/server_command_parser.py" \
    "$SCRIPT_DIR/../lib/server_command_parser.py" \
    "$SCRIPT_DIR/../../skills/eval/automation/lib/server_command_parser.py"; do
    if [[ -f "$cand" ]]; then PARSER_FILE=$cand; return 0; fi
  done
  return 1
}

GPU_ALLOWLIST=${GPU_ALLOWLIST//[[:space:]]/}
[[ -z "$GPU_ALLOWLIST" || "$GPU_ALLOWLIST" =~ ^[0-9]+(,[0-9]+)*$ ]] || \
  die "GPU_ALLOWLIST 必须是逗号分隔的 GPU 编号,例如 2,3,4,5"

for cmd in python3 curl rocm-smi setsid flock tail grep; do
  command -v "$cmd" >/dev/null 2>&1 || die "找不到命令:$cmd"
done

for v in TP_SIZE_PLACEHOLDER; do :; done # (保留空行给后续校验)
for v in START_PORT END_PORT SERVER_START_TIMEOUT HEALTH_CHECK_INTERVAL \
  GPU_POLL_INTERVAL SHUTDOWN_TIMEOUT FAILURE_LOG_LINES; do
  is_positive_integer "${!v}" || die "$v 必须是正整数"
done
for v in GPU_VRAM_MAX_PERCENT GPU_HCU_MAX_PERCENT GPU_CONFIRM_SECONDS GPU_WAIT_TIMEOUT; do
  is_nonnegative_integer "${!v}" || die "$v 必须是非负整数"
done
((START_PORT <= END_PORT)) || die "START_PORT 不能大于 END_PORT"

find_parser || die "找不到 server_command_parser.py,请用 --parser PATH 指定"
log "使用命令解析器:$PARSER_FILE"

# ---------------- 解析 server 命令 ----------------
if ! SERVER_METADATA=$(python3 "$PARSER_FILE" metadata "$SERVER_COMMAND" 2>&1); then
  die "server_command.sh 解析失败:$SERVER_METADATA"
fi
mapfile -t SERVER_META <<<"$SERVER_METADATA"
((${#SERVER_META[@]} == 4)) || die "服务命令解析器返回了异常结果"

MODEL_PATH=${SERVER_META[0]%/}
MODEL_NAME=${SERVER_META[1]}
TP_SIZE=${SERVER_META[2]}
PP_SIZE=${SERVER_META[3]}
REQUIRED_GPUS=$((TP_SIZE * PP_SIZE))
[[ -d "$MODEL_PATH" ]] || die "模型路径不存在:$MODEL_PATH"
log "模型:$MODEL_NAME($MODEL_PATH) 需要 GPU:$REQUIRED_GPUS 张(TP=$TP_SIZE, PP=$PP_SIZE)"

mkdir -p "$RESULT_ROOT" "$GPU_LOCK_DIR" "$PORT_LOCK_DIR"

# ---------------- 运行状态 ----------------
SELF_PGID=$(python3 -c 'import os; print(os.getpgrp())')
KEEP_SERVER=0
TIME_TAG=$(date +'%Y%m%d_%H%M%S')
RUN_DIR="${RESULT_ROOT}/start-${TIME_TAG}"
SERVER_LOG="${RUN_DIR}/server.log"
mkdir -p "$RUN_DIR"
START_SEC=$SECONDS

SERVER_PID=""
SERVER_PGID=""
SELECTED_GPUS=()
GPU_LOCK_FDS=()
PORT_LOCK_FD=""
PORT=""

STEP_RESULT=""    # OK | RETRYABLE | FATAL | TIMEOUT
FAIL_STAGE=""     # parse|acquire|reserve-port|launch|health|cleanup

# ---------------- 锁/GPU/端口 工具(语义沿用 auto_eval.sh) ----------------
query_free_ports() {
  python3 - "$HOST" "$START_PORT" "$END_PORT" <<'PY'
import socket
import sys
host = sys.argv[1]
start_port = int(sys.argv[2])
end_port = int(sys.argv[3])
for port in range(start_port, end_port + 1):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind((host, port))
    except OSError:
        continue
    else:
        print(port)
    finally:
        sock.close()
PY
}

release_port_lock() {
  if [[ -n "$PORT_LOCK_FD" ]]; then
    flock -u "$PORT_LOCK_FD" 2>/dev/null || true
    exec {PORT_LOCK_FD}>&- 2>/dev/null || true
    PORT_LOCK_FD=""
  fi
  PORT=""
}

select_and_lock_port() {
  local port lock_fd
  local -a free_ports=()
  release_port_lock
  mapfile -t free_ports < <(query_free_ports)
  for port in "${free_ports[@]}"; do
    exec {lock_fd}>"${PORT_LOCK_DIR}/port_${HOST//[^A-Za-z0-9_.-]/_}_${port}.lock"
    if flock -n "$lock_fd"; then
      PORT=$port
      PORT_LOCK_FD=$lock_fd
      return 0
    fi
    exec {lock_fd}>&-
  done
  return 1
}

query_free_gpus() {
  local smi_output
  if ! smi_output=$(rocm-smi 2>&1); then
    log "rocm-smi 执行失败:${smi_output}" >&2
    return 1
  fi
  printf '%s\n' "$smi_output" | awk \
    -v max_vram="$GPU_VRAM_MAX_PERCENT" \
    -v max_hcu="$GPU_HCU_MAX_PERCENT" '
      $1 ~ /^[0-9]+$/ {
        gpu=$1
        vram=$6
        hcu=$7
        gsub(/%/, "", vram)
        gsub(/%/, "", hcu)
        if ((vram + 0) < max_vram && (hcu + 0) <= max_hcu) {
          print gpu
        }
      }
    '
}

gpu_is_allowed() {
  local gpu=$1
  [[ -z "$GPU_ALLOWLIST" || ",$GPU_ALLOWLIST," == *",$gpu,"* ]]
}

release_gpu_locks() {
  local fd
  for fd in "${GPU_LOCK_FDS[@]:-}"; do
    [[ -n "$fd" ]] || continue
    flock -u "$fd" 2>/dev/null || true
    exec {fd}>&- 2>/dev/null || true
  done
  GPU_LOCK_FDS=()
  SELECTED_GPUS=()
}

select_and_lock_gpus() {
  local output gpu lock_fd
  local -a free_gpus=()
  release_gpu_locks
  if ! output=$(query_free_gpus); then
    return 1
  fi
  if [[ -n "$output" ]]; then
    mapfile -t free_gpus <<<"$output"
  fi
  if ((${#free_gpus[@]} < REQUIRED_GPUS)); then
    return 1
  fi
  for gpu in "${free_gpus[@]}"; do
    gpu_is_allowed "$gpu" || continue
    exec {lock_fd}>"${GPU_LOCK_DIR}/gpu_${gpu}.lock"
    if flock -n "$lock_fd"; then
      SELECTED_GPUS+=("$gpu")
      GPU_LOCK_FDS+=("$lock_fd")
    else
      exec {lock_fd}>&-
    fi
    if ((${#SELECTED_GPUS[@]} == REQUIRED_GPUS)); then
      return 0
    fi
  done
  release_gpu_locks
  return 1
}

selected_gpus_still_free() {
  local output gpu
  if ! output=$(query_free_gpus); then
    return 1
  fi
  for gpu in "${SELECTED_GPUS[@]}"; do
    if ! grep -qx -- "$gpu" <<<"$output"; then
      return 1
    fi
  done
}

get_process_group() {
  local pid=$1 pgid
  pgid=$(python3 - "$pid" 2>/dev/null <<'PY' || true
import os
import sys
print(os.getpgid(int(sys.argv[1])))
PY
  )
  printf '%s\n' "${pgid:-$pid}"
}

terminate_process_group() {
  local name=$1 pid=$2 pgid=$3
  local deadline target
  [[ -n "$pid" ]] || return 0
  if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" != "$SELF_PGID" ]]; then
    target="-$pgid"
  else
    target="$pid"
  fi
  if kill -0 -- "$target" 2>/dev/null; then
    log "停止${name}:PID=${pid},PGID=${pgid}"
    kill -TERM -- "$target" 2>/dev/null || true
    deadline=$((SECONDS + SHUTDOWN_TIMEOUT))
    while kill -0 -- "$target" 2>/dev/null && ((SECONDS < deadline)); do
      sleep 1
    done
    if kill -0 -- "$target" 2>/dev/null; then
      log "${name}未在 ${SHUTDOWN_TIMEOUT}s 内退出,发送 KILL"
      kill -KILL -- "$target" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup_current_attempt() {
  # OK 后资源交接给服务进程组(服务持有锁 fd);此处不再清理
  if ((KEEP_SERVER == 1)); then
    return 0
  fi
  terminate_process_group "SGLang Server" "$SERVER_PID" "$SERVER_PGID"
  SERVER_PID=""
  SERVER_PGID=""
  release_port_lock
  release_gpu_locks
}

on_signal() {
  local signal=$1 code=$2
  log "收到 ${signal},正在释放本轮资源"
  exit "$code"
}

trap cleanup_current_attempt EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

# ---------------- 结果输出 ----------------
write_json_file() {
  local file=$1
  shift
  python3 - "$file" "$@" <<'PY'
import json
import sys
file = sys.argv[1]
pairs = sys.argv[2:]
obj = {}
numeric_keys = {"pid", "pgid", "port", "elapsed_s"}
for i in range(0, len(pairs), 2):
    key = pairs[i]
    value = pairs[i + 1]
    if key in numeric_keys:
        try:
            value = int(value)
        except ValueError:
            pass
    obj[key] = value
with open(file, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY
}

emit_ok() {
  local elapsed=$((SECONDS - START_SEC))
  local gpus_csv selected_csv=""
  selected_csv=$(IFS=,; printf '%s' "${SELECTED_GPUS[*]}")
  write_json_file "$RUN_DIR/started.json" \
    result ok pid "$SERVER_PID" pgid "$SERVER_PGID" port "$PORT" \
    gpus_csv "$selected_csv" \
    health_url "http://${HEALTH_HOST}:${PORT}/health" \
    server_log "$SERVER_LOG" run_dir "$RUN_DIR" \
    model_name "$MODEL_NAME" model_path "$MODEL_PATH" \
    started_at "$(date -Is)" elapsed_s "$elapsed"
  log "SGLang 服务健康检查通过:http://${HEALTH_HOST}:${PORT}(pid=$SERVER_PID, pgid=$SERVER_PGID)"
  echo "[start-server] STEP_RESULT=OK pid=$SERVER_PID pgid=$SERVER_PGID port=$PORT gpus=$selected_csv server_log=$SERVER_LOG run_dir=$RUN_DIR"
}

emit_failure() {
  # $1=result $2=stage $3=error(单行)
  local result=$1 stage=$2 error=$3
  local gpus_csv=""
  ((${#SELECTED_GPUS[@]})) && gpus_csv=$(IFS=,; printf '%s' "${SELECTED_GPUS[*]}")
  write_json_file "$RUN_DIR/failed.json" \
    result "$result" stage "$stage" error "$error" \
    port "$PORT" gpus_csv "$gpus_csv" \
    server_log "$SERVER_LOG" run_dir "$RUN_DIR" \
    started_at "$(date -Is)"
  echo "[start-server] STEP_RESULT=${result} stage=${stage} error=${error} server_log=${SERVER_LOG}"
}

show_log_tail() {
  local path=$1
  [[ -f "$path" ]] || return 0
  log "服务日志最近 ${FAILURE_LOG_LINES} 行($path):"
  tail -n "$FAILURE_LOG_LINES" "$path" || true
}

# ---------------- 主流程 ----------------
# 阶段 acquire:等卡 + 锁卡(超时 -> TIMEOUT)
ACQUIRE_DEADLINE=0
if ((GPU_WAIT_TIMEOUT > 0)); then
  ACQUIRE_DEADLINE=$((SECONDS + GPU_WAIT_TIMEOUT))
fi
while true; do
  if select_and_lock_gpus; then
    if ((GPU_CONFIRM_SECONDS > 0)); then
      log "发现候选 GPU:${SELECTED_GPUS[*]},${GPU_CONFIRM_SECONDS}s 后再次确认"
      sleep "$GPU_CONFIRM_SECONDS"
    fi
    if selected_gpus_still_free; then
      break
    fi
    log "候选 GPU 状态发生变化,重新等待"
    release_gpu_locks
  else
    log "等待可用 GPU(需要 ${REQUIRED_GPUS} 张)..."
  fi
  if ((ACQUIRE_DEADLINE > 0 && SECONDS >= ACQUIRE_DEADLINE)); then
    log "等卡超时(GPU_WAIT_TIMEOUT=${GPU_WAIT_TIMEOUT}s)"
    show_log_tail "$SERVER_LOG"
    emit_failure TIMEOUT acquire "等卡超时:${GPU_WAIT_TIMEOUT}s 内无 ${REQUIRED_GPUS} 张空闲 GPU"
    exit 5
  fi
  sleep "$GPU_POLL_INTERVAL"
done

selected_csv=$(IFS=,; printf '%s' "${SELECTED_GPUS[*]}")
log "GPU 已锁定:${selected_csv}"

# 阶段 reserve-port
if ! select_and_lock_port; then
  log "没有找到可用端口(${START_PORT}-${END_PORT})"
  emit_failure RETRYABLE reserve-port "端口范围内无可用端口"
  exit 3
fi
log "端口:${PORT}"

# 阶段 launch
export PORT HOST MODEL_NAME HIP_VISIBLE_DEVICES="$selected_csv"
log "启动 SGLang Server(GPU=${selected_csv}, PORT=${PORT})..."
setsid python3 "$PARSER_FILE" run "$SERVER_COMMAND" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
SERVER_PGID=$(get_process_group "$SERVER_PID")
log "SGLang Server 已启动:PID=${SERVER_PID},PGID=${SERVER_PGID}"

# 阶段 health
HEALTH_DEADLINE=$((SECONDS + SERVER_START_TIMEOUT))
HEALTH_OK=0
while ((SECONDS < HEALTH_DEADLINE)); do
  if curl -fsS "http://${HEALTH_HOST}:${PORT}/health" >/dev/null 2>&1; then
    HEALTH_OK=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep "$HEALTH_CHECK_INTERVAL"
done

if ((HEALTH_OK == 1)); then
  KEEP_SERVER=1
  emit_ok
  exit 0
fi

if kill -0 "$SERVER_PID" 2>/dev/null; then
  # 进程仍存活但超时未健康
  log "SGLang Server 启动超过 ${SERVER_START_TIMEOUT}s(进程存活,未健康)"
  show_log_tail "$SERVER_LOG"
  emit_failure TIMEOUT health "服务在 ${SERVER_START_TIMEOUT}s 内未通过健康检查(进程仍存活)"
  exit 5
fi

# 进程已退出:启动失败
log "SGLang Server 启动失败(进程退出)"
show_log_tail "$SERVER_LOG"
emit_failure FATAL launch "SGLang Server 进程退出,详见日志"
exit 4
