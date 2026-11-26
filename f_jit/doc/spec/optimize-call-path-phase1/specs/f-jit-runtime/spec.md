## MODIFIED Requirements

### Requirement: H64 / H65 字段读写

runtime SHALL 提供 H64 `host_get_field(obj, index) → cell` 与 H65 `host_set_field(obj, index, cell) → 0`。H64 对值型字段直取原值、零登记；对句柄型字段（4–14）marshal 为句柄并登记 1 槽（条件分配型）；obj tag≠11 → 8；index/类型防御命中 → 99。H65 对值型字段直存、对句柄型字段 fetch 后存引用；`mutable=false` → 19；obj tag≠11 → 8；不登记新槽；变更型路由 SHALL 复用 M1 §9.15 三条规则。

字段表 SHALL 以**不可变快照**发布：注册期在写锁内构造新快照并原子发布，查找期 SHALL 只读取当前快照并按 index 取出访问器序列，SHALL NOT 在查找期取全局锁、SHALL NOT 拷贝序列、SHALL NOT 产生分配。`accepts` SHALL 在任何锁之外求值（宿主闭包可重入注册）。快照 SHALL 只增不删，唯一例外是测试复位 SHALL 发布空快照。查询结果 SHALL 与「按注册序逐条 `accepts`」的语义逐位一致：同一 index 下多个类的访问器按注册序命中，不同类的 index 可重复。

#### Scenario: 值型与句柄型读

- **WHEN** 分别读取值型字段与句柄型/14 字段
- **THEN** 前者零登记并返回原值；后者登记 1 槽并返回句柄；宿主对象状态不变

#### Scenario: 写后宿主可见

- **WHEN** 通过 H65 修改一个对象字段后调用返回宿主
- **THEN** 宿主在同一对象上观测到修改；同一对象身份不变

#### Scenario: 只读字段双防线

- **WHEN** 对 `mutable=false` 字段执行 H65
- **THEN** 返回 19；前端糖路径已在编译期拒绝

#### Scenario: 并发读与注册不互斥

- **WHEN** 一个线程反复 `find` 已注册的 index，另一线程同时注册新的 index/新类的访问器
- **THEN** 读方要么看到旧快照、要么看到新快照，均返回与注册序一致的唯一访问器；不出现空表、撕裂或死锁

#### Scenario: 重入注册

- **WHEN** 某个访问器的 `accepts` 在执行期间注册另一个访问器
- **THEN** 注册成功；本次查找仍按已取得的快照完成，不自我死锁

#### Scenario: 复位发布空快照

- **WHEN** 测试调用 `resetForTest()` 后查找任意 index
- **THEN** 返回空（未命中），此前取得的旧快照不再被新的查找使用

### Requirement: 宿主异常专用码与异常栈

runtime SHALL 把全部宿主侧调用面（CALL_HOST 闭包、预定义与包装、构造适配器、成员访问器）的未捕获异常统一转码为 `ErrCode.HOST_EXCEPTION=21`；`cause` SHALL 为原始异常全文（含完整仓颉异常栈），桥 SHALL 把完整栈打印到诊断流；`site` SHALL 为对应调用指令偏移；终止语义 SHALL 为 fail-fast（立即结束执行、不提供恢复）。`99` SHALL 仅保留给引擎侧实现缺陷；并发调用中的失败 SHALL 互不串扰。

cause 旁路 SHALL 为**调用线程私有**：按 ctx 地址登记，`record` / `causeOf` / `exceptionOf` / `takeCause` / `clear` SHALL 只作用于当前线程的登记表，SHALL NOT 需要进程级互斥，SHALL NOT 在无记录时产生分配。`JitContext.free` 调用 `clear` 后，该 ctx 的 cause 与异常对象 SHALL 立即不可见，不留残留条目。ctx 的 `create` / `record` / `free` SHALL 在同一线程完成（桥的 finally 收尾结构保证）；跨线程读取 cause SHALL 得到「无记录」，不得读到其它线程的 cause。

#### Scenario: 21 与 99 分类

- **WHEN** 分别触发宿主闭包异常与引擎内部非预期异常
- **THEN** 前者 21，后者 99；两码的描述与站点语义不混用

#### Scenario: 栈完整性与终止

- **WHEN** 一个多层宿主调用栈抛出异常
- **THEN** cause 含按顺序排列的完整帧；错误点后的字节码不执行

#### Scenario: 并发隔离

- **WHEN** 多个线程并发触发宿主异常
- **THEN** 每个调用只观察到自己的 21/cause/site，互不覆盖

#### Scenario: 线程本地不可见

- **WHEN** A 线程记录一个 cause 后，B 线程以同一 ctx 调用 `causeOf` / `takeCause`
- **THEN** B 线程得到「无记录」，不读到 A 线程的 cause 或异常对象

#### Scenario: 释放即清空

- **WHEN** 记录一个 cause 后对同一 ctx 调用 `JitContext.free`
- **THEN** 同线程随后以该地址查询为「无记录」；再次分配得到同一地址时也不会读到旧 cause
