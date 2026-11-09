# `fountain::fprobe`

服务器监控可执行模块：`fprobe agent` 部署到每个节点，周期采集主机指标并通过 RPC
暴露给监督端；`fprobe supervisor` 汇聚多节点数据，提供告警、图表、周期报告与扩展
渠道。扩展契约见 [`fountain::f_probe`](../f_probe/README.md)。

> 本模块目前处于实现中，命令与配置以 `--help` 输出和后续文档为准。
