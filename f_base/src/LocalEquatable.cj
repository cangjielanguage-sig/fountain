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
package fountain::f_base

/**
 * 支持 local 实例的相等比较。
 *
 * std 的 `Equatable` 给 `@ local?` / `@ local!` 的 `==` 提供了会抛
 * `UnimplementedException` 的默认体，而子接口不允许把父接口的默认成员重新声明为抽象
 * （`cannot override implemented interface function ... with abstract function`）。
 * 因此这里把真正的比较放到新命名的抽象 hook `localEq` 上，local 路径的 `==` / `!=`
 * 默认实现转调它；普通 `==` 由实现类提供：
 *
 * - `localEq(this @ local?, other: T @ local?)`：唯一抽象成员，由实现类提供；
 * - `==(this @ local?)`：转调 `localEq`；
 * - `@ local!` 的 `==` / `!=`：先转成 `@ local?` 视图，再转调。
 *
 * 普通 `==(other: T)` **不在这里给默认实现**，由实现类（DataAssist 生成）提供。
 * 原因：普通实例没有 local region，把它当成 `@ local?` 视图去调用 localEq 时，
 * 一旦访问非 Copyable 字段就会报 `alloc native local object without local object region`。
 * 普通 `!=` 由 std `Equatable` 的默认实现 `!(this == other)` 提供。
 *
 * 这样 `LocalEquatable<T>` 仍是 `Equatable<T>`，泛型 `where T <: Equatable<T>` 的代码
 * 可以直接使用；同时 local 实例不会命中 std 的抛异常默认体。
 */
public interface LocalEquatable<T> <: Equatable<T> {
    /** 真正执行相等比较；实现类必须重写。只对 local 实例调用。 */
    func localEq(this @ local?, other: T @ local?): Bool

    operator func ==(this @ local?, other: T @ local?): Bool {
        this.localEq(other)
    }

    operator func ==(this @ local!, other: T @ local!): Bool {
        let lhs: LocalEquatable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localEq(rhs)
    }

    operator func !=(this @ local!, other: T @ local!): Bool {
        let lhs: LocalEquatable<T> @ local? = this
        let rhs: T @ local? = other
        !lhs.localEq(rhs)
    }
}
