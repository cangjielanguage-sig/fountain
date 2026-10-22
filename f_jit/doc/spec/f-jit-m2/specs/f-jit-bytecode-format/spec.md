# Spec Delta

## Purpose

`bytecode` 包定义字节码的静态模型与 `.fbc` 容器格式：opcode 元信息、显式小端编解码、指令解码、函数目录与类型表、常量表、站点/名字表、容器读写与加载期校验，以及指纹原语。M2 增量把 `CALL_HOST` 从保留槽激活，并把加载校验按 `verMajor` 参数化。

## MODIFIED Requirements

### Requirement: opcode 元信息表全量登记

opcode 表 SHALL 提供 256 项元信息（编码、名称、操作数格式、长度、类别），未分配槽一律为保留，特定禁区标记为禁用；已分配项 SHALL 与规格 opcode 表逐条一致。M2 SHALL 把 `0x79`（`OP_CALL_HOST`）登记为 `fmt="u8"`、`len=2`、`cat=CAT_CALL`，M1 预留的 `u16 fid` 编码废弃；`0x7A`/`0x7B`（`HW_OPEN`/`HW_CLOSE`）保持 `CAT_CALL` 类别但在 M1/M2 汇编期一律 `ERR_NOT_IMPL`。

#### Scenario: CALL_HOST 行元信息

- **WHEN** 读取 `OPCODE_TABLE[0x79]`
- **THEN** 名称为 `CALL_HOST`、格式为 `u8`、长度为 2、类别为 `CAT_CALL`，且编码字段等于 0x79

#### Scenario: 禁区与保留区

- **WHEN** 在 M1 或 M2 规则集下汇编 `0x7A` / `0x7B`
- **THEN** 汇编期返回 `ERR_NOT_IMPL`，不产生可执行机器码

#### Scenario: 已分配项逐条核对

- **WHEN** 逐条比对 M1 已分配 opcode 的名称、长度、格式与类别
- **THEN** 除 `0x79` 行外全部逐位不变

#### Scenario: 表规模与自洽

- **WHEN** 读取 opcode 表
- **THEN** 大小为 256，且第 i 项的编码字段等于 i；新增 `CALL_HOST` 行不改变表规模

### Requirement: 函数目录与局部类型表校验

函数目录条目 SHALL 为定长 26 字节并支持增/查/校验；局部类型表每槽 1 字节，合法码集 SHALL 按单元 `verMajor` 分派：verMajor 1 为 0–12，verMajor 2 为 0–14，verMajor 3 为 0–19（15=Any、16–19=JSON，M3 登记），**20–255 恒拒绝**；13/14 为句柄型槽。

#### Scenario: 条目定长往返

- **WHEN** 编解码一条函数目录条目
- **THEN** 占用 26 字节且所有字段保真

#### Scenario: 类型表按版本拒绝

- **WHEN** 分别以 verMajor 1 加载含 13 的类型表、以 verMajor 2 加载含 15 的类型表、以 verMajor 3 加载含 20 的类型表
- **THEN** 三者均在加载期拒绝；verMajor 2 放行 13/14，verMajor 3 放行 15–19

#### Scenario: 13/14 为句柄槽

- **WHEN** 查询类型码 13/14 的 `isHandleSlot`
- **THEN** 均为真；0–3 为假，4–12 维持 M1 判定

#### Scenario: 目录越界拒绝

- **WHEN** 目录条目的偏移或长度超出代码段，或入口函数号不在目录中
- **THEN** 校验拒绝；该面与 verMajor 无关，v1/v2 产物同样拒绝

### Requirement: 常量表模型与拼装

常量表 SHALL 支持列表/映射/字符串/值/区间/正则等载荷类型的注册，返回递增句柄号；正则 SHALL 按「模式 + 标志」去重且标志归一；冻结后 SHALL 拒绝写入。M2 SHALL NOT 新增常量 kind：HostClosure 与 HostObject 均不可常量化，常量 kind 1–10 与注册/加载行为保持 M1 不变。

#### Scenario: 宿主值不可常量化

- **WHEN** 尝试把 HostClosure 或 HostObject 注册为常量
- **THEN** 注册 API 拒绝；合法常量 kind 1–10 的行为与 M1 逐位一致

