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
import std.reflect.*
import std.sync.Mutex
import fountain::f_base.UnsafeBytes
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DiagCode
import fountain::f_jit.base.DiagnosticLevel
import fountain::f_jit.base.DiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.RegistrationException
import fountain::f_jit.base.RegistrationRejectKind
import fountain::f_jit.runtime.HostFieldTable

/**
 * 反射自动注册（m2 §12.5、design-m2 §6.1.2）。
 *
 * 仅在**宿主侧注册期**使用：枚举 `std.reflect` 可见的 public 成员，生成与手工注册等价的
 * `ClassDescriptor` + 包装函数 + 字段访问器。字节码/JIT 执行路径零反射。
 *
 * 逐成员尽力注册：
 * - `static var` / `static mut prop` 永久跳过（附 B）；
 * - 类型不在映射表 → 该成员跳过 + `RegistrationSkipped`；
 * - 命名冲突 → 该名跳过 + `RegistrationSkipped`；
 * - JSON 谱系类 / 关闭反射 → `RegistrationException` 且**不登记**（v0.8.32）。
 */
protected class ReflectRegistrar {
    /**
     * 反射元数据保活表（类名 → `TypeInfo`）。
     *
     * 生成的访问器 / 方法绑定 / 构造适配器只**闭包捕获成员级** `*Info`；而 `getValue` /
     * `apply` / `ConstructorInfo.apply` 内部还要用**声明类的 `TypeInfo`** 做参数与返回值的
     * ABI 转换。若注册函数返回后 `ClassTypeInfo` 失去强引用，该元数据可能被回收，后续调用
     * 就在转换阶段读到失效指针。
     *
     * 实测形态（2026-10-20）：SIGSEGV 落在**被调方法体内**（`ReflectUser.greet` 的
     * `StringBuilder.append`），而 `ApplyCJMethod(..., TypeInfo*)` 的最后一个实参已悬空——
     * 即崩溃点离真正的失效点很远，只在并发/GC 压力下偶发。
     *
     * 故按类名保留一份强引用；重复注册同一类不增长。
     */
    private static let retained: ArrayList<TypeInfo> = ArrayList<TypeInfo>()
    private static let retainedNames: ArrayList<String> = ArrayList<String>()
    private static let retainedMtx = Mutex()

    private static func retainClass(cls: ClassTypeInfo): Unit {
        synchronized(retainedMtx) {
            var i = 0
            while (i < retainedNames.size) {
                if (retainedNames[i] == cls.name) {
                    return
                }
                i = i + 1
            }
            retainedNames.add(cls.name)
            retained.add(cls)
        }
    }

    /** 测试：已保活的类数（重复注册不增长）。 */
    public static func retainedCount(): Int64 {
        synchronized(retainedMtx) {
            retainedNames.size
        }
    }

    /** 测试：清空保活表（用例隔离）。 */
    public static func resetRetainedForTest(): Unit {
        synchronized(retainedMtx) {
            retainedNames.clear()
            retained.clear()
        }
    }

