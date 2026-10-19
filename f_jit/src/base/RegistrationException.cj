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
 * 注册期拒绝类别（`doc/jit-bytecode-m2.md` v0.8.32 §12.5、`design-m2.md` §2.2）。
 *
 * 六值对应六类硬拒绝：类名冲突四类（已注册类 / 已注册函数名 / 内建类型名 / 关键字）、
 * JSON 谱系类、关闭反射的构建。成员名冲突属「跳过 + diagnostics」，不在此列。
 */
public enum RegistrationRejectKind <: Equatable<RegistrationRejectKind> {
    | DuplicateClass
    | FunctionNameClash
    | BuiltinTypeName
    | Keyword
    | JsonFamily
    | ReflectionUnavailable

    public operator func ==(other: RegistrationRejectKind): Bool {
        match (this) {
            case DuplicateClass =>
                match (other) {
                    case DuplicateClass => true
                    case _ => false
                }
            case FunctionNameClash =>
                match (other) {
                    case FunctionNameClash => true
                    case _ => false
                }
            case BuiltinTypeName =>
                match (other) {
                    case BuiltinTypeName => true
                    case _ => false
                }
            case Keyword =>
                match (other) {
                    case Keyword => true
                    case _ => false
                }
            case JsonFamily =>
                match (other) {
                    case JsonFamily => true
                    case _ => false
                }
            case ReflectionUnavailable =>
                match (other) {
                    case ReflectionUnavailable => true
                    case _ => false
                }
        }
    }
}

/**
 * 注册期拒绝异常 —— **不占运行期 ErrCode**（§12.5「注册期拒绝」）。
 *
 * 只在宿主侧注册调用栈（`Compiler.registerClass` / `registerType<T>()` /
 * `ReflectRegistrar`）抛出：不经字节码 / JIT / 解释器、不入 `.fbc`、不进三引擎差分。
 * 继承 `fountain::f_base.BaseException`，宿主可统一按 fountain 异常捕获并读回
 * `kind` / `name` / `occupiedBy`。
 *
 * 消息模板（三段 + 补救）：
 * `class '<name>' rejected at registration: <kind 说明>〔conflicts with <occupiedBy>〕; <hint>`
 */
public class RegistrationException <: BaseException {
    /** 拒绝类别。 */
    public let kind: RegistrationRejectKind

    /** 被拒类名。 */
    public let name: String

    /** 已占者描述（`class:User` / `func:size` / `builtin:Int64` / `keyword:match`）；无则 `None`。 */
    public let occupiedBy: ?String

    public init(kind: RegistrationRejectKind, name: String, occupiedBy: ?String) {
        super(RegistrationException.buildMessage(kind, name, occupiedBy))
        this.kind = kind
        this.name = name
        this.occupiedBy = occupiedBy
    }

    private static func buildMessage(kind: RegistrationRejectKind, name: String,
        occupiedBy: ?String): String {
        let kindText = match (kind) {
            case DuplicateClass => '类名与已注册类冲突'
            case FunctionNameClash => '类名与已注册函数名冲突'
            case BuiltinTypeName => '类名与内建类型名冲突'
            case Keyword => '类名与关键字冲突'
            case JsonFamily => 'JSON 谱系类拒绝注册'
            case ReflectionUnavailable => '关闭反射的构建无法注册'
        }
        let conflict = match (occupiedBy) {
            case Some(v) => '〔conflicts with ${v}〕'
            case None => ''
        }
        let hint = match (kind) {
            case JsonFamily => 'JSON 谱系为内建类型，无需注册'
            case ReflectionUnavailable => '回退手工注册'
            case _ => '改名（成员名冲突请用手工注册起别名）'
        }
        "class '${name}' rejected at registration: ${kindText}${conflict}; ${hint}"
    }
}
