# auto-work —— 服务器侧 headless DSH 的自动化执行框架

> 目标:在服务器容器里基于 DSH **headless**(一次一任务、跑完即退)构建可复用的自动化执行框架:
> 把"启动服务 / 编译 / 版本适配 / 自我维护"这类工作做成 **确定性 step + 薄 skill**,让 harness 用一句话就能稳定执行,
> 并保证每个动作可验证、可留痕、可回退。

---

## 1. 设计要点(简短)

- **层级**:`step`(原子,零 LLM,exit code/产物判定)← `task`(step 组合,薄 LLM)← `skill`(task+分析决策,LLM 编排)。
  本仓库当前以 **step + skill** 两层为主(task 提示词那套 wrapper 形态已废弃)。
- **确定性优先**:所有机械动作(启动、采样证据、推进判定、乱码判定、清理)都写成确定性 step,LLM 只做需要理解代码/意图的一步。
- **一次一任务**:headless 每个进程只干一件事;跨轮记忆/证据走文件(每轮产物目录 + 台账)。
- **执行形态 = DSH 原生 skill**:skill 放进 `$DSH_HOME/skills/<name>/SKILL.md`,headless 按 description 自动加载,无需 wrapper/长路径。
- 权限前提:headless 执行 bash 需要 `DSH_PERMISSION_MODE=danger-full-access`(一次性容器内使用)。

## 2. 当前仓库结构

```
auto-work/                       # 代码根(默认部署到容器 /home/auto-work)
├─ config.env                    # ★ 部署配置(代码根/运行时根/DSH 根),环境变量可覆盖
├─ README.md
├─ lib/
│  └─ server_command_parser.py   # sglang 启动命令的解析/校验/执行核心(step 自动发现)
├─ steps/                        # 确定性 step(零 LLM,可单独跑)
│  ├─ start-server.sh            #   单次真实启动:等卡→锁卡→选端口→起服务→等 /health
│  ├─ adapt-attempt.sh           #   适配循环的单次"启动+证据采集"(产 attempt.json)
│  ├─ curl-smoke.sh              #   启动成功后 curl 冒烟 + 确定性乱码判定(smoke.json)
│  ├─ compile-sglang.sh          #   编译安装 sglang-das(支持 async/wait,缺 rust 自愈重试一次)
│  ├─ examples/server_command.example.sh
│  └─ start-server.md            #   start-server step 的契约文档
└─ skills/                       # DSH 原生技能(安装到 $DSH_HOME/skills 后被 headless 自动发现)
   ├─ start-server/SKILL.md      #   用给定命令启动 SGLang 服务并汇报(PID/端口/GPU/日志)
   ├─ compile-sglang/SKILL.md    #   编译/安装 sglang(默认源码 /home/sglang-das)
   ├─ adapt-start/SKILL.md       #   新版本启动适配循环(照 origin/v0.5.12_dev 移植 → 能启动 → curl 验乱码)
   └─ fix-auto-work/SKILL.md     #   自我维护:改 auto-work 自身文件并同步到技能安装目录
```

## 3. 运行时布局(代码根与运行产物分离)

| 位置 | 默认值 | 内容 |
|---|---|---|
| 代码根 `AUTO_WORK` | `/home/auto-work` | 上面的仓库内容(部署用 git clone/pull) |
| 运行时根 `RUNS_DIR` | `/home/runs` | 每轮请求一个目录: `server_command.sh` + step 结果(`start-<ts>/…`、`attempt.json`、`record.md`、`change.diff` 等) |
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
| `adapt-start` | 新版本启动报代码错误 → 照 `origin/v0.5.12_dev` 移植 → 循环到能启动 → curl 验乱码 | adapt-attempt + start-server + curl-smoke | `用 adapt-start 技能:适配当前 sglang 让它能启动,命令用 /home/server_command.sh` |
| `fix-auto-work` | 改 auto-work 自身(skill/task/step/config)并同步安装目录 | —(文件操作) | `用 fix-auto-work 技能:以后 start-server 没贴命令时直接用 /home/server_command.sh` |

start-server 结果码:`0 OK / 2 输入错 / 3 RETRYABLE / 4 FATAL / 5 TIMEOUT`;产物 `started.json`(成功交接 PID/PGID/端口/GPU/日志)或 `failed.json`(stage/error/日志路径)。成功时服务保持运行、锁归服务进程,停止用 `kill -TERM -<PGID>`。

## 5. adapt-start 的工作方式(核心战役技能)

```
循环(≤ MAX_ITER=15):
  adapt-attempt.sh(每轮)→ attempt.json{ok,stage,signature,sglang_file:sglang_line,server_log,started_json,failed_json}
  判定(只按 JSON 字段):
    ok            → curl-smoke 判乱码 → 汇报(服务保持运行)
    非代码类失败  → 原地退出汇报
    无进展/循环(signature 与任一历史轮重复)→ git checkout 回退本轮改动 → 原地退出汇报
  有进展 → 移植:git show origin/v0.5.12_dev:<文件> → edit 单点最小修改 → 记录 → 下一轮
产物:RUNS_DIR/adapt-<ts>/
      MODIFICATIONS.md(总台账:编号|问题/日志|方案 diff|验证结果)
      iter-NNN/{server_command.sh, start-*/…, attempt.json, record.md, change.diff}
纪律:绝不 git commit;改动只留 /home/sglang-das 工作区 diff;每轮必须有真实启动证据。
```

## 6. 服务器部署与使用

```bash
# 1) 部署代码根(容器内)
git clone https://github.com/Zhuwenbopro/auto-work.git /home/auto-work
# 或已存在则更新: cd /home/auto-work && git pull

# 2) 前置
#    执行权限(dsh-env.sh 里应已含):
grep DSH_PERMISSION_MODE /sgl/dsh-env.sh   # → export DSH_PERMISSION_MODE=danger-full-access
#    命令源(可选,供 start-server/adapt-start 复用):
test -f /home/server_command.sh

# 3) 安装技能(headless 每次新进程才看到;代码根与技能目录是两处)
cp -r /home/auto-work/skills/* /sgl/.dsh-home/skills/

# 4) 探针
dsh --profile headless "列出你的技能目录里的技能名称"

# 5) 触发(示例)
cd /home
dsh --profile headless "用 start-server 技能启动服务,命令用 /home/server_command.sh"
dsh --profile headless "用 adapt-start 技能:适配当前 sglang 让它能启动,命令用 /home/server_command.sh"
```

## 7. Git 工作流(保持三处一致:GitHub = 源,本地 = 编辑,服务器 = 执行)

```bash
# 本地改完发布:
git -C auto-work add -A && git -C auto-work commit -m "..." && git -C auto-work push

# 服务器更新:
cd /home/auto-work && git pull
cp -r /home/auto-work/skills/* /sgl/.dsh-home/skills/   # 改了任何 skill 后都要重装
```

> 坑:改了技能但忘了拷到 `/sgl/.dsh-home/skills/`,headless 仍用旧版;改了 step 但忘了 commit/pull,服务器用旧 step——两边契约会悄悄不一致。

## 8. 开放问题 / 下一步候选

- [ ] 把 `start-server` 之外的旧工作总结(zhangwobopro/skills 仓库的 eval/bench-serving/tracing/compare-eval)按本框架移植成 step+skill
- [ ] `release-server` 等配套 step/技能(按 started.json 的 PGID 停服务、确认端口/GPU 释放)
- [ ] 探索 0.1.3+ 的 workflow 子系统做更复杂的本地编排
- [ ] 长调优战役(性能调优)状态文件化,复用 step/skill 分层
