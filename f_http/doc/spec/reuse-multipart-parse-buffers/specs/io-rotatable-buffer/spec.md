# io-rotatable-buffer

## Purpose

定义 `f_io.RotatableBuffer.read` 在底层流 EOF 处的截断行为：只返回真实数据范围内的字节，读完返回 0，不把窗口后半的旧/零字节当作数据。

## ADDED Requirements

### Requirement: read 在 EOF 处返回 0

`RotatableBuffer.read(bytes)` SHALL 将读取长度同时限制在 `sectionEnd`（若有）与真实数据末尾 `bufferEnd` 之内；当 `offset` 到达真实数据末尾时 MUST 返回 0，MUST NOT 从窗口后半读取未初始化/旧数据。

#### Scenario: 普通 EOF

- **WHEN** 底层流只有 3 B，缓冲请求 64 B
- **THEN** 首次 `read` 返回 3，第二次返回 0

#### Scenario: 空流

- **WHEN** 底层流没有数据
- **THEN** 首次 `read` 返回 0

#### Scenario: 恰好半窗

- **WHEN** 底层流恰好填满半个窗口后 EOF
- **THEN** 首次 `read` 返回真实长度，第二次返回 0

### Requirement: 既有正数据行为不变

在真实数据范围内，`read` 的写入字节、`offset` 推进、`sectionEnd` / 窗口旋转与 `partEnd` 语义 SHALL 与改动前一致。

#### Scenario: 既有调用回归

- **WHEN** 运行 `f_io` 既有 30 条测试
- **THEN** 全部通过
