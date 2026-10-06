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
package fountain::f_orm.wrap

import std.database.sql.*
import std.reflect.*
import fountain::f_base.*

public class QueryResultWrap <: QueryResult {
    private let columnInfoMap = HashMap<String, Int64>()
    // bug.md §1.13（ORM-2）：列信息在构造期取一次，不再让每个单元格都穿透到 result.columnInfos
    private let columns: Array<ColumnInfo>
    private var list = unsafeZeroValue<ArrayList<Any>>()
    private let indexStartsWith: Int64
    // bug-orm.md §3.2 ORM-C6（陷阱 1 / B）：本结果是否交出过流（BLOB/CLOB）。含流的结果**不进** `SqlExecutor`
    // 的结果缓存——缓存会把值留到结果集关闭之后，一旦驱动交出的是"绑定结果集/句柄的流"，缓存里就是失效值。
    // 判据按"实际读出的单元格"置位（没读的 BLOB 列不影响缓存），所以置位点在取数路径上（`getOrNull`）。
    private var hadStream_ = false

    /** 本结果是否交出过 `InputStream`（BLOB/CLOB）；供 `SqlExecutor` 决定要不要写结果缓存 */
    public prop hadStream: Bool {
        get() {
            hadStream_
        }
    }
    /** 取数路径上标记"这一格是流"（`InputStream` 与 `?InputStream` 的 `Some` 都算；`None` 不算） */
    private func noteStreamCell(cell: Any): Unit {
        if (let x: ?InputStream <- cell) {
            match (x) {
                case Some(_) => hadStream_ = true
                case _ => ()
            }
        }
    }
    public QueryResultWrap(private let driverName: String, private let result: QueryResult) {
        indexStartsWith = ORMConfig.getIndexStartsWith(driverName: driverName)
        columns = result.columnInfos
        for (i in 0..columns.size) {
            columnInfoMap[columns[i].name] = i
        }
        list = ArrayList<Any>(columns.size)
    }
    // bug.md §1.13（ORM-2）：把「列类型 -> 取值」的判定收进按需构造的取值器，避免在每个单元格上重写这段 match。
    // 取值器按需构造（不预先为每列建表）：一列最多只在被读到时构造一次闭包。
    // 必须是 static：构造期不允许调用实例方法。
    private static func makeReader(result: QueryResult, typeName: String): (Int64) -> Any {
        match(typeName){
            case 'SqlChar' | 'SqlVarchar' | 'String' | 'string' | 'char' | 'text' | 'varchar' | 'name' | 'bpchar' | 'json' | 'jsonb' | 'xml' | 'uuid' => { i => result.getOrNull<String>(i) }
            case 'SqlClob' | 'SqlBlob' | 'std.io.InputStream' | 'InputStream' => { i => result.getOrNull<InputStream>(i) }
            case 'SqlBinary' | 'SqlVarBinary' | 'Array<Byte>' | 'Array<UInt8>' | 'bytea' => { i => result.getOrNull<Array<Byte>>(i) }
            case 'SqlDecimal' | 'Decimal' | 'std.math.numeric.Decimal' | 'numeric' | 'money' => { i => result.getOrNull<Decimal>(i) }
            case 'SqlBool' | 'Bool' | 'bool' => { i => result.getOrNull<Bool>(i) }
            case 'SqlByte' | 'Int8' => { i => result.getOrNull<Int8>(i) }
            case 'UInt8' | 'Byte' => { i => result.getOrNull<UInt8>(i) }
            case 'SqlSmallInt' | 'Int16' => { i => result.getOrNull<Int16>(i) }
            case 'UInt16' => { i => result.getOrNull<UInt16>(i) }
            case 'SqlInteger' | 'Int32' => { i => result.getOrNull<Int32>(i) }
            case 'UInt32' | 'int2' | 'int4' => { i => result.getOrNull<UInt32>(i) }
            case 'SqlBigInt' | 'Int64' | 'int8' => { i => result.getOrNull<Int64>(i) }
            case 'UInt64' => { i => result.getOrNull<UInt64>(i) }
            case 'SqlReal' | 'Float32' | 'float4' => { i => result.getOrNull<Float32>(i) }
            case 'SqlDouble' | 'Float64' | 'float8' => { i => result.getOrNull<Float64>(i) }
            case 'SqlDate' | 'SqlTime' | 'SqlTimeTz' | 'SqlTimestamp' | 'DateTime' | 'std.time.DateTime' | 'date' | 'time' | 'timetz' | 'timestamptz' | '' => { i => result.getOrNull<DateTime>(i) }
            case 'SqlInterval' | 'Duration' | 'interval' => { i => result.getOrNull<Duration>(i) }
            case _ => { i => result.getOrNull<String>(i) }
        }
    }
    public func next(): Bool {
        list.clear()
        result.next()
    }

