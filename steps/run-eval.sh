#!/usr/bin/env bash
# ============================================================================
# run-eval.sh —— step: 对一台(已健康)服务执行 EvalScope 评测(单一职责,workload)
#
# 职责:给定 started.json(或 --server-root 下最新一份),用 lib/eval_command.sh
#   (测试部门权威副本,整份照搬)跑一轮 EvalScope;进程退出码 + 服务健康看门狗
#   决定结果,写 eval.json。本 step 不起服不停服、不碰 GPU/端口锁;
#   起/停由上层(start-server / release-server / skill)负责。
#
# 结果码:
#   0  OK         评测完成(workload 退出码 0)
#   2  输入/用法错误(started.json 缺失损坏、模型目录缺失、参数非法)
#   4  FAILED     评测失败(workload 非 0)或服务已死/中途死亡(server_died)
#   5  TIMEOUT    整体超时 --timeout-s
#   (结果细类见 eval.json.result: ok|failed|server_died|timeout)
#
# 用法:
#   bash run-eval.sh (--started-json PATH | --server-root DIR) [选项]
#   选项:
#     --started-json PATH   直接用这份 started.json(模式 B 附着)
#     --server-root DIR     (与 --started-json 互斥)取 DIR/start-*/started.json 最新一份
#     --config PATH         可选 config.env(提供 EVAL_* / HOST 等默认)
#     --datasets CSV        覆盖 EVAL_DATASETS(逗号分隔,如 humaneval,math_500)
#     --batch N             覆盖 EVAL_BATCH(默认 64)
#     --limit VAL           覆盖 EVAL_LIMIT(None/空=全部;int=前N条;float=前N%)
#     --thinking true|false 覆盖 EVAL_ENABLE_THINKING(默认 false)
#     --eval-command PATH   覆盖受管副本位置(默认 ${AUTO_WORK}/lib/eval_command.sh)
#     --model-dir PATH      当 started.json 缺 model_path 时兜底(本地模型目录)
#     --result-root PATH    RUN_DIR 父目录(默认 ${RUNS_DIR:-/home/runs})
#     --timeout-s N         整体超时(秒;0=不限,默认不限)
#     -h, --help
#
# 环境:依赖 python3 curl setsid;config/环境可设 HOST/HEALTH_HOST/SHUTDOWN_TIMEOUT。
# 产物:${RESULT_ROOT}/eval-<ts>/  { eval.log, eval.json, eval_command.sh(拷贝留痕) }
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/run_common.sh"

# ---------------- 参数解析 ----------------
STARTED_JSON=""
SERVER_ROOT=""
CONFIG_FILE=""
DATASETS_CSV=""
BATCH=""
LIMIT=""
THINKING=""
EVAL_COMMAND_SCRIPT=""
MODEL_DIR_OVERRIDE=""
RESULT_ROOT=""
TIMEOUT_S=""

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//' >&2
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
    --datasets)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--datasets 需要 CSV" >&2; exit 2; }
      DATASETS_CSV=$2; shift 2 ;;
    --batch)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--batch 需要数字" >&2; exit 2; }
      BATCH=$2; shift 2 ;;
    --limit)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--limit 需要值" >&2; exit 2; }
      LIMIT=$2; shift 2 ;;
    --thinking)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--thinking 需要 true|false" >&2; exit 2; }
      THINKING=$2; shift 2 ;;
    --eval-command)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--eval-command 需要路径" >&2; exit 2; }
      EVAL_COMMAND_SCRIPT=$2; shift 2 ;;
    --model-dir)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--model-dir 需要路径" >&2; exit 2; }
      MODEL_DIR_OVERRIDE=$2; shift 2 ;;
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
: "${HOST:=127.0.0.1}"
: "${HEALTH_HOST:=127.0.0.1}"
: "${SHUTDOWN_TIMEOUT:=15}"
: "${RESULT_ROOT:=${RUNS_DIR:-/home/runs}}"
: "${EVAL_ENABLE_THINKING:=false}"
: "${EVAL_BATCH:=64}"
: "${EVAL_LIMIT:=None}"
: "${EVAL_DATASETS:=humaneval,math_500,gsm8k}"   # 默认三集;用户点名则只测点名集

THINKING=${THINKING:-$EVAL_ENABLE_THINKING}
case "$THINKING" in
  true|TRUE|True|false|FALSE|False) ;;
  *) die "--thinking 必须是 true|false(当前:$THINKING)" ;;
esac
BATCH=${BATCH:-$EVAL_BATCH}
is_positive_integer "$BATCH" || die "EVAL_BATCH 必须是正整数(当前:$BATCH)"
LIMIT=${LIMIT:-$EVAL_LIMIT}
DATASETS_CSV=${DATASETS_CSV:-$EVAL_DATASETS}

MODEL_DIR=${MODEL_DIR_OVERRIDE:-$STARTED_MODEL_PATH}
MODEL_DIR=${MODEL_DIR:-${MODEL_PATH:-}}
[[ -n "$MODEL_DIR" ]] || die "缺少模型目录:started.json.model_path 为空且未给 --model-dir/MODEL_PATH"
MODEL_DIR=${MODEL_DIR%/}
[[ -d "$MODEL_DIR" ]] || die "模型目录不存在:$MODEL_DIR"

