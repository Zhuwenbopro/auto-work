# auto-work —— 服务器侧 headless DSH 的自动化执行框架

> 目标:在服务器容器里基于 DSH **headless**(一次一任务、跑完即退)构建可复用的自动化执行框架:
> 把"启动服务 / 编译 / 版本适配 / 评测 / 压测 / profiling / 自我维护"这类工作做成 **确定性 step + 薄 skill**,
> 让 harness 用一句话就能稳定执行,并保证每个动作可验证、可留痕、可回退。

---

## 1. 设计要点(简短)

- **层级**:`step`(原子,零 LLM,exit code/产物判定)← `task`(step 组合,薄 LLM)← `skill`(task+分析决策,LLM 编排)。
  本仓库当前以 **step + skill** 两层为主(task 提示词那套 wrapper 形态已废弃)。
- **确定性优先**:所有机械动作(启动、workload、收尾、判定)都写成确定性 step,LLM 只做需要理解请求/读产物汇报的一步。
- **workload step 无资源副作用**:`run-eval` / `run-bench` / `run-profile` 只吃 `started.json`,
  不起服、不停服、不碰 GPU/端口锁;起/停由 skill 组合 `start-server` + `release-server`。
- **一次一任务**:headless 每个进程只干一件事;跨轮记忆/证据走文件(每轮产物目录 + 台账)。
- **执行形态 = DSH 原生 skill**:skill 放进 `$DSH_HOME/skills/<name>/SKILL.md`,headless 按 description 自动加载,无需 wrapper/长路径。
- 权限前提:headless 执行 bash 需要 `DSH_PERMISSION_MODE=danger-full-access`(一次性容器内使用)。

## 2. 当前仓库结构

```
auto-work/                       # 代码根(默认部署到容器 /home/auto-work)
├─ config.env                    # ★ 部署配置(代码根/运行时根/DSH 根),环境变量可覆盖
├─ .gitignore
├─ README.md
├─ lib/                          # 受管副本与共享库(step 自动发现)
│  ├─ server_command_parser.py   #   sglang 启动命令解析/校验/执行核心
│  ├─ eval_command.sh            #   EvalScope 执行口径(测试部门权威,整份搬运,不改)
│  ├─ bench_serving.sh           #   bench_serving 网格口径(测试部门权威,整份搬运,不改)
│  ├─ run_profile.py             #   Torch Profiler 采集客户端(整份搬运,不改)
│  └─ run_common.sh              #   run-* step 共享库(读 started.json/健康看门狗/进程组终止/JSON 写)
├─ steps/                        # 确定性 step(零 LLM,可单独跑)
│  ├─ start-server.sh            #   单次真实启动:等卡→锁卡→选端口→起服务→等 /health(→ started.json)
│  ├─ release-server.sh          #   按 started.json 停服 + rocm-smi 复核(→ release.json,幂等)
│  ├─ run-eval.sh                #   EvalScope workload:跑受管 eval_command.sh(→ eval.json)
│  ├─ run-bench.sh               #   bench_serving workload:跑受管 bench_serving.sh(→ bench.json + all.csv)
│  ├─ run-profile.sh             #   profiler workload:跑受管 run_profile.py(→ profile.json + trace)
│  ├─ adapt-attempt.sh           #   适配循环的单次"启动+证据采集"(产 attempt.json)
│  ├─ curl-smoke.sh              #   启动成功后 curl 冒烟 + 确定性乱码判定(smoke.json)
│  ├─ compile-sglang.sh          #   编译安装 sglang-das(async/wait/--sync)
│  ├─ examples/server_command.example.sh
│  └─ start-server.md            #   start-server step 的契约文档
├─ skills/                       # DSH 原生技能(安装到 $DSH_HOME/skills 后被 headless 自动发现)
│  ├─ start-server/SKILL.md      #   用给定命令启动 SGLang 服务并汇报(PID/端口/GPU/日志)
│  ├─ compile-sglang/SKILL.md    #   编译/安装 sglang(默认源码 /home/sglang-das)
│  ├─ adapt-start/SKILL.md       #   新版本启动适配循环(照 origin/v0.5.12_dev 移植;成功用 release-server 收尾)
│  ├─ eval/SKILL.md              #   EvalScope 评测(默认评测完停服释放;附着模式可不停)
│  ├─ bench-serving/SKILL.md     #   bench_serving 压测(长度对×并发网格;默认压完停服释放)
│  ├─ tracing/SKILL.md           #   Torch Profiler 短 trace 采集(默认采完停服释放)
│  └─ fix-auto-work/SKILL.md     #   自我维护:改 auto-work 自身文件并同步到技能安装目录
└─ tests/                        # 服务器端回归护栏(fake 客户端,不碰 GPU;见 tests/README.md)
   ├─ run_common.test.sh
   ├─ eval_command.test.sh
   ├─ bench_serving.test.sh
   └─ README.md
```

