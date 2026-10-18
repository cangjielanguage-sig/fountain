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
import fountain::f_jit.runtime.JitContext

/**
 * S6.5 统一函数包装 `call<T>`（§8.2 六步）。
 *
 * 执行器由装载层注入（机器码或纯字节码同一接口）：
 * `body(ctx, cells)` 返回结果 cell；`replay(ctx, cells)` 供 `-1 DEOPT` 透明重跑。
 */
public class JitFunction {
    private let nargs: Int64
    private let retType: UInt16
    private let paramTypes: Array<UInt16>
    private let body: (JitContext, Array<Int64>) -> Int64
    private let replay: (JitContext, Array<Int64>) -> Int64
    private let report: String

    public init(nargs: Int64, retType: UInt16, paramTypes: Array<UInt16>,
        body: (JitContext, Array<Int64>) -> Int64,
        replay: (JitContext, Array<Int64>) -> Int64, report: String) {
        this.nargs = nargs
        this.retType = retType
        this.paramTypes = paramTypes
        this.body = body
        this.replay = replay
        this.report = report
    }

    /** 六步调用：长度 → 封送 → 执行 → 解包 → `T` 校验 → 返回。 */
    public func call<T>(args: Array<Any>): T {
        // 1. 参数个数
        if (Int64(args.size) != this.nargs) {
            return JitFunction.contractFail('实参个数不符：期望 ${this.nargs}，实际 ${args.size}')
        }
        // 5（前置）：`T` 与签名返回类型一致
        let want = JitFunction.localTypeOf<T>()
        match (want) {
            case Some(t) =>
                if (t != this.retType) {
                    return JitFunction.contractFail('T 与返回类型不符（§8.2 第 5 步）')
                }
            case None => return JitFunction.contractFail('T 不是可解包类型')
        }
        let marshal = CallMarshal()
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        try {
            // 2. 封送
            let cells = Array<Int64>(args.size, repeat: 0)
            var i = 0
            while (i < args.size) {
                cells[i] = marshal.marshalArg(this.paramTypes[i], args[i])
                i = i + 1
            }
            // 3. 执行 + 三态收尾
            let cell = this.body(ctx, cells)
            let ret = JitReport.finish(ctx, cell, { => this.replay(ctx, cells) }, this.report)
            // 4. 解包
            let v = marshal.makeRetUnboxer(this.retType)(ret)
            // 6. 返回 T
            match (v as T) {
                case Some(x) => return x
                case None => return JitFunction.contractFail('返回值与 T 不符')
            }
        } finally {
            marshal.cleanup()
            JitContext.free(ctx)
        }
    }

    private static func localTypeOf<T>(): ?UInt16 {
        let n = TypeInfo.of<T>().name
        if (n == 'Int64') {
            return Some(LocalType.I64)
        }
        if (n == 'Float64') {
            return Some(LocalType.F64)
        }
        if (n == 'Bool') {
            return Some(LocalType.BOOL)
        }
        if (n == 'Unit') {
            return Some(LocalType.UNIT)
        }
        if (n == 'String') {
            return Some(LocalType.STRING)
        }
        None
    }

    private static func contractFail<T>(msg: String): T {
        throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None, msg)
    }
}
