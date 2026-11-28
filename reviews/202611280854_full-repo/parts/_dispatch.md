# 分部分审查的公共指令（fountain-review 阶段三，2026-11-28 全量补齐）

本文件是所有 reviewer 子 agent 的公共前缀。读完本文件后，**必须再读** `D:/docs/work/cangjie/projects/fountain/skills/fountain-review/reviewer.md`，按它的模板与铁律执行。

## 固定参数

- 项目根：`D:/docs/work/cangjie/projects/fountain`
- 范围界定：`D:/docs/work/cangjie/projects/fountain/reviews/202611280854_full-repo/scope.md`
- 模块清单：`D:/docs/work/cangjie/projects/fountain/reviews/202611280854_full-repo/modules.md`
- 基线：**工作区快照**（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源写「存量」
- 报告目录：`D:/docs/work/cangjie/projects/fountain/docs/review/2026-11-28/`
- 同日已存在一份主 Agent 写的**抽样版** `<module>.md`：本轮的合并结果会另存为 `<module>_v2.md`（主 Agent 负责合并，你只写分部分报告，**不要**写 `docs/review/` 下的模块报告）

## 你这一轮的任务形态

- 你只负责**一个模块的一个部分**：文件清单是 `files/<module>.partN.txt`（模块共 `<module>.partN.txt` 里列出的文件必须**逐个读完**）
- 输出：`parts/<module>.partN.md`
- 报告严格用 `reviewer.md` 的模板（发现 / 优化可行性方案 / 待验证假设 / 文件覆盖 / 覆盖自检 / 模块统计 / 总评），但「文件覆盖」「覆盖自检」「模块统计」**只统计本部分**
- 报告开头注明「模块第 N/M 部分」
- 完成后只返回一行 `REVIEW_WRITTEN:<分报告路径>`

## 各模块的审查重点（本轮的「专项」）

| 模块 | 重点 |
| --- | --- |
| f_jit | 动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑 |
| f_chart | 渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑 |
| f_svg | SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑 |
| f_llm | 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全 |
| fprobe | 采集正确性与低开销、句柄与缓冲区生命周期、并发安全、死代码、重复逻辑 |
| fmq | 投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑 |
| f_xml | XML 解析与安全（XXE/实体展开/转义）、递归与栈溢出、OOM、死代码、重复逻辑 |
| fdbm | 多数据源与连接生命周期、启动期装配、并发安全、死代码、重复逻辑 |
| f_zip | 压缩包解析与安全（zip slip/炸弹）、流式与内存、资源释放、死代码、重复逻辑 |
| f_uring | 原生内存与数组固定、异步提交的并发正确性、close 幂等、错误路径回收 |
| f_rpc | 重试收敛、服务发现信任边界、配置解析健壮性、日志入参暴露、启动期依赖 |
| f_tui | 终端字节流读写（短写/EINTR/残缺序列）、raw mode 恢复、退出钩子与信号、每帧分配 |
| f_security | 登录状态契约与密钥暴露面、重复逻辑、死代码、并发安全 |
| f_probe | 扩展契约与实现一致性、注册表并发、重复逻辑、死代码、README 覆盖 |

## 铁律（与 reviewer.md 一致，这里再强调三条）

1. **不改源码、不跑构建、不提交**。
2. 死代码与重复逻辑必须**机械过一遍**（全仓 grep 引用、函数体两两比对），不能只凭语感写「未发现」。
3. 性能类结论没有改前基线 + 改后对照（`-O2`、同输入、中位数）就**只能**写进「待验证假设」或「优化可行性方案（无基线）」，不得写成缺陷。
