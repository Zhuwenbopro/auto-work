# 设计:eval · bench · tracing 移植为 step + skill(定稿 v1,已确认)

> 状态:草案(用户确认中)。配套实现仓库:auto-work;移植来源:`Zhuwenbopro/skills` 的
> `eval/bench-serving/tracing` 三份 Copilot 形态 automation(测试部门脚本,视为行为权威)。
> 原则:**忠实移植执行逻辑,不自创口径**;只把它们拆成"确定性 step + 薄 skill",换掉外层 Copilot 交互壳。

## 0. 已确认决策(与用户的讨论结论)

| 决策点 | 结论 |
|---|---|
| 范围 | eval(EvalScope)+ bench + tracing(profiler)三条链路;compare-eval 留后 |
| 执行逻辑权威 | eval 处理逻辑以 `skills/eval/automation`(测试部门)为准;bench 延续旧 `2eval.sh`/`bench_serving.sh` 客户端口径;不另起炉灶 |
| step 拆分 | workload step(`run-eval`/`run-bench`/`run-profile`)只吃 `started.json`,零生命周期代码;新增公共 `release-server` step;起/停由 skill 组合 |
| 收尾默认 | 一次评测/压测结束 → 默认停服释放;用户显式要求才保留 |
| 执行形态 | 同步等完 + 整体超时(确定性 timeout 判定) |
| 层级纪律 | step = 零 LLM 确定性;skill = 编排/选参/汇报;LLM 只读 JSON 决策,不临场发明命令 |

## 1. 调用形态(一次完整任务)

```
模式 A —— 全生命周期(默认,无人值守):
  bash steps/start-server.sh --server-command <cmd> …      → started.json(OK 后服务在跑、锁归服务)
  bash steps/run-eval.sh --started-json <…>  [--config …]  → eval.json        (或 run-bench / run-profile)
  bash steps/release-server.sh --started-json <…>          → 停服 + rocm-smi 复核,资源释放
  └ 汇报(读各 JSON,不猜日志)

模式 B —— 附着已运行服务(外部/他人启动):
  bash steps/run-eval.sh --started-json <外部路径> …       → 只跑 workload,不碰锁、不停服务
```

- workload step 全部**无副作用于资源**:不锁卡、不起服、不停服;结果目录自含(started.json 里的 server_log/run_dir 供引用)。
- `release-server.sh` 同时替换 adapt-start 成功路径里手写的停服段落(同一语义,单一实现)。
- ⚠️ **依赖一个前置小改动**:started.json 目前没有 `model_path`,而 bench 的 `--tokenizer` 与 eval 的 `--model` 都需要**本地模型目录**。拟给 start-server.sh 的 started.json **追加 `model_path` 字段**(parser metadata 早已解析,纯增量、向后兼容)。

## 2. 运行时布局与命名(对齐既有)

```
RUNS_DIR(/home/runs)/
├─ eval-<ts>/         run-eval 一轮:server_command.sh?、eval_command.sh(拷贝)、
│                     start-<ts>/(start-server 产物,模式 A)、eval.log、eval.json
├─ bench-<ts>/        run-bench 一轮:…、bench.log、<每组合 .log/.jsonl>、all.csv、bench.json
├─ profile-<ts>/      run-profile 一轮:…、profile.log、profile/*.trace.json.gz、profile.json
└─ adapt-<ts>/        (既有,不动)
```

workload step 复用的输入:started.json 的 `port/gpus/model_name/model_path/server_log/run_dir`。

## 3. 新 step 契约草案

### 3.1 release-server.sh(公共,先做)
- 入参:`--started-json PATH`
- 行为:读 pid/pgid → `TERM -PGID`(guard:pgid 非数字或 == 自身 → 退化为单 PID)→ 每秒轮询至 SHUTDOWN_TIMEOUT → `KILL`;GPU/端口锁随进程组退出自动释放(flock 随 fd 关闭),**锁文件不删**;`rocm-smi` 复核 gpus 已空闲。
- 产物:`release.json {result: released|already_gone|failed, pid, pgid, gpus_checked, …}`
- 幂等:进程已死 → `already_gone`,仍复核。

