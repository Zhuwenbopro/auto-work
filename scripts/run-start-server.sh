#!/usr/bin/env bash
# ============================================================================
# run-start-server.sh —— 形态 B 入口:把"自然语言启动请求"交给容器内 headless DSH
#
# 用法(容器内,已部署 auto-work 到 /home/auto-work):
#   bash /home/auto-work/scripts/run-start-server.sh "用户请求文本..."
# 或从文件读请求:
#   bash /home/auto-work/scripts/run-start-server.sh --request-file req.txt
#
# 切换部署位置:
#   1) export AUTO_WORK=/path/to/auto-work     # 换 auto-work 位置(默认 /home/auto-work)
#   2) export RUNS_DIR=/path/to/runs           # 换运行时数据根(默认 /home/runs,原 work/ 与 runs/ 合并于此)
#   3) export DSH_ENV_FILE=/path/dsh-env.sh    # dsh 环境文件(默认 /sgl/dsh-env.sh)
#   4) 编辑 ${AUTO_WORK}/config.env 永久生效
#
# 请求示例:
#   bash run-start-server.sh "用下面的命令启动服务
#   export SGLANG_ENABLE_SPEC_V2=1
#   sglang serve --model-path /models/... --tp-size 2"
#
# 行为: 定位部署根 → 生成本轮工作目录 → 拼装"任务提示词 + 用户请求 + 本轮参数"→ dsh
# 退出码: dsh 退出码(0=任务完成;1=中止/出错);step 级结果见汇报中的 结果: 行
# ============================================================================
set -euo pipefail

# ---- 定位部署根(env 覆盖 → config.env) ----
AUTO_WORK="${AUTO_WORK:-/home/auto-work}"
CONFIG_FILE="${AUTO_WORK}/config.env"
[ -f "$CONFIG_FILE" ] && { # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  AUTO_WORK="${AUTO_WORK:-/home/auto-work}"
}

# ---- 派生路径 ----
DSH_ENV_FILE="${DSH_ENV_FILE:-/sgl/dsh-env.sh}"
TASK_FILE="${TASKS_DIR:-${AUTO_WORK}/tasks}/start-server.task.md"
STEP_FILE="${STEP_START_SERVER:-${STEPS_DIR:-${AUTO_WORK}/steps}/start-server.sh}"
PARSER_FILE="${PARSER:-${LIB_DIR:-${AUTO_WORK}/lib}/server_command_parser.py}"
# RESULT_ROOT:见下"本轮工作目录"(缺省 = 本轮 REQ_WORK,结果并入本轮目录)

# ---- 前置检查 ----
[ -f "$DSH_ENV_FILE" ] || { echo "!! 未找到 $DSH_ENV_FILE(请先跑 setup-dsh.sh 或设置 DSH_ENV_FILE)" >&2; exit 1; }
[ -f "$TASK_FILE" ] || { echo "!! 未找到任务提示词:$TASK_FILE" >&2; exit 1; }
[ -f "$STEP_FILE" ] || { echo "!! 未找到 step:$STEP_FILE" >&2; exit 1; }
[ -f "$PARSER_FILE" ] || { echo "!! 未找到 parser:$PARSER_FILE(请从 skills 仓库拷贝到 auto-work/lib)" >&2; exit 1; }

# ---- 请求文本 ----
REQUEST_FILE=""
if [ "${1:-}" = "--request-file" ]; then
  REQUEST_FILE="$2"
  [ -f "$REQUEST_FILE" ] || { echo "!! 请求文件不存在:$REQUEST_FILE" >&2; exit 1; }
  REQUEST=$(cat "$REQUEST_FILE")
else
  [ $# -gt 0 ] || { echo "用法: $0 \"请求\" 或 $0 --request-file f" >&2; exit 2; }
  REQUEST="$*"
fi

# ---- 本轮工作目录(运行时数据根统一到 RUNS_DIR,默认 /home/runs)----
TS=$(date +'%Y%m%d_%H%M%S')
# 每轮请求一个目录:server_command.sh 与 step 结果(start-<t>/)都在这里,
# 不再像以前那样同时建 work/<ts> 与 runs/start-<t> 两个目录。
REQ_WORK="${RUNS_DIR:-/home/runs}/${TS}"
RESULT_ROOT="${RESULT_ROOT:-$REQ_WORK}"
mkdir -p "$REQ_WORK" "$RESULT_ROOT"

# shellcheck source=/dev/null
source "$DSH_ENV_FILE"
cd "$REQ_WORK"

MSG=$(cat <<EOF
$(cat "$TASK_FILE")

用户请求:
${REQUEST}

本轮参数(路径以这里为准,任务不要自行猜测):
AUTO_WORK=${AUTO_WORK}
REQ_WORK=${REQ_WORK}
RESULT_ROOT=${RESULT_ROOT}
STEP=${STEP_FILE}
PARSER=${PARSER_FILE}
EOF
)

echo "==> DSH_HOME   = $DSH_HOME"
echo "==> AUTO_WORK  = $AUTO_WORK"
echo "==> REQ_WORK   = $REQ_WORK"
echo "==> 任务开始(推理在 stderr,最终答案在 stdout)..."
echo
dsh --profile headless "$MSG"
status=$?
echo
if [ $status -eq 0 ]; then
  echo "==> 任务完成(exit 0)"
else
  echo "!! 任务中止或出错(exit $status)"
fi
exit $status
