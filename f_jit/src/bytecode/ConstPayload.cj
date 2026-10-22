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

/**
 * 常量 kind 码与常量载荷 —— design-m1 §3.3.6、plan-m1 S2.7。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.5「常量表序列化（与句柄解耦）」。
 *
 * **`ConstKind` 为什么是「类 + `static const`」而不是 enum**（design D3）：kind 是 §11.5 的
 * **线上码**（写进 `.fbc`、参与序列化分派），而仓颉 enum 的构造器不携带数值。
 *
 * **`ConstPayload` 为什么是 enum**：它是**闭合变体集**，与 kind **一一对应**，实例化与编解码
 * 一律 `match` 分派（design-m1 §3.3.6）。
 */

/** 常量 kind（M1：1–10；M3 追加 11=Json）。 */
public class ConstKind {
    /** kind 1：Int64，载荷 `i64`。 */
    public static const I64: UInt8 = 1u8
    /** kind 2：Float64，载荷 8 B（**必须 canonical**，加载器校验，§11.3）。 */
    public static const F64: UInt8 = 2u8
    /** kind 3：String，载荷 `u32` 字节长 + UTF-8 字节（§11.4）。 */
    public static const STRING: UInt8 = 3u8
    /** kind 4：List，载荷 `u32` 元素数 + `u32[常量表索引]`（DAG）。 */
    public static const LIST: UInt8 = 4u8
    /** kind 5：Map，载荷 `u32` 键值对数 + `u32[键索引, 值索引]`（DAG）。 */
    public static const MAP: UInt8 = 5u8
    /** kind 6：Decimal，载荷 `u8 sign + i32 scale + u32 长度 + 系数字节串`（ASCII '0'–'9'）。 */
    public static const DECIMAL: UInt8 = 6u8
    /** kind 7：DateTime，载荷 `i64` = epochNanos（UTC，§11.4「时间值仅 UTC」）。 */
    public static const DATETIME: UInt8 = 7u8
    /** kind 8：Duration，载荷 `i64` = nanos。 */
    public static const DURATION: UInt8 = 8u8
    /** kind 9：Range，载荷 `i64 start + i64 end + i64 step + u8 isClosed`（1 = `..=`）。 */
    public static const RANGE: UInt8 = 9u8
    /** kind 10：Regex，载荷 `u8 flags + u16 长度 + pattern UTF-8 字节`。 */
    public static const REGEX: UInt8 = 10u8
    /** kind 11（M3）：Json，载荷 `u32 长度 + 规范化后的原始 JSON UTF-8 字节`（与 kind 3 同构）。 */
    public static const JSON: UInt8 = 11u8
}

/**
 * 常量载荷（闭合变体集，与 `ConstKind` 一一对应）。
 *
 * `PList` / `PMap` 存的是**常量表索引**（DAG 引用）：允许共享子结构，**禁止环**
 * （环检测在加载期，§11.5）。序列化中**只有值、没有句柄 ID**——句柄 ID 是加载期分配的
 * 运行期索引，跨进程 / 跨平台都不稳定，禁止写入字节码。
 */
public enum ConstPayload {
    | PI64(Int64)
    | PF64(UInt64)
    | PStr(String)
    | PList(Array<UInt32>)
    | PMap(Array<(UInt32, UInt32)>)
    | PDec(UInt8, Int32, String)
    | PDateTime(Int64)
    | PDuration(Int64)
    | PRange(Int64, Int64, Int64, Bool)
    | PRegex(String, UInt8)
    | PJson(String)

    /** 载荷 → kind 码（序列化分派；与 `ConstKind` 一一对应）。 */
    public static func kindOf(p: ConstPayload): UInt8 {
        match (p) {
            case PI64(_) => ConstKind.I64
            case PF64(_) => ConstKind.F64
            case PStr(_) => ConstKind.STRING
            case PList(_) => ConstKind.LIST
            case PMap(_) => ConstKind.MAP
            case PDec(_, _, _) => ConstKind.DECIMAL
            case PDateTime(_) => ConstKind.DATETIME
            case PDuration(_) => ConstKind.DURATION
            case PRange(_, _, _, _) => ConstKind.RANGE
            case PRegex(_, _) => ConstKind.REGEX
            case PJson(_) => ConstKind.JSON
        }
    }
}
