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
 * 支持 local 实例的比较。
 *
 * 继承 [LocalEquatable]：真正的排序比较放在抽象 hook `localCompare` 上，
 * `@ local?` / `@ local!` 的 `compare` 与 `<` / `>` / `<=` / `>=` 默认转调它。
 *
 * 普通（`@ ~local`）的 `compare` **要求实现类提供**（DataAssist 生成非模态版本），
 * 普通运算符直接基于普通 `compare`，不经过 local 视图：
 * 普通实例没有 local region，若把普通实例当 `@ local?` 去调 `localCompare`，
 * 访问非 Copyable 字段时会报 `alloc native local object without local object region`。
 *
 * `localEq` 有默认实现（`compare == EQ`），因此只实现 `localCompare` 的类也能获得
 * 完整的 local 相等比较；`equal` + `compare` 同时存在时，DataAssist 会生成显式的
 * `localEq` 覆盖它。
 *
 * 注意：本接口已继承 `LocalEquatable`，不要再把 `LocalEquatable` 显式加进同一个类的
 * 父接口列表。由于 `Equatable` 同时经 `LocalEquatable` 与 `Comparable` 两条路径，
 * 这里必须显式实现普通与 `@ local?` 的 `!=`，否则编译器会报 must be implemented。
 */
public interface LocalComparable<T> <: LocalEquatable<T> & Comparable<T> {
    /** 真正执行排序比较；实现类必须重写。只对 local 实例调用。 */
    func localCompare(this @ local?, other: T @ local?): Ordering

    /** 默认相等语义：比较结果为 `EQ`。 */
    func localEq(this @ local?, other: T @ local?): Bool {
        this.localCompare(other) == EQ
    }

    operator func ==(this @ local?, other: T @ local?): Bool {
        this.localEq(other)
    }

    operator func ==(this @ local!, other: T @ local!): Bool {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localEq(rhs)
    }

    operator func !=(this @ local!, other: T @ local!): Bool {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        !lhs.localEq(rhs)
    }

    operator func !=(this @ local?, other: T @ local?): Bool {
        !(this.localEq(other))
    }

    /** 普通比较的运算符：基于普通 `compare`，不经过 local 视图。 */
    operator func ==(other: T): Bool {
        this.compare(other) == EQ
    }

    /** 显式实现普通 `!=`，消除 LocalEquatable / Comparable 两条 Equatable 路径的歧义。 */
    operator func !=(other: T): Bool {
        !(this == other)
    }

    operator func <(other: T): Bool {
        this.compare(other) == LT
    }

    operator func >(other: T): Bool {
        this.compare(other) == GT
    }

    operator func <=(other: T): Bool {
        this.compare(other) != GT
    }

    operator func >=(other: T): Bool {
        this.compare(other) != LT
    }

    func compare(this @ local?, other: T @ local?): Ordering {
        this.localCompare(other)
    }

    func compare(this @ local!, other: T @ local!): Ordering {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localCompare(rhs)
    }

    operator func <(this @ local?, other: T @ local?): Bool {
        this.localCompare(other) == LT
    }

    operator func <(this @ local!, other: T @ local!): Bool {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localCompare(rhs) == LT
    }

    operator func >(this @ local?, other: T @ local?): Bool {
        this.localCompare(other) == GT
    }

    operator func >(this @ local!, other: T @ local!): Bool {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localCompare(rhs) == GT
    }

    operator func <=(this @ local?, other: T @ local?): Bool {
        this.localCompare(other) != GT
    }

    operator func <=(this @ local!, other: T @ local!): Bool {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localCompare(rhs) != GT
    }

    operator func >=(this @ local?, other: T @ local?): Bool {
        this.localCompare(other) != LT
    }

    operator func >=(this @ local!, other: T @ local!): Bool {
        let lhs: LocalComparable<T> @ local? = this
        let rhs: T @ local? = other
        lhs.localCompare(rhs) != LT
    }
}
