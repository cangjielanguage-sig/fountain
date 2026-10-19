# Spec Delta

## Purpose

`runtime` 包承载执行期全部设施：64 字节非托管上下文、句柄表与窗口/逃逸区、迭代器表、helper 实现集、诊断转储与报告，以及作为语义基准的解释器。M2 增量增加宿主闭包回调、签名验签、字段读写 helper、提升组与 `CALL_HOST` 解释语义。

## MODIFIED Requirements

### Requirement: 句柄表标识与类型校验

句柄表 SHALL 把宿主对象钉为整数标识，同一对象复用同一标识，不同类型对象给出不同标识；读取时类型不符 SHALL 返回空，释放后旧标识 SHALL 失效且表项不按原位复用（世代号校验）。M2 SHALL 扩展条目载荷：tag=10 为 `HostCallback{fn, sig}`，tag=11 为不透明宿主对象引用（宿主类实例）；`pin` SHALL 对函数值与已注册类实例开放，无 token 的其他对象仍以 19 拒绝；tag 11 SHALL 作为「不透明宿主对象引用」大类，M3 JSON 句柄复用同 tag，不新开标签。

#### Scenario: 同对象同标识

- **WHEN** 两次钉住同一函数值/同一注册类实例、以及钉住两个不同类型的对象
- **THEN** 前两者标识相同，后者标识不同；tag 10/11 与载荷类型一致

#### Scenario: 无 token 对象仍拒绝

- **WHEN** 钉住一个既非函数值、也非已注册类实例的宿主对象
- **THEN** 以 19 拒绝，不产生 tag 10/11 条目

#### Scenario: 释放后不可达

- **WHEN** 释放某 tag 10/11 标识后再次读取
- **THEN** 返回空；表项复用后旧标识因世代号不同被拦截

### Requirement: 逃逸区与窗口重置

逃逸槽 SHALL 在窗口重置后保持可用且标识不变，非逃逸槽随重置失效；按规则的自动回收 SHALL 只作用于窗口区间内的槽。M2 的提升 SHALL 为**槽级原地提升**：对「闭包自身槽 + 全部句柄型捕获所指的槽」迁出窗口记账、表项保留、ID 与 gen 不变、不参与后续分配重用；不复制、不改址、不进入句柄所指对象内部（容器免级联）。调用 try/finally 清理 SHALL 豁免提升槽；唯一释放路径为 `close`。

#### Scenario: 逃逸槽幸存

- **WHEN** 某槽被登记为逃逸后执行窗口重置
- **THEN** 该槽仍可取到同一对象；未逃逸槽失效

#### Scenario: 提升组槽级语义

- **WHEN** 一个逃逸闭包捕获容器后执行提升
- **THEN** 只提升容器那 1 个槽，不遍历容器内部；窗口重置后元素仍可读且引用身份不变

#### Scenario: try/finally 豁免

- **WHEN** 调用收尾的 try/finally 清理一个已在提升组中的槽
- **THEN** 该槽不被释放，计数保持至显式 `close`

### Requirement: helper 只写错误码不抛异常

全部 helper SHALL 以「薄入口 + 普通实现」提供，失败 SHALL 只写入错误槽并按规定返回，绝不把异常抛给字节码或机器码；分配型 helper 登记一个新槽，变更型 helper 不登记新槽。M2 SHALL 新增 H63（CALL_HOST 转发）、H64（字段读，条件分配型）、H65（字段写，变更型）；宿主侧异常 SHALL 统一转码为 21（H63 的闭包异常、H64/H65 的访问器异常），引擎侧兜底仍为 99；H65 SHALL 触发变更型路由（常量禁写自然满足、deopt 禁令、防御 -1 → 99）。

#### Scenario: 失败不逃逸

- **WHEN** 触发 H63 的 tag 不符、H64/H65 的 obj tag 不符、H65 的 `mutable=false`
- **THEN** 分别写入 8 / 8 / 19，异常被内部转码吞掉，不向上传播

#### Scenario: 窗口账目分野

- **WHEN** 分别调用 H63（引用型返回）、H64（句柄型字段）、H65
- **THEN** H63/H64 各登记至多 1 槽；H65 不登记新槽

#### Scenario: 宿主异常统一 21

- **WHEN** H63 调用的宿主闭包或 H64/H65 的访问器抛出仓颉异常
- **THEN** 写入 21 与完整 cause，site 指向对应调用指令；不写成 99

#### Scenario: 迭代中修改同容器

- **WHEN** 迭代过程中修改被迭代的同一映射
- **THEN** 以并发修改类错误码失败；修改其它容器不受影响

### Requirement: 单次诊断转储与报告组装

