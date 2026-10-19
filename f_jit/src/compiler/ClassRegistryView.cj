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
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.SourcePos

/**
 * 编译期类注册表**只读快照**（design-m2 §4.1.2、m2 §12.4）。
 *
 * 快照语义与 `PredefinedSnapshot` 同族：`SourceCompiler` 在构造时捕获一份，后续注册变更
 * 不影响已创建的视图。描述符本身不可变，数组做防御性拷贝避免入参集合的后续变更穿透。
 */
protected class ClassRegistrySnapshot {
    public let classes: Array<ClassDescriptor>

    public init(classes: Array<ClassDescriptor>) {
        this.classes = classes.clone()
    }

    public static func empty(): ClassRegistrySnapshot {
        ClassRegistrySnapshot(Array<ClassDescriptor>())
    }
}

/**
 * 前端只读视图：类型注解合法性、字段/方法/构造器解析。
 *
 * **不维护继承图**（v0.8.31）：只查快照中该类的条目；不在表中即未命中，由调用方转成
 * 含类名/成员名的编译错误。
 */
protected class ClassRegistryView {
    private let snapshot: ClassRegistrySnapshot

    public init(snapshot: ClassRegistrySnapshot) {
        this.snapshot = snapshot
    }

    public func classOf(name: String): ?ClassDescriptor {
        for (c in this.snapshot.classes) {
            if (c.name == name) {
                return Some(c)
            }
        }
        None
    }

    public func isRegistered(name: String): Bool {
        match (this.classOf(name)) {
            case Some(_) => true
            case None => false
        }
    }

    /** 类名 → 描述符；未注册 → `SourceCompileException`（消息含类名）。 */
    public func requireClass(name: String, pos: SourcePos, src: String): ClassDescriptor {
        match (this.classOf(name)) {
            case Some(c) => c
            case None =>
                diagFail(DiagKind.TYPE_MISMATCH, src, 0, pos.line, pos.column,
                    '未注册的类名「${name}」（前端只查注册表快照，不做继承谱系上溯，m2 §12.4）')
        }
    }

    public func fieldOf(className: String, field: String): ?PublicField {
        match (this.classOf(className)) {
            case Some(c) =>
                for (f in c.fields) {
                    if (f.name == field) {
                        return Some(f)
                    }
                }
                None
            case None => None
        }
    }

    public func methodOf(className: String, method: String): ?PublicMethod {
        match (this.classOf(className)) {
            case Some(c) =>
                for (m in c.methods) {
                    if (m.name == method) {
                        return Some(m)
                    }
                }
                None
            case None => None
        }
    }

    public func ctorsOf(className: String): Array<PublicCtor> {
        match (this.classOf(className)) {
            case Some(c) => c.ctors
            case None => Array<PublicCtor>()
        }
    }

    /** 字段解析；未注册类 / 未知字段 → 编译错误（消息含类名与成员名）。 */
    public func requireField(className: String, field: String, pos: SourcePos,
        src: String): PublicField {
        let _ = this.requireClass(className, pos, src)
        match (this.fieldOf(className, field)) {
            case Some(f) => f
            case None =>
                diagFail(DiagKind.TYPE_MISMATCH, src, 0, pos.line, pos.column,
                    '类「${className}」未注册字段「${field}」' +
                    '（前端只查注册表条目；继承成员未入表 → 编译错误，m2 §12.4/v0.8.31）')
        }
    }

    /** 方法解析；未注册类 / 未知方法 → 编译错误（消息含类名与成员名）。 */
    public func requireMethod(className: String, method: String, pos: SourcePos,
        src: String): PublicMethod {
        let _ = this.requireClass(className, pos, src)
        match (this.methodOf(className, method)) {
            case Some(m) => m
            case None =>
                diagFail(DiagKind.TYPE_MISMATCH, src, 0, pos.line, pos.column,
                    '类「${className}」未注册方法「${method}」（前端只查注册表条目，m2 §12.4）')
        }
    }

    /** 构造器集；未注册类 → 编译错误。 */
    public func requireCtors(className: String, pos: SourcePos, src: String): Array<PublicCtor> {
        let _ = this.requireClass(className, pos, src)
        this.ctorsOf(className)
    }

    /** 仅供诊断：已注册类名清单。 */
    public func registeredList(): String {
        var sb = StringBuilder()
        sb.append('[')
        var first = true
        for (c in this.snapshot.classes) {
            if (!first) {
                sb.append(', ')
            }
            sb.append(c.name)
            first = false
        }
        sb.append(']')
        sb.toString()
    }

    /** 某个 14 型表达式的静态类知识是否可用。 */
    public static func isHostObjectCode(code: UInt16): Bool {
        code == LocalType.HOST_OBJECT
    }

    /** 值型码（0–3）：捕获恒有效（m2 §14.7）。 */
    public static func isValueCode(code: UInt16): Bool {
        code >= LocalType.I64 && code <= LocalType.UNIT
    }

    /** 便于测试/分析使用的类名数组快照（与 `ClassRegistrySnapshot` 同义）。 */
    public static func of(classes: Array<ClassDescriptor>): ClassRegistryView {
        ClassRegistryView(ClassRegistrySnapshot(classes))
    }
}