EVAL_COMMAND_SCRIPT=${EVAL_COMMAND_SCRIPT:-${EVAL_COMMAND:-"$SCRIPT_DIR/../lib/eval_command.sh"}}
[[ -f "$EVAL_COMMAND_SCRIPT" ]] || die "找不到 eval_command.sh:$EVAL_COMMAND_SCRIPT"

if [[ -n "$TIMEOUT_S" ]]; then
  is_nonnegative_integer "$TIMEOUT_S" || die "--timeout-s 必须是非负整数"
fi
for cmd in python3 curl setsid; do
  command -v "$cmd" >/dev/null 2>&1 || die "找不到命令:$cmd"
done

# ---------------- 本轮目录 ----------------
TIME_TAG=$(date +'%Y%m%d_%H%M%S')
RUN_DIR="${RESULT_ROOT%/}/eval-${TIME_TAG}"
mkdir -p "$RUN_DIR"
EVAL_LOG="${RUN_DIR}/eval.log"
cp "$EVAL_COMMAND_SCRIPT" "$RUN_DIR/eval_command.sh"
START_SEC=$SECONDS
OVERALL_DEADLINE=0
if [[ -n "$TIMEOUT_S" && "$TIMEOUT_S" -gt 0 ]]; then
  OVERALL_DEADLINE=$((SECONDS + TIMEOUT_S))
fi

log "本轮目录:$RUN_DIR"
log "评测:datasets=${DATASETS_CSV} batch=${BATCH} limit=${LIMIT} thinking=${THINKING} model=${MODEL_DIR}"

# 服务先行健康确认(附着模式:外部服务可能已不在)
RESULT=""
STAGE=""
LEGACY_EXIT=""
if ! health_ok "$STARTED_HEALTH_URL"; then
  RESULT=server_died
  STAGE=precheck
  log "服务不可达(${STARTED_HEALTH_URL}),直接判定 server_died"
fi

# ---------------- 执行评测 ----------------
if [[ -z "$RESULT" ]]; then
  export MODEL_PATH="$MODEL_DIR"
  export MODEL_NAME="${STARTED_MODEL_NAME:-}"
  export HOST HEALTH_HOST PORT="$STARTED_PORT"
  export RUN_DIR EVAL_LOG
  export EVAL_ENABLE_THINKING="$THINKING"
  export EVAL_DATASETS="$DATASETS_CSV"
  export EVAL_BATCH="$BATCH"
  export EVAL_LIMIT="$LIMIT"
  log "启动 EvalScope(eval_command.sh)..."
  setsid bash "$EVAL_COMMAND_SCRIPT" >"$EVAL_LOG" 2>&1 &
  WORK_PID=$!
  WORK_PGID=$(get_process_group "$WORK_PID")

  while :; do
    if ! kill -0 "$WORK_PID" 2>/dev/null; then
      if wait "$WORK_PID"; then
        WORK_EXIT=0
      else
        WORK_EXIT=$?
      fi
      if ((WORK_EXIT == 0)); then
        RESULT=ok
        STAGE=done
      else
        RESULT=failed
        STAGE=eval
        LEGACY_EXIT=$WORK_EXIT
        log "EvalScope 评测失败,退出状态=${WORK_EXIT},详见 $EVAL_LOG"
      fi
      break
    fi
    if ((OVERALL_DEADLINE > 0 && SECONDS >= OVERALL_DEADLINE)); then
      RESULT=timeout
      STAGE=timeout
      log "评测超过整体超时(${TIMEOUT_S}s),终止 workload"
      break
    fi
    if ! health_ok "$STARTED_HEALTH_URL"; then
      RESULT=server_died
      STAGE=watchdog
      log "评测期间服务不可达(${STARTED_HEALTH_URL}),终止 workload"
      break
    fi
    sleep 2
  done

  if [[ "$RESULT" == timeout || "$RESULT" == server_died ]]; then
    terminate_process_group "EvalScope workload" "$WORK_PID" "$WORK_PGID" "$SHUTDOWN_TIMEOUT"
  fi
fi

# ---------------- 结果 ----------------
elapsed=$((SECONDS - START_SEC))
write_json_file "$RUN_DIR/eval.json" \
  result "$RESULT" stage "${STAGE:-}" legacy_exit "${LEGACY_EXIT:-}" \
  datasets "$DATASETS_CSV" batch "$BATCH" limit "$LIMIT" thinking "$THINKING" \
  model_name "${STARTED_MODEL_NAME:-}" model_path "$MODEL_DIR" \
  eval_log "$EVAL_LOG" eval_command "$EVAL_COMMAND_SCRIPT" \
  started_json "$STARTED_JSON" server_log "${STARTED_SERVER_LOG:-}" \
  run_dir "$RUN_DIR" elapsed_s "$elapsed"

case "$RESULT" in
  ok)
    echo "[run-eval] STEP_RESULT=ok datasets=${DATASETS_CSV} eval_log=$EVAL_LOG eval_json=$RUN_DIR/eval.json"
    exit 0 ;;
  failed|server_died)
    echo "[run-eval] STEP_RESULT=${RESULT} stage=${STAGE} legacy_exit=${LEGACY_EXIT:-} eval_log=$EVAL_LOG eval_json=$RUN_DIR/eval.json"
    exit 4 ;;
  timeout)
    echo "[run-eval] STEP_RESULT=timeout stage=timeout eval_log=$EVAL_LOG eval_json=$RUN_DIR/eval.json"
    exit 5 ;;
  *) die "内部错误:未知 RESULT=$RESULT" ;;
esac
