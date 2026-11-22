# io-rotatable-buffer

## ADDED Requirements

### Requirement: 分隔符延迟跳过

`RotatableBuffer.read(bytes)` SHALL 在 `offset` 到达 `sectionEnd` 时结束本次读取并返回 `partEnd = true`，但 MUST NOT 在同一次调用内消费分隔符。分隔符 MUST 在下一次 `read` 调用开始时消费，随后从下一 section 继续读取；若分隔符跨越半窗边界，MUST 先完成窗口旋转再定位下一 section。

#### Scenario: 读到 sectionEnd 当次不越过分隔符

- **WHEN** 当前 section 内容为 3 B，调用方一次请求 8 B
- **THEN** `read` 返回 3 且 `partEnd` 为 `true`，`offset` 停在 `sectionEnd`，随后 `indexOf(分隔符)` 仍返回该位置

#### Scenario: 下一次 read 跳过并读到后续数据

- **WHEN** 上一次 `read` 已在 `sectionEnd` 结束，调用方再次 `read`
- **THEN** 本次读取先消费分隔符，再返回下一 section 的字节，返回值不含分隔符本身

#### Scenario: 分隔符跨半窗

- **WHEN** 分隔符的起始位置在半窗内、结束位置越过半窗边界
- **THEN** 下一次 `read` 先旋转窗口，再消费分隔符，返回的字节与不分窗时逐字节一致

## MODIFIED Requirements

### Requirement: 既有正数据行为不变

在真实数据范围内，`read` 的写入字节、窗口旋转与 `partEnd` 语义 SHALL 与改动前一致。分隔符消费时机按「分隔符延迟跳过」要求：读到 `sectionEnd` 的当次调用结束后，`offset` 停在该处，不再提前越过分隔符。

#### Scenario: 既有调用回归

- **WHEN** 运行 `f_io` 既有 33 条测试
- **THEN** 全部通过

#### Scenario: 连续多个 section

- **WHEN** 缓冲区含 3 个连续 section，调用方按 section 逐段读取
- **THEN** 每段内容与分隔符位置正确，第三段读到 `sectionEnd` 后再 `read` 返回 0
