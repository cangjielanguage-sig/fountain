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

/**
 * 预定义函数注册契约（design-m1 §7.3.2、§8.4；M2 起下沉到 `base`）。
 *
 * `impl` 收**已解包**的仓颉值，返回须与 `retType` 匹配（返回值校验发生在调用期；
 * 构造期只校验类型码合法集）。
 *
 * **M2 位置调整**：`PublicMethod.bind` 需要引用本类型，而 `base` 不能反向依赖根包
 * （会形成包循环）。因此本类从根包下沉到 `base`，根包经 `Root.cj` 的 `public import`
 * 保持 `fountain::f_jit.PredefinedFunction` 用户面不变。
 *
 * **M2 合法集扩展**（plan-m1 S6.1「M2 续 13/14」）：形参追加 13（HostClosure）与
 * 14（HostObject），返回类型放开到 14；12（内部闭包）仍不可作形参，9（Regex）沿
 * M1 预定义面不加入。
 */
public class PredefinedFunction {
    public let name: String
    public let paramTypes: Array<UInt16>
    public let retType: UInt16
    public let impl: (Array<Any>) -> Any

    public init(name: String, paramTypes: Array<UInt16>, retType: UInt16,
        impl: (Array<Any>) -> Any) {
        PredefinedFunction.checkParamTypes(name, paramTypes)
        PredefinedFunction.checkRetType(name, retType)
        this.name = name
        this.paramTypes = paramTypes
        this.retType = retType
        this.impl = impl
    }

    /** M2 形参类型：0–8、10–11、13、14（不含 9 Regex 与 12 内部闭包）。 */
    private static func checkParamTypes(name: String, ts: Array<UInt16>): Unit {
        for (t in ts) {
            let ok = (t <= LocalType.RANGE) || (t == LocalType.LIST) || (t == LocalType.MAP) ||
                (t == LocalType.HOST_CLOSURE) || (t == LocalType.HOST_OBJECT)
            if (!ok) {
                throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
                    '预定义函数「${name}」的形参类型码非法: ${t}（M2 允许 0–8/10–11/13/14，§8.4）')
            }
        }
    }

    private static func checkRetType(name: String, t: UInt16): Unit {
        if (t > LocalType.HOST_OBJECT) {
            throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
                '预定义函数「${name}」的返回类型码非法: ${t}（M2 允许 0–14，§8.4）')
        }
    }
}
