/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

public class DataNone <: Data {
    public static let INSTANCE = DataNone()
    private init() {}
    public func toString(): String {
        "None"
    }
    public static func tryParse(data: String): ?Data {
        let d = extractPureString(data)
        if (d.size != 4) {
            return None<Data>
        }
        match (d.toAsciiLower()) {
            case "null" | "none" => INSTANCE
            case _ => None<Data>
        }
    }
    public static func parse(data: String): Data {
        tryParse(data).getOrThrow {
            DataException("DataNone.parse receives string 'null' 'none' or there upper cases, but current is ${data}")
        }
    }
}
