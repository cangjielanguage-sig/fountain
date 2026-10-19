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
package fountain::f_jit

import std.collection.ArrayList
import std.sync.Mutex
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.RegistrationException
import fountain::f_jit.base.RegistrationRejectKind
import fountain::f_jit.compiler.ClassRegistrySnapshot

/**
 * 宿主侧类注册表（m2 §12.4/§12.5、design-m2 §6.1.1）。
 *
 * **快照语义**：`snapshot()` 返回调用时刻的类清单副本；之后 `register` 不影响旧快照，
 * 因此已编译单元持有的是注册当时的静态知识（§8.4）。
 *
 * **注册期拒绝**（v0.8.32）：类名冲突四类——已注册类 / 已注册函数名 / 内建类型名 /
 * 关键字——一律抛 `RegistrationException` 且**不登记**。成员名冲突不在此层处理
 * （走「跳过 + `RegistrationSkipped`」，见 `ReflectRegistrar`）。
 *
 * 反射自动注册生成的包装函数不进 `ClassDescriptor`（后者只有字段/方法/构造器），
 * 由本表额外持有，`Compiler.snapshot()` 统一并入预定义函数快照。
 */
protected class ClassRegistry {
    private let mtx: Mutex = Mutex()
    private let classes: ArrayList<ClassDescriptor> = ArrayList<ClassDescriptor>()
    /** 已注册的预定义函数名（用于类名 vs 函数名冲突判定）。 */
    private let functions: ArrayList<String> = ArrayList<String>()
    /** 反射自动注册生成的包装函数（静态 prop/let、getter/setter 等）。 */
    private let autoFns: ArrayList<PredefinedFunction> = ArrayList<PredefinedFunction>()

    public init() {}

    /** 登记一个已注册函数名（由 `Compiler.registerFunction` 调用）。 */
    public func noteFunction(name: String): Unit {
        synchronized(this.mtx) {
            if (this.indexOfFunctionLocked(name) < 0) {
                this.functions.add(name)
            }
        }
    }

    /** 注销函数名（由 `Compiler.unregisterFunction` 调用）。 */
    public func removeFunction(name: String): Unit {
        synchronized(this.mtx) {
            let i = this.indexOfFunctionLocked(name)
            if (i >= 0) {
                this.functions.remove(at: i)
            }
        }
    }

    /** 注册一个类；拒绝 ⇒ `RegistrationException` 且注册表不变。 */
    public func register(desc: ClassDescriptor): Unit {
        ClassRegistry.rejectIfIllegalName(desc.name)
        synchronized(this.mtx) {
            if (this.indexOfClassLocked(desc.name) >= 0) {
                throw RegistrationException(RegistrationRejectKind.DuplicateClass, desc.name,
                    Some('class:${desc.name}'))
            }
            if (this.indexOfFunctionLocked(desc.name) >= 0) {
                throw RegistrationException(RegistrationRejectKind.FunctionNameClash, desc.name,
                    Some('func:${desc.name}'))
            }
            this.classes.add(desc)
        }
    }

    /** 编译期只读视图的快照（深拷贝类清单；描述符自身不可变）。 */
    public func snapshot(): ClassRegistrySnapshot {
        synchronized(this.mtx) {
            ClassRegistrySnapshot(this.classes.toArray())
        }
    }

    /** 名字是否已被预定义函数/自动包装函数占用（反射逐成员跳过判定）。 */
    public func hasFunction(name: String): Bool {
        synchronized(this.mtx) {
            this.indexOfFunctionLocked(name) >= 0
        }
    }

    public func resolve(name: String): ?ClassDescriptor {
        synchronized(this.mtx) {
            let i = this.indexOfClassLocked(name)
            if (i >= 0) {
                Some(this.classes[i])
            } else {
                None
            }
        }
    }

    /** 反射自动注册追加的包装函数（按注册序）。 */
    public func autoFunctions(): Array<PredefinedFunction> {
        synchronized(this.mtx) {
            this.autoFns.toArray()
        }
    }

