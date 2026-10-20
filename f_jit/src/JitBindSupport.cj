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

import std.reflect.TypeInfo
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType

/**
 * `@JitBind` 的**运行期支撑**（M2.1）。
 *
 * 宏只负责拼语法；类型码、绑定名、失败转码都收在这里，宏生成的代码因此可以保持很薄。
 * 与 `ReflectRegistrar.mapType` 同一张映射表——宏展开的签名与反射注册的签名必须**逐位一致**，
 * 否则 `overrides` 会与反射项对不上（前者按方法名匹配，签名不符会让 Lowerer 的实参校验错位）。
 */
public class JitBindSupport {
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

    /** 实参类型不符 → `CALL_CONTRACT`（3），不是宿主异常（21）。 */
    public static func typeMismatch(): Nothing {
        throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
            '@JitBind 生成的绑定收到类型不符的实参')
    }
}