## 3. 运行时布局(代码根与运行产物分离)

| 位置 | 默认值 | 内容 |
|---|---|---|
| 代码根 `AUTO_WORK` | `/home/auto-work` | 上面的仓库内容(部署用 git clone/pull) |
| 运行时根 `RUNS_DIR` | `/home/runs` | 每轮请求一个目录:`server_command.sh` + step 结果(`start-<ts>/…`、`eval-<ts>/…`、`bench-<ts>/…`、`profile-<ts>/…`、`adapt-<ts>/iter-NNN/…`) |
| DSH 配置根 `DSH_HOME` | `/sgl/.dsh-home` | 技能安装目录 `skills/<name>/SKILL.md`、profiles、key |
| dsh 环境文件 `DSH_ENV_FILE` | `/sgl/dsh-env.sh` | 含 `DSH_PERMISSION_MODE=danger-full-access` |

切换全部走环境变量 > `config.env` > 内置默认;代码里不留写死运行时路径。

## 4. 技能清单与触发

安装:把 `skills/*` 拷到 `$DSH_HOME/skills/`(名字全局唯一、kebab-case)。headless 消息里点名技能最稳:
"用 **<技能名>** 技能:<要做的事>"。description 也支持自动匹配。

| 技能 | 一句话用途 | 依赖 step | 典型触发 |
|---|---|---|---|
| `start-server` | 用给定命令(内联或 `/home/server_command.sh`)启动服务并汇报 | start-server | `用 start-server 技能启动服务,命令用 /home/server_command.sh` |
| `compile-sglang` | 编译安装 sglang-das(镜像已含依赖,不装 requirements) | compile-sglang | `用 compile-sglang 技能编译 sglang` |
| `adapt-start` | 新版本启动报代码错误 → 照 `origin/v0.5.12_dev` 移植 → 循环到能启动 → curl 验乱码 → release-server 收尾 | adapt-attempt + curl-smoke + release-server | `用 adapt-start 技能:适配当前 sglang 让它能启动,命令用 /home/server_command.sh` |
| `eval` | 对服务跑 EvalScope 评测(数据集/limit/batch/thinking),默认评测完停服释放 | start-server + run-eval + release-server | `用 eval 技能评测 math500,limit 32` |
| `bench-serving` | 对服务跑 bench_serving 压测(长度对×并发),默认压完停服释放 | start-server + run-bench + release-server | `用 bench-serving 技能压测 4096/1024,并发 1,2,4,8` |
| `tracing` | 对服务采 1 次 Torch Profiler trace(默认采完停服释放) | start-server + run-profile + release-server | `用 tracing 技能采集 profile,输入长 2048` |
| `fix-auto-work` | 改 auto-work 自身(skill/step/config)并同步安装目录 | —(文件操作) | `用 fix-auto-work 技能:以后 start-server 没贴命令时直接用 /home/server_command.sh` |

start-server 结果码:`0 OK / 2 输入错 / 3 RETRYABLE / 4 FATAL / 5 TIMEOUT`;产物 `started.json`
(pid/pgid/port/gpus_csv/**model_path**/health_url/server_log/run_dir)或 `failed.json`。
成功时服务保持运行、锁归服务进程;**收尾统一走 `release-server.sh`**(TERM→宽限→KILL + rocm-smi 复核,
产物 `release.json`,`result = released|already_gone|failed`,幂等)。

run-* workload 结果码:`0 OK / 2 输入错 / 4 失败(含 server_died) / 5 整体超时`;
产物 JSON 的 `result` 字段给细类(eval/bench: `ok|failed|server_died|timeout`;
profile: 另有 `no_trace`)。skill 只按 JSON 分流汇报,不猜日志。

## 5. 评测/压测/profiling 的任务形态

