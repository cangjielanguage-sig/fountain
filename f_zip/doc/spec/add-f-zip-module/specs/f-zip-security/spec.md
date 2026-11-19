# Spec Delta

## Purpose

为 `fountain::f_zip` 提供默认开启的安全策略：解压路径穿越（Zip Slip）拦截、符号链接处理、ZIP 炸弹上限、加密 ZIP 拒绝，以及可定位的错误信息。策略只在「整棵目录树」语义的操作（`unzip` / `zip`）中生效，不污染底层读取 API。

## ADDED Requirements

### Requirement: Zip Slip 路径校验

`unzip(input, dir)` 与 `unzip(path, dir)` SHALL 对每个条目名执行以下校验，任一不通过即抛出 `ZipException`，消息形如 `条目路径非法：${name}`：

1. 拒绝绝对路径（以 `/` 开头，或以盘符 / UNC 前缀开头）
2. 拒绝包含 `..` 路径段的条目名
3. 规范化（解析 `.` / `..` / 重复分隔符后）必须仍以目标目录为前缀
4. 不通过校验的条目 SHALL NOT 在文件系统上创建任何文件或目录（包括中间目录）

#### Scenario: 相对穿越

- **WHEN** 解压含条目 `../../etc/passwd` 的 ZIP
- **THEN** 抛出 `ZipException`，且目标目录之外没有文件被创建

#### Scenario: 绝对路径

- **WHEN** 解压含条目 `/abs/path.txt` 的 ZIP
- **THEN** 抛出 `ZipException`

#### Scenario: 目标目录内的 `..` 折叠仍合法

- **WHEN** 条目名为 `a/../b.txt`，规范化后为 `b.txt`（仍在目标目录内）
- **THEN** 按实现取舍：要么拒绝（含 `..` 段一律拒绝），要么安全落盘为 `b.txt`
- **AND** 无论哪种，都不得写到目标目录之外

#### Scenario: 名字伪装

- **WHEN** 条目名为 `a/../../b.txt`
- **THEN** 拒绝，不写入目标目录之外

#### Scenario: 校验先于落盘

- **WHEN** 一个 ZIP 的前两条合法、第三条非法
- **THEN** 前两条正常写出，第三条抛异常
- **AND** 第三条不会先创建目录再报错

### Requirement: 符号链接无条件跳过

`unzip` 与 `zip(output, dir)` SHALL 跳过符号链接，SHALL NOT 跟随、SHALL NOT 重建、SHALL NOT 因此报错。

- `unzip` 遇到 Unix mode `(externalAttributes >> 16) & 0xF000 == 0xA000` 的条目 → 跳过并记一条 warning（含条目名与链接目标）
- `zip(output, dir)` 遇到符号链接文件 → 跳过并记 warning
- `zip(output, dir)` 遇到**目录**符号链接 → 跳过整棵子树，不递归
- `ZipReader.read(name)` / `open(name)` 对符号链接条目 SHALL 按普通条目返回链接目标字符串的字节（读取层不做策略）
- `ZipWriter.addFile(name, path)` 传入符号链接路径时 SHALL 跟随（调用方显式指定单个文件）

#### Scenario: 解压不落链接

- **WHEN** 解压一个含 `link -> /etc/passwd` 条目的 ZIP
- **THEN** 目标目录下不存在 `link`，且有一条 warning 日志

#### Scenario: 打包跳过文件链接

- **WHEN** 用 `zip` 打包一个含符号链接文件的目录
- **THEN** 包内没有该链接条目，目标文件本身仍被打包（若它被直接遍历到）

#### Scenario: 目录链接不递归

- **WHEN** 打包一个含 `loop -> /` 目录符号链接的目录
- **THEN** 不进入 `loop`，遍历正常结束，不出现无限递归或海量条目

#### Scenario: 读取层不做策略

- **WHEN** 用 `ZipReader.read("link")` 读一个符号链接条目
- **THEN** 返回链接目标路径字符串的字节

#### Scenario: addFile 跟随

- **WHEN** `addFile("x.txt", 指向 real.txt 的链接)`
- **THEN** 写入 real.txt 的内容

### Requirement: ZIP 炸弹四道上限

