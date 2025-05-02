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

import std.convert.Parsable

public class DataBool <: Data & Hashable & Equatable<DataBool> {
    public static let TRUE = DataBool(true)
    public static let FALSE = DataBool(false)
    private DataBool(public let data: Bool){}
    public func toString(): String {
        data.toString()
    }
    public static func tryParse(data: String): ?Data {
        match(Bool.tryParse(extractPureString(data).toAsciiLower())){
            case Some(x) => DataBool(x)
            case _ => None<Data>
        }
    }
    public static func parse(data: String): Data {
        tryParse(data).getOrThrow{DataException("DataBool.parse receives string 'truer' 'false' or there upper cases, but current is ${data}")}
    }
    public func toBool(): Bool {
        data
    }
    public func tryToBool(): ?Bool {
        data
    }
    public func hashCode(): Int64 {
        data.hashCode()
    }
    public operator func ==(other: DataBool): Bool {
        data == other.data
    }
}
extend Bool <: DataFields<Bool> {
    public func toData(): Data {
        if(this) {
            DataBool.TRUE
        } else {
            DataBool.FALSE
        }
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match(data){
            case x: DataBool => x.tryToBool()
            case _: DataNone => None<Bool>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Bool>()}')
            case x: DataString =>
                let s = x.toString().toAsciiLower()
                if (s == "true" || s == "false") {
                    Bool.tryParse(s)
                } else {
                    None<Bool>
                }
            case x: DataReal =>
                x.toDecimal() != Decimal.zero
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted to ${TypeInfos.get<Bool>()}')
            case _ => None<Bool>
        }
    }
}
