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
package fountain::f_excel

import std.time.DateTime

/**
 * 数字格式的最小描述。
 *
 * M1 只消费 `Builtin` 的日期子集（`14`–`22`、`45`–`47`）与 `General`；
 * 其余值原样保留，写入时记一条 `NumberFormatNotSupportedInM1`（M2-a 接管完整样式）。
 */
public enum NumberFormat <: Equatable<NumberFormat> & ToString {
    | General
    | Builtin(Int64)
    | Custom(String)

    public operator func ==(that: NumberFormat): Bool {
        match ((this, that)) {
            case (General, General) => true
            case (Builtin(a), Builtin(b)) => a == b
            case (Custom(a), Custom(b)) => a == b
            case _ => false
        }
    }

    public operator func !=(that: NumberFormat): Bool {
        !(this == that)
    }

    public func toString(): String {
        match (this) {
            case General => "General"
            case Builtin(id) => "Builtin(${id})"
            case Custom(code) => "Custom(${code})"
        }
    }
}

/**
 * 单元格值。
 *
 * `Formula` 的第一个参数是**原文（不带前导 `=`）**，第二个是缓存值；读取不求值（M2 才提供显式求值）。
 * M1 不含 `TimeSpan`：`[h]:mm:ss` 类格式按 `Date` 返回并记 `UnsupportedTimeFormat`。
 */
public enum CellValue <: ToString {
    | Empty
    | Number(Float64)
    | Text(String)
    | Boolean(Bool)
    | Error(String)
    | Date(DateTime)
    | Formula(String, Option<CellValue>)

    public func toString(): String {
        match (this) {
            case Empty => ""
            case Number(v) => "${v}"
            case Text(v) => v
            case Boolean(v) => if (v) { "TRUE" } else { "FALSE" }
            case Error(v) => v
            case Date(v) => v.toString()
            case Formula(src, cached) => match (cached) {
                case Some(v) => "=${src} => ${v}"
                case None => "=${src}"
            }
        }
    }
}
