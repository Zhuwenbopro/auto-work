# auto-work —— 服务器侧 headless DSH 自动工作方案(设计讨论记录)

> 创建于 2026-09,基于本地会话"接 HANDOFF 后如何构建自动工作方案"的多轮讨论。
> 相关:上一阶段落地文档见 `../dsh-server-setup/`;工作总结技能仓库(本地克隆)见 `../skills/`(远端 `github.com/Zhuwenbopro/skills`)。
> 本文档记录**已达成共识的框架**与**尚未拍板的开放问题**,是后续实现的蓝本。

---

## 1. 背景与目标

- 环境 A(服务器):VSCode Remote + 临时 Docker 容器,做 sglang 在**海光 DCU** 上的算子适配/框架调优/bug 解决。镜像内网构建不可改;`/sgl` = host `/public/home/zhuwenbo`,跨容器持久共享。
- 服务器容器内已装 DSH **headless**(0.1.2-rc.1,`dsh --profile headless "任务"`,一次一任务、跑完即退、0=完成 1=出错),API key 与 profile 修复均已固化(见 dsh-server-setup/HANDOFF.md)。
- **本方案目标**:在"一次一任务、无 GUI、无交互追问"的 headless 之上,构建**自动化工作方案**——让多步工作(性能调优、bug 分析、批量评测/压测)能够按预定义的路线稳定、可续跑地执行,而非依赖单次对话的临场发挥。

## 2. 本质问题:如何让 agent 的行动路线"严格确定"

- agent 本质是 **LLM 驱动循环**:每轮由模型决定调用什么工具/怎么调。**skill 只是压缩单步不确定性的指令+CLI 工具包**,不能保证"路线"确定。
- 要让路线严格确定,拓扑必须放到**模型之外**的编排层。
- DSH 现成机制(查证自本地 deepseek-harness checkout,`docs/subsystems/workflow.md`):
  - **workflow 子系统** = "脚本即拓扑":一段 JS 脚本在独立 worker 里执行,控制流完全由代码决定;叶子 = `agent()` 子代理(支持 JSON Schema 结构化输出校验);失败纪律硬性——叶子失败得 `null`(可编程处理),**误用钩子 `fatal` 直接杀死 run**,不静默降级。
  - **诚实边界**:路由可以严格;叶子(agent)内部推理仍非确定——不确定性只能被"圈住"(schema/exit code/固定输出契约/checkpoint),不能被消灭。
  - **版本/形态差异**:服务器是 0.1.2rc1 headless,比本地 checkout(0.1.3-alpha.1)旧;workflow 工具是否可用必须服务器实测(`dsh --profile headless --dump-config`),不能拿本地文档直接套。

## 3. 两种实现档位

| 档位 | 做法 | 适用 | LLM 角色 |
|---|---|---|---|
| **档 1:外部严格驱动器** | 服务器上普通 bash/python 把拓扑写成显式状态机:每节点 = 一次 headless 调用或脚本;节点结果 = exit code + 结构化输出;转移代码写死(成功→X,失败→恢复节点Y/记卡点/回报) | 生命周期/流水线机械、可枚举成功失败的工作(GPU 评测、压测、编译、对照实验调度) | 只在节点内部执行,路由零 LLM |
| **档 2:workflow/编排编排** | 本地侧用 workflow 工具或子代理做分析→决策→派活;或带护栏的战役主循环 | 推理/分析为主的工作(调优决策、bug 调查) | 编排与分析是 LLM |

两者可组合:**拓扑(下一步谁决定)放驱动器/编排,推理(单步怎么干)放叶子**。

## 4. 工作层级:step / task / skill(已共识的框架)

三层本质是按 **LLM 密度从下往上递增** 划分;确定性随层上升而下降,契约决定层间通信。

