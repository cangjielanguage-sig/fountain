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
package fountain::f_llm.balance

import std.convert.*

/**
 * 余额单位归一。
 *
 * **对外一律是元**（`BalanceSnapshot.total` / `granted` / `toppedUp` 都是 `"110.00"` 这种形态），
 * 但上游口径不一：腾讯云给的是**分**，DeepSeek 与火山引擎给的是元。
 * 单位差异只在这里消化，快照的使用方不需要知道谁用分。
 */
public struct BalanceUnits {
    public static const YUAN = 'yuan'
    public static const FEN = 'fen'

    private init(){}

    /** 把上游金额文本按单位换算成元，返回 (元字符串, 元数值) */
    public static func toYuan(text: String, unit: String): (String, Float64) {
        let raw = BalanceUnits.parse(text)
        let yuan = if(unit == FEN){ raw / 100.0f64 }else{ raw }
        (format(yuan), yuan)
    }

    /** 只解析不换算（已经在元的口径上时用） */
    public static func parse(text: String): Float64 {
        try{
            Float64.parse(text)
        }catch(_: Exception){
            0.0f64
        }
    }

    /** 固定两位小数，避免 `100.0` 这种展示 */
    public static func format(yuan: Float64): String {
        let cents = Int64(yuan * 100.0f64 + if(yuan >= 0.0f64){ 0.5f64 }else{ -0.5f64 })
        let sign = if(cents < 0){ '-' }else{ '' }
        let absolute = if(cents < 0){ -cents }else{ cents }
        let whole = absolute / 100
        let rest = absolute % 100
        '${sign}${whole}.${if(rest < 10){ "0${rest}" }else{ "${rest}" }}'
    }

    /** 读平台单位覆盖：`conf['balanceUnit'] = yuan|fen` */
    public static func unitOf(defaultUnit: String, override: String): String {
        let value = override.trimAscii().toAsciiLower()
        if(value == YUAN || value == '元'){
            return YUAN
        }
        if(value == FEN || value == '分'){
            return FEN
        }
        defaultUnit
    }
}
