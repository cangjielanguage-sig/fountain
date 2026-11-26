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
package fountain::f_rule.table

/**
 * 决策表的两条执行路径（`doc/11-assembly.md` §4.5）。
 *
 * 同一实例只能走其中一条：装配路径（`compileInto`）与聚合路径（`TableExecutor`）
 * 都会触发规则，混合使用会重复执行。同模式重复使用合法。
 */
public enum TableMode <: ToString & Equatable<TableMode> {
    /** 未使用。 */
    | Unbound
    /** 已被编译进规则集（议程路径）。 */
    | Assembled
    /** 已被 `TableExecutor` 执行（聚合路径）。 */
    | Executed

    public func toString(): String {
        match (this) {
            case Unbound => "Unbound"
            case Assembled => "Assembled"
            case Executed => "Executed"
        }
    }

    public operator func ==(other: TableMode): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: TableMode): Bool {
        !(this == other)
    }
}
