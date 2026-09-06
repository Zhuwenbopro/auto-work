---
name: eval
description: '对一台健康(或刚启动)的 SGLang 服务跑一轮 EvalScope 评测(数据集/limit/batch/thinking 可选),默认评测完停服释放;汇报各数据集分数。Use when: 用户要求评测/跑 EvalScope/测准确率/测 math500、humaneval、gsm8k 等数据集,或提到 eval 技能。'
whenToUse: '需要对一个 sglang 服务命令做准确率评测(开箱数据集),或对已运行服务附着评测时。'
---

# EvalScope 评测(eval)

你是一次性编排代理。**所有机械动作执行现成 step,不许临场发明命令**;你负责:选数据集/limit/batch/thinking、决定"起新服务还是附着现有服务"、读 `eval.json` 分流、默认收尾、从 EvalScope 产物读分数汇报。评测执行口径在受管副本 `lib/eval_command.sh`(测试部门权威,不许改)。

## 路径与固定参数

- `AUTO_WORK` 默认 `/home/auto-work`;step 目录 `${AUTO_WORK}/steps/`,受管副本 `${AUTO_WORK}/lib/`
  - `start-server.sh`(起服务;`--server-command` 必填)
  - `run-eval.sh`(workload;产物 `eval.json`)
  - `release-server.sh`(收尾;产物 `release.json`)
- **`RUNS_DIR` 默认 `/home/runs`**;本轮根:`EVAL_ROOT = ${RUNS_DIR}/eval-<时间戳>/`
- 命令源:用户内联 sglang 命令 > `/home/server_command.sh`
- 评测参数默认:`EVAL_DATASETS=humaneval,math_500,gsm8k`(**三个都测**)、`EVAL_BATCH=64`、`EVAL_LIMIT=None`(全量)、`EVAL_ENABLE_THINKING=false`;**用户点名了数据集 → 只测点名的那个/那几个**,其余以用户为准
- 数据集命名:step 层不做改写;请求里说 `math500` 时由你归一为 `math_500` 再传给 `--datasets`,其余名字原样透传;非法字符/重复由 step 报输入错

## 前置(任一不满足 → "输入错误"汇报退出)

1. `echo ok` 能跑(否则先设 `DSH_PERMISSION_MODE=danger-full-access`);
2. `test -f /home/server_command.sh` 或用户给了内联命令(用 parser 校验一次);
3. 能解析 started.json:若声称"已有服务在跑",先确认那份 started.json 存在。

## 执行(两种模式)

### 模式 A —— 起新服务评测(默认,无人值守)

1. 建本轮根:`EVAL_ROOT="${RUNS_DIR:-/home/runs}/eval-$(date +'%Y%m%d_%H%M%S')"; mkdir -p "$EVAL_ROOT"`;
2. 准备命令源:内联 → 规范化写入 `${EVAL_ROOT}/server_command.sh`;否则 `cp /home/server_command.sh ${EVAL_ROOT}/server_command.sh`;
3. 起服务(固定命令,照抄):
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/start-server.sh" \
     --server-command "${EVAL_ROOT}/server_command.sh" \
     --result-root "${EVAL_ROOT}"
   ```
   - 退出 0 / 读到 `started.json` 才继续;非 0 → 读同轮 `failed.json`(stage/error)按失败汇报;
4. 跑评测(固定命令,照抄):
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/run-eval.sh" \
     --server-root "${EVAL_ROOT}" \
     --datasets "${EVAL_DATASETS}" [--batch N] [--limit N] [--thinking true|false] \
     --result-root "${EVAL_ROOT}"
   ```
   (不加 --datasets 等即用默认;用户没给就别加对应旗标)
5. 读 `${EVAL_ROOT}/eval-<ts>/eval.json` 分流:
   - `result == ok` → 继续汇报路径;
   - `result == failed` → 读 eval.log 尾部几行,按失败汇报(服务仍在跑,用 release 收尾);
   - `result == server_died` → 服务已挂,按失败汇报(卡会被 release 复核确认已释放);
   - `result == timeout` → 按超时汇报(workload 已终止,release 收尾);
6. **收尾(默认停服释放,用户显式说"保留服务"才跳过)**:
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/release-server.sh" \
     --started-json <start-server 那轮 start-*/started.json 绝对路径>
   ```
   读 `release.json` 的 `result`(`released|already_gone|failed`)与 `gpus_state` 汇报。

### 模式 B —— 附着已运行服务

用户给了 started.json 路径 / 说已有服务在跑 → 跳过起服,直接:
```bash
bash "${AUTO_WORK:-/home/auto-work}/steps/run-eval.sh" \
  --started-json <路径> --datasets … [--limit N] [--thinking true|false]
```
结果同模式 A 分流;是否停服听用户(默认**不停**服务,它不属于本次任务生命周期)。

## 汇报格式

```
结果: 评测 <ok|failed|server_died|timeout>(datasets=…, batch=…, limit=…, thinking=…)
- eval.json: <绝对路径>(result/stage/legacy_exit/elapsed_s)
- 服务: <模式 A:已停(release.json result + gpus_state)|模式 B:保持运行,未动>
- 模型: <model_name(model_path)>
- 分数/EvalScope 产物: <从 run_dir 的 EvalScope work-dir 报告读出的各数据集分数与样本数;读不到就写报告目录路径>
- 日志: eval.log=<绝对路径>(失败时附尾部几行)
```

## 纪律

> 0. **选卡是代码职责**:start-server 负责等卡/锁卡/选端口/注入 `HIP_VISIBLE_DEVICES`(parser 会覆盖命令文件里的设备与端口)。本任务**禁止自行探测 GPU(rocm-smi)、读取 step 实现、猜测或改动设备变量**;前置只需 `echo ok` + 命令文件 parser 校验 + (声明已有服务时)确认 started.json。

1. 只按 `eval.json` / `release.json` 分流,不猜日志;命令照抄 step;
2. 不修改 `lib/eval_command.sh`;测试部门要改数据集/生成口径,改的是这份受管副本;
3. 服务是稀缺资源:模式 A 默认评测完停服释放;保留只在用户明确要求时;
4. 一次一任务,汇报后结束。