    public prop columnInfos: Array<ColumnInfo> {
        get() {
            columns
        }
    }
    public func get<T>(index: Int64): T {
        getOrNull<T>(index).getOrThrow()
    }
    public func getOrNull<T>(index: Int64): ?T {
        if(columns.size <= index){
            return None<T>
        }
        try{
            if (index >= list.size) {
                for (i in list.size..=index) {
                    let cell = makeReader(result, columns[i].typeName)(i + indexStartsWith)
                    // bug-orm.md §3.2 ORM-C6（陷阱 1 / B）：守住"这一格是流"，供 SqlExecutor 决定是否进结果缓存
                    noteStreamCell(cell)
                    list.add(cell)
                }
                // list.add(result.getOrNull<T>(index))
            }
            func convertFromString(idx: Int64, s: ?String): ?T {
                match(s){
                    case Some(x) => 
                        let v: Any = match(None<T>){
                            case _: ?Int8 => Int8.parse(x)
                            case _: ?Int16 => Int16.parse(x)
                            case _: ?Int32 => Int32.parse(x)
                            case _: ?Int64 => Int64.parse(x)
                            case _: ?UInt8 => UInt8.parse(x)
                            case _: ?UInt16 => UInt16.parse(x)
                            case _: ?UInt32 => UInt32.parse(x)
                            case _: ?UInt64 => UInt64.parse(x)
                            case _: ?Float16 => Float16.parse(x)
                            case _: ?Float32 => Float32.parse(x)
                            case _: ?Float64 => Float64.parse(x)
                            case _: ?BigInt => BigInt.parse(x)
                            case _: ?Decimal => Decimal.parse(x)
                            case _: ?Duration => Duration.parse(x)
                            case _: ?DateTime => DateTime.parse(x)
                            case _ => throw ORMException('String ${x} cannot be parsed to ${TypeInfo.of<T>()}')
                        }
                        list[idx] = v
                        v as T
                    case _ => None<T>
                }
            }
            match(list[index]){
                case x: T => x
                case x: ?T => x
                case x: String => convertFromString(index, x)
                case x: ?String => convertFromString(index, x)
                case x: ?Int8 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?Int16 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?Int32 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?Int64 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?UInt8 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?UInt16 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?UInt32 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?UInt64 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?Float16 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?Float32 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?Float64 => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => Int8(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => Int16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => Int32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => Int64(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => UInt8(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => UInt16(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => UInt32(x) as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => UInt64(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => BigInt(x) as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?BigInt => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => x.toInt8() as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => x.toInt16() as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => x.toInt32() as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => x.toInt64() as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => x.toUInt8() as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => x.toUInt16() as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => x.toUInt32() as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => x.toUInt64() as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => Float16(x.toInt64()) as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => Float32(x.toInt64()) as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => Float64(x.toInt64()) as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => Decimal(x) as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?Decimal => match(None<T>){
                    case _: ?Int8 => match(x){
                        case Some(x) => x.toInt8() as T
                        case _ => None<T>
                    }
                    case _: ?Int16 => match(x){
                        case Some(x) => x.toInt16() as T
                        case _ => None<T>
                    }
                    case _: ?Int32 => match(x){
                        case Some(x) => x.toInt32() as T
                        case _ => None<T>
                    }
                    case _: ?Int64 => match(x){
                        case Some(x) => x.toInt64() as T
                        case _ => None<T>
                    }
                    case _: ?UInt8 => match(x){
                        case Some(x) => x.toUInt8() as T
                        case _ => None<T>
                    }
                    case _: ?UInt16 => match(x){
                        case Some(x) => x.toUInt16() as T
                        case _ => None<T>
                    }
                    case _: ?UInt32 => match(x){
                        case Some(x) => x.toUInt32() as T
                        case _ => None<T>
                    }
                    case _: ?UInt64 => match(x){
                        case Some(x) => x.toUInt64() as T
                        case _ => None<T>
                    }
                    case _: ?Float16 => match(x){
                        case Some(x) => x.toFloat16() as T
                        case _ => None<T>
                    }
                    case _: ?Float32 => match(x){
                        case Some(x) => x.toFloat32() as T
                        case _ => None<T>
                    }
                    case _: ?Float64 => match(x){
                        case Some(x) => x.toFloat64() as T
                        case _ => None<T>
                    }
                    case _: ?BigInt => match(x){
                        case Some(x) => x.toBigInt() as T
                        case _ => None<T>
                    }
                    case _: ?Decimal => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?Duration => match(None<T>){
                    case _: ?Duration => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?DateTime => match(None<T>){
                    case _: ?DateTime => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _: ?String => match(x){
                        case Some(x) => x.toString() as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?Array<Byte> => match(None<T>){
                    case _: ?Array<Byte> => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
                case x: ?InputStream => match(None<T>){
                    case _: ?InputStream => match(x){
                        case Some(x) => x as T
                        case _ => None<T>
                    }
                    case _ => 
                        let column = columnInfos[index]
                        throw ORMException('colum index: ${index}, column type: ${column.typeName}, column name: ${column.name}, requires: ${TypeInfo.of<T>()}')
                }
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
