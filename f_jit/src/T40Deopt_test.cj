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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.invokeHelper
import fountain::f_jit.test.TCase

/**
 * M3 R6.4（T40 对账）· deopt 重放：盒在重放路径上仍可读（窗口不重置），
 * `is` / `as` 的结果与首次一致——盒是**分配型**，重放重建等值盒、可观察语义不变。
 *
 * 放在根包：`JitFunction` 在 `fountain::f_jit`，runtime 子包不能反向依赖。
 */
@Test
public class T40Deopt_test {
    /**
     * 首次装箱得到的句柄。用**静态**变量跨 body/replay 传递——仓颉不允许把捕获可变局部变量的
     * 闭包存起来（两个 lambda 都要交给 `JitFunction`）。
     */
    private static var boxId: Int64 = 0

    /** 首次装箱 41 后置 DEOPT；重放读同一个盒，`is` 命中、`as` 取值不变。 */
    @TestCase
    public func deoptReplayKeepsBoxSemantics(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
        T40Deopt_test.boxId = 0
        let f = JitFunction(0, LocalType.BOOL, Array<UInt16>(),
            { c, _ =>
                T40Deopt_test.boxId = invokeHelper(c, 78, [Int64(LocalType.I64), 41])
                c.errCode = ErrCode.DEOPT
                -1
            },
            { c, _ =>
                let isI64 = invokeHelper(c, 79, [T40Deopt_test.boxId, Int64(LocalType.I64), 0xFFFF])
                let v = invokeHelper(c, 80, [T40Deopt_test.boxId, Int64(LocalType.I64), 0xFFFF])
                if (isI64 == 1 && v == 41) {
                    1
                } else {
                    0
                }
            }, '')
        @Assert(f.call<Bool>(Array<Any>()), true)
        @Assert(TCase.hit('T40/deopt-replay', true), true)
    }
}
