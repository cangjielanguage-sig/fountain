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
}
