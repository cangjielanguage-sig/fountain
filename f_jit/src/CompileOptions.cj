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

import fountain::f_jit.base.JitException
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.JitMode
import fountain::f_jit.base.DiagnosticsSink

/**
 * 编译配置（design §7.3.2、plan S6.1）。
 *
 * `jit` = 用户意图（Off/Auto/Force），`cpuFeatures` 预留给 M2，`diagnostics` 只收降级/告警。
 */
public class CompileOptions {
    public var jit: JitMode = JitMode.Auto
    public var cpuFeatures: UInt64 = 0
    public let diagnostics: DiagnosticsSink

    public init(diagnostics: DiagnosticsSink) {
        this.diagnostics = diagnostics
    }
}

/**
 * 预定义函数注册契约（design §7.3.2、§8.4）。
 *
 * `impl` 收**已解包**的仓颉值，返回须与 `retType` 匹配（返回值校验发生在调用期；
 * 构造期只校验类型码合法集）。
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

    /** M1 形参类型：0–8、10–11（不含 Closure=12）。 */
    private static func checkParamTypes(name: String, ts: Array<UInt16>): Unit {
        for (t in ts) {
            let ok = (t <= LocalType.RANGE) || (t == LocalType.LIST) || (t == LocalType.MAP)
            if (!ok) {
                throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
                    '预定义函数「${name}」的形参类型码非法: ${t}（M1 允许 0–8/10–11，§8.4）')
            }
        }
    }

    private static func checkRetType(name: String, t: UInt16): Unit {
        if (t > LocalType.CLOSURE) {
            throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
                '预定义函数「${name}」的返回类型码非法: ${t}（M1 允许 0–12，§8.4）')
        }
    }
}