#### Scenario: 常量段零增量

- **WHEN** 编译一个仅含 M1 构造的源单元并以 M2 加载器读取
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

### Requirement: 加载期拒绝面完整

加载器 SHALL 对下列情形逐一拒绝并给出容器格式类错误码：魔数错误、主版本不受支持、未知标志位或要求 JIT 的标志位置位、段长不符、常量图成环、坏载荷、目录越界、类型表非法、站点表问题、名字表坏键、校验和不符。M2 加载器 SHALL 兼容 verMajor 1 与 2：v1 按 v1 规则集校验（0–12、无 CALL_HOST），v2 按 v2 规则集校验（0–14、CALL_HOST 合法）；M1 加载器遇 verMajor 2 SHALL 以 18 拒绝。含 14 形参、成员访问或构造的单元经**无注册表分发入口** SHALL 在加载期拒绝；JSON 谱系（M3 内建码 16–19）零注册，不触发该拒绝面。

#### Scenario: 版本兼容矩阵

- **WHEN** 同一加载器分别加载 v1 与 v2 产物
- **THEN** v1 产物按 v1 规则集通过，v2 产物按 v2 规则集通过；v1 规则集下出现的 13/14 或 CALL_HOST 被判非法

#### Scenario: M1 加载器拒绝 v2

- **WHEN** 以 M1 规则集加载 verMajor 2 产物
- **THEN** 以 18 拒绝，并按兼容矩阵给出最小可接受版本信息

#### Scenario: 无注册表分发拒绝

- **WHEN** 经分发入口加载一个含 14 形参/成员访问/构造的 v2 单元
- **THEN** 加载期拒绝；仅含 M3 JSON 内建码的单元不因「无注册表」被拒

#### Scenario: 每条拒绝面独立可测

- **WHEN** 分别构造上述全部非法容器（含 v2 新增的规则集分派与分发入口拒绝面）
- **THEN** 每种都被拒绝，错误码与规格一致，且互不掩盖

## ADDED Requirements

### Requirement: 版本兼容矩阵与规则集分派

`FbcReader` SHALL 以规则集对象参数化加载校验，规则集至少包含：合法 LocalType 集合、合法指令集、14 槽注册表依赖校验、类型表/站点/名字校验参数。规则集 SHALL 按 `verMajor` 选择：1 → M1 规则集；2 → M2 规则集；3 → M3 规则集（本次仅登记合法集 0–19，不实现 M3 语义）。兼容矩阵 SHALL 为：v1 产物在 M1/M2 加载器均通过（M2 按 v1 规则集）；v2 产物在 M1 加载器拒绝（18）、在 M2 加载器通过。

#### Scenario: 规则集取用可断言

- **WHEN** 用同一份 v1 产物与 v2 产物分别加载并记录实际取用的规则集
- **THEN** 前者取 M1 规则集、后者取 M2 规则集，记录与矩阵一致

#### Scenario: 矩阵边界

- **WHEN** 以 M2 加载器加载 verMajor 1、2、3 产物
- **THEN** 1/2 按各自规则集通过，3 以 18 拒绝（M3 未实现）

### Requirement: CALL_HOST 指令语义

`CALL_HOST`（0x79）SHALL 以 `u8 argc` 为操作数，操作数栈布局为 `[h_fn, a1..an]`（句柄在栈底，实参从左到右压入），执行语义 SHALL 等价于 `CALL_HELPER` H63，并由汇编器自动尾随 `CHECK_ERR`；机器码 lowering SHALL 复用 `CALL_HELPER` 模板 A（`call H63` + 自动 `CHECK_ERR`），不引入新模式。argc 为编译期立即数。

#### Scenario: 字节码语义与 helper 转发一致

- **WHEN** 执行 `CALL_HOST 2` 且栈为 `[h_fn, a1, a2]`
- **THEN** 解释器取栈底句柄、逐参转换、调用宿主闭包、封装返回值，与 H63 转发逐位一致

#### Scenario: 机器码零新模式

- **WHEN** 检查包含 `CALL_HOST` 的 v2 单元的机器码
- **THEN** 仅出现 `CALL_HELPER` 模板 A 的 `call H63` 与 `CHECK_ERR` 序列，无新增调用模式
