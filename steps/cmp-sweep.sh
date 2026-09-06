#!/usr/bin/env bash
# ============================================================================
# cmp-sweep.sh —— step: 单一变量对比的串行扫描驱动(cmp-eval / cmp-bench 共用)
#
# 职责:给定基线命令 + variants spec(或现成 variant 目录),为每个变体:
#   start-server → run-eval / run-bench → release-server,逐一执行、失败隔离,
#   产 cmp.json(装配层:每变体 ok/失败 + 各产物路径 + 参数),不做分数解读。
# 纪律:同一 workload 参数作用于所有变体(保证可比);仅用户声明的变量不同;
#   任一变体命令 parser 校验失败 → 整体不启动(不浪费 GPU 做部分实验)。
#
# 结果码:
#   0  全部变体 ok
#   2  输入/用法错误(含任一变体校验失败,未启动任何服务)
#   4  部分变体失败(cmp.json 已写,含每变体状态)
#
# 用法:
#   bash cmp-sweep.sh --mode eval|bench (--baseline-command F --spec F | --variant-dir D) [选项]
#   选项:
#     --mode eval|bench          必填:跑 run-eval 还是 run-bench
#     --baseline-command PATH    --spec 模式:基线命令文件(被生成器读取)
#     --spec PATH                变体 spec JSON(见 lib/make_variants.py 头注释)
#     --variant-dir DIR          直接使用现成变体目录(每子目录含 server_command.sh)
#     --result-root PATH         本轮根父目录(默认 ${RUNS_DIR:-./cmp_runs})
#     --parallel N               预留:v1 仅支持 1(串行),>1 报错
#     --max-variants N           可选护栏:变体数上限
#     --timeout-s N              透传给每个 run-* 的整体超时(秒)
#     --datasets CSV             透传 run-eval(eval 模式)
#     --limit VAL                透传 run-eval
#     --batch N                  透传 run-eval
#     --thinking true|false      透传 run-eval
#     --pairs CSV                透传 run-bench(bench 模式)
#     --concurrencies CSV        透传 run-bench
#     --multiplier N             透传 run-bench
#     -h, --help
#
# 产物:${RESULT_ROOT}/cmp-<mode>-<ts>/
#   variants/<label>/{server_command.sh, spec.json, start-*/…, <mode>-*/…, variant.json}
#   cmp.json
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/run_common.sh"

MODE=""
BASELINE=""
SPEC=""
VARIANT_DIR=""
RESULT_ROOT=""
PARALLEL=""
MAX_VARIANTS=""
TIMEOUT_S=""
DATASETS=""
LIMIT=""
BATCH=""
THINKING=""
PAIRS=""
CONCURRENCIES=""
MULTIPLIER=""

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' >&2
}

while (($#)); do
  case "$1" in
    --mode) MODE=$2; shift 2 ;;
    --baseline-command) BASELINE=$2; shift 2 ;;
    --spec) SPEC=$2; shift 2 ;;
    --variant-dir) VARIANT_DIR=$2; shift 2 ;;
    --result-root) RESULT_ROOT=$2; shift 2 ;;
    --parallel) PARALLEL=$2; shift 2 ;;
    --max-variants) MAX_VARIANTS=$2; shift 2 ;;
    --timeout-s) TIMEOUT_S=$2; shift 2 ;;
    --datasets) DATASETS=$2; shift 2 ;;
    --limit) LIMIT=$2; shift 2 ;;
    --batch) BATCH=$2; shift 2 ;;
    --thinking) THINKING=$2; shift 2 ;;
    --pairs) PAIRS=$2; shift 2 ;;
    --concurrencies) CONCURRENCIES=$2; shift 2 ;;
    --multiplier) MULTIPLIER=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误:未知参数:$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$MODE" == "eval" || "$MODE" == "bench" ]] || { echo "错误:--mode 必须是 eval|bench" >&2; exit 2; }
[[ -n "$BASELINE" || -n "$VARIANT_DIR" ]] || { echo "错误:需要 --baseline-command+--spec 或 --variant-dir" >&2; exit 2; }
[[ -n "$BASELINE" && -n "$SPEC" ]] || [[ -n "$VARIANT_DIR" ]] || \
  { echo "错误:--spec 模式需同时给 --baseline-command;或改用 --variant-dir" >&2; exit 2; }

: "${RESULT_ROOT:=${RUNS_DIR:-./cmp_runs}}"
PARALLEL=${PARALLEL:-1}
[[ "$PARALLEL" == "1" ]] || { echo "错误:--parallel > 1 尚未实现(v1 只支持串行)" >&2; exit 2; }

GEN="${GEN:-$SCRIPT_DIR/../lib/make_variants.py}"
PARSER="${PARSER:-$SCRIPT_DIR/../lib/server_command_parser.py}"
RUN_STEP=""
if [[ "$MODE" == "eval" ]]; then
  RUN_STEP="$SCRIPT_DIR/run-eval.sh"
