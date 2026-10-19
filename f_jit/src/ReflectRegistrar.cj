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
    /** 注册 `T`；`enabled=false` 模拟关闭反射的构建（测试与宿主配置可判）。 */
    public static func registerType<T>(into!: ClassRegistry, diag!: DiagnosticsSink,
        enabled!: Bool = true): Unit where T <: Object {
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
        var info: ?TypeInfo = None
        try {
            info = Some(TypeInfo.of<T>())
        } catch (_: Exception) {
            throw RegistrationException(RegistrationRejectKind.ReflectionUnavailable, typeName, None)
        }
        let cls = match (info) {
            case Some(t) =>
                match (t) {
                    case c: ClassTypeInfo => c
                    case _ =>
                        throw RegistrationException(RegistrationRejectKind.ReflectionUnavailable,
                            typeName, None)
                }
            case None =>
                throw RegistrationException(RegistrationRejectKind.ReflectionUnavailable,
                    typeName, None)
        }
        let name = cls.name
        let ancestry = ReflectRegistrar.ancestryOf(cls)

        let fields = ArrayList<PublicField>()
        let methods = ArrayList<PublicMethod>()
        let ctors = ArrayList<PublicCtor>()
        let auto = ArrayList<PredefinedFunction>()
        let pending = ArrayList<() -> Unit>()
        let localNames = ArrayList<String>()

        // ---- 实例字段（let / var）----
        for (v in cls.instanceVariables) {
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
            pending.add({ =>
                HostFieldTable.register(index: rowIdx, `type`: rowCode, mutable: rowMutable,
                    accepts: { o => ReflectRegistrar.isInstanceOf(o, rowAncestry) },
                    getter: { o => member.getValue(o) },
                    setter: { o, x => member.setValue(o, x) })
            })
            let _ = rowName
        }

        // ---- 实例属性（prop / mut prop）----
        for (p in cls.instanceProperties) {
            let codeOpt = ReflectRegistrar.mapType(p.typeInfo)
            if (codeOpt.isNone()) {
                ReflectRegistrar.skip(diag, '${name}.${p.name}', '属性类型不可映射')
                continue
            }
            let code = match (codeOpt) {
                case Some(c) => c
                case None => 0u16
            }
            // SDK 1.3.0-alpha 的反射对 mut prop 报首字母大写（如 `Score`）；
            // 源面成员名仍为声明名，这里统一归一为首字母小写。
            let propName = if (p.isMutable()) {
                ReflectRegistrar.lowerFirst(p.name)
            } else {
                p.name
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
            let bind = PredefinedFunction(bindName, sig, ret,
                { args => f.apply(args[0], ReflectRegistrar.tail(args)) })
            methods.add(PublicMethod(name: f.name, bind: bind))
            auto.add(bind)
        }

        // ---- 静态 let / 只读 prop / 静态 func ----
        for (v in cls.staticVariables) {
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
            auto.add(PredefinedFunction(v.name, Array<UInt16>(),
                ReflectRegistrar.unwrapCode(codeOpt), { _ => v.getValue() }))
        }
        for (p in cls.staticProperties) {
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
            auto.add(PredefinedFunction(p.name, Array<UInt16>(),
                ReflectRegistrar.unwrapCode(codeOpt), { _ => p.getValue() }))
        }
        for (f in cls.staticFunctions) {
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
            auto.add(PredefinedFunction(f.name, ReflectRegistrar.unwrapParams(paramCodes),
                ReflectRegistrar.unwrapCode(codeOpt),
                { args => f.apply(staticType, args) }))
        }

        // ---- 构造器 ----
        for (c in cls.constructors) {
            match (ReflectRegistrar.buildCtor(c)) {
                case Some(pc) => ctors.add(pc)
                case None =>
                    ReflectRegistrar.skip(diag, '${name}.<init>', '构造器参数/返回类型不可映射')
            }
        }

        // 全量构建完成后一次性登记：任何拒绝都不会留下半成品。
        let descObj = ClassDescriptor(name: name, fields: fields.toArray(),
            methods: methods.toArray(), ctors: ctors.toArray())
        into.register(descObj)
        for (p in pending) {
            p()
        }
        for (f in auto) {
            into.addAutoFunction(f)
        }
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
    public static func buildCtor(info: ConstructorInfo): ?PublicCtor {
        let codes = ReflectRegistrar.mapParams(info.parameters)
        match (codes) {
            case Some(ps) => Some(PublicCtor(params: ps, adapter: { args => info.apply(args) }))
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
