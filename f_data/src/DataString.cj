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

public class DataString <: Data & Hashable & Comparable<DataString> {
    public DataString(public let data: String){}
    public init(data: ToString){
        this(data.toString())
    }
    private init(){
        this("")
    }
    public func toString(): String {
        data
    }
    public static func tryParse(data: String): ?Data {
        DataString(data)
    }
    public static func parse(data: String): Data {
        DataString(data)
    }
    public func hashCode(): Int64 {
        data.hashCode()
    }
    public func compare(other: DataString): Ordering {
        data.compare(other.data)
    }
}
extend String <: DataFields<String> {
    public func toData(): Data {
        DataString(this)
    }
    public static func fromData(data: Data, flag!: DataConversionFlag = SILENCE): String {
        tryFromData(data, flag: flag).value.getOrThrow{DataException("${data} cannot be converted to String")}
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<String> {
        match(data){
            case x: DataString => DataOption(x.data)
            case x: DataNone => DataOption<String>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match to ${TypeInfos.get<String>()}')
            case x => DataOption(x.toString())
        }
    }
}
