# 设计:cmp-eval · cmp-bench —— 单一变量对比(定稿 v1)

> 状态:定稿,已实现。思路来源:旧 `Zhuwenbopro/skills/compare-eval`(多配置并发对照)按
> 本框架重做并拆成"按结果类型"两条技能:**cmp-eval**(变量 → EvalScope 准确率)、
> **cmp-bench**(变量 → bench_serving 性能)。执行沿用"拓扑在驱动、推理在叶"。

## 已确认决策

| 决策点 | 结论 |
|---|---|
| 变体定义 | spec(JSON delta)+ 确定性生成器 `lib/make_variants.py`;skill 只翻译不手写完整命令 |
| 驱动 | 新增确定性 `steps/cmp-sweep.sh`:生成变体 → parser 统一校验(任一失败不启动)→ 每变体 start→run-*→release → 失败隔离 → `cmp.json`(默认串行,`--parallel N` 槽位并行) |
| 并行度 | 默认串行;用户要求时 `--parallel N` 槽位并行(至多 N 个变体同时跑,每变体独立 start-server,靠其等卡/锁卡/flock 保证不撞卡);`--parallel` 大于变体数自动收敛;并行时各档可能落在不同卡组(汇报须注明),严格同卡组请串行 |
| 公平性 | 所有变体用同一 workload 参数(同数据集或同网格),仅用户声明的变量不同;启动前列出全部变体、>8 先确认 |
| 汇总粒度 | cmp.json 只做装配(每变体 ok/失败 + 产物路径 + 参数);分数/指标解读由 skill 读各变体产物汇报 |

## 组件

```
lib/make_variants.py   基线 server_command.sh + spec → variants/<label>/server_command.sh + spec.json
steps/cmp-sweep.sh     驱动:--mode eval|bench;产物 ${RUNS_DIR}/cmp-<mode>-<ts>/{variants/,cmp.json}
skills/cmp-eval        用户语 → spec + 参数;跑 cmp-sweep --mode eval;汇报分数对照表
skills/cmp-bench       用户语 → spec + 参数;跑 cmp-sweep --mode bench;汇报指标对照表
```

## spec 语义(生成器契约)

```json
[
  { "label": "baseline", "description": "基线(原命令)" },
  { "label": "spec-on", "description": "开 EAGLE",
    "env": { "SGLANG_ENABLE_SPEC_V2": "1" } },
  { "label": "no-topo", "description": "去掉 NCCL_TOPO_FILE",
    "env_unset": ["NCCL_TOPO_FILE"] },
  { "label": "cuda-graph-off", "description": "关 cuda graph",
    "args": { "add": ["--cuda-graph-backend-prefill", "disabled", "--cuda-graph-backend-decode", "disabled"] } },
  { "label": "page-64", "description": "page-size 64(覆盖基线 16)",
    "args": { "set": [["--page-size", "64"]] } }
]
```

- 保留基线全部 export/unset 行与 serve 参数;`env`/`env_unset` 重建环境行;
  `args.add` 追加、`args.set` 覆盖同名选项、`args.remove` 删除选项(值启发式);
- label:唯一、`^[A-Za-z0-9._-]+$`、不含 `/`;顺序即执行顺序;每目录留 `spec.json` 审计。

## cmp.json(v1 装配层)

```json
{ "result": "ok|partial", "mode": "eval|bench", "count": N, "root": "…",
  "variants": [ { "label", "description", "ok", "start_ok", "run_result",
                  "started_json", "result_json", "release_result", "release_json", "vdir" } ],
  "elapsed_s": … }
```

退出码:0 全 ok;4 partial;2 输入/任一变体 parser 校验失败(未启动任何服务)。

并行示例:`cmp-sweep.sh --mode eval --baseline-command … --spec … --parallel 2`(省略 `--parallel` = 串行)。

## 后续候选

- ~~`cmp-sweep --parallel N`~~ 已实现:槽位式并行(默认串行,用户要求时开启)。严格"同卡组 pinning / 组分发"与深度汇总仍开放;
- 深度汇总(把 EvalScope 分数/bench rows 解析进 cmp.json);
- 与 `fix-auto-work`/`compile-sglang` 组合做"改一个参数→自动对照验证"闭环。
