# f_xml 构建 WARNING 清单

`cjpm build` 在本模块内产生以下 WARNING（stdlib / `f_base` 自身的警告不计）。每条都给出原因，
不允许出现「未说明的 WARNING」。

## 1. 仅被测试使用的观测器（5 条）

| 位置 | 警告 | 原因 |
|---|---|---|
| `XmlPullParser.cj` `totalExpanded()` | unused function | 实体展开总量的观测点，`EntitySecurity_test` 用它断言「Billion Laughs 在 1 MB 内被中断」。 |
| `ExpandSink.cj` `spillPath()` | unused function | `Spill_test` 用它断言「溢出文件用完即删」。 |
| `ExpandSink.cj` `retainedBytes()` | unused function | `Spill_test` 用它断言「内存侧保留字节不随展开量增长」。 |
| `ExpandSink.cj` `size()` | unused function | 便于诊断溢出大小的只读访问器，测试与人工排查用。 |
| `ExpandSink.cj` `readAll()` | unused function | 一次性读回全部展开结果，供测试把溢出路径与内存路径逐字节比较。 |

## 2. `XmlEventHandler` 默认实现的形参（15 条）

`XmlEventHandler` 的所有方法都有默认实现（返回 `Continue`）。默认实现里不使用形参，编译器据此
报 `unused variable`。

**不能改成 `_` 前缀**：这些形参名是接口文档的一部分（调用方按名字理解事件载荷），而且实现方覆盖
方法时用的就是这些语义名。这是「所有方法都有默认实现」这一设计（决策 13）的必然代价。

## 3. 上游警告（不在本模块）

`BaseException.cj`（`f_base`）的 `@Deprecated`、以及 stdlib 内部若干 `unused` 警告由依赖自身产生，
与本模块无关。
