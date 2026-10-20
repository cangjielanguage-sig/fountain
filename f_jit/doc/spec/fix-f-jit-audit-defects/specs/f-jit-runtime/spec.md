# Spec Delta

## MODIFIED Requirements

### Requirement: H78–H80 装箱与类型问答

runtime SHALL 提供三个顶层 `@C` helper：H78 `any_box(typecode: u8, cell) → h`（**分配型**：值型拷贝进盒、句柄型 fetch 后存引用，登记 1 槽；失败 6/8/16）、H79 `any_is(h, typecode: u8, aux: u16) → 0/1`（**纯读**：集合外类型回 0 而非错误；14 按仓颉继承语义判定；除 8 外永不失败）、H80 `any_as(h, typecode: u8, aux: u16) → cell`（**条件分配型**：命中 → 值型拆箱直返 / 句柄型按引用 pin 并登记 1 槽；未命中 → **22**，site = 调用点；失败 8/16/22）。类型描述符 SHALL 以 `typecode` + `aux` 两个 cell 压栈传递，`aux` 编码为：List → 元素码、Map → `(键码 << 8) | 值码`、**14 → 目标类 `$as$<C>` 的 16 位 helper id**、其余 `0xFFFF`；JSON 目标（16–19）`aux = 0xFFFF`。

`typecode = 14` 的判定 SHALL 由类界决定：`aux != 0xFFFF` 时 H79/H80 SHALL 把命中判定委托给该 id 对应的 `$as$<C>`（子类实例命中、无关类不命中、向下转型不命中）；`aux == 0xFFFF` SHALL 保留「任意非 JSON 宿主对象」的兼容口径（仅当前端拿不到类名时出现）。H80 在 14 命中后 SHALL 以 `TypeToken.HOST_OBJECT`（tag 11）登记句柄，SHALL NOT 走通用 `pin`（后者对未登记类以 `RESERVED` 拒绝并报 8，或错记为 tag 12）；未命中 SHALL 为 22，`site` 为 `any_as` 调用点。前端 SHALL 在发射期为 14 目标填入该 id；`$as$<C>` 槽不存在 SHALL 为编译错误，SHALL NOT 拖到运行期。

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

#### Scenario: 14 目标命中与类界

- **WHEN** 盒装类 `A` 实例后分别执行 `as A`、`as A 的父类`、`as 与 A 无关的 B`、`as A 的子类`
- **THEN** 依次成功、成功、22、22；成功的返回值句柄 tag 为 11 且 `getAs(id, HOST_OBJECT)` 取回同一对象

#### Scenario: 同版本 aux 编码

- **WHEN** 编译 `as C`（左值为 Any）与 `is C`（左值为 Any）
- **THEN** 产物中 `aux` 为 `$as$C` 的 16 位 helper id，不是 `0xFFFF`；目标非 14 时 `aux` 编码不变

## ADDED Requirements

### Requirement: helper 分配与窗口记账

H78 与 H80 的全部句柄型分支（4–11、14、15、16–19）SHALL 经窗口内分配路径登记，使 `hwTop` / `hwCap` 记账与实际分配一致；H79 SHALL NOT 产生任何分配。窗口容量触顶 SHALL 以 16（`HANDLE_WINDOW_FULL`）失败。

#### Scenario: 窗口记账

- **WHEN** 在容量为 N 的窗口内连续执行 N+1 次命中型的 `any_as(…, 14, …)` 或容器拆箱
- **THEN** 第 N+1 次以 16（窗口触顶）失败，`windowUsed()` 与实际分配次数一致

#### Scenario: H79 零分配

- **WHEN** 对同一盒连续执行 1000 次 `any_is`
- **THEN** `windowUsed()` 不变、句柄表长度不变

### Requirement: 位运算指令的栈纪律

解释器 SHALL 对每一个比较/逻辑/位运算 opcode 保持「按元数弹栈、压回 1 个结果」的净效应：一元 `NOT`（0x5E）与 `BNOT_I`（0x65）各弹 1 个操作数，二元 opcode（0x5F–0x64、0x66–0x6A）各弹 2 个。`BNOT_I` 的结果 SHALL 为按位取反 `0 - a - 1`，SHALL NOT 恒为 −1，SHALL NOT 遗留操作数。

#### Scenario: BNOT_I 取值与栈深

- **WHEN** 依次执行 `~0`、`~(-1)`、`~7`
- **THEN** 结果依次为 `-1`、`0`、`-8`，且每次执行前后栈深不变

#### Scenario: 与机器码逐位一致

- **WHEN** 同一函数分别走解释器与 AArch64 后端
- **THEN** 三个取值逐位相同

#### Scenario: 一元与二元不串

- **WHEN** 执行 `NOT` 与 `AND/OR/XOR/SHL/SHR/USHR`
- **THEN** 各指令的弹栈个数与结果均与 M1 规格一致

### Requirement: 句柄槽的代数校验与回收

`fetchAnyBox` SHALL 校验代数（`gens[i] == genOf(id)`），槽复用后旧 ID SHALL 以 8（`HANDLE_TYPE`）失败，与 `fetchHostObject` 同构。

释放路径 SHALL 保证逃逸槽最终可回收：桥在调用收尾 SHALL 对 15 与 16–19 的逃逸返回执行与 4–14 相同的归还动作；`release` 对逃逸槽 SHALL 复位逃逸标记并归还空闲槽表；窗口重置 SHALL 继续只释放「未逃逸且非常量」的槽。

#### Scenario: 旧 ID 不可读新盒

- **WHEN** 释放一个 Any 盒句柄，槽被后续分配复用，再用旧 ID 调 `any_is`
- **THEN** 以 8 失败，不返回新盒的内容

#### Scenario: 逃逸槽不泄漏

- **WHEN** 连续 1000 次「返回逃逸句柄（4–14、15、16–19 各一组）→ 宿主取回 → 归还」
- **THEN** 句柄表长度与 `windowUsed()` 不随次数增长

### Requirement: 迭代器表的调用级生命周期

`IterTable` SHALL 在一次桥调用结束时清空全部条目与代数（正常返回、抛错、中断、DEOPT 重放四种出口都清），使跨调用的陈旧游标以 99 失败。表内状态 SHALL 在并发 `open/next/close/clearAll` 下保持一致，不自增丢失、不越界。

#### Scenario: 调用结束即清空

- **WHEN** 一次调用内建立迭代器并在返回前不关闭
- **THEN** 调用返回后 `liveCount()` 为 0，该游标再用必 99

#### Scenario: 异常出口同样清空

- **WHEN** 调用在迭代中途抛业务错误或被打断
- **THEN** 条目同样清零，下一位调用者看到的 `liveCount()` 为 0

#### Scenario: 并发不撕裂

- **WHEN** 多线程并发建立/推进/关闭迭代器，同时另一线程清空
- **THEN** 无越界、无重复游标、无死锁
