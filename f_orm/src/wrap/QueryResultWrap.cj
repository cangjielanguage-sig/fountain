/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_orm.wrap

import std.database.sql.*
import f_base.*

public class QueryResultWrap <: QueryResult {
    private let columnInfoMap = HashMap<String, Int64>()
    private var list = unsafeZeroValue<ArrayList<Any>>()
    public QueryResultWrap(private let driverName: String, private let result: QueryResult) {
        for (i in 0..columnInfos.size) {
            columnInfoMap[columnInfos[i].name] = i
        }
        list = ArrayList<Any>(columnInfos.size)
    }
    public func next(): Bool {
        list.clear()
        result.next()
    }

    public prop columnInfos: Array<ColumnInfo> {
        get() {
            result.columnInfos
        }
    }
    public func get<T>(index: Int64): T {
        getOrNull<T>(index).getOrThrow()
    }
    public func getOrNull<T>(index: Int64): ?T {
        if (index >= list.size) {
            for (i in list.size..=index) {
                list.add(result.getOrNull<T>(i))
            }
        }
        (list[index] as ?T).getOrThrow{
            let column = columnInfos[index]
            ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
        }
    }
    public func get<T>(columnName: String): T {
        get<T>(columnInfoMap[columnName])
    }
    public func getOrNull<T>(columnName: String): ?T {
        getOrNull<T>(columnInfoMap[columnName])
    }
    public func next(values: Array<SqlDbType>): Bool {
        throw ORMException('this func is deprecated')
    }
    public func toMap(): HashMap<String, Any> {
        let map = HashMap<String, Any>()
        for ((column, index) in columnInfoMap) {
            map[column] = match(columnInfos[index].typeName) {
                case 'SqlChar' | 'SqlVarchar' | 'String' | 'Rune' => get<String>(index)
                case 'SqlNullableChar' | 'SqlNullableVarchar' | 'Option<String>' | '?String' | 'Option<Rune>' | '?Rune' => getOrNull<String>(index)
                case 'SqlClob' | 'InputStream' => get<InputStream>(index)
                case 'SqlNullableClob' => getOrNull<InputStream>(index)
                case 'SqlBinary' | 'SqlVarBinary' | 'Array<Byte>' | 'Array<UInt8>' => get<Array<Byte>>(index)
                case 'SqlNullableBinary' | 'SqlNullableVarBinary' | 'Option<Array<Byte>>' | 'Option<Array<UInt8>>' | '?Array<Byte>' | '?Array<UInt8>' => getOrNull<Array<Byte>>(index)
                case 'SqlBlob' => get<InputStream>(index)
                case 'SqlNullableBlob' => getOrNull<InputStream>(index)
                case 'SqlDecimal' | 'Decimal' => get<Decimal>(index)
                case 'SqlNullableDecimal' | '?Decimal' | 'Option<Decimal>' => getOrNull<Decimal>(index)
                case 'SqlBool' | 'Bool' => get<Bool>(index)
                case 'SqlNullableBool' | '?Bool' | 'Option<Bool>' => getOrNull<Bool>(index)
                case 'SqlByte' | 'Byte' | 'UInt8' => get<UInt8>(index)
                case 'SqlNullableByte' | '?Byte' | 'Option<Byte>' | '?UInt8' | 'Option<UInt8>' => getOrNull<UInt8>(index)
                case 'SqlSmallInt' | 'Int16' => get<Int16>(index)
                case 'SqlNullableSmallInt' | '?Int16' | 'Option<Int16>' => getOrNull<Int16>(index)
                case 'SqlInteger' | 'Int32' => get<Int32>(index)
                case 'SqlNullableInteger' | '?Int32' | 'Option<Int32>' => getOrNull<Int32>(index)
                case 'SqlBigInt' | 'Int64' => get<Int64>(index)
                case 'SqlNullableBigInt' | '?Int64' | 'Option<Int64>' => getOrNull<Int64>(index)
                case 'SqlReal' | 'Float32' => get<Float32>(index)
                case 'SqlNullableReal' | '?Float32' | 'Option<Float32>' => getOrNull<Float32>(index)
                case 'SqlDouble' | 'Float64' => get<Float64>(index)
                case 'SqlNullableDouble' | '?Float64' | 'Option<Float64>' => getOrNull<Float64>(index)
                case 'SqlDate' | 'SqlTime' | 'SqlTimeTz' | 'SqlTimestamp' | 'DateTime' => get<DateTime>(index)
                case 'SqlNullableDate' | 'SqlNullableTime' | 'SqlNullableTimeTz' | 'SqlNullableTimestamp' |
                     '?DateTime' | 'Option<DateTime>' => getOrNull<DateTime>(index)
                case 'SqlInterval' | 'Duration' => get<Duration>(index)
                case 'SqlNullableInterval' | '?Duration' | 'Option<Duration>' => getOrNull<Duration>(index)
                case _ => throw SqlException("Unsupported typeName ${columnInfos[index].typeName}")
            }
        }
        map
    }
    public func isClosed(): Bool {
        result.isClosed()
    }
    public func close(): Unit {
        result.close()
    }
}
