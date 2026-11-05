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
package fountain::f_svg

import std.collection.*

/** 引用深度上限：pattern / marker / gradient 共用。 */
internal let SVG_MAX_REFERENCE_DEPTH: Int64 = 64

/**
 * 一次渲染内的跨嵌套引用守卫。
 *
 * 嵌套渲染器与 tile 渲染共享同一实例：内容通过 fill / marker-* 指回祖先时只 warning，
 * 合法但超过深度上限的链抛 `Limit`。
 */
internal class SvgRenderGuard {
    private let stack = ArrayList<Int64>()

    /** 进入一层引用；返回 `false` 表示命中循环，调用方应停止展开。 */
    func enter(identity: Int64, kind: String, warnings: ArrayList<String>): Bool {
        for (value in this.stack) {
            if (value == identity) {
                warnings.add("${kind} 存在内容自引用循环，已停止展开")
                return false
            }
        }
        if (Int64(this.stack.size) >= SVG_MAX_REFERENCE_DEPTH) {
            throw SvgException(
                "${kind} 内容嵌套深度超过上限 ${SVG_MAX_REFERENCE_DEPTH}",
                kind: SvgErrorKind.Limit
            )
        }
        this.stack.add(identity)
        true
    }

    func leave(): Unit {
        if (this.stack.size > 0) {
            this.stack.remove(at: this.stack.size - 1)
        }
    }
}