### 3.2 run-eval.sh(workload)——忠实移植 eval_command.sh + 单发语义
- 入参:`--started-json PATH`;可选 `--eval-command PATH`(默认受管副本 `${AUTO_WORK}/lib/eval_command.sh`,可指回测试部门原文件)。
- 配置键(沿用旧名,值即契约):`EVAL_DATASETS` / `EVAL_BATCH` / `EVAL_LIMIT`(None=全量,float=前 N%)/ `EVAL_ENABLE_THINKING`(默认 false)。
- 行为(忠实移植):
  1. 拷贝 eval_command.sh 进本轮目录(留痕),export:`MODEL_PATH/MODEL_NAME/TP_SIZE/PP_SIZE/HOST/PORT/RUN_DIR/HIP_VISIBLE_DEVICES` + EVAL_*;
  2. `setsid bash eval_command.sh > eval.log 2>&1 &`;看门狗每 2s:服务 `/health` 失败(或自起模式 pid 死)→ 服务死亡分支;`wait` 收真实退出码;
  3. evalscope 调用形状、gen-config 合并/分组、dataset-args、thinking 注入 —— **整份照搬,一字不改**(红线见 §4.1)。
- 判定:`eval.json {result: ok|failed|server_died|timeout, legacy_exit, stage, datasets, eval_log, server_log, run_dir, started_at, elapsed_s}`;明细 = EvalScope work-dir 产出,不做脚本内汇总(与旧版一致)。
- 超时:可选整体 `--timeout-s`;评测中途服务死 = `server_died`,不误报为评测失败。旧退出码 10/20/125/124 记录进 `legacy_exit`/`stage` 便于对照测试断言。

### 3.3 run-bench.sh(workload)——忠实移植 bench_serving.sh 网格
- 入参:`--started-json PATH`;需要 started.json.`model_path` 作 `--tokenizer`(本地目录,**绝不用 served 短名**)。
- 配置键:`BENCH_PAIRS`(`"in out"` 逗号分隔,每项恰两正整数)、`BENCH_CONCURRENCIES`(正整数 CSV)、`CONCURRENCY_MULTIPLIER`(=每档请求数 = 并发 × 倍数)、可选 `--timeout-s`。
- 行为(忠实移植):
  1. 先写 all.csv 表头(21 列,逐字,见 §4.2);export 上述 BENCH_* + MODEL_NAME/HOST/PORT/RUN_DIR;
  2. 双层循环(pairs × concurrencies),每次单条压测命令(逐字,见 §4.2):`python3 -m sglang.bench_serving --backend sglang --base-url http://HOST:PORT --tokenizer "$MODEL_PATH" --dataset-name random-ids --random-range-ratio 1 --random-input-len … --random-output-len … --request-rate inf --max-concurrency … --num-prompts … --output-file <run_dir>/<model>-<batch>-in<in>-out<out>.jsonl`,`2>&1 | tee <同名>.log`(pipefail 保退出码);
  3. 指标从 .log 按**行首前缀**提取 20 项(TTFT/TPOT/ITL 的 mean/p95/p99、各种 throughput 等)→ 追加 all.csv;无显式 warmup,request-rate=inf;
  4. 看门狗:压测期间服务死 → server_died 分支。
- 判定:`bench.json {result: ok|partial|failed|server_died|timeout, legacy_exit, rows:[{input,output,request_rate,num_prompts,max_concurrency,concurrency,peak_conc,duration_s,rps,gen_throughput_tok_s,total_throughput_tok_s,peak_output_ttpt,mean/p95/p99_ttft,tpot,itl}], all_csv, bench_log, server_log, run_dir, elapsed_s}`。结果文件命名沿用 `<model>-<batch>-in<in>-out<out>.{log,jsonl}` + `all.csv`,审计可回溯。

