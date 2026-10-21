/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_jit.base

/**
 * 桥内部执行结果 —— design-m1 §2.3.6、plan-m1 S1.5、规格 §8 / §8.1 / §3.2。
 *
 * 四个构造器与 cell 载荷**一一对应**（§3.2）：`Int` = i64 直值、`Float` = f64 位型、
 * `Handle` = 句柄 ID（**已按 §8.1 逃逸**，宿主经 `HandleTable.get(id)` 取回对象）、
 * `Unit` = 无返回值（同样是 `errCode = 0`）。
 *
 * **产生点唯一**：`invoke` / `tryInvoke`（private，§7.3.3）三态收尾第 3 步的 `errCode == 0`
 * 分支；`-1`（DEOPT 重跑）/ `-2`（中断）/ `>0`（报告）三条路径**不产生** `JitValue`。
 *
 * **选 `enum` 而非 `Any`**（§2.3.6）：① 与 cell 1:1、零装箱（热路径/批量调用）；② 显式区分值型与
 * 句柄型——两者回收规则不同（`call<T>` 路径解包后**自动回收**窗口逃逸槽，`invoke` 路径的 `Handle`
 * **只能显式 `release`**）。
 *
 * **分派提醒（§2.3.6）**：`Handle` 与 `Int` 载荷同型（Int64）⇒ **按构造器标签分派，
 * 不得按载荷类型判断**；本类型的 `==` 因此按构造器标签实现（`Int(7) != Handle(7)`）。
 *
 * **可见性 `protected`（design D2 / §8.7 D3 结案）**：唯一消费者 `invoke` / `tryInvoke` 为
 * private，无用户面路径；规格 §8 行 827 的 `public` 已同步为 `protected`。
 *
 * **构造器名 `Unit` 的拼写说明**：`Unit` 是仓颉关键字（Appendix/keyword），不能作普通标识符；
 * 为保持规格里的构造器名不变，这里用**原始标识符**（反引号包裹，identifier.md「原始标识符」）
 * 声明为 `` `Unit` ``，引用形如 ``JitValue.`Unit` ``。
 */
protected enum JitValue <: Equatable<JitValue> {
    | Int(Int64)
    | Float(Float64)
    | Handle(Int64)
    | `Unit`

    public operator func ==(other: JitValue): Bool {
        match (this) {
            case Int(a) =>
                match (other) {
                    case Int(b) => a == b
                    case _ => false
                }
            case Float(a) =>
                match (other) {
                    case Float(b) => a == b
                    case _ => false
                }
            case Handle(a) =>
                match (other) {
                    case Handle(b) => a == b
                    case _ => false
                }
            case `Unit` =>
                match (other) {
                    case `Unit` => true
                    case _ => false
                }
        }
    }
}
