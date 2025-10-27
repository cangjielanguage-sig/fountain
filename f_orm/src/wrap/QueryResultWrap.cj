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
import std.reflect.*
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
        try{
            if (index >= list.size) {
                let columns = result.columnInfos
                for (i in list.size..index) {
                    let column = columns[i]
                    let v: Any = match(column.typeName){
                        case 'SqlChar' | 'SqlVarchar' | 'String' => result.getOrNull<String>(i)
                        case 'SqlClob' | 'SqlBlob' | 'std.io.InputStream' | 'InputStream' => result.getOrNull<InputStream>(i)
                        case 'SqlBinary' | 'SqlVarBinary' | 'Array<Byte>' | 'Array<UInt8>' => result.getOrNull<Array<Byte>>(i)
                        case 'SqlDecimal' | 'Decimal' | 'std.math.numeric.Decimal' => result.getOrNull<Decimal>(i)
                        case 'SqlBool' | 'Bool' => result.getOrNull<Bool>(i)
                        case 'SqlByte' | 'Int8' => result.getOrNull<Int8>(i)
                        case 'UInt8' | 'Byte' => result.getOrNull<UInt8>(i)
                        case 'SqlSmallInt' | 'Int16' => result.getOrNull<Int16>(i)
                        case 'UInt16' => result.getOrNull<UInt16>(i)
                        case 'SqlInteger' | 'Int32' => result.getOrNull<Int32>(i)
                        case 'UInt32' => result.getOrNull<UInt32>(i)
                        case 'SqlBigInt' | 'Int64' => result.getOrNull<Int64>(i)
                        case 'UInt64' => result.getOrNull<UInt64>(i)
                        case 'SqlReal' | 'Float32' => result.getOrNull<Float32>(i)
                        case 'SqlDouble' | 'Float64' => result.getOrNull<Float64>(i)
                        case 'SqlDate' | 'SqlTime' | 'SqlTimeTz' | 'SqlTimestamp' | 'DateTime' | 'std.time.DateTime' => result.getOrNull<DateTime>(i)
                        case 'SqlInterval' | 'Duration' => result.getOrNull<Duration>(i)
                        case _ => result.getOrNull<String>(i)
                    }
                    list.add(v)
                }
                list.add(result.getOrNull<T>(index))
            }
            func convert(idx: Int64, s: ?String): ?T {
                match(s){
                    case Some(x) where TypeInfo.of<T>().isSubtypeOf(TypeInfo.of<Parsable<T>>()) => 
                        let ti = TypeInfo.of<T>()
                        let fn = ti.getStaticFunction('parse', [TypeInfo.of<String>()])
                        let v = match(fn.apply(ti, [x])){
                            case x: ?T => x
                            case _ => None<T>
                        }
                        list[idx] = v
                        v
                    case _ => None<T>
                }
            }
            match(list[index]){
                case x: T => x
                case x: ?T => x
                case x: String => convert(index, x)
                case x: ?String => convert(index, x)
                case x: ToString => convert(index, '${x}')
                case _ => 
                    let column = columnInfos[index]
                    throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
            }
        }catch(e: Exception){
            let column = columnInfos[index]
            throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}', e)
        }
    }
    public func get<T>(columnName: String): T {
        getOrNull<T>(columnName).getOrThrow()
    }
    public func getOrNull<T>(columnName: String): ?T {
        match(columnInfoMap.get(columnName)){
            case Some(idx) => getOrNull<T>(idx)
            case _ => None<T>
        }
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
