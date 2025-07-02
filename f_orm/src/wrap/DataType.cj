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
    public DataType(
        private let nullable: Bool,
        public let columnName: String
    ) {}
    protected func getValue<T>(result: QueryResultWrap): Any {
        let any: Any = if (nullable) {
            result.getOrNull<T>(columnName)
        } else {
            result.get<T>(columnName)
        }
        any
    }
    public func get(result: QueryResultWrap): Any
}

public class UnknownDataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Any>(result)
    }
}

public class BoolDataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Bool>(result)
    }
}

public class Int8DataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Int8>(result)
    }
}

public class UInt8DataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<UInt8>(result)
    }
}

type ByteDataType = UInt8DataType

public class Int16DataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Int16>(result)
    }
}

public class UInt16DataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<UInt16>(result)
    }
}

public class Int32DataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Int32>(result)
    }
}

public class UInt32DataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<UInt32>(result)
    }
}

public class Int64DataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Int64>(result)
    }
}

public class UInt64DataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<UInt64>(result)
    }
}

public class DecimalDataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Decimal>(result)
    }
}

public class RuneDataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Rune>(result)
    }
}

public class StringDataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<String>(result)
    }
}

public class InputStreamDataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<InputStream>(result)
    }
}

public class DurationDataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Duration>(result)
    }
}

public class DateTimeDataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<DateTime>(result)
    }
}

public class ByteArrayDataType <: DataType {
    public init(nullable: Bool, columnName: String) {
        super(nullable, columnName)
    }
    public func get(result: QueryResultWrap): Any {
        getValue<Array<Byte>>(result)
    }
}
