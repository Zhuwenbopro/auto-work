#!/usr/bin/env bash
# ============================================================================
# run-bench.sh —— step: 对一台(已健康)服务执行 bench_serving 压测网格(workload)
#
# 职责:给定 started.json(或 --server-root 下最新一份),用 lib/bench_serving.sh
#   (测试部门权威客户端,整份照搬)按 长度对 × 并发 网格跑压测,产出
#   all.csv + 每组合 .log/.jsonl,并把 all.csv 解析为 bench.json 的 rows。
#   本 step 不起服不停服、不碰 GPU/端口锁;起/停由上层负责。
#
# 结果码:
#   0  OK         网格全部完成(bench_serving.sh 退出 0)
#   2  输入/用法错误(started.json 缺失损坏、模型目录缺失、参数非法)
#   4  FAILED     压测失败(客户端非 0)或服务已死/中途死亡(server_died)
#   5  TIMEOUT    整体超时 --timeout-s
#   (结果细类见 bench.json.result: ok|failed|server_died|timeout)
#
# 用法:
#   bash run-bench.sh (--started-json PATH | --server-root DIR) [选项]
#   选项:
#     --started-json PATH     直接用这份 started.json(模式 B 附着)
#     --server-root DIR       取 DIR/start-*/started.json 最新一份
#     --config PATH           可选 config.env(BENCH_* / HOST 默认)
#     --pairs CSV             覆盖 BENCH_PAIRS("in out" 逗号分隔,如 "4096 1024,8192 1024")
#     --concurrencies CSV     覆盖 BENCH_CONCURRENCIES(如 1,2,4,8)
#     --multiplier N          覆盖 CONCURRENCY_MULTIPLIER(每档请求数=并发×倍数,默认 1)
#     --bench-command PATH    覆盖受管副本(默认 ${AUTO_WORK}/lib/bench_serving.sh)
#     --model-dir PATH        started.json 缺 model_path 时兜底(--tokenizer 用本地目录)
#     --result-root PATH      RUN_DIR 父目录(默认 ${RUNS_DIR:-./bench_runs})
#     --timeout-s N           整体超时(秒;0=不限,默认不限)
#     -h, --help
#
# 环境:依赖 python3 curl setsid;config/环境可设 HOST/SHUTDOWN_TIMEOUT。
# 产物:${RESULT_ROOT}/bench-<ts>/ { bench.log, all.csv,
#        <model>-<batch>-in<in>-out<out>.{log,jsonl}, bench.json }
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/run_common.sh"

# ---------------- 参数解析 ----------------
STARTED_JSON=""
SERVER_ROOT=""
CONFIG_FILE=""
PAIRS_CSV=""
CONCURRENCIES_CSV=""
MULTIPLIER=""
BENCH_COMMAND_SCRIPT=""
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
    --pairs)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--pairs 需要 CSV" >&2; exit 2; }
      PAIRS_CSV=$2; shift 2 ;;
    --concurrencies)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--concurrencies 需要 CSV" >&2; exit 2; }
      CONCURRENCIES_CSV=$2; shift 2 ;;
    --multiplier)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--multiplier 需要正整数" >&2; exit 2; }
      MULTIPLIER=$2; shift 2 ;;
    --bench-command)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "错误:--bench-command 需要路径" >&2; exit 2; }
      BENCH_COMMAND_SCRIPT=$2; shift 2 ;;
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
: "${SHUTDOWN_TIMEOUT:=15}"
: "${RESULT_ROOT:=${RUNS_DIR:-./bench_runs}}"
: "${BENCH_PAIRS:=4096 1024}"
: "${BENCH_CONCURRENCIES:=1,2,4,8,16,32,64,128}"
: "${CONCURRENCY_MULTIPLIER:=1}"

