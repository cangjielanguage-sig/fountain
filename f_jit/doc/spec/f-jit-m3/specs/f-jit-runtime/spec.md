# Spec Delta

## MODIFIED Requirements

### Requirement: 单次诊断转储与报告组装

诊断转储 SHALL 保证「首个收敛点获胜」且去优化不触发转储，转储区禁用时跳过；报告 SHALL 按固定模板给出错误、源码位置与变量清单（无名槽省略名字，句柄型按类型名加索引呈现，值型按文本化规则）。M2 把句柄型值呈现外延到 13/14：13 记为 `<HostClosure>#idx`、14 记为 `<HostObject>#idx`。M3 SHALL 再外延到 15–19：15 记为 `<Any>#idx`、16–19 分别记为 `<JsonValue>#idx` / `<JsonObject>#idx` / `<JsonArray>#idx` / `<JsonNull>#idx`；SHALL 使用**大类名/内建码名**呈现，不取对象、不解析具体类（标量节点按 16 呈现）；三行模板、条目格式、槽位序号为键、`site=-1` / `dbgBase=0`、`-1`/`-2` 不转储、最深失败帧获胜等 M1 规则 SHALL 逐条不变。

#### Scenario: 13/14 大类名呈现

- **WHEN** 报告变量清单中出现 13/14 型槽
- **THEN** 分别输出 `<HostClosure>#idx` 与 `<HostObject>#idx`，不输出具体注册类名

#### Scenario: 15–19 呈现

- **WHEN** 报告变量清单中出现 Any 盒、JSON 对象、数组、null 与标量节点
- **THEN** 依次输出 `<Any>#idx`、`<JsonObject>#idx`、`<JsonArray>#idx`、`<JsonNull>#idx`、`<JsonValue>#idx`，且不触发任何解析或取对象

#### Scenario: 报告逐位一致

- **WHEN** 对比 M1 与 M2 对同一错误生成的报告
- **THEN** 除 13/14 值呈现外，三行模板、行号/变量格式与边界规则逐位一致

#### Scenario: 首个收敛点获胜

- **WHEN** 一次调用中多个点试图转储
- **THEN** 只有首个收敛点的转储生效，后续不再覆盖

## ADDED Requirements

### Requirement: H78–H80 装箱与类型问答

runtime SHALL 提供三个顶层 `@C` helper：H78 `any_box(typecode: u8, cell) → h`（**分配型**：值型拷贝进盒、句柄型 fetch 后存引用，登记 1 槽；失败 6/8/16）、H79 `any_is(h, typecode: u8, aux: u16) → 0/1`（**纯读**：集合外类型回 0 而非错误；14 按仓颉继承语义判定；除 8 外永不失败）、H80 `any_as(h, typecode: u8, aux: u16) → cell`（**条件分配型**：命中 → 值型拆箱直返 / 句柄型按引用 pin 并登记 1 槽；未命中 → **22**，site = 调用点；失败 8/16/22）。类型描述符 SHALL 以 `typecode` + `aux` 两个 cell 压栈传递，`aux` 编码为：List → 元素码、Map → `(键码 << 8) | 值码`、其余 `0xFFFF`；JSON 目标（16–19）`aux = 0xFFFF`。

容器转型 SHALL 走**校验路径**：`as List<Any>` / `as Map<…,Any>` 按 `(typecode, aux)` 的有限分支表判「是容器且元素/键值类型一致」，不符即 22（不变语义：`ArrayList<Int64>` 不匹配 `ArrayList<Any>`）。退化路径（不校验 + 宿主契约）SHALL 仅在 reified 不可用的环境启用，且必须显式标注。

全部新增操作 SHALL NOT 构成变更型来源：box 不可变、is 纯读、as 仅分配 ⇒ 不置 `flags.bit0`、不触发 deopt 禁令；重放安全沿用「重复分配等值对象」。

#### Scenario: 装箱往返

- **WHEN** 对 Int64 与 String 分别 `any_box` 后 `any_as` 取回
- **THEN** 值型逐位相等且与原件无关联（改原件不影响盒）；引用型为同一对象；各登记 1 槽

#### Scenario: is 的三种回答

- **WHEN** 对装 Int64 的盒做 `is Int64` / `is String` / `is Closure`（集合外）
- **THEN** 依次为 true / false / false，且均不产生错误码

#### Scenario: as 未命中

- **WHEN** 对装 String 的盒做 `as Int64`
- **THEN** 错误码 22、site 为 `any_as` 调用点，且不返回任何值

#### Scenario: 容器转型校验

- **WHEN** 对 `ArrayList<Int64>` 盒做 `as List<Any>`，与对 `ArrayList<Any>` 盒做同一转型
- **THEN** 前者 22、后者成功；元素类型一致才命中

#### Scenario: 不触发 deopt 禁令

- **WHEN** 检查仅含装箱与 is/as 的函数的 flags 与 deopt 源登记
- **THEN** `flags.bit0` 未置位，函数仍可 deopt 重放

### Requirement: H81–H83 JSON 世界内可变 API

runtime SHALL 提供 H81 `json_get(h16, key, mode: u8) → h15`（**条件分配型**）、H82 `json_set(h16, key, typecode: u8, v) → 0`（**变更型**）、H83 `json_new(mode: u8) → h16`（**分配型**，实际码 17/18）。三者形参 SHALL 以 `h16`（JsonValue 基码）接收，并按**码级继承表**接受 17/18/19 实参。