`unzip` SHALL 透传 `ZipLimits` 的四条规则，并在解压过程中**持续计数**：超限立即中断，同时删除已写出的半截文件（避免"先把磁盘写满再报错"）。SHALL NOT 要求"落盘前预知大小"——流式解压只有解完才知道实际大小，能承诺的只是"超限即停 + 清理半截文件"：

1. 单条目解压超过 `maxEntrySize` → 中断并报错，已写出的半截文件 SHALL 被删除
2. 本次累计解压超过 `maxTotalSize` → 中断
3. 条目数超过 `maxEntries` → **解析中央目录时**拒绝
4. 压缩比超过 `ratioWarnThreshold` → 记 warning 日志后继续

上限计数 SHALL 按**实际解压出的字节**累加，SHALL NOT 采信 header 的 `uncompressedSize`。

#### Scenario: 高压缩比炸弹被拦

- **WHEN** 用默认 `ZipLimits` 解压一个 10 MB 压缩、解压后 1 GB 的单条目 ZIP
- **THEN** 在累计超过 `maxEntrySize`（512 MB）时中断并抛出 `ZipException`
- **AND** 目标目录中没有留下不完整的该条目文件

#### Scenario: 上限可放宽

- **WHEN** 用 `ZipLimits(maxEntrySize: 2L * 1024 * 1024 * 1024)` 解压同一样本
- **THEN** 若总量在限额内则正常解压

#### Scenario: 条目数在解析期拒绝

- **WHEN** 用 `ZipLimits(maxEntries: 100)` 解压一个中央目录声明 1000 条的 ZIP
- **THEN** 抛出 `ZipException`，且没有创建任何文件

#### Scenario: 计数不采信 header

- **WHEN** 一个条目 header 声称 `uncompressedSize` 为 1，实际解压出 1 GB
- **THEN** 仍按实际字节累计并在超限时中断

### Requirement: 加密 ZIP 拒绝

`f_zip` SHALL 在读取阶段检查 general purpose flag 的 bit 0 与 bit 6，任一置位即抛 `ZipException`，消息形如 `不支持加密 ZIP（${name}）`。

`unzip` 的承诺按**可观察行为**表述，而不是"整包原子性"——`unzip()` 是逐条边解边写：

- 遇到加密条目 SHALL 抛出 `ZipException`，SHALL NOT 跳过它继续解其余条目
- 该加密条目本身 SHALL NOT 写出任何字节（目标目录下不出现该名字对应的文件）
- **已落盘的前序条目允许保留**：本模块不承诺回滚（不删已写出的前序文件、也不承诺"要么全对要么全无"）

#### Scenario: 解压加密条目

- **WHEN** `unzip` 遇到 bit 0 为 1 的条目
- **THEN** 抛出 `ZipException`，该条目不被写出

#### Scenario: 不做部分支持

- **WHEN** 一个 ZIP 含一条加密条目与两条普通条目
- **THEN** 抛出 `ZipException`，不得"跳过加密条目继续解其余"
- **AND** 加密条目本身不写出任何字节，目标目录下不存在该条目名对应的文件
- **AND** 位于它之前、已解出的条目允许保留（不承诺回滚）

### Requirement: 可诊断的错误信息

所有安全相关的 `ZipException` SHALL 携带可定位的信息：涉及条目时 MUST 包含条目名；涉及上限时 MUST 包含上限值与实际值；涉及压缩方法时 MUST 包含方法数值。SHALL NOT 只给出"解压失败"这类无信息量的消息。

#### Scenario: 路径非法带名字

- **WHEN** 条目 `../x` 被拒绝
- **THEN** 消息为 `条目路径非法：../x`

#### Scenario: 超限带数值

- **WHEN** 单条目解压超过 512 MB
- **THEN** 消息包含上限值 `536870912` 与条目名

#### Scenario: 方法不支持带数值

- **WHEN** 遇到 method 93
- **THEN** 消息包含 `93` 与条目名

### Requirement: 安全用例随实现交付

模块 SHALL 附带覆盖上述策略的单元测试，且 SHALL 包含至少以下负例：相对穿越、绝对路径、深层穿越、符号链接条目、目录符号链接、高压缩比炸弹、条目数超限、加密条目。测试 SHALL 在 `cjpm test` 下全绿。

#### Scenario: 负例全部有对应用例

- **WHEN** 运行 `f_zip` 的单元测试
- **THEN** 上述八类负例各至少有一条用例，且都断言抛出的 `ZipException` 消息包含关键字段