诊断转储 SHALL 保证「首个收敛点获胜」且去优化不触发转储，转储区禁用时跳过；报告 SHALL 按固定模板给出错误、源码位置与变量清单（无名槽省略名字，句柄型按类型名加索引呈现，值型按文本化规则）。M2 SHALL 把句柄型值呈现外延到 13/14：13 记为 `<HostClosure>#idx`、14 记为 `<HostObject>#idx`；SHALL 使用**大类名**呈现，不取对象、不解析注册类名；三行模板、条目格式、槽位序号为键、`site=-1` / `dbgBase=0`、`-1`/`-2` 不转储、最深失败帧获胜等 M1 规则 SHALL 逐条不变。

#### Scenario: 13/14 大类名呈现

- **WHEN** 报告变量清单中出现 13/14 型槽
- **THEN** 分别输出 `<HostClosure>#idx` 与 `<HostObject>#idx`，不输出具体注册类名

#### Scenario: 报告逐位一致

- **WHEN** 对比 M1 与 M2 对同一错误生成的报告
- **THEN** 除 13/14 值呈现外，三行模板、行号/变量格式与边界规则逐位一致

#### Scenario: 首个收敛点获胜

- **WHEN** 一次调用中多个点试图转储
- **THEN** 只有首个收敛点的转储生效，后续不再覆盖

### Requirement: 解释器是语义基准

解释器 SHALL 实现全部指令语义（控制、常量栈、局部、整型含溢出与除零与求余四象限、浮点、比较逻辑位、控制流、调用与闭包、类型转换、容器与值提取），错误后不再执行后续指令，可失败调用后按自动错误检查短路。M2 SHALL 实现 `CALL_HOST`：取栈底句柄、按签名逐参转换、调用宿主闭包、封装返回值；其行为 SHALL 与 H63 转发逐位一致，v2 规则集下的单元可含 0x79。

#### Scenario: 失败即终止

- **WHEN** 指令序列中某点写入错误码（含 `CALL_HOST` 的 21）
- **THEN** 自该点起的剩余指令不再执行，操作数栈不再消费，控制收敛到唯一出口

#### Scenario: CALL_HOST 与 H63 对拍

- **WHEN** 同一 v2 单元分别经解释器与 H63 路径执行
- **THEN** 结果、错误码、site 与报告逐位一致

#### Scenario: 逐组语义可断言

- **WHEN** 按分组执行各指令（含整型边界、浮点非数、相对跳转、函数调用、闭包调用、预定义函数路由、类型守卫与断言）
- **THEN** 结果与错误码/站点与规格逐条一致；M2 增量为 `CALL_HOST` 一组的对拍

## ADDED Requirements

### Requirement: HostCallback 与签名描述符

runtime SHALL 提供 `HostCallback`（`fn: Any`、`sig: SignatureDescriptor`）与 `SignatureDescriptor`（`params: Array<UInt16>`、`ret: UInt16`、`validate()`）。`HostCallback` 为句柄条目载荷，持有宿主闭包强引用，调用期间闭包不会死亡。`SignatureDescriptor.validate` SHALL 要求 T/R ∈ 0–8、10–11、14，拒绝 12/13。

#### Scenario: 签名合法性

- **WHEN** 构造 `SignatureDescriptor([0,4], 2)` 与 `([12], 2)` 并调用 `validate`
- **THEN** 前者为真；含 12/13 的签名（T 或 R）为假；14 合法

### Requirement: 签名验签与条目缓存

纯静态工具类 `SignatureVerifier`（无实例、无构造、无状态）SHALL 提供 `verify(value: Any, declared: SignatureDescriptor)`：以**单次 `is (T1..Tn) -> R`** 判定（声明签名取自前端/桥静态知识，子类型语义覆盖参数个数、逐参与返回），失败返回 None（→19），成功产出描述符。`cached(entry: HostCallback)` SHALL 在条目已验签时返回 `entry.sig`，否则返回 None；缓存一律落在条目上。

#### Scenario: 单次判定覆盖全部不符

- **WHEN** 分别以非函数值、参数个数不符、逐参类型不符、返回类型不符的值验签
- **THEN** 全部返回 None；合法函数值返回描述符

#### Scenario: 缓存复用

- **WHEN** 对同一 `HostCallback` 连续调用 `cached`
- **THEN** 首次（未验签）返回 None；写入 `sig` 后返回同一描述符，且不产生第二次 `is` 判定

### Requirement: H63 CALL_HOST 转发器

