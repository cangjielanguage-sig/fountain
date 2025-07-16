/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

public class DataUnit <: Data & Hashable & Equatable<DataUnit> {
    public static let UNIT = DataUnit()
    private init() {}
    public func toString(): String {
        '()'
    }
    public static func tryParse(data: String): ?Data {
        if (data == "()") {
            DataUnit.UNIT
        } else {
            None<Data>
        }
    }
    public static func parse(data: String): Data {
        tryParse(data).getOrThrow {
            DataException("DataBool.parse receives string 'true' 'false' or their upper cases, but current is ${data}")
        }
    }
    public func toUnit(): Unit {
        ()
    }
    public func tryToUnit(): ?Unit {
        ()
    }
    public func hashCode(): Int64 {
        ().hashCode()
    }
    public operator func ==(other: DataUnit): Bool {
        true
    }
}

extend Unit <: DataFields<Unit> {
    public func toData(): Data {
        DataUnit.UNIT
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        match (data) {
            case x: DataUnit => x.tryToUnit()
            case _: DataNone => None<Unit>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException(
                '(${data}) does not match ${TypeInfos.get<Unit>()}')
            case x: DataString => DataUnit.tryParse(x.toString())
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException(
                '(${data}) cannot be converted to ${TypeInfos.get<Unit>()}')
            case _ => None<Unit>
        }
    }
}
