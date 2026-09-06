#!/usr/bin/env bash
# ============================================================================
# run-profile.sh —— step: 对一台(已健康)服务采集 Torch Profiler trace(workload)
#
# 职责:给定 started.json(或 --server-root 下最新一份),用 lib/run_profile.py
#   (整份搬运:1 预热请求 -> /start_profile(num_steps=3, CPU+GPU) -> 1 follow-up
#   generate -> finally /stop_profile -> 轮询 trace 文件)采集短 trace。
#   本 step 不起服不停服、不碰 GPU/端口锁;起/停由上层负责。
#
# 结果码:
#   0  OK         trace 找到(exit 0)
#   2  输入/用法错误(started.json 缺失损坏、参数非法)
#   4  FAILED     采集失败(exit 1)/ 超时无 trace(no_trace, exit 2)/ 服务死(server_died)
#   5  TIMEOUT    整体超时 --timeout-s
#   (结果细类见 profile.json.result: ok|no_trace|failed|server_died|timeout)
#
# 用法:
#   bash run-profile.sh (--started-json PATH | --server-root DIR) [选项]
#   选项:
#     --started-json PATH     直接用这份 started.json
#     --server-root DIR       取 DIR/start-*/started.json 最新一份
#     --config PATH           可选 config.env(PROFILE_* / HEALTH_HOST 默认)
#     --input-len N           覆盖 PROFILE_INPUT_LEN(默认 4096)
#     --output-len N          覆盖 PROFILE_OUTPUT_LEN(默认 3)
#     --warmup-output-len N   覆盖 PROFILE_WARMUP_OUTPUT_LEN(默认 1)
#     --request-timeout N     覆盖 PROFILE_REQUEST_TIMEOUT(默认 600,单 HTTP 调用)
#     --trace-timeout N       覆盖 PROFILE_TRACE_TIMEOUT(默认 180,等 trace)
#     --profile-command PATH  覆盖受管副本(默认 ${AUTO_WORK}/lib/run_profile.py)
#     --result-root PATH      RUN_DIR 父目录(默认 ${RUNS_DIR:-/home/runs})
#     --timeout-s N           整体超时(秒;0=不限,默认不限)
#     -h, --help
#
# 环境:依赖 python3 curl setsid;config/环境可设 HEALTH_HOST/SHUTDOWN_TIMEOUT。
# 已知坑:shell 侧 export SGLANG_TORCH_PROFILER_DIR=RUN_DIR,payload output_dir=
#   RUN_DIR/profile 不一致 -> trace 可能落在任一处;本 step 两处都轮询并如实记录。
# 产物:${RESULT_ROOT}/profile-<ts>/ { profile.log, profile/, profile.json }
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/run_common.sh"

# ---------------- 参数解析 ----------------
STARTED_JSON=""
SERVER_ROOT=""
CONFIG_FILE=""
INPUT_LEN=""
OUTPUT_LEN=""
WARMUP_OUTPUT_LEN=""
REQUEST_TIMEOUT=""
TRACE_TIMEOUT=""
PROFILE_SCRIPT=""
RESULT_ROOT=""
TIMEOUT_S=""

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//' >&2
}

while (($#)); do
  case "$1" in
    --started-json)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--started-json 需要路径" >&2; exit 2; }
      STARTED_JSON=$2; shift 2 ;;
    --server-root)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--server-root 需要目录" >&2; exit 2; }
      SERVER_ROOT=$2; shift 2 ;;
    --config)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--config 需要路径" >&2; exit 2; }
      CONFIG_FILE=$2; shift 2 ;;
    --input-len)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--input-len 需要正整数" >&2; exit 2; }
      INPUT_LEN=$2; shift 2 ;;
    --output-len)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--output-len 需要正整数" >&2; exit 2; }
      OUTPUT_LEN=$2; shift 2 ;;
    --warmup-output-len)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--warmup-output-len 需要正整数" >&2; exit 2; }
      WARMUP_OUTPUT_LEN=$2; shift 2 ;;
    --request-timeout)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--request-timeout 需要正整数" >&2; exit 2; }
      REQUEST_TIMEOUT=$2; shift 2 ;;
    --trace-timeout)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--trace-timeout 需要正整数" >&2; exit 2; }
      TRACE_TIMEOUT=$2; shift 2 ;;
    --profile-command)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--profile-command 需要路径" >&2; exit 2; }
      PROFILE_SCRIPT=$2; shift 2 ;;
    --result-root)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--result-root 需要路径" >&2; exit 2; }
      RESULT_ROOT=$2; shift 2 ;;
    --timeout-s)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--timeout-s 需要秒数" >&2; exit 2; }
      TIMEOUT_S=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误:未知参数:$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || { echo "错误:配置文件不存在:$CONFIG_FILE" >&2; exit 2; }
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# ---------------- 定位 started.json ----------------
if [[ -z "$STARTED_JSON" && -n "$SERVER_ROOT" ]]; then
  STARTED_JSON=$(locate_started_json "$SERVER_ROOT") || \
    { echo "错误:--server-root 下没有找到 start-*/started.json:$SERVER_ROOT" >&2; exit 2; }
