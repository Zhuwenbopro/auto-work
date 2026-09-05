#!/usr/bin/env bash
# ============================================================================
# compile-sglang.sh —— step: 编译并安装 HYGON-AI sglang-das(HCU/ROCm)
#
# 职责:在给定源码目录把 sglang 安装进当前 Python 环境并验证(import + pip show)。
#       镜像已含依赖,故不安装 requirements_hcu.txt;流程 = AOT kernel + editable sglang。
#       build-aot-kernel 只编译算子并离线安装本地 wheel(--no-deps/--no-index),
#       不从 PyPI 下载/更新任何依赖(镜像已够);失败停在该命令,不做自愈。
#       kernel 编译要求本机 rustc/cargo >= 1.85:build-aot-kernel 前先校验版本,
#       缺失或不足会自动升级 Rust 工具链(>= 1.85)再继续编译;升级失败或仍不足才 FATAL。
#   成功 -> exit 0,日志末行 RESULT=OK
#   失败 -> 停在该命令,exit 非 0,日志末行 RESULT=FATAL stage=...
#        stage: clone|uninstall-kernel|build-aot-kernel|install-editable|verify-import|verify-kernel
# 编译很长:默认 async(后台 + pid/log),另提供 wait 轮询与 --sync 前台模式。
#
# 用法:
#   bash compile-sglang.sh start    [--src-dir DIR] [--result-root DIR]   # async 启动
#   bash compile-sglang.sh wait PID [max_seconds]  [--result-root DIR]    # 轮询(单次默认 ≤50s)
#   bash compile-sglang.sh --sync   [--src-dir DIR] [--result-root DIR]   # 前台跑(直跑/调试)
# 退出码:0=OK 2=用法/前置失败 3=wait 看到失败 4=FATAL
# ============================================================================
set -Eeuo pipefail

AUTO_WORK="${AUTO_WORK:-/home/auto-work}"
RESULT_ROOT="${RESULT_ROOT:-/home/runs}"
SRC_DIR="/home/sglang-das"
GIT_REPO="https://github.com/HYGON-AI/sglang-das.git"
FAILURE_LOG_LINES=80

MODE="start"
PID_ARG=""
MAX_WAIT=50
LOG_OVERRIDE=""

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' >&2; }

