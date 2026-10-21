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
 * 句柄类型 token 常量命名空间 —— design-m1 §2.3.9、plan-m1 S1.2。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §6（类型 token 表）：
 *
 * ```
 * 0 保留，1=List 2=Map 3=String 4=Decimal 5=DateTime 6=Duration 7=Range 8=Regex 9=Closure
 * ```
 *
 * 该编码同时用于：句柄槽 `tag`（§0 句柄槽 `idx:u32 + tag:u16 + gen:u16`，作为 helper fetch 的
 * 类型校验依据）、`IS_TYPE` / `GUARD_TYPE` / `CAST` / H17–H19 的操作数（§6「`IS_TYPE/GUARD_TYPE/
 * CAST/H17–H19` 与句柄槽 `tag` 均使用该编码」）。M1 是**封闭集**，加载器遇未知值拒绝。
 *
 * 与 `LocalType` 的映射**只写在 `LocalType.fromToken` 一处**（§11.7 一一对应表），本类不重复维护
 * 反向表，避免两处漂移。
 */
public class TypeToken {
    /** 0 = 保留（§6「加载器遇 0 拒绝」）。 */
    public static const RESERVED: UInt16 = 0u16

    public static const LIST: UInt16 = 1u16
    public static const MAP: UInt16 = 2u16
    public static const STRING: UInt16 = 3u16
    public static const DECIMAL: UInt16 = 4u16
    public static const DATETIME: UInt16 = 5u16
    public static const DURATION: UInt16 = 6u16
    public static const RANGE: UInt16 = 7u16
    public static const REGEX: UInt16 = 8u16
    public static const CLOSURE: UInt16 = 9u16

    /** token → 名称（诊断用）；M1 封闭集之外的值给非空兜底，便于定位「未知 token」。 */
    public static func name(tok: UInt16): String {
        match (tok) {
            case 0u16 => 'Reserved'
            case 1u16 => 'List'
            case 2u16 => 'Map'
            case 3u16 => 'String'
            case 4u16 => 'Decimal'
            case 5u16 => 'DateTime'
            case 6u16 => 'Duration'
            case 7u16 => 'Range'
            case 8u16 => 'Regex'
            case 9u16 => 'Closure'
            case _ => 'Unknown(${tok})'
        }
    }
}
