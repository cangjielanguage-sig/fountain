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
 * 源位置 —— design-m1 §2.3.3、plan-m1 S1.5。
 *
 * 站点表（`SiteEntry = (off, line, column)`，规格 §11.6）条目查得后的**值**：`line` 与 `column`
 * 均 **1 起**，列按 **Unicode 码点** 计（与 §8.2 `SourcePos` 同定义）；查询未命中时桥侧取
 * `?SourcePos = None`（§9.16）。
 *
 * 用 `struct` 是因为它是**纯值**、无身份、随站点表被三引擎共享；实现 `Equatable` 让报告与
 * 差分断言可以直接 `==`（plan-m1 S1.5 的「`==` 语义」）。
 */
public struct SourcePos <: Equatable<SourcePos> {
    /** 1 起。 */
    public let line: Int64
    /** 1 起，按 Unicode 码点计。 */
    public let column: Int64

    public const init(line: Int64, column: Int64) {
        this.line = line
        this.column = column
    }

    public operator func ==(other: SourcePos): Bool {
        this.line == other.line && this.column == other.column
    }
}
