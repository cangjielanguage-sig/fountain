# http-multipart

## Purpose

定义 `f_http` multipart 解析器的流式块复用与健壮性契约：正常报文解析结果不变，截断报文必须终止，多文件与落盘读取可用；公开 API 不变。

## ADDED Requirements

### Requirement: 流式块缓冲与 CRLF 复用

`MultipartFormDataParser` SHALL 在同一实例内复用一块 1024 B 的流式/文件块缓冲，并复用 2 B 的 CRLF 判定缓冲；header 块 MUST 每次按精确长度分配，MUST NOT 复用（`String.unsafeUtf8` 的别名会让 key/filename 逃逸后仍指向缓冲）。

#### Scenario: 多文件复用同一块

- **WHEN** 一次 `parse()` 含 3 个落盘文件 part
- **THEN** 三个文件内容各自正确，流式块只创建一次

#### Scenario: CRLF 零尾部

- **WHEN** 上一轮 CRLF 读取留下 `\r\n`，下一轮只读到 1 字节或 0 字节
- **THEN** 判定与「每轮新建 2 B 数组」一致，不会误进 header 分支

### Requirement: 截断报文必须终止

`parse()` SHALL 在底层流 EOF 时终止，不得无限循环；缺少终止分隔符的报文 MUST 抛出 `MultipartException`。

#### Scenario: 缺终止分隔符

- **WHEN** 报文在最后一个 part 内容后结束，没有 `--boundary--`
- **THEN** `parse()` 抛 `MultipartException`，不挂起

### Requirement: 多文件与落盘读取

同一次 `parse()` SHALL 支持至少 2 个落盘文件 part；`MultipartFile.bytes()` 对落盘 part SHALL 返回完整内容。

#### Scenario: 两个落盘文件

- **WHEN** 两个内容超过窗口的文件 part
- **THEN** 两个 `File` 都可读，内容逐字节正确

#### Scenario: 落盘 bytes

- **WHEN** 对落盘 `MultipartFile` 调 `bytes()`
- **THEN** 返回内容与写入内容逐字节一致，不抛 `FSException`

### Requirement: 公开 API 不变

`MultipartFormDataParser` / `MultipartFile` 的公开签名、访问级别与配置项 SHALL 保持不变；`chunkBuffer()` 为包内可见，不属于公开 API。

#### Scenario: 契约检查

- **WHEN** 审查 `git diff f_http/src`
- **THEN** 无 `public` 符号增删改
