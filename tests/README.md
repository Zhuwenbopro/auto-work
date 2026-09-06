# auto-work tests —— 服务器端回归护栏

> 这些测试**只能在服务器容器跑**(依赖 bash 4+、python3、真实文件系统语义),
> Windows 本地沙箱跑不了 bash,别在本地尝试。
> 全部测试**不碰 GPU/端口/真实服务**,只用 fake 客户端与临时目录验证契约形状。

## 运行

```bash
cd /home/auto-work/tests
bash run_common.test.sh
bash eval_command.test.sh
bash bench_serving.test.sh
bash make_variants.test.sh
```

每个脚本 `OK` 收尾、非零退出即失败。覆盖点:

| 脚本 | 验证的契约 |
|---|---|
| `run_common.test.sh` | started.json 读取/numeric 转换;`--server-root` 下最新 started.json 定位 |
| `eval_command.test.sh` | humaneval 的 evalscope 调用形状(model/api-url/batch/datasets 单参数/gen-config 合并 max_tokens=4096 + enable_thinking/thinking 注入/humaneval dataset-args) |
| `bench_serving.test.sh` | 网格单组合输出:all.csv 表头+数据行逐字、`<model>-<batch>-in<in>-out<out>.{log,jsonl}` 命名、output-file 不散落 |
| `make_variants.test.sh` | cmp 变体生成:顺序/.order、`args.set` 覆盖、`args.add` 追加、env/env_unset 重建、非法 label 报错 |

## 说明

旧仓库(测试部门)的 `test_retry/test_port_lock/test_generation_config/test_auto_bench`
针对的是已废弃的 auto_eval/auto_bench 大脚本(等卡/锁/生命周期)。移植后等卡锁卡等
生命周期统一由 `start-server.sh` 承担,这些旧断言不再直接适用;上面的测试把
**同样的行为契约**(调用形状、CSV 口径、gen-config 合并)对准新受管副本,
作为未来改动的回归基线。旧测试文件保留在原仓库对照。