    /** 注册 `T`；`enabled=false` 模拟关闭反射的构建（测试与宿主配置可判）。 */
    public static func registerType<T>(into!: ClassRegistry, diag!: DiagnosticsSink,
        enabled!: Bool = true, bindings!: JitBindings = JitBindings.empty()): Unit
        where T <: Object {
        var typeName = '<unknown>'
        try {
            typeName = TypeInfo.of<T>().name
        } catch (_: Exception) {
            typeName = '<unknown>'
        }
        if (!enabled) {
            throw RegistrationException(RegistrationRejectKind.ReflectionUnavailable, typeName, None)
        }
        if (ReflectRegistrar.isJsonFamily(typeName)) {
            throw RegistrationException(RegistrationRejectKind.JsonFamily, typeName, None)
        }
        // 直接取 TypeInfo（不再经 `?TypeInfo` 中转：那条路径上 `None` 分支恒不可达，
        // 编译器会报 unreachable pattern——2026-10-20 清理）。
        let info = try {
            TypeInfo.of<T>()
        } catch (_: Exception) {
            throw RegistrationException(RegistrationRejectKind.ReflectionUnavailable, typeName, None)
        }
        let cls = match (info) {
            case c: ClassTypeInfo => c
            case _ =>
                throw RegistrationException(RegistrationRejectKind.ReflectionUnavailable,
                    typeName, None)
        }
        let name = cls.name
        // `@JitBind` 在包初始化期把绑定登记到「类全限定名 → 绑定」表里。
        // 显式传参**合并**到自动登记之上（同成员以显式为准），不整体取代：否则只想改一个方法
        // 也会把字段/构造器/静态成员的绑定一起丢掉，退回反射后引用型成员还会撞上「默认拒绝」。
        let effective = JitBindSupport.enrolledOf(name).withOverrides(bindings)
        ReflectRegistrar.retainClass(cls)
        let ancestry = ReflectRegistrar.ancestryOf(cls)

        let fields = ArrayList<PublicField>()
        let methods = ArrayList<PublicMethod>()
        let ctors = ArrayList<PublicCtor>()
        let auto = ArrayList<PredefinedFunction>()
        let pending = ArrayList<() -> Unit>()
        let localNames = ArrayList<String>()
        // 父类字段先占号再登记自有字段：字段表是全局 index 空间，子类自有 index 必须避开
        // 父类已用的 0..k-1（否则 bucket 撞车，accepts 先命中父类访问器读错字段）。
        ReflectRegistrar.mergeAncestorFields(cls, ancestry, fields, pending, diag)

        // ---- 实例字段（let / var）----
        for (v in cls.instanceVariables) {
            if (ReflectRegistrar.isIgnored(effective, v.name)) {
                continue
            }
            // m3 §3/§12-4：HostObject 字段类型**不扩展**至 15（Any）——逐成员跳过 + 诊断。
            if (v.typeInfo.name == 'Any') {
                ReflectRegistrar.skip(diag, '${name}.${v.name}',
                    '字段类型不得为 Any（15 仅限局部 / 形参 / 返回，m3 §3/§12-4）')
                continue
            }
            let codeOpt = ReflectRegistrar.mapType(v.typeInfo)
            if (codeOpt.isNone()) {
                ReflectRegistrar.skip(diag, '${name}.${v.name}', '字段类型不可映射')
                continue
            }
            let code = match (codeOpt) {
                case Some(c) => c
                case None => 0u16
            }
            let idx = UInt16(fields.size)
            let typeRef: ?String = if (code == LocalType.HOST_OBJECT) {
                Some(v.typeInfo.name)
            } else {
                None
            }
            let mutable = v.isMutable()
            fields.add(PublicField(name: v.name, `type`: code, index: idx,
                mutable: mutable, typeRef: typeRef))
            let member = v
            let rowName = name
            let rowCode = code
            let rowIdx = idx
            let rowMutable = mutable
            let rowAncestry = ancestry
            // 有类型化绑定时优先用它（`@JitBind` 生成：直接读写字段，不经 MCC）
            let typedField = effective.fieldOf(v.name)
            pending.add({ =>
                HostFieldTable.register(index: rowIdx, `type`: rowCode, mutable: rowMutable,
                    accepts: { o => ReflectRegistrar.isInstanceOf(o, rowAncestry) },
                    getter: { o =>
                        match (typedField) {
                            case Some(b) => b.get(o)
                            case None => member.getValue(o)
                        }
                    },
                    setter: { o, x =>
                        match (typedField) {
                            case Some(b) => match (b.set) {
                                case Some(s) => s(o, x)
                                case None => member.setValue(o, x)
                            }
                            case None => member.setValue(o, x)
                        }
                    })
            })
            let _ = rowName
        }

        // ---- 实例属性（prop / mut prop）----
        for (p in cls.instanceProperties) {
            // SDK 1.3.0-alpha 的反射对 mut prop 报首字母大写（如 `Score`）；
            // 源面成员名仍为声明名，这里统一归一为首字母小写。
            let propName = if (p.isMutable()) {
                ReflectRegistrar.lowerFirst(p.name)
            } else {
                p.name
            }
            if (ReflectRegistrar.isIgnored(effective, p.name) ||
                ReflectRegistrar.isIgnored(effective, propName)) {
                continue
            }
            let codeOpt = ReflectRegistrar.mapType(p.typeInfo)
            if (codeOpt.isNone()) {
                ReflectRegistrar.skip(diag, '${name}.${p.name}', '属性类型不可映射')
                continue
            }
            let code = match (codeOpt) {
                case Some(c) => c
                case None => 0u16
            }
            let okClaim = ReflectRegistrar.claimName(propName, into, localNames, diag, '${name}.${propName}')
            if (!okClaim) {
                continue
            }
            let getter = PredefinedFunction(propName, [LocalType.HOST_OBJECT], code,
                { args => p.getValue(args[0]) })
            methods.add(PublicMethod(name: propName, bind: getter))
            auto.add(getter)
            if (p.isMutable()) {
                let setterName = 'set' + ReflectRegistrar.upperFirst(propName)
                if (!ReflectRegistrar.claimName(setterName, into, localNames, diag,
                    '${name}.${propName}')) {
                    continue
                }
                let setter = PredefinedFunction(setterName,
                    [LocalType.HOST_OBJECT, code], LocalType.UNIT,
                    { args =>
                        p.setValue(args[0], args[1])
                        ()
                    })
                methods.add(PublicMethod(name: setterName, bind: setter))
                auto.add(setter)
            }
        }

        // ---- 实例方法（func）----
        for (f in cls.instanceFunctions) {
            if (ReflectRegistrar.isIgnored(effective, f.name)) {
                continue
            }
            let codeOpt = ReflectRegistrar.mapType(f.returnType)
            if (codeOpt.isNone()) {
                ReflectRegistrar.skip(diag, '${name}.${f.name}', '返回类型不可映射')
                continue
            }
            let paramCodes = ReflectRegistrar.mapParams(f.parameters)
            if (paramCodes.isNone()) {
                ReflectRegistrar.skip(diag, '${name}.${f.name}', '参数类型不可映射')
                continue
            }
            let bindName = '${name}.${f.name}'
            let sig = ReflectRegistrar.prepend(LocalType.HOST_OBJECT,
                ReflectRegistrar.unwrapParams(paramCodes))
            let ret = ReflectRegistrar.unwrapCode(codeOpt)
            // GAP-13：反射 `apply` 在**引用型**参数/返回上会走 MCC 的 `ArgValue` 转换，实测必现
            // SIGSEGV（栈顶落在被调方法体内，离真正失效点很远）。默认不再生成这种绑定：
            // 宁可注册期少一个方法（+ 一条 Warn 诊断），也不要在 JIT 里直接杀进程。
            // 需要它的宿主用 `overrides` 提供类型化实现（M2.1），此时本条不跳过。
            if (!ReflectRegistrar.hasOverrideName(effective.methods, f.name) &&
                ReflectRegistrar.unsafeForReflect(sig, ret)) {
                ReflectRegistrar.skip(diag, '${name}.${f.name}',
                    '引用型参数/返回在反射 apply 上会 SIGSEGV（GAP-13），请用 overrides 提供类型化绑定')
                continue
            }
            let bind = PredefinedFunction(bindName, sig, ret,
                { args => f.apply(args[0], ReflectRegistrar.tail(args)) },
                retName: ReflectRegistrar.retNameOf(f.returnType, ret))
            methods.add(PublicMethod(name: f.name, bind: bind))
            auto.add(bind)
        }

        // ---- 静态 let / 只读 prop / 静态 func ----
        for (v in cls.staticVariables) {
            if (ReflectRegistrar.isIgnored(effective, v.name)) {
                continue
            }
            if (v.isMutable()) {
                ReflectRegistrar.skip(diag, '${name}.${v.name}', 'static var 永久排除（附 B）')
                continue
            }
            let codeOpt = ReflectRegistrar.mapType(v.typeInfo)
            if (codeOpt.isNone()) {
                ReflectRegistrar.skip(diag, '${name}.${v.name}', '静态字段类型不可映射')
                continue
            }
            if (!ReflectRegistrar.claimName(v.name, into, localNames, diag, '${name}.${v.name}')) {
                continue
            }
            auto.add(match (effective.staticOf(v.name)) {
                case Some(typed) => typed
                case None => PredefinedFunction(v.name, Array<UInt16>(),
                    ReflectRegistrar.unwrapCode(codeOpt), { _ => v.getValue() })
            })
        }
        for (p in cls.staticProperties) {
            if (ReflectRegistrar.isIgnored(effective, p.name)) {
                continue
            }
            if (p.isMutable()) {
                ReflectRegistrar.skip(diag, '${name}.${p.name}', 'static mut prop 永久排除（附 B）')
                continue
            }
            let codeOpt = ReflectRegistrar.mapType(p.typeInfo)
            if (codeOpt.isNone()) {
                ReflectRegistrar.skip(diag, '${name}.${p.name}', '静态属性类型不可映射')
                continue
            }
            if (!ReflectRegistrar.claimName(p.name, into, localNames, diag, '${name}.${p.name}')) {
                continue
            }
            auto.add(match (effective.staticOf(p.name)) {
                case Some(typed) => typed
                case None => PredefinedFunction(p.name, Array<UInt16>(),
                    ReflectRegistrar.unwrapCode(codeOpt), { _ => p.getValue() })
            })
        }
        for (f in cls.staticFunctions) {
            if (ReflectRegistrar.isIgnored(effective, f.name)) {
                continue
            }
            let codeOpt = ReflectRegistrar.mapType(f.returnType)
            if (codeOpt.isNone()) {
                ReflectRegistrar.skip(diag, '${name}.${f.name}', '静态函数返回类型不可映射')
                continue
            }
            let paramCodes = ReflectRegistrar.mapParams(f.parameters)
            if (paramCodes.isNone()) {
                ReflectRegistrar.skip(diag, '${name}.${f.name}', '静态函数参数类型不可映射')
                continue
            }
            if (!ReflectRegistrar.claimName(f.name, into, localNames, diag, '${name}.${f.name}')) {
                continue
            }
            let staticType = TypeInfo.of<T>()
            auto.add(match (effective.staticOf(f.name)) {
                case Some(typed) => typed
                case None => PredefinedFunction(f.name, ReflectRegistrar.unwrapParams(paramCodes),
                    ReflectRegistrar.unwrapCode(codeOpt),
                    { args => f.apply(staticType, args) },
                    retName: ReflectRegistrar.retNameOf(f.returnType,
                        ReflectRegistrar.unwrapCode(codeOpt)))
            })
        }

        // ---- 构造器 ----
        for (c in cls.constructors) {
            match (ReflectRegistrar.buildCtor(c, bindings: effective)) {
                case Some(pc) => ctors.add(pc)
                case None =>
                    ReflectRegistrar.skip(diag, '${name}.<init>', '构造器参数/返回类型不可映射')
            }
        }

        // 父类方法/属性（X）：子类描述符内重新登记，子类同名成员优先。
        ReflectRegistrar.mergeAncestorMethods(cls, ancestry, methods, diag)

        // 全量构建完成后一次性登记：任何拒绝都不会留下半成品。
        let (mergedMethods, mergedFns) = ReflectRegistrar.applyOverrides(methods.toArray(),
            auto.toArray(), effective.methods)
        let descObj = ClassDescriptor(name: name, fields: fields.toArray(),
            methods: mergedMethods, ctors: ctors.toArray(),
            parents: ReflectRegistrar.parentsOf(ancestry))
        into.register(descObj)
        for (p in pending) {
            p()
        }
        for (f in mergedFns) {
            into.addAutoFunction(f)
        }
        // M2.3：为每个类合成 `$as$<C>` —— `as C` 的运行期判定（`(14) -> Bool`）。
        // 名字带 `$`，与用户标识符不可能相撞；判定走反射父链，子类实例算命中。
        into.addAutoFunction(PredefinedFunction('$as$' + name,
            [LocalType.HOST_OBJECT], LocalType.BOOL,
            { args =>
                match (args[0]) {
                    case o: Object => ReflectRegistrar.isInstanceOfClass(o, name)
                    case _ => false
                }
            }))
    }

