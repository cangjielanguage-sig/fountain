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

import fountain::f_base.BaseException

/**
 * 编译期错误载体 —— design-m1 §2.3.2、plan-m1 S1.9、规格 §8.4 / §9.16。
 *
 * **不占用运行期错误码**（spec「与运行期错误分离」）：编译期失败在 `compile` 时刻抛出，
 * **不写 ctx 错误槽、不涉及 `ErrCode`**——错误码是「世界内执行」的码，编译期不在那条路径上
 * （design-m2 §12.5 对注册期异常用的是同一套体例）。
 *
 * 成员口径（§2.3.2）：
 *
 * - `kind`：`DiagKind` 常量字符串，清单见 §4.3.9（词法族 + 解析/名字/校验族）；测试按 kind 断言；
 * - `position`：源码字节位置；
 * - `line` / `column`：**1 起**，列按 Unicode 码点；
 * - `lineText`：**错误所在源码行原文（不含换行）**——这是「错误信息包含源码行文本」的兑现；
 * - `hint`：修复提示（未注册函数的场景附已注册清单，§8.4 需求 4）。
 *
 * 同样继承 `fountain::f_base.BaseException`，`message` 由六个字段组装后经 `super(message)` 转发。
 */
public class SourceCompileException <: BaseException {
    /** 错误分类（`DiagKind` 常量，§4.3.9）。 */
    public let kind: String
    /** 源码字节位置。 */
    public let position: Int64
    /** 1 起。 */
    public let line: Int64
    /** 1 起，按 Unicode 码点计。 */
    public let column: Int64
    /** 错误所在源码行原文（不含换行）。 */
    public let lineText: String
    /** 修复提示（含已注册函数清单等）。 */
    public let hint: String

    public init(kind: String, position: Int64, line: Int64, column: Int64, lineText: String, hint: String) {
        super('${kind} @ ${line}:${column}（字节位置 ${position}）：${lineText}${hintSuffix(hint)}')
        this.kind = kind
        this.position = position
        this.line = line
        this.column = column
        this.lineText = lineText
        this.hint = hint
    }
}

/** `hint` 为空时不在报告文本里留下空的「提示：」段。 */
private func hintSuffix(hint: String): String {
    if (hint.isEmpty()) {
        ''
    } else {
        '｜提示：${hint}'
    }
}
