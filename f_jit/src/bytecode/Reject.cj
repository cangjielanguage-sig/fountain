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
package fountain::f_jit.bytecode

import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException

/**
 * 加载期拒绝的**唯一抛出点** —— design D11「11 类非法情形集中在一个 `validate` 里」。
 *
 * 错误码依据 `doc/jit-bytecode-m1.md`：
 *
 * - **18（`ERR_NOT_IMPL`）**：`.fbc` 容器格式类拒绝——魔数错、主版本不受支持、未知 flags 位 /
 *   `bit1=1`、段长不符、常量图成环、坏载荷、目录越界、类型表非法、站点表问题、名字表坏键、
 *   crc32 不符（§11.6「未知 flags 位或更高 verMajor → 加载期拒绝（桥抛
 *   `JitException(code=18, ERR_NOT_IMPL 语义)`）」、§11.8）。
 * - **14（`ERR_ARG_MISMATCH`）**：正则常量非法 / 空 pattern（§3.3「非法 pattern 或 flags
 *   组合 → 加载期拒绝（`JitException(14)`，site=-1）」）。
 *
 * `site = -1` 与 `fnId = -1`：加载期失败**不落在任何字节码执行点上**（§2 表末「19 为桥层
 * 契约错误、site=-1」的同款口径）。
 */
internal func rejectFormat(msg: String): Nothing {
    throw JitException(ErrCode.NOT_IMPL, -1, -1, None, msg)
}

/** 正则常量（kind 10）非法或空 pattern → 14（§3.3、§11.5 kind 10）。 */
internal func rejectRegex(msg: String): Nothing {
    throw JitException(ErrCode.ARG_MISMATCH, -1, -1, None, msg)
}