    /**
     * 注册接口（X）：无 `T <: Object` 约束（接口不是 Object 子类型），方法绑定来自 `@JitBind`。
     *
     * 反射能列出接口方法，但它们是**抽象声明**——`InstanceFunctionInfo.apply` 抛
     * `Cannot invoke abstract function`。因此这里不提供反射回退：没有 `@JitBind` 就拒绝。
     */
    public static func registerInterface<I>(into!: ClassRegistry, diag!: DiagnosticsSink,
        enabled!: Bool = true, bindings!: JitBindings = JitBindings.empty()): Unit {
        let info = TypeInfo.of<I>()
        let iface = match (info) {
            case i: InterfaceTypeInfo => i
            case _ =>
                throw RegistrationException(RegistrationRejectKind.ReflectionUnavailable,
                    info.name, Some('不是接口类型'))
        }
        let name = iface.name
        if (!enabled) {
            throw RegistrationException(RegistrationRejectKind.ReflectionUnavailable, name, None)
        }
        let auto = JitBindSupport.enrolledOf(name)
        let effective = auto.withOverrides(bindings)
        if (effective.methods.size == 0) {
            throw RegistrationException(RegistrationRejectKind.ReflectionUnavailable, name,
                Some('接口必须用 @JitBind 提供方法绑定（反射无法调用抽象方法）'))
        }
        let methods = ArrayList<PublicMethod>()
        let parents = ArrayList<String>()
        for (pname in effective.parents) {
            parents.add(pname)
            match (into.resolve(pname)) {
                case Some(pd) =>
                    for (m in pd.methods) {
                        if (!ReflectRegistrar.hasMethod(methods, m.name)) {
                            methods.add(m)
                        }
                    }
                case None => ()
            }
        }
        for (m in effective.methods) {
            if (!ReflectRegistrar.hasMethod(methods, m.name)) {
                methods.add(m)
            }
        }
        into.register(ClassDescriptor(name: name, fields: Array<PublicField>(),
            methods: methods.toArray(), ctors: Array<PublicCtor>(),
            parents: parents.toArray(), isInterface: true))
        for (m in methods) {
            into.addAutoFunction(m.bind)
        }
        // 接口的 `$as$<I>`：与类同名的转换判定（`as I` / 14 形参校验共用）
        into.addAutoFunction(PredefinedFunction('$as$' + name,
            [LocalType.HOST_OBJECT], LocalType.BOOL,
            { args =>
                match (args[0]) {
                    case o: Object => ReflectRegistrar.isInstanceOfHost(o, name)
                    case _ => false
                }
            }))
    }

