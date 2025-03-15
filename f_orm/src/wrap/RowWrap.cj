/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm.wrap

import std.collection.HashMap
import std.collection.concurrent.ConcurrentHashMap
import f_base.*
import f_exception.UnreachableException
import f_orm.exception.*

public class RowWrap <: Row {
    private static let sqlDataToDataMap = ConcurrentHashMap<String, (SqlDbType) -> AnyData>()
    private var itr: Iterator<AnyData> = EmptyIterator<AnyData>.INSTANCE
    public RowWrap(
        private let driverName: String,
        private let columnInfos: Map<String, Int64>,
        private let row: Array<SqlDbType>
    ) {
        itr = RowWrapIterator(this)
    }
    static func registerSqlDataToDataConverter(driverName: String, converter: (SqlDbType) -> AnyData) {
        sqlDataToDataMap[driverName] = converter
    }
    private static func sqlDataToData(driverName: String, data: SqlDbType): AnyData {
        match (data) {
            case x: SqlAnyData => x.getData()

            //现在由于运行时的限制上面的match pattern无法匹配，还保留着它是盼着将来的运行时能够支持。
            //这个错误在代码量很少，代码不够复杂的情况不会出现。
            //下面的match pattern不能删除，否则会在运行时出异常，
            case x: SqlChar => x.value
            case x: SqlNullableChar => x.value
            case x: SqlVarchar => x.value
            case x: SqlNullableVarchar => x.value
            case x: SqlBinary => x.value
            case x: SqlNullableBinary => x.value
            case x: SqlVarBinary => x.value
            case x: SqlNullableVarBinary => x.value
            case x: SqlClob => DataInputStream(x.value)
            case x: SqlNullableClob => match (x.value) {
                case Some(x) => DataInputStream(x)
                case _ => None<DataInputStream>
            }
            case x: SqlBlob => DataInputStream(x.value)
            case x: SqlNullableBlob => match (x.value) {
                case Some(x) => DataInputStream(x)
                case _ => None<DataInputStream>
            }
            case x: SqlBool => x.value
            case x: SqlNullableBool => x.value
            case x: SqlByte => x.value
            case x: SqlNullableByte => x.value
            case x: SqlSmallInt => x.value
            case x: SqlNullableSmallInt => x.value
            case x: SqlInteger => x.value
            case x: SqlNullableInteger => x.value
            case x: SqlBigInt => x.value
            case x: SqlNullableBigInt => x.value
            case x: SqlReal => x.value
            case x: SqlNullableReal => x.value
            case x: SqlDouble => x.value
            case x: SqlNullableDouble => x.value
            case x: SqlDecimal => x.value
            case x: SqlNullableDecimal => x.value
            case x: SqlDate => x.value
            case x: SqlNullableDate => x.value
            case x: SqlTime => x.value
            case x: SqlNullableTime => x.value
            case x: SqlTimeTz => x.value
            case x: SqlNullableTimeTz => x.value
            case x: SqlTimestamp => x.value
            case x: SqlNullableTimestamp => x.value
            case x: SqlInterval => x.value
            case x: SqlNullableInterval => x.value
            case x => match (sqlDataToDataMap.get(driverName)) {
                case Some(fn) => fn(x)
                case _ => throw ORMException("UNSUPPORTED SqlDbType ${x.name}")
            }
        }
    }
    public func get(columnName: String): ?AnyData {
        if (let Some(index) <- columnInfos.get(columnName)) {
            let data: AnyData = sqlDataToData(driverName, row[index])
            data
        } else {
            None<AnyData>
        }
    }
    public operator func [](columnName: String): AnyData {
        get(columnName).getOrThrow {throw ORMException("column ${columnName} is not found")}
    }
    public func iterator(): Iterator<AnyData> {
        itr
    }
    public operator func [](index: Int64): AnyData {
        sqlDataToData(driverName, row[index])
    }
    public prop size: Int64 {
        get() {
            row.size
        }
    }
    public func isEmpty(): Bool {
        row.isEmpty()
    }
    public func toArray(): Array<AnyData> {
        Array<AnyData>(size) {
            i => this[i]
        }
    }
    public func toMap(): HashMap<String, Any> {
        let map = HashMap<String, Any>()
        for ((k, v) in columnInfos) {
            map[k] = sqlDataToData(driverName, row[v])
        }
        map
    }
}
public class RowWrapIterator <: Iterator<AnyData> {
    private var index = -1
    private var size = 0
    public RowWrapIterator(private let row: RowWrap) {
        size = row.size
    }
    public func next(): ?AnyData {
        index++
        if (index < size) {
            row[index]
        } else {
            None<AnyData>
        }
    }
}
