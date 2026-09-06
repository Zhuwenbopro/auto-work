---
name: bench
description: '对一台健康(或刚启动)的 SGLang 服务跑 bench_serving 压测网格(长度对 × 并发),默认压完停服释放;汇报吞吐/TTFT/TPOT/ITL。Use when: 用户要求压测/跑吞吐测试/测 TTFT、TPOT、ITL/指定并发与长度组合,或提到 bench 技能。'
whenToUse: '需要对一个 sglang 服务命令做性能压测(合成数据、随机长度对 × 并发网格),或对已运行服务附着压测时。'
---

# bench_serving 压测(bench)

你是一次性编排代理。**所有机械动作执行现成 step,不许临场发明命令**;你负责:选长度对/并发/倍数、决定"起新服务还是附着现有服务"、读 `bench.json` 分流、默认收尾、汇报性能指标。压测口径在受管副本 `lib/bench_serving.sh`(测试部门权威,不许改)。

## 路径与固定参数

- `AUTO_WORK` 默认 `/home/auto-work`;step 目录 `${AUTO_WORK}/steps/`,受管副本 `${AUTO_WORK}/lib/`
  - `start-server.sh` / `run-bench.sh`(产物 `bench.json`)/ `release-server.sh`(产物 `release.json`)
- **`RUNS_DIR` 默认 `/home/runs`**;本轮根:`BENCH_ROOT = ${RUNS_DIR}/bench-<时间戳>/`
- 命令源:用户内联 sglang 命令 > `/home/server_command.sh`
- 压测参数默认:`BENCH_PAIRS="4096 1024"`、`BENCH_CONCURRENCIES="1,2,4,8,16,32,64,128"`、`CONCURRENCY_MULTIPLIER=1`(每档请求数 = 并发 × 倍数);用户给了以用户为准
- **tokenizer 铁律**:压测客户端 `--tokenizer` 必须是**本地模型目录**(started.json.model_path / --model-dir),绝不能用 /v1/models 返回的短 served 名(会被当 HF repo id → 401/非本地目录)

## 前置(任一不满足 → "输入错误"汇报退出)

1. `echo ok` 能跑;
2. `test -f /home/server_command.sh` 或用户给了内联命令(parser 校验一次);
3. 声称"已有服务在跑"时,先确认那份 started.json 存在且 model_path 可读。

## 执行(两种模式)

### 模式 A —— 起新服务压测(默认,无人值守)

1. 建本轮根:`BENCH_ROOT="${RUNS_DIR:-/home/runs}/bench-$(date +'%Y%m%d_%H%M%S')"; mkdir -p "$BENCH_ROOT"`;
2. 命令源:内联 → 规范化写入 `${BENCH_ROOT}/server_command.sh`;否则 `cp /home/server_command.sh ${BENCH_ROOT}/server_command.sh`;
3. 起服务(固定命令,照抄):
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/start-server.sh" \
     --server-command "${BENCH_ROOT}/server_command.sh" \
     --result-root "${BENCH_ROOT}"
   ```
   退出 0 / 有 `started.json` 才继续;非 0 → 读 `failed.json` 按失败汇报;
4. 压测(固定命令,照抄;用户没给网格就别加对应旗标,用默认):
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/run-bench.sh" \
     --server-root "${BENCH_ROOT}" \
     [--pairs "…" ] [--concurrencies "…"] [--multiplier N] \
     [--timeout-s N] --result-root "${BENCH_ROOT}"
   ```
5. 读 `${BENCH_ROOT}/bench-<ts>/bench.json` 分流:
   - `result == ok` → 汇报各组合指标(rows 已解析为 JSON 数组;20 列指标直接读);
   - `result == failed` → 读 bench.log 尾部,按失败汇报(已完成格数 completed_cells 一并汇报);
   - `result == server_died|timeout` → 按相应失败汇报(completed_cells = 已跑部分,不算全损);
6. **收尾(默认停服释放,用户显式说保留才跳过)**:
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/release-server.sh" \
     --started-json <start-server 那轮 start-*/started.json 绝对路径>
   ```
   读 `release.json` 的 `result` 与 `gpus_state` 汇报。

### 模式 B —— 附着已运行服务

用户给了 started.json 路径 / 说已有服务在跑 → 跳过起服,直接:
```bash
bash "${AUTO_WORK:-/home/auto-work}/steps/run-bench.sh" \
  --started-json <路径> [--pairs …] [--concurrencies …] [--multiplier N]
```
是否停服听用户(默认**不停**,服务不属于本次生命周期)。

## 汇报格式

```
结果: 压测 <ok|failed|server_died|timeout>(pairs=…, concurrencies=…, multiplier=…, cells=completed/expected)
- bench.json: <绝对路径>
- 指标: 每组合一行 —— in/out、并发、rps、generate/total throughput(tok/s)、mean/p95/p99 TTFT·TPOT·ITL(ms)
        (数值直接从 bench.json.rows 抄;失败/超时的行注明未完成)
- 服务: <模式 A:已停(release.json result + gpus_state)|模式 B:保持运行,未动>
- 产物: all.csv=<绝对路径>;每组合 .log/.jsonl 在同一 run_dir
```

## 纪律

> 0. **选卡是代码职责**:start-server 负责等卡/锁卡/选端口/注入 `HIP_VISIBLE_DEVICES`(parser 会覆盖命令文件里的设备与端口)。本任务**禁止自行探测 GPU(rocm-smi)、读取 step 实现、猜测或改动设备变量**;前置只需 `echo ok` + 命令文件 parser 校验 + (声明已有服务时)确认 started.json。

1. 只按 `bench.json` / `release.json` 分流,不猜日志;命令照抄 step;
2. 不修改 `lib/bench_serving.sh`;不把短 served 名当 tokenizer;
3. 服务是稀缺资源:模式 A 默认压完停服释放;保留只在用户明确要求时;
4. 一次一任务,汇报后结束。