    /** 字段名是否已在描述符中（子类优先，重复即跳过）。 */
    private static func hasField(fields: ArrayList<PublicField>, name: String): Bool {
        for (f in fields) {
            if (f.name == name) {
                return true
            }
        }
        false
    }

    /** 方法名是否已在描述符中（注册表以名字为键，重载同名视作同一条）。 */
    private static func hasMethod(methods: ArrayList<PublicMethod>, name: String): Bool {
        for (m in methods) {
            if (m.name == name) {
                return true
            }
        }
        false
    }

    /**
     * 成员名是否被 `@IgnoreJitBinding` 排除（D10）。
     *
     * 排除是**真不登记**：反射侧看到这个名字就不再生成自动包装，否则宏虽然没给绑定，
     * 这里会退回反射包装，脚本仍能调用，忽略标记等于没生效。
     */
    private static func isIgnored(b: JitBindings, name: String): Bool {
        for (x in b.ignored) {
            if (x == name) {
                return true
            }
        }
        false
    }

    private static func findMethod(b: JitBindings, name: String): ?PublicMethod {
        for (m in b.methods) {
            if (m.name == name) {
                return Some(m)
            }
        }
        None
    }

    /**
     * 父类字段并入子描述符（X）：**在自有字段之前**调用，先占号。
     *
     * 字段表是全局 index 空间（同 index 多访问器靠 `accepts` 区分），子类自有字段若也从 0
     * 开始编号，bucket 会撞上父类访问器并先命中——读出来的是父类同号字段。
     */
    private static func mergeAncestorFields(cls: ClassTypeInfo, ancestry: Array<String>,
        fields: ArrayList<PublicField>, pending: ArrayList<() -> Unit>, diag: DiagnosticsSink): Unit {
        var cur = cls.superClass
        var depth = 0
        while (depth < 32) {
            let p = match (cur) {
                case Some(c) => c
                case None => return
            }
            if (p.name != 'Object') {
                let pb = JitBindSupport.enrolledOf(p.name)
                for (v in p.instanceVariables) {
                    if (ReflectRegistrar.hasField(fields, v.name) ||
                        ReflectRegistrar.isIgnored(pb, v.name)) {
                        continue
                    }
                    let codeOpt = ReflectRegistrar.mapType(v.typeInfo)
                    if (codeOpt.isNone()) {
                        continue
                    }
                    let code = ReflectRegistrar.unwrapCode(codeOpt)
                    let idx = UInt16(fields.size)
                    let typeRef: ?String = if (code == LocalType.HOST_OBJECT) {
                        Some(v.typeInfo.name)
                    } else {
                        None
                    }
                    let mutable = v.isMutable()
                    fields.add(PublicField(name: v.name, `type`: code, index: idx,
                        mutable: mutable, typeRef: typeRef))
                    let member = v
                    let rowCode = code
                    let rowMutable = mutable
                    let rowIdx = idx
                    let rowAncestry = ancestry
                    let typed = pb.fieldOf(v.name)
                    pending.add({ =>
                        HostFieldTable.register(index: rowIdx, `type`: rowCode,
                            mutable: rowMutable,
                            accepts: { o => ReflectRegistrar.isInstanceOf(o, rowAncestry) },
                            getter: { o =>
                                match (typed) {
                                    case Some(b) => b.get(o)
                                    case None => member.getValue(o)
                                }
                            },
                            setter: { o, x =>
                                match (typed) {
                                    case Some(b) => match (b.set) {
                                        case Some(s) => s(o, x)
                                        case None => member.setValue(o, x)
                                    }
                                    case None => member.setValue(o, x)
                                }
                            })
                    })
                }
            }
            cur = p.superClass
            depth = depth + 1
        }
    }

