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
package fountain::f_jit.compiler

import std.collection.ArrayList
import fountain::f_base.UnsafeBytes
import fountain::f_jit.base.SourceCompileException

/**
 * 编译期诊断的**唯一出口**（design §4.3.1「编译期错误只有一个出口」、§8.4）。
 *
 * 全部失败统一走 `SourceCompileException`（不占 §2 运行期错误码、不写 ctx 错误槽）；
 * `DiagnosticsSink` 只收降级 / 告警，**不承担错误通道**（design §4.1 note）。
 *
 * `lineText` = 错误所在源码行的**原文（不含换行）**——这是 §9.16「错误信息包含源码行文本」的兑现。
 * 实现按**字节** Walk（不依赖 String 下标语义，与 `bytecode` 包既有体例一致）。
 */

/**
 * 抛编译期错误：`Nothing` 返回类型让调用点可直接写在 `return` / 表达式位置。
 *
 * 位置一律取**换行规范化之后**的源码口径（design §4.3.1「基于规范化后的源码」），
 * 保证同一源码在任何平台编译出的诊断位置一致（P3 精神）。
 */
internal func diagFail(kind: String, src: String, pos: Int64, line: Int64, column: Int64, hint: String): Nothing {
    throw SourceCompileException(kind, pos, line, column, lineTextAt(src, line), hint)
}

/** 取第 `line` 行（1 起）的源码原文，不含换行符；越界 → 空串。 */
internal func lineTextAt(src: String, line: Int64): String {
    let bs = src.unsafeBytes()
    var cur: Int64 = 1
    var p: Int64 = 0
    // 先走到目标行起点
    while (p < bs.size && cur < line) {
        if (bs[p] == 0x0Au8) {
            cur = cur + 1
        }
        p = p + 1
    }
    if (cur != line) {
        return ''
    }
    var out = ArrayList<UInt8>()
    while (p < bs.size && bs[p] != 0x0Au8) {
        out.add(bs[p])
        p = p + 1
    }
    String.fromUtf8(out.toArray())
}

/** 简约形式：hint 为空（多数词法错误的修复提示已写在 kind 语义里）。 */
internal func diagFail(kind: String, src: String, pos: Int64, line: Int64, column: Int64): Nothing {
    diagFail(kind, src, pos, line, column, '')
}
