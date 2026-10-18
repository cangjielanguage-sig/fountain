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
package fountain::f_jit.runtime

/** 机器码可调用的 helper 入口地址（@C 函数指针 → 整数）。 */
public class HelperAddresses {
    /** 统一分派入口 `h_dispatch(hid, ctx, args, n)` 的地址。 */
    public static func dispatch(): Int64 {
        let f: CFunc<(Int64, CPointer<Unit>, CPointer<Int64>, Int64) -> Int64> = h_dispatch
        Int64(CPointer<Unit>(f).toUIntNative())
    }

    /**
     * 诊断转储入口 `jit_dump(dump, errCode, fnId, nLocals, locals)` 的地址（T50 BAIL 块）。
     *
     * 入参全部是原生值：机器码从 ctx 读 `dbgBase`（off 56）与 `errCode`（off 0）后直传，
     * 避免在 C2N 边界上构造托管对象。第 5 参指向 `locals[0]`，后续局部槽在 −8、−16…
     */
    public static func dump(): Int64 {
        let f: CFunc<(CPointer<Int64>, Int64, Int64, Int64, CPointer<Int64>) -> Int64> = jit_dump
        Int64(CPointer<Unit>(f).toUIntNative())
    }
}