    /**
     * 父类方法/属性并入子描述符（X）：**在自有方法之后**调用，子类同名成员优先。
     *
     * 绑定优先取父类的 `@JitBind`（对子实例上转即可调用），否则退回反射（具体方法可 apply）。
     */
    private static func mergeAncestorMethods(cls: ClassTypeInfo, ancestry: Array<String>,
        methods: ArrayList<PublicMethod>, diag: DiagnosticsSink): Unit {
        var cur = cls.superClass
        var depth = 0
        while (depth < 32) {
            let p = match (cur) {
                case Some(c) => c
                case None => return
            }
            if (p.name != 'Object') {
                let pb = JitBindSupport.enrolledOf(p.name)
                for (f in p.instanceFunctions) {
                    if (ReflectRegistrar.hasMethod(methods, f.name) ||
                        ReflectRegistrar.isIgnored(pb, f.name)) {
                        continue
                    }
                    match (ReflectRegistrar.findMethod(pb, f.name)) {
                        case Some(pm) => methods.add(PublicMethod(name: f.name, bind: pm.bind))
                        case None =>
                            let codeOpt = ReflectRegistrar.mapType(f.returnType)
                            let paramCodes = ReflectRegistrar.mapParams(f.parameters)
                            if (codeOpt.isNone() || paramCodes.isNone()) {
                                ReflectRegistrar.skip(diag, '${p.name}.${f.name}', '父类方法类型不可映射')
                                continue
                            }
                            let sig = ReflectRegistrar.prepend(LocalType.HOST_OBJECT,
                                ReflectRegistrar.unwrapParams(paramCodes))
                            let ret = ReflectRegistrar.unwrapCode(codeOpt)
                            if (ReflectRegistrar.unsafeForReflect(sig, ret)) {
                                ReflectRegistrar.skip(diag, '${p.name}.${f.name}',
                                    '引用型参数/返回在反射 apply 上会 SIGSEGV（GAP-13），请给父类加 @JitBind')
                                continue
                            }
                            methods.add(PublicMethod(name: f.name,
                                bind: PredefinedFunction('${p.name}.${f.name}', sig, ret,
                                    { args => f.apply(args[0], ReflectRegistrar.tail(args)) },
                                    retName: ReflectRegistrar.retNameOf(f.returnType, ret))))
                    }
                }
                for (pp in p.instanceProperties) {
                    let propName = if (pp.isMutable()) {
                        ReflectRegistrar.lowerFirst(pp.name)
                    } else {
                        pp.name
                    }
                    if (ReflectRegistrar.hasMethod(methods, propName) ||
                        ReflectRegistrar.isIgnored(pb, pp.name) ||
                        ReflectRegistrar.isIgnored(pb, propName)) {
                        continue
                    }
                    match (ReflectRegistrar.findMethod(pb, propName)) {
                        case Some(pm) => methods.add(PublicMethod(name: propName, bind: pm.bind))
                        case None =>
                            let codeOpt = ReflectRegistrar.mapType(pp.typeInfo)
                            if (codeOpt.isNone()) {
                                continue
                            }
                            let ret = ReflectRegistrar.unwrapCode(codeOpt)
                            methods.add(PublicMethod(name: propName,
                                bind: PredefinedFunction(propName, [LocalType.HOST_OBJECT], ret,
                                    { args => pp.getValue(args[0]) },
                                    retName: ReflectRegistrar.retNameOf(pp.typeInfo, ret))))
                    }
                }
            }
            cur = p.superClass
            depth = depth + 1
        }
    }