runtime SHALL 提供顶层 `@C` helper H63 `host_call_trampoline`：fetch 栈底句柄 → `HostCallback{fn, sig}`（tag≠10 → 8）→ 按 sig 逐参 cell→仓颉值（值型原值；句柄型 get；14 取实例引用）→ 调用 `fn` → 返回值封装为 cell（R 为引用型 → 窗口登记 1 槽；值型 → 原值）。宿主闭包异常 SHALL catch-all → 21 + cause（含完整仓颉栈、桥打印）并 fail-fast；重入 JIT SHALL 合法（新 ctx、独立事务、内层错误不影响外层）；含 `CALL_HOST` 的函数 SHALL 置 `flags.bit0` 并拒绝 deopt 源；运行期防御 -1 → 99。

#### Scenario: 正常调用与窗口登记

- **WHEN** 以值型返回与引用型返回分别调用 H63
- **THEN** 值型不登记槽；引用型登记 1 槽，hwTop 增加 1，结果正确

#### Scenario: 异常与站点

- **WHEN** 宿主闭包抛出异常
- **THEN** 写入 21、cause 含完整栈、site 为 CALL_HOST 偏移；后续指令不执行

#### Scenario: 重入隔离

- **WHEN** 宿主闭包体内再次调用同一/另一 `JitFunction`（深度 ≥3）并在内层失败
- **THEN** 内层使用独立 ctx/错误槽/窗口；内层失败不覆盖外层错误槽，外层结果正确

### Requirement: H64 / H65 字段读写

runtime SHALL 提供 H64 `host_get_field(obj, index) → cell` 与 H65 `host_set_field(obj, index, cell) → 0`。H64 对值型字段直取原值、零登记；对句柄型字段（4–14）marshal 为句柄并登记 1 槽（条件分配型）；obj tag≠11 → 8；index/类型防御命中 → 99。H65 对值型字段直存、对句柄型字段 fetch 后存引用；`mutable=false` → 19；obj tag≠11 → 8；不登记新槽；变更型路由 SHALL 复用 M1 §9.15 三条规则。

#### Scenario: 值型与句柄型读

- **WHEN** 分别读取值型字段与句柄型/14 字段
- **THEN** 前者零登记并返回原值；后者登记 1 槽并返回句柄；宿主对象状态不变

#### Scenario: 写后宿主可见

- **WHEN** 通过 H65 修改一个对象字段后调用返回宿主
- **THEN** 宿主在同一对象上观测到修改；同一对象身份不变

#### Scenario: 只读字段双防线

- **WHEN** 对 `mutable=false` 字段执行 H65
- **THEN** 返回 19；前端糖路径已在编译期拒绝

### Requirement: 提升组

runtime SHALL 提供 `PromotionGroup`（per-逃逸闭包清单）：`add(id)` 幂等提升并计数 +1（重复提升/多闭包共享捕获）；`release(id)` 计数 −1、归零释放（gen+1 可复用）；`contains(id)` 判定组内；`size()` 返回组规模。路径 A 常量槽 SHALL NOT 入组、不释放（释放点仅单元卸载）；调用 try/finally 清理 SHALL 豁免提升槽。

#### Scenario: 共享捕获计数

- **WHEN** 两个逃逸闭包共享同一句柄型捕获，先后提升并各 `release` 一次
- **THEN** 计数为 2；第一次 release 后仍存活，第二次归零释放且 gen+1

#### Scenario: 幂等提升

- **WHEN** 对同一槽重复 `add`
- **THEN** 不重复登记、计数按规则递增；`contains` 恒为真

#### Scenario: 常量不入组

- **WHEN** 闭包捕获路径 A 常量
- **THEN** 该捕获不进入提升组，`close` 不释放它

### Requirement: 宿主异常专用码与异常栈

runtime SHALL 把全部宿主侧调用面（CALL_HOST 闭包、预定义与包装、构造适配器、成员访问器）的未捕获异常统一转码为 `ErrCode.HOST_EXCEPTION=21`；`cause` SHALL 为原始异常全文（含完整仓颉异常栈），桥 SHALL 把完整栈打印到诊断流；`site` SHALL 为对应调用指令偏移；终止语义 SHALL 为 fail-fast（立即结束执行、不提供恢复）。`99` SHALL 仅保留给引擎侧实现缺陷；并发调用中的失败 SHALL 互不串扰。

#### Scenario: 21 与 99 分类

- **WHEN** 分别触发宿主闭包异常与引擎内部非预期异常
- **THEN** 前者 21，后者 99；两码的描述与站点语义不混用

#### Scenario: 栈完整性与终止

- **WHEN** 一个多层宿主调用栈抛出异常
- **THEN** cause 含按顺序排列的完整帧；错误点后的字节码不执行

#### Scenario: 并发隔离

- **WHEN** 多个线程并发触发宿主异常
- **THEN** 每个调用只观察到自己的 21/cause/site，互不覆盖
