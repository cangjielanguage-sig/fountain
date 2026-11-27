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

import std.collection.HashMap
import std.reflect.TypeInfo
import std.sync.Mutex
import std.sync.AtomicReference
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.JitBindings
import fountain::f_jit.base.LocalType

/**
 * `@JitBind` 的**运行期支撑**（M2.1）。
 *
 * 宏只负责拼语法；类型码、绑定名、失败转码都收在这里，宏生成的代码因此可以保持很薄。
 * 与 `ReflectRegistrar.mapType` 同一张映射表——宏展开的签名与反射注册的签名必须**逐位一致**，
 * 否则 `overrides` 会与反射项对不上（前者按方法名匹配，签名不符会让 Lowerer 的实参校验错位）。
 */
/**
 * 登记表的不可变快照：**写时复制 + 原子发布**，读路径零锁零拷贝。
 *
 * 两张表放同一个快照里，保证「类的 overrides」与「接口谓词」看到的是同一代登记。
 */
private class BindSnapshot {
    let enrolled: HashMap<String, JitBindings>
    let interfaceAccepts: HashMap<String, (Object) -> Bool>

    init(enrolled: HashMap<String, JitBindings>, interfaceAccepts: HashMap<String, (Object) -> Bool>) {
        this.enrolled = enrolled
        this.interfaceAccepts = interfaceAccepts
    }
}

public class JitBindSupport {
    /**
     * `@JitBind` 的**自动登记表**：类全限定名 → 该类的 overrides。
     *
     * 宏不往类里插声明，也不生成中间函数——它在包级放一个 `let jitBindEnroll_X = enrollOf<X>([...])`，
     * 包初始化时把表填好；`registerType<T>()` 不传 `overrides` 时按 `TypeInfo.of<T>().name` 自动取用。
     *
     * 读多写少：登记只发生在包初始化 / `registerClass`，查询在封送接口实参时每次调用都会发生，
     * 因此表用不可变快照发布（`AtomicReference`），读者不再取全局锁。
     */
    /**
     * 测试专用：快照发布之后、返回之前调用，用于确定性复现「发布时机」竞态
     * （默认 `None`；只在包初始化 / `registerClass` 的冷路径上多一次 Option 匹配）。
     */
    internal static var publishHook: ?(() -> Unit) = None

    private static let writeMtx = Mutex()
    private static let current = AtomicReference<BindSnapshot>(
        BindSnapshot(HashMap<String, JitBindings>(), HashMap<String, (Object) -> Bool>()))

    private static func copyBindings(src: HashMap<String, JitBindings>): HashMap<String, JitBindings> {
        let out = HashMap<String, JitBindings>()
        for ((k, v) in src) {
            out[k] = v
        }
        out
    }

    private static func copyAccepts(
        src: HashMap<String, (Object) -> Bool>): HashMap<String, (Object) -> Bool> {
        let out = HashMap<String, (Object) -> Bool>()
        for ((k, v) in src) {
            out[k] = v
        }
        out
    }

    /** `LocalType.HOST_OBJECT`（14）的编译期常量：宏里直接引用，避免再包一层函数。 */
    public static let HOST_OBJECT_CODE: UInt16 = LocalType.HOST_OBJECT

    /** `LocalType.UNIT`（3）：无返回值方法的类型码。 */
    public static let UNIT_CODE: UInt16 = LocalType.UNIT

    /** 静态类型 → `LocalType` 码；映射不到 → 注册期 CAll_CONTRACT（在用户注册处就炸，不留到调用期）。 */
    public static func code<T>(): UInt16 {
        let info = TypeInfo.of<T>()
        match (ReflectRegistrar.mapType(info)) {
            case Some(c) => c
            case None =>
                throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
                    'JitBind：类型「${info.name}」无法映射为 LocalType')
        }
    }

    /** slot 名（`类名.方法名`）：与 `ReflectRegistrar` 反射注册的命名口径一致。 */
    public static func bindName(t: TypeInfo, m: String): String {
        '${t.name}.${m}'
    }

    /** 同 `bindName`，但把 `TypeInfo` 藏进泛型实参——宏生成的代码因此不必 `import std.reflect`。 */
    public static func bindNameOf<T>(m: String): String {
        '${TypeInfo.of<T>().name}.${m}'
    }

    /** 包初始化期由宏生成的 `let` 调用：按类全限定名登记 overrides。 */
    public static func enrollOf<T>(b: JitBindings): Unit {
        let key = TypeInfo.of<T>().name
        synchronized (JitBindSupport.writeMtx) {
            let old = JitBindSupport.current.load()
            let enrolled = JitBindSupport.copyBindings(old.enrolled)
            enrolled[key] = b
            JitBindSupport.current.store(BindSnapshot(enrolled, old.interfaceAccepts))
        }
    }

    /**
     * 接口版登记：除 bindings 外还登记 `o is I` 谓词。
     *
     * 反射的 `ClassTypeInfo` 不暴露 `interfaces`（实测无该成员），接口实现关系只能由宏在
     * 编译期用语言级 `is` 固化成一个谓词。
     */
    public static func enrollInterfaceOf<T>(b: JitBindings, accepts: (Object) -> Bool): Unit {
        let key = TypeInfo.of<T>().name
        synchronized (JitBindSupport.writeMtx) {
            let old = JitBindSupport.current.load()
            let enrolled = JitBindSupport.copyBindings(old.enrolled)
            let acceptsMap = JitBindSupport.copyAccepts(old.interfaceAccepts)
            enrolled[key] = b
            acceptsMap[key] = accepts
            JitBindSupport.current.store(BindSnapshot(enrolled, acceptsMap))
            match (JitBindSupport.publishHook) {
                case Some(h) => h()
                case None => ()
            }
        }
    }

    /** 对象是否实现了名为 `name` 的已注册接口。 */
    public static func acceptsInterface(o: Object, name: String): Bool {
        let snap = JitBindSupport.current.load()
        match (snap.interfaceAccepts.get(name)) {
            case Some(g) => g(o)
            case None => false
        }
    }

    /** 是否为已登记的接口。 */
    public static func isInterface(name: String): Bool {
        JitBindSupport.current.load().interfaceAccepts.get(name).isSome()
    }

    /** 接口的父接口名（未登记 → 空）。 */
    public static func parentsOf(name: String): Array<String> {
        JitBindSupport.enrolledOf(name).parents
    }

    /** 取某类的自动登记；没有则空数组（注册侧据此判断是否走反射）。 */
    public static func enrolledOf(name: String): JitBindings {
        match (JitBindSupport.current.load().enrolled.get(name)) {
            case Some(v) => v
            case None => JitBindings.empty()
        }
    }

    /** 实参类型不符 → `CALL_CONTRACT`（3），不是宿主异常（21）。 */
    public static func typeMismatch(): Nothing {
        throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
            '@JitBind 生成的绑定收到类型不符的实参')
    }
}