    /** 14 的实例判定：类祖先链 ∪ 已注册接口谓词（X）。 */
    public static func isInstanceOfHost(o: Object, name: String): Bool {
        if (ReflectRegistrar.isInstanceOfClass(o, name)) {
            return true
        }
        JitBindSupport.acceptsInterface(o, name)
    }

    /**
     * 手工覆盖合并（M2.1「overrides」）：按**方法名**替换反射生成的绑定，未命中的追加。
     *
     * 为什么必须同时改方法表与自动包装函数表：前端 `Lowerer` 用 `m.bind.name` 查 slot，
     * 运行期执行的是该 slot 的 `impl`。只换方法表 ⇒ slot 仍指旧反射实现，覆盖静默失效。
     *
     * 为什么保留反射生成的 bind 名：slot 以名字为键，换名会让同一方法在快照里出现两条；
     * 手工 bind 的名字只是宿主侧标识，不参与解析。手写的签名与实现则原样采用。
     */
    private static func applyOverrides(base: Array<PublicMethod>,
        auto: Array<PredefinedFunction>, overrides: Array<PublicMethod>)
        : (Array<PublicMethod>, Array<PredefinedFunction>) {
        if (overrides.size == 0) {
            return (base, auto)
        }
        var methods = ReflectRegistrar.copyMethods(base)
        var fns = ReflectRegistrar.copyFunctions(auto)
        for (ov in overrides) {
            var hit = -1
            var i = 0
            while (i < methods.size) {
                if (methods[i].name == ov.name) {
                    hit = i
                    break
                }
                i = i + 1
            }
            if (hit < 0) {
                // 反射没生成（类外方法 / 该成员被跳过）：按新增登记，slot 同时补一条
                methods = ReflectRegistrar.appendMethod(methods, ov)
                fns = ReflectRegistrar.appendFunction(fns, ov.bind)
                continue
            }
            let canonical = methods[hit].bind.name
            let rebind = PredefinedFunction(canonical, ov.bind.paramTypes, ov.bind.retType,
                ov.bind.impl, retName: ov.bind.retName)
            methods[hit] = PublicMethod(name: ov.name, bind: rebind)
            fns = ReflectRegistrar.replaceFunction(fns, canonical, rebind)
        }
        (methods, fns)
    }

    private static func appendMethod(xs: Array<PublicMethod>, m: PublicMethod): Array<PublicMethod> {
        let out = Array<PublicMethod>(xs.size + 1, repeat: m)
        var i = 0
        while (i < xs.size) {
            out[i] = xs[i]
            i = i + 1
        }
        out[xs.size] = m
        out
    }

    private static func appendFunction(xs: Array<PredefinedFunction>, f: PredefinedFunction)
        : Array<PredefinedFunction> {
        let out = Array<PredefinedFunction>(xs.size + 1, repeat: f)
        var i = 0
        while (i < xs.size) {
            out[i] = xs[i]
            i = i + 1
        }
        out[xs.size] = f
        out
    }