fi
[[ -n "$STARTED_JSON" ]] || { echo "错误:必须提供 --started-json 或 --server-root" >&2; exit 2; }
[[ -f "$STARTED_JSON" ]] || { echo "错误:started.json 不存在:$STARTED_JSON" >&2; exit 2; }

read_started_json "$STARTED_JSON"
[[ "$STARTED_PORT" =~ ^[0-9]+$ ]] || die "started.json 缺少合法 port"
[[ -n "$STARTED_HEALTH_URL" ]] || die "started.json 缺少 health_url"

# ---------------- 默认值与校验 ----------------
: "${HEALTH_HOST:=127.0.0.1}"
: "${SHUTDOWN_TIMEOUT:=15}"
: "${RESULT_ROOT:=${RUNS_DIR:-/home/runs}}"
: "${PROFILE_INPUT_LEN:=4096}"
: "${PROFILE_OUTPUT_LEN:=3}"
: "${PROFILE_WARMUP_OUTPUT_LEN:=1}"
: "${PROFILE_REQUEST_TIMEOUT:=600}"
: "${PROFILE_TRACE_TIMEOUT:=180}"

INPUT_LEN=${INPUT_LEN:-$PROFILE_INPUT_LEN}
OUTPUT_LEN=${OUTPUT_LEN:-$PROFILE_OUTPUT_LEN}
WARMUP_OUTPUT_LEN=${WARMUP_OUTPUT_LEN:-$PROFILE_WARMUP_OUTPUT_LEN}
REQUEST_TIMEOUT=${REQUEST_TIMEOUT:-$PROFILE_REQUEST_TIMEOUT}
TRACE_TIMEOUT=${TRACE_TIMEOUT:-$PROFILE_TRACE_TIMEOUT}

for v in INPUT_LEN OUTPUT_LEN WARMUP_OUTPUT_LEN REQUEST_TIMEOUT TRACE_TIMEOUT; do
  is_positive_integer "${!v}" || die "$v 必须是正整数"
done

PROFILE_SCRIPT=${PROFILE_SCRIPT:-${PROFILE_COMMAND:-"$SCRIPT_DIR/../lib/run_profile.py"}}
[[ -f "$PROFILE_SCRIPT" ]] || die "找不到 run_profile.py:$PROFILE_SCRIPT"

if [[ -n "$TIMEOUT_S" ]]; then
  is_nonnegative_integer "$TIMEOUT_S" || die "--timeout-s 必须是非负整数"
fi
for cmd in python3 curl setsid; do
  command -v "$cmd" >/dev/null 2>&1 || die "找不到命令:$cmd"
done

# ---------------- 本轮目录 ----------------
TIME_TAG=$(date +'%Y%m%d_%H%M%S')
RUN_DIR="${RESULT_ROOT%/}/profile-${TIME_TAG}"
mkdir -p "$RUN_DIR"
PROFILE_LOG="${RUN_DIR}/profile.log"
cp "$PROFILE_SCRIPT" "$RUN_DIR/run_profile.py"
START_SEC=$SECONDS
OVERALL_DEADLINE=0
if [[ -n "$TIMEOUT_S" && "$TIMEOUT_S" -gt 0 ]]; then
  OVERALL_DEADLINE=$((SECONDS + TIMEOUT_S))
fi

log "本轮目录:$RUN_DIR"
log "profile:input=${INPUT_LEN} output=${OUTPUT_LEN} warmup_output=${WARMUP_OUTPUT_LEN} trace_timeout=${TRACE_TIMEOUT}s"

# 服务先行健康确认
RESULT=""
STAGE=""
LEGACY_EXIT=""
if ! health_ok "$STARTED_HEALTH_URL"; then
  RESULT=server_died
  STAGE=precheck
  log "服务不可达(${STARTED_HEALTH_URL}),直接判定 server_died"
fi

