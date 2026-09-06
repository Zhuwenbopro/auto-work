---
name: tracing
description: '对一台健康(或刚启动)的 SGLang 服务采集 1 次 Torch Profiler trace(默认关 CUDA graph 场景建议由启动命令自带),默认采完停服释放;汇报 trace 路径。Use when: 用户要求 profile、prof、torch profiler、算子调用、GPU kernel trace、运行过程分析,或提到 tracing 技能。'
whenToUse: '需要对一个 sglang 服务命令做短 serving trace 采集(warmup + prefill1 + decode2),或对已运行服务附着采集时。'
---

# Torch Profiler 采集(tracing)

你是一次性编排代理。**所有机械动作执行现成 step,不许临场发明命令**;你负责:选输入/输出长度、决定"起新服务还是附着现有服务"、读 `profile.json` 分流、默认收尾、汇报 trace 路径。采集口径在受管副本 `lib/run_profile.py`(整份搬运,不许改)。

## 路径与固定参数

- `AUTO_WORK` 默认 `/home/auto-work`;step 目录 `${AUTO_WORK}/steps/`,受管副本 `${AUTO_WORK}/lib/`
  - `start-server.sh` / `run-profile.sh`(产物 `profile.json`)/ `release-server.sh`(产物 `release.json`)
- **`RUNS_DIR` 默认 `/home/runs`**;本轮根:`PROFILE_ROOT = ${RUNS_DIR}/profile-<时间戳>/`
- 命令源:用户内联 sglang 命令 > `/home/server_command.sh`
- 采集参数默认:`PROFILE_INPUT_LEN=4096`、`PROFILE_OUTPUT_LEN=3`(1 prefill + 2 decode)、`PROFILE_WARMUP_OUTPUT_LEN=1`、`PROFILE_REQUEST_TIMEOUT=600`、`PROFILE_TRACE_TIMEOUT=180`;用户给了以用户为准
- 采集序列(受管副本内固定):1 预热请求 → `/start_profile`(num_steps=3、CPU+GPU、prefix `prefill1-decode2`)→ 1 个同长 profile 请求 → finally `/stop_profile` → 轮询 trace 文件

## 前置(任一不满足 → "输入错误"汇报退出)

1. `echo ok` 能跑;
2. `test -f /home/server_command.sh` 或用户给了内联命令(parser 校验一次);
3. 声称"已有服务在跑"时,先确认那份 started.json 存在且 /health 可达。

## 执行(两种模式)

### 模式 A —— 起新服务采集(默认,无人值守)

1. 建本轮根:`PROFILE_ROOT="${RUNS_DIR:-/home/runs}/profile-$(date +'%Y%m%d_%H%M%S')"; mkdir -p "$PROFILE_ROOT"`;
2. 命令源:内联 → 规范化写入 `${PROFILE_ROOT}/server_command.sh`;否则 `cp /home/server_command.sh ${PROFILE_ROOT}/server_command.sh`;
   - 提示:若目标是看具体 Python/CUDA 算子,eager 更清晰——可建议启动命令加 `--cuda-graph-backend-prefill disabled --cuda-graph-backend-decode disabled`(用户认可才加,属启动命令内容,不在本 step 职责);
3. 起服务(固定命令,照抄):
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/start-server.sh" \
     --server-command "${PROFILE_ROOT}/server_command.sh" \
     --result-root "${PROFILE_ROOT}"
   ```
   退出 0 / 有 `started.json` 才继续;非 0 → 读 `failed.json` 按失败汇报;
4. 采集(固定命令,照抄;没给长度就用默认):
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/run-profile.sh" \
     --server-root "${PROFILE_ROOT}" \
     [--input-len N] [--output-len N] [--warmup-output-len N] \
     --result-root "${PROFILE_ROOT}"
   ```
5. 读 `${PROFILE_ROOT}/profile-<ts>/profile.json` 分流:
   - `result == ok` → 汇报 trace 路径(traces 数组);
   - `result == no_trace` → 超时没等到 trace,按失败汇报(附 profile.log 尾部);
   - `result == failed|server_died|timeout` → 按相应失败汇报;
6. **收尾(默认停服释放,用户显式说保留才跳过)**:
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/release-server.sh" \
     --started-json <start-server 那轮 start-*/started.json 绝对路径>
   ```
   读 `release.json` 的 `result` 与 `gpus_state` 汇报。

### 模式 B —— 附着已运行服务

用户给了 started.json 路径 / 说已有服务在跑 → 跳过起服,直接:
```bash
bash "${AUTO_WORK:-/home/auto-work}/steps/run-profile.sh" \
  --started-json <路径> [--input-len N] [--output-len N]
```
是否停服听用户(默认**不停**,服务不属于本次生命周期)。

## 汇报格式

```
结果: 采集 <ok|no_trace|failed|server_died|timeout>(input=…, output=…)
- profile.json: <绝对路径>
- trace 文件: <profile.json.traces 里的路径,用 Perfetto/Chrome Trace Viewer 打开>
- 服务: <模式 A:已停(release.json result + gpus_state)|模式 B:保持运行,未动>
- 日志: profile.log=<绝对路径>(失败时附尾部几行)
```

## 纪律

> 0. **选卡是代码职责**:start-server 负责等卡/锁卡/选端口/注入 `HIP_VISIBLE_DEVICES`(parser 会覆盖命令文件里的设备与端口)。本任务**禁止自行探测 GPU(rocm-smi)、读取 step 实现、猜测或改动设备变量**;前置只需 `echo ok` + 命令文件 parser 校验 + (声明已有服务时)确认 started.json。

1. 只按 `profile.json` / `release.json` 分流,不猜日志;命令照抄 step;
2. 不修改 `lib/run_profile.py`(payload 硬编码/退出码是行为权威);
3. 服务是稀缺资源:模式 A 默认采完停服释放;保留只在用户明确要求时;
4. 一次一任务,汇报后结束。
