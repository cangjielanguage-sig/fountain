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

public abstract class DataType {
    private let _index = AtomicInt64(-1)
    public DataType(
        private let nullable: Bool,
        public let columnName: String
    ){}
    private mut prop index: Int64 {
        get(){
            _index.load()
        }
        set(value){
            _index.store(value)
        }
    }
    protected func swapIfNeed(index: Int64): Unit {
        _index.compareAndSwap(-1,  index)
    }
    protected func getValue<T>(result: QueryResult): Any {
        let any: Any = 
        if(nullable){
            (result as QueryResultWrap)?.getOrNull<T>(columnName) ?? None
        }else{
            (result as QueryResultWrap)?.get<T>(columnName).getOrThrow()
        }
        value = any
        any
    }
    public func get(result: QueryResult): Any
}
public class UnknownDataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Any>(result)
    }
}
public class BoolDataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Bool>(result)
    }
}
public class Int8DataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Int8>(result)
    }
}
public class UInt8DataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<UInt8>(result)
    }
}
type ByteDataType = UInt8DataType

public class Int16DataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Int16>(result)
    }
}
public class UInt16DataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<UInt16>(result)
    }
}

public class Int32DataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Int32>(result)
    }
}
public class UInt32DataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<UInt32>(result)
    }
}
public class Int64DataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Int64>(result)
    }
}
public class UInt64DataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<UInt64>(result)
    }
}
public class DecimalDataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Decimal>(result)
    }
}
public class RuneDataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Rune>(result)
    }
}
public class StringDataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<String>(result)
    }
}
public class InputStreamDataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<InputStream>(result)
    }
}
public class DurationDataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Duration>(result)
    }
}
public class DateTimeDataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<DateTime>(result)
    }
}
public class ByteArrayDataType <: DataType {
    public init(nullable: Bool, columnName: String){
        super(nullable, columnName)
    }
    public func get(result: QueryResult): Any {
        getValue<Array<Byte>>(result)
    }
}