    /** 反射/手工注册内部：追加一个自动包装函数（同名幂等跳过）。 */
    public func addAutoFunction(f: PredefinedFunction): Unit {
        synchronized(this.mtx) {
            let i = this.indexOfFunctionLocked(f.name)
            if (i >= 0) {
                return
            }
            this.functions.add(f.name)
            this.autoFns.add(f)
        }
    }

    // ---- 类名合法性（v0.8.32 四类冲突）----

    private static func rejectIfIllegalName(name: String): Unit {
        if (ClassRegistry.isBuiltinName(name)) {
            throw RegistrationException(RegistrationRejectKind.BuiltinTypeName, name,
                Some('builtin:${name}'))
        }
        if (ClassRegistry.isKeywordName(name)) {
            throw RegistrationException(RegistrationRejectKind.Keyword, name,
                Some('keyword:${name}'))
        }
    }

    /** 内建类型名（源语言类型注解可解析的名字——注册类不得遮蔽）。 */
    public static func isBuiltinName(name: String): Bool {
        match (name) {
            case 'Int64' | 'Int32' | 'Int16' | 'Int8' | 'UInt64' | 'UInt32' | 'UInt16' |
                 'UInt8' | 'Float64' | 'Float32' | 'Bool' | 'Unit' | 'String' | 'Rune' |
                 'Decimal' | 'DateTime' | 'Duration' | 'Range' | 'Regex' | 'ArrayList' |
                 'HashMap' | 'List' | 'Map' | 'Any' | 'Object' | 'Nothing' | 'Closure' |
                 'Option' => true
            case _ => false
        }
    }

    /** 仓颉语言关键字（注册类名不得与关键字冲突）。 */
    public static func isKeywordName(name: String): Bool {
        match (name) {
            case 'abstract' | 'as' | 'break' | 'case' | 'catch' | 'class' | 'const' |
                 'continue' | 'do' | 'else' | 'enum' | 'extend' | 'false' | 'finally' |
                 'for' | 'foreign' | 'func' | 'if' | 'import' | 'in' | 'init' | 'interface' |
                 'is' | 'let' | 'macro' | 'main' | 'match' | 'mut' | 'new' | 'not' | 'null' |
                 'open' | 'operator' | 'override' | 'package' | 'private' | 'prop' |
                 'protected' | 'public' | 'quote' | 'redef' | 'return' | 'sealed' | 'spawn' |
                 'static' | 'struct' | 'super' | 'synchronized' | 'this' | 'throw' | 'true' |
                 'try' | 'type' | 'unsafe' | 'var' | 'where' | 'while' => true
            case _ => false
        }
    }

    // ---- 内部（调用方持锁）----

    private func indexOfClassLocked(name: String): Int64 {
        var i = 0
        while (i < this.classes.size) {
            if (this.classes[i].name == name) {
                return i
            }
            i = i + 1
        }
        -1
    }

    private func indexOfFunctionLocked(name: String): Int64 {
        var i = 0
        while (i < this.functions.size) {
            if (this.functions[i] == name) {
                return i
            }
            i = i + 1
        }
        -1
    }
}

/** 供 `ClassRegistryView` 同口径查询的宿主侧辅助（桥边界校验用）。 */
protected func classFieldOf(desc: ?ClassDescriptor, field: String): ?PublicField {
    match (desc) {
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

/** 宿主侧方法解析（与 `ClassRegistryView.methodOf` 同数据）。 */
protected func classMethodOf(desc: ?ClassDescriptor, method: String): ?PublicMethod {
    match (desc) {
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

/** 宿主侧构造器集（与 `ClassRegistryView.ctorsOf` 同数据）。 */
protected func classCtorsOf(desc: ?ClassDescriptor): Array<PublicCtor> {
    match (desc) {
        case Some(c) => c.ctors
        case None => Array<PublicCtor>()
    }
}