while (($#)); do
  case "$1" in
    start)
      MODE="start"; shift ;;
    wait)
      MODE="wait"
      PID_ARG="${2:-}"; MAX_WAIT="${3:-50}"
      if   [ $# -ge 3 ]; then shift 3
      elif [ $# -ge 2 ]; then shift 2
      else shift; fi ;;
    --sync)
      MODE="sync"; shift ;;
    --src-dir)
      (($# >= 2)) || { echo "缺 --src-dir 值" >&2; exit 2; }
      SRC_DIR=$2; shift 2 ;;
    --result-root)
      (($# >= 2)) || { echo "缺 --result-root 值" >&2; exit 2; }
      RESULT_ROOT=$2; shift 2 ;;
    --log)
      LOG_OVERRIDE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数:$1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*"; }

# ---------------- 内部流水线(后台进程执行体) ----------------
run_pipeline() {
  local src=$1 logf=$2 stage=""

  echo "===== compile-sglang 开始 src=$src python=$(python3 --version 2>&1) =====" >>"$logf"

  # run_in <stage> <workdir> <cmd...>:在指定目录执行并追加日志;失败写 FATAL 标记并返回 1
  run_in() {
    local st=$1 wd=$2
    shift 2
    if [ ! -d "$wd" ]; then
      printf '[compile-sglang] RESULT=FATAL stage=%s reason="工作目录不存在:%s"\n' "$st" "$wd" >>"$logf"
      return 1
    fi
    printf '\n===== [compile] STAGE=%s cmd: %s (cwd=%s) =====\n' "$st" "$*" "$wd" >>"$logf"
    if ! ( cd "$wd" && "$@" ) >>"$logf" 2>&1; then
      printf '[compile-sglang] RESULT=FATAL stage=%s\n' "$st" >>"$logf"
      return 1
    fi
  }

  # build-aot-kernel:只编译算子,不下载/更新任何依赖。
  # 说明:`python3 setup_hip.py install` 会走 easy_install 自动解析安装 install_requires
  # (日志里表现为 Searching/Downloading pypi 的 torch/triton/nvidia-*),故改为
  # bdist_wheel 只编译 + pip 离线安装本地 wheel(--no-deps/--no-index);镜像已含全部依赖。
  # ==== Rust 工具链门禁:kernel(AOT)编译要求 rustc/cargo >= 1.85(版本不足会在
  # bdist_wheel 里报出晦涩的编译错误)。缺失/不足时 step 自动下载升级 Rust 工具链
  # 到 >= 1.85(默认:有 rustup 则 `rustup toolchain install 1.85.0 --profile minimal`
  # 并设为默认;无 rustup 则官方脚本 sh.rustup.rs 装 rustup + 默认 1.85.0)。整条安装
  # 命令可用环境变量 RUST_INSTALL_CMD 覆盖(如离线/内网镜像的本地安装脚本),离线下载
  # 较慢属正常。升级后重新校验,仍不足或升级失败才 FATAL;其它编译错误不做自愈。 ====
  tool_rustc_ver() {
    local v="?"
    if command -v rustc >/dev/null 2>&1; then
      v=$(rustc --version 2>/dev/null | awk '{print $2}' || true)
    fi
    printf '%s' "${v:-?}"
  }
  tool_cargo_ver() {
    local v="?"
    if command -v cargo >/dev/null 2>&1; then
      v=$(cargo --version 2>/dev/null | awk '{print $2}' || true)
    fi
    printf '%s' "${v:-?}"
  }
  # 参数:rustc 版本、cargo 版本;两者都存在且 >= 1.85.0 才满足
  rust_ge_185() {
    [ "$1" != "?" ] && [ "$2" != "?" ] \
      && printf '1.85.0\n%s\n' "$1" | sort -V -C \
      && printf '1.85.0\n%s\n' "$2" | sort -V -C
  }
  # 自动安装/升级 Rust 工具链(>= 1.85);安装命令可用 RUST_INSTALL_CMD 覆盖。
  install_rust_toolchain() {
    local cmd=""
    if [ -n "${RUST_INSTALL_CMD:-}" ]; then
      cmd=$RUST_INSTALL_CMD
      printf '[compile-sglang] 使用环境变量 RUST_INSTALL_CMD 指定的安装命令\n' >>"$logf"
    elif command -v rustup >/dev/null 2>&1; then
      cmd="rustup toolchain install 1.85.0 --profile minimal && rustup default 1.85.0"
    else
      cmd="curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.85.0 --profile minimal"
    fi
    printf '[compile-sglang] rust 工具链缺失或 < 1.85,自动升级(要求 >= 1.85.0,下载可能较慢)...\n' >>"$logf"
    printf '\n===== [compile] STAGE=build-aot-kernel cmd: rust 工具链自动升级: %s =====\n' "$cmd" >>"$logf"
    if ! eval "$cmd" >>"$logf" 2>&1; then
      printf '[compile-sglang] RESULT=FATAL stage=build-aot-kernel reason="Rust 工具链自动升级失败(kernel 编译要求 >= 1.85.0);请检查网络,或设置环境变量 RUST_INSTALL_CMD 指定可用的安装命令(如离线镜像脚本)后重试"\n' >>"$logf"
      return 1
    fi
    # rustup 默认装到 $CARGO_HOME(缺省 ~/.cargo),把其 bin 加入 PATH 以替换系统旧版 rustc/cargo
    export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true
    hash -r 2>/dev/null || true
    printf '[compile-sglang] rust 工具链升级命令执行完成,重新校验版本\n' >>"$logf"
    return 0
  }
  # 门禁:满足则放行;缺失/不足 -> 自动升级一次 -> 重查;仍不足/升级失败才 FATAL。
  check_rust_toolchain() {
    local st=$1 rustc_ver cargo_ver
    rustc_ver=$(tool_rustc_ver)
    cargo_ver=$(tool_cargo_ver)
    if ! rust_ge_185 "$rustc_ver" "$cargo_ver"; then
      if [ "$rustc_ver" = "?" ] || [ "$cargo_ver" = "?" ]; then
        printf '[compile-sglang] 缺少或无法解析 rustc/cargo(rustc=%s cargo=%s),kernel 编译要求 >= 1.85.0,自动安装...\n' "$rustc_ver" "$cargo_ver" >>"$logf"
      else
        printf '[compile-sglang] rustc/cargo 版本不足:要求 >= 1.85.0,当前 rustc=%s cargo=%s,自动升级...\n' "$rustc_ver" "$cargo_ver" >>"$logf"
      fi
      install_rust_toolchain || return 1
      rustc_ver=$(tool_rustc_ver)
      cargo_ver=$(tool_cargo_ver)
    fi
    if ! rust_ge_185 "$rustc_ver" "$cargo_ver"; then
      printf '[compile-sglang] RESULT=FATAL stage=%s reason="自动升级后 rustc/cargo 仍不足:要求 >= 1.85.0,当前 rustc=%s cargo=%s;请检查安装命令,或设置 RUST_INSTALL_CMD 指定可用安装命令后重试"\n' \
        "$st" "$rustc_ver" "$cargo_ver" >>"$logf"
      return 1
    fi
    printf '[compile-sglang] rust 工具链满足要求:rustc=%s cargo=%s(要求 >= 1.85.0)\n' "$rustc_ver" "$cargo_ver" >>"$logf"
    return 0
  }
  # ==== end rust toolchain guard ====

  build_aot_kernel_stage() {
    local src=$1 wd="$1/python/sglang/kernels/aot" whl=""
    check_rust_toolchain build-aot-kernel || return 1
    printf '\n===== [compile] STAGE=build-aot-kernel cmd: python3 setup_hip.py bdist_wheel (cwd=%s) =====\n' "$wd" >>"$logf"
    if ! ( cd "$wd" && python3 setup_hip.py bdist_wheel ) >>"$logf" 2>&1; then
      printf '[compile-sglang] RESULT=FATAL stage=build-aot-kernel\n' >>"$logf"
      return 1
    fi
    whl=$(ls "$wd"/dist/sglang_kernel-*.whl 2>/dev/null | head -n 1 || true)
    if [ -z "$whl" ]; then
      printf '[compile-sglang] RESULT=FATAL stage=build-aot-kernel reason="未找到构建产物 wheel:%s/dist/sglang_kernel-*.whl"\n' "$wd" >>"$logf"
      return 1
    fi
    printf '\n===== [compile] STAGE=build-aot-kernel cmd: pip3 install --no-deps --no-build-isolation --no-index %s =====\n' "$whl" >>"$logf"
    if ! pip3 install --no-deps --no-build-isolation --no-index "$whl" >>"$logf" 2>&1; then
      printf '[compile-sglang] RESULT=FATAL stage=build-aot-kernel\n' >>"$logf"
      return 1
    fi
    return 0
  }

  # 0. 源码目录(仅缺失时 clone;已有则复用,不删除不覆盖)
  if [ ! -d "$src/.git" ]; then
    echo "==> git clone $GIT_REPO -> $src" >>"$logf"
    if ! git clone "$GIT_REPO" "$src" >>"$logf" 2>&1; then
      printf '[compile-sglang] RESULT=FATAL stage=clone\n' >>"$logf"
      return 4
    fi
  else
    echo "==> 复用已有源码目录:$src" >>"$logf"
  fi

  run_in uninstall-kernel "$src" pip3 uninstall -y sglang-kernel || return 4

  build_aot_kernel_stage "$src" || return 4

  run_in install-editable "$src" pip3 install -e "python[all_hip]" \
    --no-deps --no-build-isolation --no-index || return 4

  run_in verify-import "$src" python3 -c \
    "import sglang; print('sglang import: OK')" || return 4

  printf '\n===== pip show sglang-kernel =====\n' >>"$logf"
  if ! pip3 show sglang-kernel >>"$logf" 2>&1; then
    printf '[compile-sglang] RESULT=FATAL stage=verify-kernel\n' >>"$logf"
    return 4
  fi

  printf '[compile-sglang] RESULT=OK\n' >>"$logf"
  return 0
}

write_json() {
  local jsonf=$1 rc=$2
  python3 - "$jsonf" "$rc" "$SRC_DIR" <<'PY' || true
import json, sys
jsonf, rc, src = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"result": "ok" if rc == "0" else "fatal", "src_dir": src},
          open(jsonf, "w"), ensure_ascii=False, indent=2)
PY
}