### 3.4 run-profile.sh(workload)——忠实移植 run_profile.py
- 入参:`--started-json PATH`;配置键:`PROFILE_INPUT_LEN`(4096)/`PROFILE_OUTPUT_LEN`(3)/`PROFILE_WARMUP_OUTPUT_LEN`(1)/`PROFILE_REQUEST_TIMEOUT`(600)/`PROFILE_TRACE_TIMEOUT`(180)。
- 行为(忠实移植,run_profile.py 整文件搬运):
  1. export `SGLANG_TORCH_PROFILER_DIR=$RUN_DIR`;`setsid python3 run_profile.py --url http://127.0.0.1:PORT --output-dir RUN_DIR/profile --input-len … --output-len … --warmup-output-len … --request-timeout … --trace-timeout … > profile.log 2>&1 &`;退出码**原样透传**(0/1/2);
  2. run_profile.py 序列:warmup 1 请求 → `POST /start_profile`(payload 硬编码:`num_steps:3, activities:[CPU,GPU], profile_prefix:"prefill1-decode2", profile_by_stage/merge_profiles:false`)→ 1 个 follow-up generate → finally `/stop_profile`(失败仅 warning)→ 每 2s rglob `RUN_DIR/profile` 找 `*.trace.json.gz|*.trace.json|*.json`(排除 server_args.json、空文件),超时 stderr + return 2;
  3. 看门狗同 eval(服务死 → server_died)。
- 判定:`profile.json {result: ok|no_trace|failed|server_died|timeout, exit_code, trace_file, profile_log, server_log, run_dir, elapsed_s}`。
- ⚠️ 已知坑(移植时保留并写明):shell 导出的 `SGLANG_TORCH_PROFILER_DIR=$RUN_DIR` 与 payload `output_dir=$RUN_DIR/profile` 不一致 → trace 可能落在 RUN_DIR;run-profile step 应**同时轮询两处**,并如实记录 trace 实际路径。

## 4. 移植红线(行为权威,不许"改进")

### 4.1 eval
1. **无数据集名改写**(math500 不自动映射;原样校验 `^[A-Za-z0-9._-]+$`,重复报错);
2. gen-config 默认模板 + humaneval(4096)/math_500(20480) 覆盖 + deep-merge + 按"合并后全等"分组,每组一次 evalscope 调用;组顺序与旧版一致(bash 关联数组序即可,不作确定性承诺);
3. evalscope 调用形状逐字:`evalscope eval --model <本地路径> --api-url http://<ip>:<port>/v1 --api-key EMPTY --eval-type openai_api --eval-batch-size <batch> [--limit <limit>] --datasets <…逐个参数> --generation-config <cfg> --stream --seed 42 --work-dir <logpath> [--dataset-args …]`;
4. thinking 只走 `extra_body.chat_template_kwargs.enable_thinking`(占位符替换),不是 CLI 参数;
5. humaneval 特例 dataset-args:`{"humaneval":{"review_timeout":30,"filters":{"remove_until":"</think>"}}}`;
6. 退出码语义映射:启动失败 10 / 评测失败 20 / 评测期服务死 125 / 健康超时 124 → eval.json `legacy_exit` + `stage`;worker 单发不重试(评测失败不重启服务,重试由 skill 决策);
7. GPU 空闲判定(rocm-smi 第 1/6/7 列,VRAM 严格 `<`、HCU `<=`)已并入 start-server 层,run-eval **不重复实现**。

### 4.2 bench
1. all.csv 表头(21 列,逐字,首行即表头、之后逐组合 append):
   `input,output,request_rate,num_prompts,max_concurrency,concurrency,Peak_concurrent_requests,duration_s,rps,generate_throughput_tok_s,total_throughput_tok_s,Peak_output_token_throughput,mean_ttft_ms,p95_ttft_ms,p99_ttft_ms,mean_tpot_ms,p95_tpot_ms,p99_tpot_ms,mean_itl_ms,p95_itl_ms,p99_itl_ms`;
2. 单条命令逐字(§3.3.2),`--tokenizer` 恒 = `$MODEL_PATH`(本地目录);`--output-file` 指向 run_dir,模块默认输出**不得散落**到脚本目录;
3. 指标提取 = .log 行首前缀匹配,文案一变即取错值 → 提取函数原样保留,不许"更稳"重写;
4. `request_rate=inf` 时 CSV 原样写 `inf`;第 5 列 = 目标并发、第 6 列 = Successful requests(实际成功数),别"纠正";
5. 退出码:服务启动失败/超时 10、压测期服务死或 bench 失败 20 → bench.json `legacy_exit`/`stage`;单发不重试。