读（H81）SHALL 返回 **Any(15) 盒**：对象/数组元素 → 节点盒；标量元素按**出口解包**规则装箱——`JsonString` → `String`、`JsonBool` → `Bool`、`JsonInt` 落 Int64 域内 → `Int64` / 超域 → `Decimal`、`JsonDecimal` → `Decimal`；JSON `null` SHALL 装箱为 **`JsonNull.instance` 单例**（非语言 null）。失败码：数组越界 4 / 对象缺键 5 / 其余 6/8/16。

写（H82）SHALL：对象置 upsert、数组仅写既有下标（越界 4，不自动扩展）；值域 = 值型 0–3（Unit 除外）/ String / JSON 节点（码 16–19）；目标 frozen → **20**；防御 -1 → 99；**不登记新槽**；函数 SHALL 置 `flags.bit0` 并拒绝全部 deopt 源。构造（H83）SHALL 产生窗口分配的新空值（可变、非常量、非 frozen）。

frozen SHALL 经读（H81）与拆箱（H80）**传播**：从 frozen 常量取出的子节点保持只读，无需树遍历。

#### Scenario: 读的出口解包

- **WHEN** 读取 `{"i":3,"big":123456789012345678901234567890,"s":"x","b":true,"n":null}`
- **THEN** 依次得到 `Int64` 盒、`Decimal` 盒（BigInt 保真）、`String` 盒、`Bool` 盒、`JsonNull.instance` 盒；后者与单例同一对象

#### Scenario: 越界与缺键

- **WHEN** 对长度 2 的数组取 `[5]`，对无键对象取 `["k"]`
- **THEN** 分别为 4 与 5

#### Scenario: 写的边界

- **WHEN** 对数组写越界下标，对对象写新键，对 frozen 常量写已有键
- **THEN** 依次 4、成功（upsert）、20

#### Scenario: frozen 传播

- **WHEN** 对常量 `{"a":{}}` 执行 `(c["a"] as JsonObject)["x"] = 1`
- **THEN** 以 20 失败；中间盒本身亦为 frozen

#### Scenario: 空形态可变

- **WHEN** 由 H83 构造 `` `{}` `` 后写入键，再经跨桥返回宿主
- **THEN** 写入成功、宿主看到同一对象上的变更；该值 frozen 为假

#### Scenario: 变更型纪律

- **WHEN** 检查含 `json_set` 的函数的 flags 与 deopt 源
- **THEN** `flags.bit0` 置位，全部 deopt 源被拒绝

### Requirement: CALL_HOST 转发特化

runtime SHALL 提供桥内部的 `SignatureTable`（键 = canonical 签名，即参数类型码序列 + 返回类型码；值 = `SignaturePlan`）与 `SignaturePlan`（逐参转换器向量 + 返回转换器 + 装配序列）。两者 SHALL **身份无关**（不含句柄 ID、单元指纹、注册表快照、对象引用），且 SHALL NOT 进入 `.fbc`。

`SignatureTable.getOrBuild` SHALL 在 **CALL_HOST 验签通过后立即调用**（验签即建，当次调用即用），同签名只建一次；不活跃调用点 SHALL 不建表。`HostCallback` SHALL 增加 `plan` 绑定，生命周期 **per-call**（随条目 try/finally 释放）；命中 plan 时 H63 SHALL 跳过逐参解释循环直通转换，未命中或构建失败 SHALL 逐字回退通用流程（结果无差、不报错、记诊断）。

argc ≤ 4 SHALL 使用预生成展开序列，argc > 4 SHALL 走通用/循环路径；`CALL_HOST u8 argc` 的合法域仍为 **0–255**，展开阈值 SHALL NOT 成为形参数量限制，两条路径结果 SHALL 逐位一致。

特化 SHALL NOT 改变可观察语义：转换器直接复用通用流程的同一转换函数，实参次序、句柄 `get` 时机、窗口登记、错误码（8/21/99 与 site）、异常转码、重入语义全部不变。失效门禁三条：携带身份信息的加速结构不得跨调用存活；若引入 Layer C 必须逐次 `(idx, gen, tag)` 全等校验 + per-call 生命周期 + 绝不跨线程共享；特化路径不得绕过既有失败路径（含 CALL_HOST 单元卸载后仍为 19）。

#### Scenario: 验签即建

- **WHEN** 执行两个同签名、不同调用点的 CALL_HOST，再执行一个从未被调用的签名
- **THEN** 构建计数等于不同签名数（前者一次），从未调用的签名不建表

#### Scenario: 展开与循环逐位一致

- **WHEN** 分别以 argc = 0、2、5、255 调用同一闭包，并强制走展开/通用两条路径
- **THEN** 结果、错误码、site、窗口账目逐位一致；255 不因超过阈值被拒绝

#### Scenario: 失效面

- **WHEN** 释放一个闭包条目后在复用槽上放入签名不同的新闭包并调用
- **THEN** 新闭包绑定自己的 plan，不命中任何旧加速；结果正确

#### Scenario: 卸载不被绕过

- **WHEN** 卸载含 CALL_HOST 的单元后再调用该单元入口
- **THEN** 仍以 19 失败，特化路径不提供旁路

#### Scenario: 格式零改动

- **WHEN** 对比特化开启前后的同一份 `.fbc`
- **THEN** 逐字节一致；机器码仍只有 `call H63` 与 `CHECK_ERR`