| 层 | 定义 | LLM 角色 | 确定性 | 落地形态 |
|---|---|---|---|---|
| **step** | 原子步:一个命令/脚本可完成的确定性事件(如起一个 server、跑某个 python 文件、锁卡、健康检查) | **零 LLM** | 完全确定(exit code / 机器可读产物判定) | 纯代码叶子,可测试 |
| **task** | 多个 step 组成的目标(如 tracing、bench-serving、eval) | **薄 LLM**,只在入口(自然语言意图→参数/命令文件)与出口(读结果→报告) | 中间路由由代码/exit code 决定 | 一次 headless 自包含调用(任务提示词 + step 清单),或纯脚本同步跑 |
| **skill** | 若干 task + 分析决策组成的工作(如性能调优、错误分析) | **核心 LLM**:读结果、判断、决定下一个 task | 只确定"契约与门禁",路线开放 | 战役:STATE + 多轮 headless;或本地 workflow 编排 |

### 边界规则(防止层级塌陷,必须遵守)

1. **层间只传契约,不传散文**:step→task 传 exit code+产物(日志标记/JSON/CSV);task→skill 传结构化结果对象;skill 的判断必须基于下层验证事实,不许拿"我觉得"当证据。
2. **step 内不允许 LLM 决策**(出现"如果…就智能判断"说明它其实是 task,要下沉);**task 不允许把 step 失败消化成成功**(沿用 DSH workflow 失败纪律:失败→记录→按预定失败分支走,不静默继续)。
3. **step 必须可重跑**(幂等或可断点):长 step(如压测数小时)+ 临时容器 ⇒ 需要 task 级 journal(跑到第几步、产物在哪),中断可续。

## 5. 现有工作总结技能仓库的归类(重命名结论)

`github.com/Zhuwenbopro/skills`(已克隆到 `../skills/`)——原仓库把 8 个都叫 "skill",按新层级大部分实为 **task**:

| 仓库原名 | 新层级 | 归类理由 |
|---|---|---|
| `eval` | **task**(档 1) | GPU 等锁→起服务→EvalScope→清理;525 行 auto_eval.sh 已把成败编进 exit code/日志标记;skill 层薄壳 |
| `bench-serving` | **task**(档 1) | 同上,共享同一生命周期核心 |
| `tracing` | **task**(档 1) | 同上,关 CUDA graph 采 trace |
| `compile-sglang` | **task**(档 1,可去 LLM) | 纯命令链 + 验证,无 GPU 仲裁/服务生命周期 |
| `compare-eval` | **task**(档 1 + 薄 LLM) | 并发调度/汇总是确定性驱动器(dispatch_plan.sh);生成变体命令与 plan.json、读 summary 下结论需 LLM |
| `experimental-bug-investigation` | **skill**(档 2) | 复现→假设→实验→根因→修复→验证;开放拓扑靠门禁(先复现才能写根因、先验证才能写已证实)+ 报告账本纪律收敛 |
| `bug-experience-writing` | skill 内**子 task**(档 2 规则门禁) | 把已验证结论蒸馏成经验条目;主要是 rubric 检查 + 一小步摘要 |
| `hello-skill` | 忽略/删 | 演示用 |

### 目标仓库布局草案

```
auto-work/
  steps/    # 纯代码叶子(无 LLM、可测试):等卡、起服务、健康检查、跑评测、清理…
  tasks/    # 每个 = 自包含任务提示词模板 + 引用的 step/自动化:
            #   eval、bench-serving、tracing、compile-sglang、compare-eval
  skills/   # 每个 = 战役定义 + STATE 模板 + 决策规则:
            #   perf-tuning(性能调优)、bug-investigation(错误分析)
```

- **task 层**放服务器:一次 headless 调用跑一个 task;或纯脚本同步跑。
- **skill 层**看情况:主循环在本地(我)每轮派活+分析,服务器只执行 task;或主循环也在服务器(驱动器 + STATE.md + 轮数/预算护栏),挂那自动连跑。

## 6. 移植时必须处理的关键差异(单次任务化)

现有 SKILL.md 是为**对话式、可跨轮**的 Copilot 写的("启动→回报 PID→之后轮次再查状态/叫停")。headless 一次一任务,须改为:

