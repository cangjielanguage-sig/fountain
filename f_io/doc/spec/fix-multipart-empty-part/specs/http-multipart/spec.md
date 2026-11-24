# http-multipart

## ADDED Requirements

### Requirement: 空内容 part 解析

`parse()` SHALL 接受内容长度为 0 的 part。无 `filename` 时 SHALL 返回空字符串值；有 `filename` 时 SHALL 返回大小为 0 的 `MultipartFile`。该场景 MUST NOT 抛出 `MultipartException`，MUST NOT 把后续 part 的首部行当作内容。

#### Scenario: 单独的空字段

- **WHEN** 报文只有一个 `name="empty"` 且内容为空的 part
- **THEN** 解析结果的 `empty` 值为长度 0 的字符串

#### Scenario: 空字段位于首、中、尾

- **WHEN** 空字段分别位于普通字段之前、之间、之后
- **THEN** 空字段值为空，相邻普通字段的值逐字符正确

#### Scenario: 超窗口字段与非空字段相邻

- **WHEN** 空字段紧跟在超过缓冲窗口的字段之后，或紧邻其前
- **THEN** 两个字段都正确解析，空字段长度仍为 0

#### Scenario: 连续两个空字段

- **WHEN** 报文含两个相邻的空字段
- **THEN** 两个字段都返回空值，且不会互相吞并首部

#### Scenario: 空文件

- **WHEN** part 带 `filename` 但内容为 0 B
- **THEN** 返回 `size` 为 0 的 `MultipartFile`，`bytes()` 为空数组