```
模式 A —— 全生命周期(默认,无人值守):
  start-server.sh …        → started.json
  run-eval.sh / run-bench.sh / run-profile.sh --server-root …   → *.json
  release-server.sh …      → release.json(默认停服释放;用户显式要求才保留)
模式 B —— 附着已运行服务:直接跑 run-* --started-json <外部路径>,不停服务。
```

行为权威(测试部门脚本,整份搬运进 `lib/`,不许"顺手改进"):EvalScope 调用形状/数据集
分组/gen-config 合并(humaneval 4096、math_500 20480、thinking 注入)、bench 网格与
21 列 all.csv 口径(`--tokenizer` 恒为本地模型目录,不用 served 短名)、run_profile.py 的
`/start_profile` payload 与退出码。详见 `docs/design-eval-bench-tracing.md` 的移植红线。

## 6. adapt-start 的工作方式(核心战役技能)

```
循环(≤ MAX_ITER=15):
  adapt-attempt.sh(每轮)→ attempt.json{ok,stage,signature,sglang_file,sglang_line,server_log,started_json,failed_json}
  判定(只按 JSON 字段):
    ok            → curl-smoke 判乱码 → verdict=ok 用 release-server.sh 收尾(停服+复核)
    非代码类失败  → 原地退出汇报
    无进展/循环(signature 与任一历史轮重复)→ git checkout 回退本轮改动 → 原地退出汇报
  有进展 → 移植:git show origin/v0.5.12_dev:<文件> → edit 单点最小修改 → 记录 → 下一轮
产物:RUNS_DIR/adapt-<ts>/
      MODIFICATIONS.md(总台账:编号|问题/日志|方案 diff|验证结果)
      iter-NNN/{server_command.sh, start-*/…, attempt.json, record.md, change.diff}
纪律:绝不 git commit;改动只留 /home/sglang-das 工作区 diff;每轮必须有真实启动证据。
```

## 7. 服务器部署与使用

```bash
# 1) 部署代码根(容器内)
git clone https://github.com/Zhuwenbopro/auto-work.git /home/auto-work
# 或已存在则更新: cd /home/auto-work && git pull

# 2) 前置
#    执行权限(dsh-env.sh 里应已含):
grep DSH_PERMISSION_MODE /sgl/dsh-env.sh   # → export DSH_PERMISSION_MODE=danger-full-access
#    命令源(可选,供 start-server/adapt-start/eval 等复用):
test -f /home/server_command.sh

# 3) 安装技能(headless 每次新进程才看到;代码根与技能目录是两处)
cp -r /home/auto-work/skills/* /sgl/.dsh-home/skills/

# 4) 探针 + 回归护栏
dsh --profile headless "列出你的技能目录里的技能名称"
bash /home/auto-work/tests/run_common.test.sh
bash /home/auto-work/tests/eval_command.test.sh
bash /home/auto-work/tests/bench_serving.test.sh

# 5) 触发(示例)
cd /home
dsh --profile headless "用 start-server 技能启动服务,命令用 /home/server_command.sh"
dsh --profile headless "用 adapt-start 技能:适配当前 sglang 让它能启动,命令用 /home/server_command.sh"
dsh --profile headless "用 eval 技能评测 math500,limit 32"
dsh --profile headless "用 bench-serving 技能压测 4096 1024,并发 1,2,4,8"
dsh --profile headless "用 tracing 技能采集 profile,输入长 2048"
```

## 8. Git 工作流(保持三处一致:GitHub = 源,本地 = 编辑,服务器 = 执行)

```bash
# 本地改完发布:
git -C auto-work add -A && git -C auto-work commit -m "..." && git -C auto-work push

# 服务器更新:
cd /home/auto-work && git pull
cp -r /home/auto-work/skills/* /sgl/.dsh-home/skills/   # 改了任何 skill 后都要重装
```

> 坑:改了技能但忘了拷到 `/sgl/.dsh-home/skills/`,headless 仍用旧版;改了 step 但忘了 commit/pull,服务器用旧 step——两边契约会悄悄不一致。

## 9. 开放问题 / 下一步候选

- [ ] 服务器冒烟验证三条新链路(eval → bench → tracing)后,再评估从 `Zhuwenbopro/skills` 仓库**择机删除**旧 automation(已停用,保留对照)
- [ ] `compare-eval`(多配置并发对照)留作后续,届时需 GPU 组分发器
- [ ] 探索 0.1.3+ 的 workflow 子系统做更复杂的本地编排
- [ ] 长调优战役(性能调优)状态文件化,复用 step/skill 分层