    /** 引用型码（4–14）：反射 `apply` 在这些参数/返回上会走 MCC 的 `ArgValue` 转换（GAP-13）。 */
    private static func isRefCode(c: UInt16): Bool {
        c >= LocalType.STRING && c <= LocalType.HOST_OBJECT
    }

    /** 签名里除接收者外，是否含引用型实参，或返回引用型。 */
    private static func unsafeForReflect(sig: Array<UInt16>, ret: UInt16): Bool {
        var i = 1
        while (i < sig.size) {
            if (ReflectRegistrar.isRefCode(sig[i])) {
                return true
            }
            i = i + 1
        }
        ReflectRegistrar.isRefCode(ret)
    }

    private static func hasOverrideName(overrides: Array<PublicMethod>, name: String): Bool {
        for (o in overrides) {
            if (o.name == name) {
                return true
            }
        }
        false
    }

    private static func copyMethods(xs: Array<PublicMethod>): Array<PublicMethod> {        let list = ArrayList<PublicMethod>()
        for (x in xs) {
            list.add(x)
        }
        list.toArray()
    }

    private static func copyFunctions(xs: Array<PredefinedFunction>): Array<PredefinedFunction> {
        let list = ArrayList<PredefinedFunction>()
        for (x in xs) {
            list.add(x)
        }
        list.toArray()
    }

    private static func replaceFunction(xs: Array<PredefinedFunction>, name: String,
        v: PredefinedFunction): Array<PredefinedFunction> {
        var hit = false
        var out = ReflectRegistrar.copyFunctions(xs)
        var i = 0
        while (i < out.size) {
            if (out[i].name == name) {
                out[i] = v
                hit = true
            }
            i = i + 1
        }
        if (!hit) {
            out = ReflectRegistrar.appendFunction(out, v)
        }
        out
    }

    /** 反射 TypeInfo → LocalType；不可映射 ⇒ None（JSON 谱系永不映射 14）。 */
    public static func mapType(info: TypeInfo): ?UInt16 {
        let n = info.name
        match (n) {
            case 'Int64' => return Some(LocalType.I64)
            case 'Float64' => return Some(LocalType.F64)
            case 'Bool' => return Some(LocalType.BOOL)
            case 'Unit' => return Some(LocalType.UNIT)
            case 'String' => return Some(LocalType.STRING)
            case 'Decimal' => return Some(LocalType.DECIMAL)
            case 'DateTime' => return Some(LocalType.DATETIME)
            case 'Duration' => return Some(LocalType.DURATION)
            case 'Regex' => return Some(LocalType.REGEX)
            // m3 §12-4：Any（15）不入字段/成员映射表；成员访问面只认确定类（14）。
            case 'Any' => return None
            case _ => ()
        }
        if (n.startsWith('Range')) {
            return Some(LocalType.RANGE)
        }
        if (n.startsWith('ArrayList')) {
            return Some(LocalType.LIST)
        }
        if (n.startsWith('HashMap')) {
            return Some(LocalType.MAP)
        }
        if (ReflectRegistrar.isJsonFamily(n)) {
            return None
        }
        match (info) {
            case _: ClassTypeInfo => Some(LocalType.HOST_OBJECT)
            case _: InterfaceTypeInfo => Some(LocalType.HOST_OBJECT)
            case _ => None
        }
    }

    /** 14 型映射的目标类名（其余码 → None）。 */
    public static func mapTypeRef(info: TypeInfo): ?String {
        match (ReflectRegistrar.mapType(info)) {
            case Some(c) => if (c == LocalType.HOST_OBJECT) { Some(info.name) } else { None }
            case None => None
        }
    }

    /** 构造器自动适配：参数不可映射 ⇒ None（该构造器跳过 + 诊断）。 */
    public static func buildCtor(info: ConstructorInfo, bindings!: JitBindings): ?PublicCtor {
        let codes = ReflectRegistrar.mapParams(info.parameters)
        match (codes) {
            case Some(ps) => match (bindings.ctorOf(ps)) {
                // 类型化构造器：参数已在绑定体里 `as` 好，直接静态调用
                case Some(typed) => Some(typed)
                case None => Some(PublicCtor(params: ps, adapter: { args => info.apply(args) }))
            }
            case None => None
        }
    }

    // ---- 内部 ----

    private static func mapParams(params: Collection<ParameterInfo>): ?Array<UInt16> {
        let out = ArrayList<UInt16>()
        for (p in params) {
            match (ReflectRegistrar.mapType(p.typeInfo)) {
                case Some(c) => out.add(c)
                case None => return None
            }
        }
        Some(out.toArray())
    }

    private static func unwrapCode(c: ?UInt16): UInt16 {
        match (c) {
            case Some(x) => x
            case None => LocalType.NONE
        }
    }

    private static func unwrapParams(c: ?Array<UInt16>): Array<UInt16> {
        match (c) {
            case Some(x) => x
            case None => Array<UInt16>()
        }
    }

