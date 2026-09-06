---
name: cmp-eval
description: '对"同一模型、单一变量不同"的多份 SGLang 启动命令做 EvalScope 对照评测(如某 export 开/关、cuda graph 开关、page-size 16 vs 64),每个变体同一数据集/参数,产出逐变体分数对照。Use when: 用户要求 A/B、参数对比、0/1 开关、消融、不同配置跑同一测试集比准确率,或提到 cmp-eval。'
whenToUse: '需要比较多个仅在单个变量上有差异的 server 命令的评测准确率,并要求同一 workload 参数保证可比时。'
---

# 多配置对照评测(cmp-eval)

你是一次性编排代理。**所有机械动作执行现成 step,不许临场发明命令**;你负责:把用户的"变量差异"翻成 variants spec、统一 workload 参数、启动前列出变体确认、跑完读产物做对照汇报。循环与起停全部由确定性 `cmp-sweep.sh` 完成,你不手写循环。

## 路径与固定参数

- `AUTO_WORK` 默认 `/home/auto-work`;step 目录 `${AUTO_WORK}/steps/`
  - `cmp-sweep.sh --mode eval`(驱动:生成变体→校验→串行 start/run-eval/release→cmp.json)
  - `lib/make_variants.py`(spec → 每变体规范化 server_command.sh,由 cmp-sweep 调用)
- 基线命令源:用户内联 sglang 命令 > `/home/server_command.sh`
- workload 参数(所有变体**同一套**):`EVAL_DATASETS`(默认 humaneval,math_500,gsm8k)、`EVAL_BATCH=64`、`EVAL_LIMIT`(默认 None 全量)、`EVAL_ENABLE_THINKING=false`;用户给了以用户为准
- 注意:用户说 `math500` → 归一为 `math_500`;点名数据集 → 只测点名的

## 把用户差异翻译成 spec(核心一步,仔细做)

spec 是 JSON 数组,**第一项放 baseline**(env/args 全空),后续每项只含用户点名的那个变量的差异:

```json
[
  { "label": "baseline", "description": "基线(原命令)" },
  { "label": "spec-off", "description": "关 EAGLE:env SGLANG_ENABLE_SPEC_V2=0",
    "env": { "SGLANG_ENABLE_SPEC_V2": "0" } },
  { "label": "cuda-graph-off", "description": "关 cuda graph(布尔开关,追加参数)",
    "args": { "add": ["--cuda-graph-backend-prefill", "disabled", "--cuda-graph-backend-decode", "disabled"] } },
  { "label": "page-64", "description": "page-size 64(替换基线里的 16)",
    "args": { "set": [["--page-size", "64"]] } },
  { "label": "no-topo", "description": "去掉 NCCL_TOPO_FILE(env_unset)",
    "env_unset": ["NCCL_TOPO_FILE"] }
]
```

- `env` = 设/覆盖 export;`env_unset` = 去掉(追加 `unset`);布尔开关/追加标志用 `args.add`;
  `args.set` 会**覆盖基线同名选项值**;**不要**塞与变量无关的差异。
- 生成器会自动保留基线里的 export 行与 serve 命令,你只需给增量。
- label 唯一、不含 `/`;spec 中不得出现基线未含又不属于变量说明的改动。

## 前置(任一不满足 → "输入错误"汇报退出)

1. `echo ok` 能跑;
2. 命令源可得:`/home/server_command.sh` 或用户内联命令(parser metadata 校验一次);
3. 弄清"变量是什么、有哪几档/开关状态"(不确定就向用户确认,不要猜)。

## 执行

1. 把基线命令写成文件(内联→规范化;否则直接指 `/home/server_command.sh` 路径),记为 `BASELINE`;存在且 parser 校验通过;
2. 建 spec 文件:`CMP_SPEC="${RUNS_DIR:-/home/runs}/cmp-eval-spec-$(date +'%Y%m%d_%H%M%S').json"`,把上一步翻译结果写成该文件;
3. **启动前列出全部变体与各自差异(一行一个),让用户过目;变体数 > 8 必须先得到用户确认**,否则不跑;
4. 执行(固定命令,照抄;workload 参数只加用户给的):
   ```bash
   bash "${AUTO_WORK:-/home/auto-work}/steps/cmp-sweep.sh" \
     --mode eval \
     --baseline-command "${BASELINE}" --spec "${CMP_SPEC}" \
     [--datasets …] [--limit N] [--batch N] [--thinking true|false] \
     [--parallel N]   # 默认串行;用户明确要求"同时跑/并行 N 档"时才加
   ```
   - **并行注意**:`--parallel N` 让至多 N 个变体同时跑(每档独立 start-server,自动等卡/锁卡);
     并行时各档可能落在**不同卡组**,汇报须注明;要严格同卡组对照请保持串行(不传 --parallel);
   - 退出 0 → 全部 ok;退出 4 → 部分失败(cmp.json 已写);退出 2 → 输入/校验错(没启动任何服务);
5. 读 `cmp.json`:按 `variants[]` 顺序,每项 `ok`/`run_result`/`result_json`/`release_result`;
   - `ok=false` 的变体单独说明原因(读其 start.out/run.out 或 result_json),**不许用缺失冒充 0 分**;
6. 每个 ok 变体:从 `result_json`(eval.json)与对应 run_dir 里 EvalScope 的 `outputs/` 报告读各数据集分数/样本数;
7. 汇报对照表(每变体一行):数据集列 × 变体列,单元格 = 分数(样本数),并列出差异说明、失败原因;指出最佳配置,不把相关写成因果。

## 汇报格式

```
结果: 对照评测 <ok|partial>(N 个变体,elapsed=…)
- cmp.json: <路径>(variants[] 含各 ok/run_result/产物路径)
- 对照表: 数据集 \\ 变体 | baseline | … —— 单元格分数(样本数);失败格注明原因
- 服务: 每变体跑完即停(release_result 记录;失败的 release 若有,说明是僵尸误判还是真失败)
- 产物: 每变体产物在 cmp.json.variants[].vdir
```

## 纪律

> 0. **选卡是代码职责**:start-server 负责等卡/锁卡/选端口/注入 `HIP_VISIBLE_DEVICES`(parser 会覆盖命令文件里的设备与端口)。本任务**禁止自行探测 GPU(rocm-smi)、读取 step 实现、猜测或改动设备变量**;前置只需 `echo ok` + 命令文件 parser 校验 + (声明已有服务时)确认 started.json。

1. 变体差异**只含用户声明的那个变量**;workload 参数对所有变体**同一套**(这是可比性的前提);
2. 只按 `cmp.json` 分流;失败变体如实标注,不阻断其它;
3. 命令/驱动照抄 step;spec 的生成与确认是你在本任务里唯一需要"写"的东西;
4. 本轮 cmp-sweep 每变体跑完即停服释放,不保留服务;
5. 一次一任务,汇报后结束。
