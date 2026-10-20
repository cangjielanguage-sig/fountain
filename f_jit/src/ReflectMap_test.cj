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
import std.collection.HashMap
import std.math.numeric.Decimal
import std.reflect.ClassTypeInfo
import std.reflect.TypeInfo
import std.regex.Regex
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.test.CtorBad
import fountain::f_jit.test.JsonObject
import fountain::f_jit.test.JsonValue
import fountain::f_jit.test.ReflectBox
import fountain::f_jit.test.ReflectUser
import fountain::f_jit.test.TCase

/** Q5.3：反射类型映射与构造器自动适配（m2 §12.5/§15）。 */
@Test
public class ReflectMap_test {
    /** 值型直映 0–3。 */
    @TestCase
    public func valueTypesMapDirectly(): Unit {
        @Assert(ReflectMap_test.code<Int64>(), LocalType.I64)
        @Assert(ReflectMap_test.code<Float64>(), LocalType.F64)
        @Assert(ReflectMap_test.code<Bool>(), LocalType.BOOL)
        @Assert(ReflectMap_test.code<Unit>(), LocalType.UNIT)
        @Assert(TCase.hit('T55/map-value-types', ReflectMap_test.code<Int64>() == LocalType.I64 &&
            ReflectMap_test.code<Float64>() == LocalType.F64 &&
            ReflectMap_test.code<Bool>() == LocalType.BOOL &&
            ReflectMap_test.code<Unit>() == LocalType.UNIT), true)
    }

    /** std 句柄类型 → 4–11（按名映射；容器泛型实参外置）。 */
    @TestCase
    public func stdHandleTypesMapTo4To11(): Unit {
        @Assert(ReflectMap_test.code<String>(), LocalType.STRING)
        @Assert(ReflectMap_test.code<Decimal>(), LocalType.DECIMAL)
        @Assert(ReflectMap_test.code<DateTime>(), LocalType.DATETIME)
        @Assert(ReflectMap_test.code<Duration>(), LocalType.DURATION)
        @Assert(ReflectMap_test.code<Range<Int64>>(), LocalType.RANGE)
        @Assert(ReflectMap_test.code<Regex>(), LocalType.REGEX)
        @Assert(ReflectMap_test.code<ArrayList<Int64>>(), LocalType.LIST)
        @Assert(ReflectMap_test.code<HashMap<String, Int64>>(), LocalType.MAP)
        @Assert(TCase.hit('T55/map-std-handles', ReflectMap_test.code<String>() == LocalType.STRING &&
            ReflectMap_test.code<HashMap<String, Int64>>() == LocalType.MAP), true)
    }

    /** 其余类 → 14 + typeRef；JSON 谱系与不可映射类型 → None。 */
    @TestCase
    public func otherClassesMapToHostObject(): Unit {
        let t = TypeInfo.of<ReflectUser>()
        @Assert(ReflectMap_test.codeOf(t), LocalType.HOST_OBJECT)
        match (ReflectRegistrar.mapTypeRef(t)) {
            case Some(n) => @Assert(n, 'ReflectUser')
            case None => @Fail('typeRef 缺失')
        }
        @Assert(ReflectMap_test.codeOpt<Int32>().isNone(), true)
        @Assert(ReflectMap_test.codeOpt<Option<Int64>>().isNone(), true)
        @Assert(ReflectMap_test.codeOptOf(TypeInfo.of<JsonValue>()).isNone(), true)
        @Assert(ReflectRegistrar.mapTypeRef(TypeInfo.of<JsonObject>()).isNone(), true)
        @Assert(TCase.hit('T55/map-host-object', ReflectMap_test.codeOf(t) == LocalType.HOST_OBJECT &&
            ReflectMap_test.codeOpt<Int32>().isNone()), true)
    }

    /** 构造器 `apply` 适配：参数逐项映射，adapter 可真正构造实例。 */
    @TestCase
    public func buildCtorAdaptsApply(): Unit {
        let cls = ClassTypeInfo.of(ReflectUser())
        var picked: ?PublicCtor = None
        for (c in cls.constructors) {
            match (ReflectRegistrar.buildCtor(c, bindings: JitBindings.empty())) {
                case Some(pc) => if (pc.params.size == 2) { picked = Some(pc) }
                case None => ()
            }
        }
        let ctor = match (picked) {
            case Some(c) => c
            case None => @Fail('未找到 2 参构造器')
        }
        @Assert(ctor.params, [LocalType.STRING, LocalType.I64])
        let made = ctor.adapter(['bob', 9])
        var ok = false
        match (made) {
            case u: ReflectUser =>
                @Assert(u.name, 'bob')
                @Assert(u.id, 9)
                ok = u.name == 'bob' && u.id == 9
            case _ => @Fail('构造器返回类型不符')
        }
        @Assert(TCase.hit('T54/reflect-ctor-apply', ok), true)
    }

    /** 泛型类按具体实例化：`ReflectBox<Int64>` 的构造器参数映射为 0。 */
    @TestCase
    public func genericClassUsesConcreteInstantiation(): Unit {
        let cls = ClassTypeInfo.of(ReflectBox<Int64>(0))
        var found = false
        for (c in cls.constructors) {
            match (ReflectRegistrar.buildCtor(c, bindings: JitBindings.empty())) {
                case Some(pc) =>
                    if (pc.params.size == 1 && pc.params[0] == LocalType.I64) {
                        found = true
                        let made = pc.adapter([7])
                        match (made) {
                            case b: ReflectBox<Int64> => @Assert(b.value, 7)
                            case _ => @Fail('泛型构造器返回类型不符')
                        }
                    }
                case None => ()
            }
        }
        @Assert(found, true)
        @Assert(TCase.hit('T55/reflect-generic-ctor', found), true)
    }

    /** 不可映射的构造器参数 → 该构造器返回 None（由 registerType 转成跳过 + 诊断）。 */
    @TestCase
    public func unmappableCtorReturnsNone(): Unit {
        let cls = ClassTypeInfo.of(CtorBad(0))
        var any = false
        var mapped = false
        for (c in cls.constructors) {
            any = true
            match (ReflectRegistrar.buildCtor(c, bindings: JitBindings.empty())) {
                case Some(_) => mapped = true
                case None => ()
            }
        }
        @Assert(any, true)
        @Assert(mapped, false)
    }

    /** 不可映射构造器 → 该构造器跳过 + diagnostics（类本身仍可注册）。 */
    @TestCase
    public func unsupportedCtorIsSkippedWithDiagnostic(): Unit {
        let reg = ClassRegistry()
        let sink = RecReflectSink()
        ReflectRegistrar.registerType<CtorBad>(into: reg, diag: sink)
        let d = match (reg.resolve('CtorBad')) {
            case Some(x) => x
            case None => @Fail('CtorBad 未注册')
        }
        @Assert(d.ctors.size, 0)
        @Assert(sink.contains('<init>'), true)
    }

    private static func code<T>(): UInt16 {
        match (ReflectRegistrar.mapType(TypeInfo.of<T>())) {
            case Some(c) => c
            case None => LocalType.NONE
        }
    }

    private static func codeOpt<T>(): ?UInt16 {
        ReflectRegistrar.mapType(TypeInfo.of<T>())
    }

    private static func codeOptOf(t: TypeInfo): ?UInt16 {
        ReflectRegistrar.mapType(t)
    }

    private static func codeOf(t: TypeInfo): UInt16 {
        match (ReflectRegistrar.mapType(t)) {
            case Some(c) => c
            case None => LocalType.NONE
        }
    }
}
