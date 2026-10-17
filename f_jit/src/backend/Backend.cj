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
package fountain::f_jit.backend

import fountain::f_jit.bytecode.LoadedUnit

/** 后端契约（design §6.3.1、§12.2）：机器码编译入口 + ABI 摘要 + 入口 thunk。 */
public interface Backend {
    /** "x86_64" / "aarch64"（缓存键与诊断用）。 */
    prop name: String

    /** ABI 摘要（CTX/FP/SP/RETV/TMP 映射；诊断/测试用）。 */
    func abiSummary(): String

    /** 整单元 lowering 到 `sink`；暂不支持 / 失败 → false（调用方降级解释器）。 */
    func compile(unit: LoadedUnit, sink: CodeBuffer): Bool

    /** 入口 thunk 区基址。 */
    func entryThunkBase(): Int64

    /** 某函数的入口 thunk 地址。 */
    func entryThunkFor(fnId: UInt32): Int64
}