PAIRS_CSV=${PAIRS_CSV:-$BENCH_PAIRS}
CONCURRENCIES_CSV=${CONCURRENCIES_CSV:-$BENCH_CONCURRENCIES}
MULTIPLIER=${MULTIPLIER:-$CONCURRENCY_MULTIPLIER}
is_positive_integer "$MULTIPLIER" || die "CONCURRENCY_MULTIPLIER 必须是正整数(当前:$MULTIPLIER)"

MODEL_DIR=${MODEL_DIR_OVERRIDE:-$STARTED_MODEL_PATH}
MODEL_DIR=${MODEL_DIR:-${MODEL_PATH:-}}
[[ -n "$MODEL_DIR" ]] || die "缺少模型目录:started.json.model_path 为空且未给 --model-dir/MODEL_PATH(--tokenizer 必须是本地目录)"
MODEL_DIR=${MODEL_DIR%/}
[[ -d "$MODEL_DIR" ]] || die "模型目录不存在:$MODEL_DIR"
MODEL_NAME=${STARTED_MODEL_NAME:-$(basename "$MODEL_DIR")}

BENCH_COMMAND_SCRIPT=${BENCH_COMMAND_SCRIPT:-${BENCH_COMMAND:-"$SCRIPT_DIR/../lib/bench_serving.sh"}}
[[ -f "$BENCH_COMMAND_SCRIPT" ]] || die "找不到 bench_serving.sh:$BENCH_COMMAND_SCRIPT"

if [[ -n "$TIMEOUT_S" ]]; then
  is_nonnegative_integer "$TIMEOUT_S" || die "--timeout-s 必须是非负整数"
fi
for cmd in python3 curl setsid; do
  command -v "$cmd" >/dev/null 2>&1 || die "找不到命令:$cmd"
done

# ---------------- 本轮目录 ----------------
TIME_TAG=$(date +'%Y%m%d_%H%M%S')
RUN_DIR="${RESULT_ROOT%/}/bench-${TIME_TAG}"
mkdir -p "$RUN_DIR"
BENCH_LOG="${RUN_DIR}/bench.log"
cp "$BENCH_COMMAND_SCRIPT" "$RUN_DIR/bench_serving.sh"
START_SEC=$SECONDS
OVERALL_DEADLINE=0
if [[ -n "$TIMEOUT_S" && "$TIMEOUT_S" -gt 0 ]]; then
  OVERALL_DEADLINE=$((SECONDS + TIMEOUT_S))
fi

log "本轮目录:$RUN_DIR"
log "压测:pairs='${PAIRS_CSV}' concurrencies='${CONCURRENCIES_CSV}' multiplier=${MULTIPLIER} model=${MODEL_DIR}"

# 服务先行健康确认
RESULT=""
STAGE=""
LEGACY_EXIT=""
if ! health_ok "$STARTED_HEALTH_URL"; then
  RESULT=server_died
  STAGE=precheck
  log "服务不可达(${STARTED_HEALTH_URL}),直接判定 server_died"
fi

# ---------------- 执行压测 ----------------
if [[ -z "$RESULT" ]]; then
  export MODEL_NAME HOST PORT="$STARTED_PORT" RUN_DIR
  export MODEL_PATH="$MODEL_DIR"
  export BENCH_PAIRS="$PAIRS_CSV"
  export BENCH_CONCURRENCIES="$CONCURRENCIES_CSV"
  export CONCURRENCY_MULTIPLIER="$MULTIPLIER"
  log "启动 bench_serving 网格(bench_serving.sh)..."
  setsid bash "$BENCH_COMMAND_SCRIPT" >"$BENCH_LOG" 2>&1 &
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
        STAGE=bench
        LEGACY_EXIT=$WORK_EXIT
        log "bench_serving 失败,退出状态=${WORK_EXIT},详见 $BENCH_LOG"
      fi
      break
    fi
    if ((OVERALL_DEADLINE > 0 && SECONDS >= OVERALL_DEADLINE)); then
      RESULT=timeout
      STAGE=timeout
      log "压测超过整体超时(${TIMEOUT_S}s),终止 workload"
      break
    fi
    if ! health_ok "$STARTED_HEALTH_URL"; then
      RESULT=server_died
      STAGE=watchdog
      log "压测期间服务不可达(${STARTED_HEALTH_URL}),终止 workload"
      break
    fi
    sleep 2
  done

  if [[ "$RESULT" == timeout || "$RESULT" == server_died ]]; then
    terminate_process_group "bench workload" "$WORK_PID" "$WORK_PGID" "$SHUTDOWN_TIMEOUT"
  fi
