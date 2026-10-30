# Pipeline 优化 tickets：每张 ticket 共用的规则

目标：pipeline 成为持续运转的 software factory。做法：
- 合入不加全局锁，靠合入后测试、发布前测试，加上自动 bisect 和 revert；
- 测试按改动影响来选，结果复用；
- 每个组件有遥测，越过阈值才发事件；
- 小 PR。

pipeline（`engine/*` 加 `docs/agents/issue-pipeline.md`）是唯一、持久的系统。`.scratch` 里的工具是临时的，不要在 `.scratch` 里实现任何机制。

## 开工
- 先读 issue 正文：`gh issue view <N> --json body,title,comments`。
- 先核实问题：在你的 worktree 上（基于当前 origin/main）确认问题仍然存在。已经修好的部分，或者前提不成立的部分，不要改，在报告里写“不适用”，并附 path:line 证据。

## 怎么改
- 做最小的完整改动。复用现有的东西：lib.sh 原语、guarded_pr_merge、deploy-culprit、node_health.py、throughput-metrics、gh-shim、调度器的 footprint 互斥。几行能写完的东西不引入新依赖。
- 不加过度防御：每一个 guard、gate 或检查，都必须对应一条真实发生过的失败。被你改成死代码的部分，直接删掉。
- 代码和文档不一致时，以今天实际在跑的代码为准；文档在同一个改动里修正，只保留一处表述，其他地方用链接，不要复制。
- 不改动任何模型、prompt 或 thinking effort 的配置（这些由维护者配置）。
- 生产：cihost 上的测试负载一律经 `.scratch/bin/cihost-test` 或 `engine/cihost-exec.py` 跑在受上限约束的 slice 里，需要在 cihost 上跑命令时这样做。只有运维负责人可以改 cihost 主机配置。不写生产数据库，不重启生产容器。
- 运行态只读：`~/.zenoforge/checkout/.scratch-supervisor/autopi/` 下的 units.json、config.json、workers 账本等由调度器和 head supervisor 写，你只读。需要重排队、改 cap、改单元状态的，写进报告的 `runtime_requests`，由 supervisor 执行。
- 例外：eval（run-eval.mjs）要调用 codex/zcode，只能在 WSL 本机跑；cihost 上没有这两个 CLI。

## 测试（非产品代码不测，写完马上落地）
- 落地前不写新测试，也不跑任何测试。改完就落地：land-direct-main 会 fast-forward live checkout，落地即生效。
- 落地后 Pipeline suites 自动跑；main 红了 fix-forward，不要回头补测。
- 例外：改到产品包（`packages/*`、`deploy/*`）的票照常走产品门禁，不适用本节。

## 落地（你自己完成）
- 在你的 worktree 里执行：`unset GH_TOKEN; TMPDIR=${HOME:-/tmp}/.zenoforge/scratch/tmp bash engine/land-direct-main.sh`。
- 退出码 75（land-lock 被占用）：等 2 分钟重试，最多 10 次。
- rebase 冲突：其他 factory ticket 也在改 lib.sh、调度器。自己 rebase 到最新的 origin/main，解决冲突，再落地。不要覆盖别人的改动。
- 如果最后判定落地车道是 PR 路径（`branch-delivery-policy` 的判定），开 PR，正文写 `Refs #<N>`，在报告里写明，不要硬推。

## 报告
- 最终 JSON 报告逐条列出验收项：met、not met 或 not applicable，并附证据（path:line、命令加退出码，或输出文件路径）。另外写明落地的 SHA。
- GitHub REST 预算：每张 ticket ≤200 次调用。核心额度剩余 <1500 时停下来报告。
- 落地后自己关票：`gh issue close <N> --comment "已落地 <SHA>（direct-main）"`；走 PR 路径的不关。
- commit trailer：Codex 用通用规则里的那条；ZCode 用 "Co-Authored-By: ZCode glm-5.3 <noreply@z.ai>"。
- 自己做，不要派子 agent：子 agent 继承你的模型与 effort，3 天里 72 个 worker 会话派了 78 个，一张票付两份 token 和 CPU。