    private static func tail(args: Array<Any>): Array<Any> {
        if (args.size <= 1) {
            return Array<Any>()
        }
        let out = Array<Any>(args.size - 1, repeat: 0)
        var i = 1
        while (i < args.size) {
            out[i - 1] = args[i]
            i = i + 1
        }
        out
    }

    private static func prepend(code: UInt16, rest: Array<UInt16>): Array<UInt16> {
        let out = Array<UInt16>(rest.size + 1, repeat: 0u16)
        out[0] = code
        var i = 0
        while (i < rest.size) {
            out[i + 1] = rest[i]
            i = i + 1
        }
        out
    }

    private static func lowerFirst(s: String): String {
        if (s.isEmpty()) {
            return s
        }
        let bytes = s.unsafeBytes().clone()
        let first = bytes[0]
        if (first >= 0x41u8 && first <= 0x5Au8) {
            bytes[0] = first + 0x20u8
        }
        String.fromUtf8(bytes)
    }

    private static func upperFirst(s: String): String {
        if (s.isEmpty()) {
            return s
        }
        let bytes = s.unsafeBytes().clone()
        let first = bytes[0]
        if (first >= 0x61u8 && first <= 0x7Au8) {
            bytes[0] = first - 0x20u8
        }
        String.fromUtf8(bytes)
    }

    private static func skip(diag: DiagnosticsSink, member: String, reason: String): Unit {
        diag.diag(DiagnosticLevel.Warn, DiagCode.RegistrationSkipped,
            '注册跳过 ${member}：${reason}（m2 §12.5）')
    }

    private static func claimName(name: String, into: ClassRegistry, local: ArrayList<String>,
        diag: DiagnosticsSink, member: String): Bool {
        if (into.hasFunction(name) || ClassRegistry.isBuiltinName(name) ||
            ClassRegistry.isKeywordName(name) || local.contains(name)) {
            ReflectRegistrar.skip(diag, member, '命名冲突（已存在同名注册）')
            return false
        }
        local.add(name)
        true
    }

    private static func isJsonFamily(name: String): Bool {
        name == 'JsonValue' || name == 'JsonObject' || name == 'JsonArray' || name == 'JsonNull'
    }

    /** 14 型返回的具体类名；其余（或不适用）→ 空串。 */
    private static func retNameOf(t: TypeInfo, code: UInt16): String {
        if (code == LocalType.HOST_OBJECT) {
            t.name
        } else {
            ''
        }
    }

    /**
     * 祖先链去掉首项（自身）⇒ `ClassDescriptor.parents`（M2.2）。
     *
     * `ancestryOf` 的首项是声明类自身、逐级到 `Object`，正好与 `parents` 的语义（直接父类在前、
     * 不含自身）对齐，不需要再反转。
     */
    private static func parentsOf(ancestry: Array<String>): Array<String> {
        if (ancestry.size <= 1) {
            return Array<String>()
        }
        let out = Array<String>(ancestry.size - 1, repeat: '')
        var i = 1
        while (i < ancestry.size) {
            out[i - 1] = ancestry[i]
            i = i + 1
        }
        out
    }

    private static func ancestryOf(cls: ClassTypeInfo): Array<String> {
        let names = ArrayList<String>()
        var cur: ?ClassTypeInfo = Some(cls)
        var depth = 0
        while (depth < 64) {
            match (cur) {
                case Some(c) =>
                    names.add(c.name)
                    cur = c.superClass
                case None => break
            }
            depth = depth + 1
        }
        names.toArray()
    }

    /** `o is C`（含子类；按反射的 superClass 链判定——opaque 声明类的边界校验）。 */
    public static func isInstanceOfClass(o: Object, name: String): Bool {
        var cur: ?ClassTypeInfo = Some(ClassTypeInfo.of(o))
        var depth = 0
        while (depth < 64) {
            match (cur) {
                case Some(c) =>
                    if (c.name == name) {
                        return true
                    }
                    cur = c.superClass
                case None => break
            }
            depth = depth + 1
        }
        false
    }

    private static func isInstanceOf(o: Object, names: Array<String>): Bool {
        // `names` 的首项 = 字段/属性的**声明类**（`ancestryOf` 从 cls 自身开始，逐级到 Object）。
        //
        // M2 语义（用户裁定）：形参声明 `A` 时可传 `B` 实例（`B <: A`）——所以判定必须是
        // 「o 是声明类的实例**含子类**」，不能是精确类相等；后者会把子类实例拒掉，与语言的
        // 继承语义相悖。反过来，源码里写未注册的 `B` 由前端在**编译期**报错，运行期不必再管。
        //
        // 祖先链的其余项不参与判定：若拿 `Object` 当键，任何对象都会命中，同 index 的访问器
        // 会互相串（`HostFieldTable.find` 取第一个 accepts 为真的表项）。
        if (names.size == 0) {
            return false
        }
        ReflectRegistrar.isInstanceOfClass(o, names[0])
    }
}
