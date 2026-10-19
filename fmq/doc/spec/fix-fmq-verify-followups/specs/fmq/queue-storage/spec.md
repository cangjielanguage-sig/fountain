# fmq 队列存储（delta）

## ADDED Requirements

### Requirement: 记录边界格式与文档化

每条队列记录在段内 SHALL 以 `[4 字节大端无符号长度][记录字节]` 存放；长度只表示后续记录字节数，
不包含 4 字节头。读取端 SHALL 以该长度确定单条边界，记录 SHALL NOT 跨段。该格式 SHALL 写入
`design.md` 与模块设计文档，并注明：升级时不得改变前缀宽度或字节序，否则旧段无法按边界读取。

#### Scenario: 格式写入设计文档

- **WHEN** 查阅 `openspec/changes/fix-fmq-verify-followups/design.md` 与 `fmq/doc/详细设计.md`
- **THEN** 能找到「4 字节大端长度 + 记录字节」的说明与兼容约束

#### Scenario: 长度不含头部

- **WHEN** 写入一条 10 字节记录
- **THEN** 段内占用 14 字节，前 4 字节解码为 10

#### Scenario: 零长度视为损坏

- **WHEN** 段中出现长度为 0 的前缀
- **THEN** 读取端停止，不返回空记录、不越界

#### Scenario: 跨段不拼接

- **WHEN** 当前段剩余空间不足以容纳「4 字节头 + 记录」
- **THEN** 先轮转，再在新段完整写入
