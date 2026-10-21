# Spec Delta

## MODIFIED Requirements

### Requirement: 常量表模型与拼装

常量表 SHALL 支持列表/映射/字符串/值/区间/正则等载荷类型的注册，返回递增句柄号；正则 SHALL 按「模式 + 标志」去重且标志归一；冻结后 SHALL 拒绝写入。M2 未新增常量 kind（HostClosure 与 HostObject 均不可常量化），常量 kind 1–10 与注册/加载行为保持 M1 不变。M3 SHALL 新增 **kind 11 = Json**：`ConstPayload.PJson(raw)` 保存**规范化后的原始 JSON 字节串**（与 kind 3 同构），`ConstRegistry.addJson(raw)` 在**拼装期只登记原始字节、不解析**，空串与超长输入 SHALL 被防御拒绝；HostClosure 仍不可常量化。

#### Scenario: 宿主值不可常量化

- **WHEN** 尝试把 HostClosure 或 HostObject 注册为常量
- **THEN** 注册 API 拒绝；合法常量 kind 1–10 的行为与 M1 逐位一致

#### Scenario: 常量段零增量

- **WHEN** 编译一个仅含 M1 构造的源单元并以 M3 加载器读取
- **THEN** 常量段布局、kind 表与实例化结果与 M1 产物逐位一致

#### Scenario: 注册去重与归一

- **WHEN** 以相同模式但不同顺序或重复的标志注册正则常量
- **THEN** 返回同一句柄号

#### Scenario: 冻结后只读

- **WHEN** 对已冻结的常量表执行注册
- **THEN** 拒绝写入，读取仍保真

#### Scenario: 有向无环共享

- **WHEN** 常量以子索引引用其它常量构成有向图
- **THEN** 共享子结构解出为同一对象；构成环时加载期拒绝

#### Scenario: JSON 常量拼装期不解析

- **WHEN** 以非法 JSON 文本调用 `addJson`
- **THEN** 拼装期照常登记原始字节并返回递增 hid（不报错、不解析）；拒绝发生在加载期

### Requirement: 版本兼容矩阵与规则集分派

`FbcReader` SHALL 以规则集对象参数化加载校验，规则集至少包含：合法 LocalType 集合、合法指令集、14 槽注册表依赖校验、类型表/站点/名字校验参数。规则集 SHALL 按 `verMajor` 选择：1 → M1 规则集；2 → M2 规则集；3 → **M3 规则集**。M3 规则集 SHALL 登记：合法 LocalType `0–19`、H78–H80 与 H81–H83 的 helper 值域、常量 kind 11 合法、类型表/站点/名字校验参数不变。兼容矩阵 SHALL 为：v1/v2 产物在 M1/M2/M3 加载器均通过（按各自 `verMajor` 规则集）；v3 产物在 M1/M2 加载器拒绝（18）、在 M3 加载器通过。

#### Scenario: 规则集取用可断言

- **WHEN** 用同一份 v1、v2、v3 产物分别加载并记录实际取用的规则集
- **THEN** 依次取 M1、M2、M3 规则集，记录与矩阵一致

#### Scenario: 矩阵边界

- **WHEN** 以 M1 与 M2 加载器分别加载 verMajor 3 产物
- **THEN** 两者均以 18 拒绝；同一产物在 M3 加载器通过

#### Scenario: 合法码边界

- **WHEN** 以 M3 规则集校验类型码 19 与 20
- **THEN** 19 通过、20 以 18 拒绝；15 与 16–19 不再被当作「未登记码」

## ADDED Requirements

### Requirement: JSON 常量的加载期实例化与冻结

加载期 SHALL 对每个 kind 11 常量**恰好实例化一次**：按体首字符构建 `JsonObject`（`{`）或 `JsonArray`（`[`）实例，登记进 ConstTable（路径 A：跨调用同 ID、单元生命周期、不可变），并把该句柄条目标记为 **frozen**。实例化 SHALL 复用 `fountain::f_data.json` 解析器；解析失败、长度不符或非 UTF-8 SHALL 在加载期以固定错误码拒绝（防御面，理论上编译期已过）。实例化后的句柄码 SHALL 为 17（对象）/ 18（数组），条目 tag 复用 11。非 kind 11 来源（H83 构造）SHALL NOT 被置 frozen。

#### Scenario: 一次解析

- **WHEN** 一个单元内多处引用同一 JSON 常量
- **THEN** 解析调用次数等于常量条目数（一次），各处句柄号相同，且跨两次调用取到同一对象身份

#### Scenario: 加载期防御拒绝

- **WHEN** 手工构造 payload 非法的 kind 11 常量（截断、长度不符、非 UTF-8、非法 JSON）
- **THEN** 加载期以固定错误码拒绝，不推迟到执行期

#### Scenario: 常量冻结

- **WHEN** 加载含非空 JSON 常量的单元并查询该句柄的 frozen 标记
- **THEN** 为真；同一单元中由 H83 构造的空 JSON 值 frozen 为假

#### Scenario: 跨平台字节一致

- **WHEN** 同一源文件在 CRLF 与 LF 环境下分别编译
- **THEN** kind 11 的 payload 逐字节一致（换行已规范化为 `\n`）