else
  RUN_STEP="$SCRIPT_DIR/run-bench.sh"
fi
for f in "$GEN" "$PARSER" "$RUN_STEP" "$SCRIPT_DIR/start-server.sh" "$SCRIPT_DIR/release-server.sh"; do
  [[ -f "$f" ]] || { echo "错误:缺少依赖文件:$f" >&2; exit 2; }
done
for cmd in python3 bash; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "错误:找不到命令:$cmd" >&2; exit 2; }
done

# ---------------- 本轮根 + 变体清单 ----------------
TIME_TAG=$(date +'%Y%m%d_%H%M%S')
ROOT="${RESULT_ROOT%/}/cmp-${MODE}-${TIME_TAG}"
VARIANTS_ROOT="$ROOT/variants"
mkdir -p "$VARIANTS_ROOT"
START_SEC=$SECONDS

if [[ -n "$SPEC" ]]; then
  [[ -f "$BASELINE" ]] || { echo "错误:基线命令不存在:$BASELINE" >&2; exit 2; }
  [[ -f "$SPEC" ]] || { echo "错误:spec 不存在:$SPEC" >&2; exit 2; }
  cp "$BASELINE" "$ROOT/baseline_server_command.sh"
  cp "$SPEC" "$ROOT/spec.json"
  if ! python3 "$GEN" --baseline "$BASELINE" --spec "$SPEC" --out "$VARIANTS_ROOT"; then
    echo "错误:变体生成失败(见上)" >&2; exit 2
  fi
  mapfile -t LABELS <"$VARIANTS_ROOT/.order"