- 每个 task = **自包含提示词模板**(像 dsh-server-setup/templates/task-prompt.md),指路到固定 automation 目录;需要 LLM 判断的只有命令提取/参数映射/结果解读。
- 起后台 worker + journal,"查状态/叫停" = 另开一次 headless 任务读文件;或 bash 层提供**同步模式**(跑到完成/失败,exit 0/1,一次给最终总结)。
- 环境注意:服务器脚本 LF 行尾、UTF-8 编码(本地 Windows 控制台直读中文会乱码,读文件用 UTF-8)。

## 7. 开放问题(尚未拍板)

1. 顶层叫 **skill** 是否会与 DSH 自身"skill 目录/工具包"语义冲突?复用该名还是改叫 campaign/战役?
2. 旧仓库"大部分是 task"的重命名结论是否认可?(决定是否重组仓库目录)
3. task 内"薄 LLM"到底出现在哪几个点,需要以样板验证;先拿 `eval`(档 1 参考实现)还是 `bug-investigation`(档 2 样板)验证层级?
4. 服务器 0.1.2rc1 headless 实际挂了哪些工具(workflow/skill/subagent 是否存在)→ 需 `--dump-config` 实测后定档。
5. skill 主循环放本地还是服务器?(关联"本地能否 ssh 直驱/或沿用粘贴协作"的旧问题)

## 8. 下一步候选

- [ ] `dsh --profile headless --dump-config` 实测服务器 headless 工具面,给档位定案
- [ ] 按样板 task 改造 `eval`:拆 step 清单 + 写自包含任务提示词,验证全链路
- [ ] 依样板推广到其余 GPU 类 task(bench-serving/tracing/compile-sglang/compare-eval)
- [ ] 设计 `bug-investigation` skill 的战役形态(门禁+STATE+经验库),作为档 2 样板
- [ ] 把本框架落成 auto-work 仓库结构(上述布局草案),skill 与 task 分层入库

## 9. 当前 auto-work 布局与部署切换

```
auto-work/                          # 部署在容器 /home/auto-work(代码根)
  config.env                        # ★ 部署配置:改这里或调用时用环境变量覆盖
  lib/server_command_parser.py      # 命令校验/执行核心(step 通过 ../lib 自动发现)
  steps/start-server.sh             # step:启动 SGLang 服务(等卡→锁卡→选端口→健康检查)
  steps/examples/server_command.example.sh
  tasks/start-server.task.md        # 形态 B 任务提示词(harness 读)
  scripts/run-start-server.sh       # 形态 B 入口(拼提示词+请求→dsh headless)
  skills/start-server/SKILL.md      # DSH 原生 skill(拷到 $DSH_HOME/skills 后被自动发现)
                                        # 代码根之外,不再生成运行时目录

/home/runs/                         # 运行时数据根(独立于代码根;默认 /home/runs,可用 RUNS_DIR 覆盖)
  <时间戳>/                         # 每轮请求一个目录:server_command.sh + step 结果(start-<t>/)。
                                    # 原 work/ 与 runs/ 两个目录已合并于此,auto-work 下不再生成。
```

**部署与切换(不再改代码)**:优先级 = 调用时环境变量 > `config.env` > 内置默认。

```bash
# 默认:AUTO_WORK=/home/auto-work;RUNS_DIR=/home/runs;DSH_HOME/DSH_ENV_FILE 仍在 /sgl(/sgl/.dsh-home,/sgl/dsh-env.sh)
export AUTO_WORK=/custom/auto-work          # 只换 auto-work 位置
export RUNS_DIR=/home/runs                  # 只换运行时数据根(默认 /home/runs,即原 work/+runs/ 合并处)
export DSH_ENV_FILE=/sgl/dsh-env.sh         # dsh 环境文件
bash "${AUTO_WORK:-/home/auto-work}/scripts/run-start-server.sh" "..."
```

> 说明:step 脚本自身可移植(`../lib` 自动发现 parser);启动健康等待上限默认 3600s(1h,超时即 TIMEOUT);任务提示词与 skill 里保留了 `/home/auto-work` 代码默认值与 `/home/runs` 运行时默认值,但均写明"以消息中的本轮参数 / 环境变量为准",由 wrapper 注入实际路径。
