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
macro package fountain::f_jit.macros

import std.ast.*
import fountain::f_macros.*

/**
 * `@IgnoreJitBinding`（D10）：成员级退出标记，配合 `@JitBind` 使用。
 *
 * 被标注的成员**原样保留**在类体里（宿主要能正常调用），只是不进注册表：
 * 子宏先把成员名通过 `setItem('member', …)` 发给父宏 `@JitBind`，父宏在遍历
 * 成员时按名字跳过。按名字忽略 ⇒ 同名重载全部跳过。
 *
 * 只允许出现在 `@JitBind` 直接修饰的类/接口体内部；用在别处由
 * `assertParentContext` 给出编译错误（这是刻意行为，不是误用兜底）。
 */
public macro IgnoreJitBinding(input: Tokens): Tokens {
    assertParentContext('JitBind')
    let decl = parseDecl(input)
    setItem('member', identifierOf(decl))
    input
}

/** 取成员标识符；若是尚未展开的嵌套宏声明，向下穿透到真实声明。 */
private func identifierOf(decl: Decl): String {
    match (decl) {
        case m: MacroExpandDecl =>
            var inner: Decl = m.macroInputDecl
            while (let md: MacroExpandDecl <- inner) {
                inner = md.macroInputDecl
            }
            inner.identifier.value
        case _ => decl.identifier.value
    }
}