### 4.3 tracing
1. run_profile.py 整文件搬运(含 payload 硬编码值、trace 轮询 pattern、退出码 0/1/2);
2. `/start_profile` payload 参数不许参数化(保持 num_steps=3 / CPU+GPU / prefill1-decode2 / False×2);
3. 成功判定只看 trace 文件存在(>0),不看内容;
4. GPU 确认 = sleep GPU_CONFIRM_SECONDS 即继续(**无二次复核**,与 bench 不同,保持差异);
5. HOST 硬编码 127.0.0.1(旧 tracing 无 HOST 键)→ 新 step 用 started.json 的 health_url 推导,不引入新配置面。

## 5. 与 start-server 的重叠消解

- 旧脚本里"等卡锁卡/复核/选端口/起服/等健康/停服/EXIT trap"整块 → **全部删除**,由 `start-server.sh`(已有)+ `release-server.sh`(新增)承担;run-* 只留 workload + 服务死亡看门狗;
- 锁空间:三份旧脚本各自/共享锁目录(`auto_eval_*`、`auto_profile_*`)→ 统一进 start-server 单一实现(config.env 的 `GPU_LOCK_DIR`/`PORT_LOCK_DIR` 可配,默认 start-server 现值);旧脚本停用后不存在并发撞车;
- 差异点自动消解:bench 端口锁文件名含净化 HOST、tracing 不含、tracing 端口探测要求 IPv4+IPv6 双栈、tracing HOST 硬编码 —— 全部收进 start-server 一处实现;
- 移植后旧 automation 目录**停用但保留**(不删,保历史与对照)。

## 6. skill 层(bundle = $DSH_HOME/skills/<name>/SKILL.md)

| skill | 职责(薄 LLM) | 依赖 step |
|---|---|---|
| `eval` | 规范化数据集/limit/thinking → 组合 start-server(如需要)→ run-eval → 读 eval.json → 默认 release-server → 汇报分数 | start-server + run-eval + release-server |
| `bench` | 选长度对×并发网格/倍数 → … → run-bench → 读 bench.json → 默认 release → 汇报吞吐 | start-server + run-bench + release-server |
| `tracing` | 选输入长/输出目录 → … → run-profile → 默认 release → 汇报 trace 路径 | start-server + run-profile + release-server |

skill 纪律与 adapt-start 一致:step 命令照抄、只按 JSON 决策、不临场发明命令、汇报含产物路径。skill 只"选参数+组合",执行口径全在 step。

## 7. 移植/实现顺序(建议)

0. start-server.sh:started.json 追加 `model_path`(增量,不破坏既有字段);
1. `release-server.sh` + 测试(并让 adapt-start 成功路径改用它)——独立可交付;
2. eval:`lib/eval_command.sh`(整份搬运)→ `steps/run-eval.sh` → `skills/eval` → 冒烟(小 limit);
3. bench:搬运 bench_serving.sh → `steps/run-bench.sh` → `skills/bench` → 冒烟(短网格);
4. tracing:搬运 run_profile.py → `steps/run-profile.sh` → `skills/tracing` → 冒烟;
5. 旧 contract 测试照搬为 auto-work/tests 回归护栏(可选,见开放问题);
6. README 增补三技能行 + 开放项勾选。

## 8. 已定决策(用户 2026-xx-xx 确认,覆盖 §0 未尽项)

- [x] **started.json 追加 `model_path`**:小幅改 start-server.sh(纯增量、向后兼容);
- [x] **eval_command.sh 权威副本放 `${AUTO_WORK}/lib/` 受管**并纳入 git;config 可指回原路径兼容;测试部门后续改动直接在受管副本上做;
- [x] **旧 automation 处置 = 择机删除**:新链路验证通过后,再从 skills 仓库移除对应 automation(避免双份维护);在此之前保留对照;
- [x] **contract 测试照搬**进 auto-work/tests 作回归护栏;
- [x] **实现顺序按 §7**(0→1→2→3→4,阶段 1 release-server 先行)。