else
  [[ -d "$VARIANT_DIR" ]] || { echo "错误:--variant-dir 不存在:$VARIANT_DIR" >&2; exit 2; }
  LABELS=()
  for d in "$VARIANT_DIR"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/server_command.sh" ]] || continue
    LABELS+=("$(basename "$d")")
  done
  IFS=$'\n' LABELS=($(printf '%s\n' "${LABELS[@]}" | sort)); unset IFS
  ((${#LABELS[@]} > 0)) || { echo "错误:--variant-dir 下没有找到含 server_command.sh 的子目录:$VARIANT_DIR" >&2; exit 2; }
  for label in "${LABELS[@]}"; do
    mkdir -p "$VARIANTS_ROOT/$label"
    cp "$VARIANT_DIR/$label/server_command.sh" "$VARIANTS_ROOT/$label/server_command.sh"
    [[ -f "$VARIANT_DIR/$label/spec.json" ]] && cp "$VARIANT_DIR/$label/spec.json" "$VARIANTS_ROOT/$label/spec.json" || true
  done
fi

N=${#LABELS[@]}
if [[ -n "$MAX_VARIANTS" ]]; then
  is_positive_integer "$MAX_VARIANTS" || { echo "错误:--max-variants 必须为正整数" >&2; exit 2; }
  ((N <= MAX_VARIANTS)) || { echo "错误:变体数 $N 超过上限 $MAX_VARIANTS" >&2; exit 2; }
fi
log "cmp-${MODE}:共 ${N} 个变体 -> $ROOT"

# ---------------- 统一校验(全部通过才启动任何服务) ----------------
INVALID=()
for label in "${LABELS[@]}"; do
  if ! python3 "$PARSER" metadata "$VARIANTS_ROOT/$label/server_command.sh" >/dev/null 2>&1; then
    INVALID+=("$label")
  fi
done
if ((${#INVALID[@]} > 0)); then
  echo "错误:以下变体命令未通过 parser 校验,不启动任何实验:${INVALID[*]}" >&2
  echo "{\"result\":\"input_error\",\"mode\":\"$MODE\",\"invalid\":[$(printf '"%s",' "${INVALID[@]}" | sed 's/,$//')],\"root\":\"$ROOT\"}" >"$ROOT/cmp.json"
  exit 2
fi
log "全部变体命令校验通过"

# ---------------- 串行扫描 ----------------
OK_ALL=1
WORKLOAD_ARGS=()
if [[ "$MODE" == "eval" ]]; then
  [[ -n "$DATASETS" ]] && WORKLOAD_ARGS+=(--datasets "$DATASETS")
  [[ -n "$LIMIT" ]] && WORKLOAD_ARGS+=(--limit "$LIMIT")
  [[ -n "$BATCH" ]] && WORKLOAD_ARGS+=(--batch "$BATCH")
  [[ -n "$THINKING" ]] && WORKLOAD_ARGS+=(--thinking "$THINKING")
else
  [[ -n "$PAIRS" ]] && WORKLOAD_ARGS+=(--pairs "$PAIRS")
  [[ -n "$CONCURRENCIES" ]] && WORKLOAD_ARGS+=(--concurrencies "$CONCURRENCIES")
  [[ -n "$MULTIPLIER" ]] && WORKLOAD_ARGS+=(--multiplier "$MULTIPLIER")
fi
[[ -n "$TIMEOUT_S" ]] && WORKLOAD_ARGS+=(--timeout-s "$TIMEOUT_S")

for ((idx = 0; idx < N; idx++)); do
  label=${LABELS[$idx]}
  vdir="$VARIANTS_ROOT/$label"
  num=$((idx + 1))
  log "[$num/$N] 变体:${label} 开始"

  # 1) 起服务
  start_out=""
  if bash "$SCRIPT_DIR/start-server.sh" --server-command "$vdir/server_command.sh" --result-root "$vdir" >"$vdir/start.out" 2>&1; then
    started_json=$(locate_started_json "$vdir" || true)
    if [[ -z "$started_json" ]]; then
      log "[$num/$N] ${label}:start-server 退出 0 但未找到 started.json,按启动失败处理"
    fi
  else
    started_json=""
    log "[$num/$N] ${label}:服务启动失败(见 $vdir/start.out)"
  fi

  ok=0
  start_ok=0
  run_result=""
  result_json=""
  release_result=""
  release_json=""
  if [[ -n "$started_json" ]]; then
    start_ok=1
    # 2) workload
    if bash "$RUN_STEP" --started-json "$started_json" "${WORKLOAD_ARGS[@]}" --result-root "$vdir" >"$vdir/run.out" 2>&1; then
      ok=1
    else
      log "[$num/$N] ${label}:workload 失败(见 $vdir/run.out)"
    fi
    result_json=$(find "$vdir" -maxdepth 2 -name "${MODE}.json" -print 2>/dev/null | sort | tail -n 1 || true)
    if [[ -n "$result_json" ]]; then
      run_result=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("result",""))' "$result_json" 2>/dev/null || true)
    fi
    # 3) 收尾(幂等;失败只记录)
    if bash "$SCRIPT_DIR/release-server.sh" --started-json "$started_json" >"$vdir/release.out" 2>&1; then
      release_result="ok"
    else
      release_result="failed"
    fi
    release_json=$(find "$vdir" -maxdepth 2 -name release.json -print 2>/dev/null | sort | tail -n 1 || true)
    if [[ -n "$release_json" ]]; then
      release_result=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("result",""))' "$release_json" 2>/dev/null || true)
    fi
  else
    ok=0
  fi
  ((ok == 1)) || OK_ALL=0

  # 每变体落 variant.json(确定性装配)
  python3 - "$vdir/variant.json" "$label" "$ok" "$start_ok" "$run_result" "$started_json" "$result_json" "$release_result" "$release_json" <<'PY'
import json
import os
import sys

out, label, ok, start_ok, run_result, started_json, result_json, release_result, release_json = sys.argv[1:]
desc = ""
sp = os.path.join(os.path.dirname(out), "spec.json")
if os.path.exists(sp):
    try:
        desc = json.load(open(sp, encoding="utf-8")).get("description", "")
    except Exception:
        desc = ""
obj = {
    "label": label,
    "description": desc,
    "ok": ok == "1",
    "start_ok": start_ok == "1",
    "run_result": run_result,
    "started_json": started_json,
    "result_json": result_json,
    "release_result": release_result,
    "release_json": release_json,
    "vdir": os.path.dirname(out),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY
  log "[$num/$N] ${label}:ok=${ok} run_result=${run_result} release=${release_result}"
done

# ---------------- 汇总 ----------------
elapsed=$((SECONDS - START_SEC))
printf '%s\n' "${LABELS[@]}" >"$ROOT/order.txt"
python3 - "$ROOT" "$MODE" "$N" "$OK_ALL" "$elapsed" "$ROOT/cmp.json" <<'PY'
import json
import os
import sys

root, mode, n, ok_all, elapsed, out = sys.argv[1:]
by_label = {}
for label in os.listdir(os.path.join(root, "variants")):
    vj = os.path.join(root, "variants", label, "variant.json")
    if os.path.exists(vj):
        with open(vj, encoding="utf-8") as f:
            by_label[label] = json.load(f)
order_file = os.path.join(root, "order.txt")
order = []
if os.path.exists(order_file):
    order = [ln.strip() for ln in open(order_file, encoding="utf-8") if ln.strip()]
if not order:
    order = sorted(by_label)
variants = [by_label[label] for label in order if label in by_label]
result = "ok" if ok_all == "1" else "partial"
obj = {
    "result": result,
    "mode": mode,
    "count": int(n),
    "root": root,
    "variants": variants,
    "elapsed_s": int(elapsed),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PY

if ((OK_ALL == 1)); then
  echo "[cmp-sweep] STEP_RESULT=ok variants=$N root=$ROOT cmp_json=$ROOT/cmp.json"
  exit 0
fi
echo "[cmp-sweep] STEP_RESULT=partial variants=$N root=$ROOT cmp_json=$ROOT/cmp.json"
exit 4