# ---------------- start:异步启动 ----------------
if [ "$MODE" = "start" ]; then
  for c in python3 pip3 git setsid; do
    command -v "$c" >/dev/null 2>&1 || { echo "缺少命令:$c" >&2; exit 2; }
  done
  TS=$(date +'%Y%m%d_%H%M%S')
  RUN_DIR="${RESULT_ROOT}/compile-${TS}"
  mkdir -p "$RUN_DIR"
  LOGF="$RUN_DIR/compile.log"
  setsid bash "$0" --sync --src-dir "$SRC_DIR" --result-root "$RESULT_ROOT" \
    --log "$LOGF" </dev/null >>"$LOGF" 2>&1 &
  PID=$!
  printf '%s\n' "$PID" >"$RUN_DIR/compile.pid"
  echo "[compile-sglang] COMPILE_RESULT=STARTED pid=$PID src=$SRC_DIR log=$LOGF run_dir=$RUN_DIR"
  exit 0
fi

# ---------------- wait:轮询 ----------------
if [ "$MODE" = "wait" ]; then
  [[ "$PID_ARG" =~ ^[0-9]+$ ]] || { echo "wait 需要 pid" >&2; exit 2; }
  find_log_by_pid() {
    local d pidfile
    for d in "$RESULT_ROOT"/compile-*/; do
      pidfile="$d/compile.pid"
      [ -f "$pidfile" ] || continue
      if [ "$(cat "$pidfile" 2>/dev/null)" = "$PID_ARG" ]; then
        printf '%s\n' "$d/compile.log"
        return 0
      fi
    done
    return 1
  }
  LOGF=""
  [ -n "$LOG_OVERRIDE" ] && LOGF=$LOG_OVERRIDE
  [ -z "$LOGF" ] && LOGF=$(find_log_by_pid || true)

  deadline=$((SECONDS + MAX_WAIT))
  while kill -0 "$PID_ARG" 2>/dev/null && ((SECONDS < deadline)); do
    sleep 2
  done

  if kill -0 "$PID_ARG" 2>/dev/null; then
    echo "[compile-sglang] COMPILE_STATE=running pid=$PID_ARG log=${LOGF:-unknown}"
    exit 0
  fi
  if [ -n "$LOGF" ] && grep -q 'RESULT=OK' "$LOGF"; then
    echo "[compile-sglang] COMPILE_STATE=done result=OK log=$LOGF"
    exit 0
  fi
  if [ -n "$LOGF" ] && grep -q 'RESULT=FATAL' "$LOGF"; then
    echo "[compile-sglang] COMPILE_STATE=done result=FATAL log=$LOGF"
    echo "---- 日志尾部 ----"; tail -n "$FAILURE_LOG_LINES" "$LOGF" || true
    exit 3
  fi
  echo "[compile-sglang] COMPILE_STATE=done result=UNKNOWN(进程已退,无标记) log=${LOGF:-unknown}"
  [ -n "$LOGF" ] && { echo "---- 日志尾部 ----"; tail -n "$FAILURE_LOG_LINES" "$LOGF" 2>/dev/null || true; }
  exit 3
fi

# ---------------- sync:前台(独立调试;也是 start 的后台执行体) ----------------
for c in python3 pip3 git; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少命令:$c" >&2; exit 2; }
done

if [ -n "$LOG_OVERRIDE" ]; then
  LOGF=$LOG_OVERRIDE
  mkdir -p "$(dirname "$LOGF")"
else
  TS=$(date +'%Y%m%d_%H%M%S')
  RUN_DIR="${RESULT_ROOT}/compile-${TS}"
  mkdir -p "$RUN_DIR"
  LOGF="$RUN_DIR/compile.log"
  echo "==> 编译日志:$LOGF (src=$SRC_DIR)"
fi

if run_pipeline "$SRC_DIR" "$LOGF"; then
  rc=0
else
  rc=4
fi
write_json "$(dirname "$LOGF")/compile.json" "$rc"

if [ "$rc" = 0 ]; then
  echo "[compile-sglang] COMPILE_RESULT=OK src=$SRC_DIR log=$LOGF"
else
  echo "[compile-sglang] COMPILE_RESULT=FATAL src=$SRC_DIR log=$LOGF"
  tail -n "$FAILURE_LOG_LINES" "$LOGF" || true
fi
exit "$rc"
