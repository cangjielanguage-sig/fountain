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
package fountain::f_dbd.common

import std.database.sql.*
import fountain::f_data.*
import fountain::f_data.macros.*

/**
 * 列信息（设计 §3.7）。
 *
 * 采用"**数据字段分名 + 只读接口属性 `@DataExclude[field]` 排除**"的形态：
 * 六个数据字段用短名 `nm`/`tn`/`len`/`scl`/`nl`/`ds`（**即线上键名**），由 `props` 生成
 * `mut` 属性 ⇒ 可解码；`ColumnInfo` 要求的六个只读属性手写并排除出序列化。
 *
 * 这么做的原因见设计 §3.4 规则 6：`private let` + 手写非 mut `prop` 只能编码不能解码，
 * 而 `props` 生成的 `mut prop` 又与 `ColumnInfo` 的非 mut 属性冲突 ⇒ "分名 + 排除"是唯一形态。
 */
@DataAssist[fields props]
public class ColumnInfoImpl <: ColumnInfo {
    private var nm: String = ''                  // name
    private var tn: String = ''                  // typeName（仓颉类型名，见设计 §8）
    private var len: Int64 = 0                   // length
    private var scl: Int64 = 0                   // scale
    private var nl: Bool = false                 // nullable
    private var ds: Int64 = 0                    // displaySize

    public init() {}

    public init(name: String, typeName: String, length: Int64, scale: Int64,
                nullable: Bool, displaySize: Int64) {
        this.nm = name
        this.tn = typeName
        this.len = length
        this.scl = scale
        this.nl = nullable
        this.ds = displaySize
    }

    // 以下 6 个只读属性满足 ColumnInfo；@DataExclude[field] 使其不参与序列化
    @DataExclude[field]
    public prop name: String {
        get() {
            nm
        }
    }
    @DataExclude[field]
    public prop typeName: String {
        get() {
            tn
        }
    }
    @DataExclude[field]
    public prop length: Int64 {
        get() {
            len
        }
    }
    @DataExclude[field]
    public prop scale: Int64 {
        get() {
            scl
        }
    }
    @DataExclude[field]
    public prop nullable: Bool {
        get() {
            nl
        }
    }
    @DataExclude[field]
    public prop displaySize: Int64 {
        get() {
            ds
        }
    }
}
