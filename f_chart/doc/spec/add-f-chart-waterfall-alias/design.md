# Design

## 1. 关系

M87 与 M16 使用同一类型字符串 `waterfall` 与同一实现 `WaterfallChart`，属于文档层面重复列出的同一能力。

## 2. 验证

回归测试直接调用 `WaterfallChart`，核对柱数、连接器数量与三种语义 class，确保别名条目不会引入行为差异。
