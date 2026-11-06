# Spec Delta — f-xml-dtd-entities

## Purpose

补齐 M1 验收记录（`verification.md` §3）里的两条 P3 缺口：`SpillDir` 四级全失败的报错
分支、两个解析器实体计数互不影响。实体上限、溢出策略、计数语义**一律不变**，本 delta
只要求「可测」与「有用例」。

## MODIFIED Requirements

### Requirement: 临时目录解析

溢出目录 SHALL 按序解析：

1. `EntityLimits.spillDir`
2. 环境变量 `TMPDIR`
3. 系统临时目录（`env.getTempDirectory()`）
4. `env.getWorkingDirectory().join(".fountain_tmp")`（自动创建）

四级全失败 SHALL 抛 `XmlException("无法创建实体溢出文件，请显式指定 spillDir")`，
SHALL NOT 降级回内存。

候选遍历 SHALL 由一个可注入候选与回落点的内部函数承担
（`SpillDir.createFileFrom(candidates, fallback)`），`createFile(limits)` SHALL 只是
「解析候选 + 调用它」的薄包装；两者行为 SHALL 逐行等价。该 seam SHALL 为 `internal`，
SHALL NOT 进入公开 API。

失败分支 SHALL 有自动化用例，SHALL NOT 依赖真实的权限故障或 `chmod`。

#### Scenario: 显式 spillDir 优先

- **WHEN** `spillDir = Some(dir)` 且 `TMPDIR` 指向别处
- **THEN** 溢出文件落在 `dir`

#### Scenario: TMPDIR 次之

- **WHEN** `spillDir = None`，`TMPDIR` 有效
- **THEN** 溢出文件落在 `TMPDIR`

#### Scenario: 四级失败明确报错

- **WHEN** 四个候选都不可用（用四个「已存在的普通文件」路径注入，含回落点）
- **THEN** 抛 `XmlException`，消息含 `spillDir`；调用方 `ExpandSink.isSpilled() == false`，
  不写内存、不产生临时文件

#### Scenario: 非回落候选缺失被跳过

- **WHEN** 候选为 `[不存在的目录, 有效临时目录]`
- **THEN** 跳过第一个，文件落在第二个

#### Scenario: 回落目录缺失时被创建

- **WHEN** 候选为 `[不存在的目录, 不存在的回落目录]`
- **THEN** 回落目录被递归创建，文件可用；用后清理

### Requirement: 计数器实例级

实体上限计数器 SHALL 是**解析器实例级**，SHALL NOT 是全局状态。
两个解析器并行解析 SHALL NOT 互相占用额度。

该性质 SHALL 有自动化用例，至少两条：

1. **交错驱动**：两个 `XmlPullParser` 交替推进，任一步一个实例的 `totalExpanded()`
   SHALL 只随自身推进变化；
2. **双线程**：两个线程各解析一份展开量接近上限（如 0.8 × `maxExpandedTotal`）的文档，
   两份 SHALL 都成功；全局计数器会导致第二份超限，因此该用例可区分实现。

#### Scenario: 两个解析器互不影响

- **WHEN** 两个线程各解析一份展开量接近上限的文档
- **THEN** 两份都成功，不因对方占用额度而超限

#### Scenario: 交错推进不串计数

- **WHEN** `p1` 推进一个事件后 `p2` 推进两个事件，再读 `p1.totalExpanded()`
- **THEN** 读数只反映 `p1` 自己已展开的字符数