fi

# ---------------- all.csv -> rows(确定性解析,不管成功与否都记录已跑部分) ----------------
ALL_CSV="${RUN_DIR}/all.csv"
ROWS_JSON="[]"
COMPLETED_CELLS=0
if [[ -f "$ALL_CSV" ]]; then
  COMPLETED_CELLS=$(($(wc -l <"$ALL_CSV") - 1))
  ((COMPLETED_CELLS < 0)) && COMPLETED_CELLS=0
  ROWS_JSON=$(python3 - "$ALL_CSV" <<'PY'
import csv
import json
import sys
path = sys.argv[1]
rows = []
with open(path, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for rec in reader:
        row = {}
        for k, v in rec.items():
            row[k] = v
        rows.append(row)
print(json.dumps(rows, ensure_ascii=False))
PY
  )
fi

# 期望格数 = pairs × concurrencies(仅作汇报;ok 判定仍以客户端退出码为准)
EXPECTED_CELLS=0
IFS=',' read -r -a _pairs <<<"$PAIRS_CSV"
IFS=',' read -r -a _concs <<<"$CONCURRENCIES_CSV"
EXPECTED_CELLS=$((${#_pairs[@]} * ${#_concs[@]}))

# ---------------- 结果 ----------------
elapsed=$((SECONDS - START_SEC))
write_json_file "$RUN_DIR/bench.json" \
  result "$RESULT" stage "${STAGE:-}" legacy_exit "${LEGACY_EXIT:-}" \
  pairs "$PAIRS_CSV" concurrencies "$CONCURRENCIES_CSV" \
  multiplier "$MULTIPLIER" expected_cells "$EXPECTED_CELLS" \
  completed_cells "$COMPLETED_CELLS" \
  model_name "$MODEL_NAME" model_path "$MODEL_DIR" \
  all_csv "$ALL_CSV" rows_json "$ROWS_JSON" \
  bench_log "$BENCH_LOG" bench_command "$BENCH_COMMAND_SCRIPT" \
  started_json "$STARTED_JSON" server_log "${STARTED_SERVER_LOG:-}" \
  run_dir "$RUN_DIR" elapsed_s "$elapsed"

# rows_json(字符串)-> rows(真正 JSON 数组),方便 skill 直接读
python3 - "$RUN_DIR/bench.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    obj = json.load(f)
obj["rows"] = json.loads(obj.pop("rows_json", "[]"))
with open(path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY

case "$RESULT" in
  ok)
    echo "[run-bench] STEP_RESULT=ok cells=${COMPLETED_CELLS}/${EXPECTED_CELLS} all_csv=$ALL_CSV bench_json=$RUN_DIR/bench.json"
    exit 0 ;;
  failed|server_died)
    echo "[run-bench] STEP_RESULT=${RESULT} stage=${STAGE} legacy_exit=${LEGACY_EXIT:-} cells=${COMPLETED_CELLS}/${EXPECTED_CELLS} bench_log=$BENCH_LOG bench_json=$RUN_DIR/bench.json"
    exit 4 ;;
  timeout)
    echo "[run-bench] STEP_RESULT=timeout stage=timeout cells=${COMPLETED_CELLS}/${EXPECTED_CELLS} bench_log=$BENCH_LOG bench_json=$RUN_DIR/bench.json"
    exit 5 ;;
  *) die "内部错误:未知 RESULT=$RESULT" ;;
esac
