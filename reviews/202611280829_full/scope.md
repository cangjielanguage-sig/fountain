# 审查范围

- **项目根**：`/storage/Users/currentUser/Documents/cangjie/projects/fountain`
- **审查范围**：f_* 框架模块 59 个 + `fboot` / `fdbm` / `fhydra` / `fleet` / `fmq` / `fprobe`，共 65 个模块（不含 demo 工程、`scripts/` 与仓库根聚合工程）
- **基线**：工作区快照（当前检出 `sts/1.3.x`；未对照远端目标分支，工作区干净）
- **审查单元**：模块（一模块一份报告，见 `modules.md`）
- **报告目录**：`docs/review/`（`<module>_review_<20261128>.md`）
- **过程目录**：`/storage/Users/currentUser/Documents/cangjie/projects/fountain/reviews/202611280829_full`
- **并行度**：每批 4 个子 agent（不同模块并行，同模块串行）

## 审查重点

- 正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点瓶颈、低性能、存量 BUG、内存/CPU 优化空间、local mode 可行性
- 并发默认按「会被多线程调用」审：先证明安全，再谈锁粒度

## 本轮特别强调

- 用户指定范围为本仓全部 f 通道模块（框架 + fboot/fdbm/fhydra/fleet/fmq/fprobe），非 demo 示例
- 大模块（>15 源文件）拆子轮，各部分先写 `{workdir}/parts/`，最后合并为一份模块报告

## 已有性能资料

（未提供：热点类结论只能按代码结构给「疑似热点（需实测）」，并在报告里写清需要补哪种 profile / 基准）

## 排除

- demo 工程：`fdemo/`、`fdbmdemo/`、`fmqdemo/`、`frpcdemo/`、`fjsonrpcdemo/`、`fmcpdemo/`
- `scripts/`、仓库根聚合工程
- `generated/`、`third_party/`、`target/`、`.worktrees/`、`.cjo`、`.so`

## 约束

- 只读审查，不改源码、不跑构建、不提交。
- 主 Agent 不读被审源码；代码阅读由 reviewer 子 agent 完成。
- 每条发现必须给：位置（文件:行号）、来源（本次改动 / 存量）、判据（review-checklist 小节）、
  证据等级（静态确定 / 需实测 / 待确认）。
- 缺陷进「发现」，性能与内存改进进「优化可行性方案」，两者分开统计。
- 每审完一个模块，立即把该模块报告写到 `docs/review/<module>_review_20261128.md`。