# ---------------- 执行采集 ----------------
if [[ -z "$RESULT" ]]; then
  export SGLANG_TORCH_PROFILER_DIR="$RUN_DIR"
  URL="http://${HEALTH_HOST}:${STARTED_PORT}"
  log "启动 Torch Profiler 采集(run_profile.py,url=${URL})..."
  setsid python3 "$PROFILE_SCRIPT" \
    --url "$URL" \
    --output-dir "$RUN_DIR/profile" \
    --input-len "$INPUT_LEN" \
    --output-len "$OUTPUT_LEN" \
    --warmup-output-len "$WARMUP_OUTPUT_LEN" \
    --request-timeout "$REQUEST_TIMEOUT" \
    --trace-timeout "$TRACE_TIMEOUT" \
    >"$PROFILE_LOG" 2>&1 &
  WORK_PID=$!
  WORK_PGID=$(get_process_group "$WORK_PID")

  while :; do
    if ! kill -0 "$WORK_PID" 2>/dev/null; then
      if wait "$WORK_PID"; then
        WORK_EXIT=0
      else
        WORK_EXIT=$?
      fi
      LEGACY_EXIT=$WORK_EXIT
      if ((WORK_EXIT == 0)); then
        RESULT=ok
        STAGE=done
      elif ((WORK_EXIT == 2)); then
        RESULT=no_trace
        STAGE=trace_timeout
        log "未在 ${TRACE_TIMEOUT}s 内找到 trace 文件(exit 2),详见 $PROFILE_LOG"
      else
        RESULT=failed
        STAGE=profile
        log "run_profile.py 失败,退出状态=${WORK_EXIT},详见 $PROFILE_LOG"
      fi
      break
    fi
    if ((OVERALL_DEADLINE > 0 && SECONDS >= OVERALL_DEADLINE)); then
      RESULT=timeout
      STAGE=timeout
      log "采集超过整体超时(${TIMEOUT_S}s),终止 workload"
      break
    fi
    if ! health_ok "$STARTED_HEALTH_URL"; then
      RESULT=server_died
      STAGE=watchdog
      log "采集期间服务不可达(${STARTED_HEALTH_URL}),终止 workload"
      break
    fi
    sleep 2
  done

  if [[ "$RESULT" == timeout || "$RESULT" == server_died ]]; then
    terminate_process_group "profile workload" "$WORK_PID" "$WORK_PGID" "$SHUTDOWN_TIMEOUT"
  fi
fi

# ---------------- 定位 trace 实际落点(两处都找:已知 env/payload 目录不一致坑) ----------------
TRACE_FILES_JSON="[]"
# shellcheck disable=SC2016
mapfile -t TRACE_FILES < <(
  find "$RUN_DIR" -maxdepth 3 -type f \( -name '*.trace.json.gz' -o -name '*.trace.json' -o -name '*.json' \) \
    ! -name 'server_args.json' -size +0c 2>/dev/null | sort
)
if ((${#TRACE_FILES[@]} > 0)); then
  TRACE_FILES_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${TRACE_FILES[@]}")
fi

# ---------------- 结果 ----------------
elapsed=$((SECONDS - START_SEC))
write_json_file "$RUN_DIR/profile.json" \
  result "$RESULT" stage "${STAGE:-}" legacy_exit "${LEGACY_EXIT:-}" \
  input_len "$INPUT_LEN" output_len "$OUTPUT_LEN" warmup_output_len "$WARMUP_OUTPUT_LEN" \
  request_timeout "$REQUEST_TIMEOUT" trace_timeout "$TRACE_TIMEOUT" \
  model_name "${STARTED_MODEL_NAME:-}" \
  traces_json "$TRACE_FILES_JSON" \
  profile_log "$PROFILE_LOG" profile_command "$PROFILE_SCRIPT" \
  started_json "$STARTED_JSON" server_log "${STARTED_SERVER_LOG:-}" \
  run_dir "$RUN_DIR" elapsed_s "$elapsed"

# traces_json(字符串)-> traces(真正 JSON 数组)
python3 - "$RUN_DIR/profile.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    obj = json.load(f)
obj["traces"] = json.loads(obj.pop("traces_json", "[]"))
with open(path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY

case "$RESULT" in
  ok)
    echo "[run-profile] STEP_RESULT=ok traces=${#TRACE_FILES[@]} profile_log=$PROFILE_LOG profile_json=$RUN_DIR/profile.json"
    exit 0 ;;
  failed|no_trace|server_died)
    echo "[run-profile] STEP_RESULT=${RESULT} stage=${STAGE} legacy_exit=${LEGACY_EXIT:-} profile_log=$PROFILE_LOG profile_json=$RUN_DIR/profile.json"
    exit 4 ;;
  timeout)
    echo "[run-profile] STEP_RESULT=timeout stage=timeout profile_log=$PROFILE_LOG profile_json=$RUN_DIR/profile.json"
    exit 5 ;;
  *) die "内部错误:未知 RESULT=$RESULT" ;;
esac
