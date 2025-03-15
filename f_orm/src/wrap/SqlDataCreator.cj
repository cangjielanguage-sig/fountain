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

import std.convert.*
import std.collection.concurrent.ConcurrentHashMap
import std.io.ByteBuffer
import f_orm.exception.ORMException

public class SqlDataCreators {
    private static let dataCreators = {
         =>
        let map = ConcurrentHashMap<String, SqlDataCreator>()
        populate(map, DataType.char, SqlCharCreator())
        populate(map, DataType.nullable_char, SqlNullableCharCreator())
        populate(map, "SqlChar", SqlCharCreator())
        populate(map, "SqlNullableChar", SqlNullableCharCreator())

        populate(map, DataType.string, SqlVarcharCreator())
        populate(map, DataType.nullable_string, SqlNullableVarcharCreator())
        populate(map, "SqlVarchar", SqlVarcharCreator())
        populate(map, "SqlNullableVarchar", SqlNullableVarcharCreator())

        populate(map, DataType.bytes, SqlBinaryCreator())
        populate(map, DataType.nullable_bytes, SqlNullableBinaryCreator())
        populate(map, "SqlBinary", SqlBinaryCreator())
        populate(map, "SqlNullableBinary", SqlNullableBinaryCreator())

        populate(map, DataType.var_bytes, SqlVarBinaryCreator())
        populate(map, DataType.nullable_var_bytes, SqlNullableVarBinaryCreator())
        populate(map, "SqlVarBinary", SqlVarBinaryCreator())
        populate(map, "SqlNullableVarBinary", SqlNullableVarBinaryCreator())

        populate(map, DataType.clob, SqlClobCreator())
        populate(map, DataType.nullable_clob, SqlNullableClobCreator())
        populate(map, "SqlClob", SqlClobCreator())
        populate(map, "SqlNullableClob", SqlNullableClobCreator())

        populate(map, DataType.blob, SqlBlobCreator())
        populate(map, DataType.nullable_blob, SqlNullableBlobCreator())
        populate(map, "SqlBlob", SqlBlobCreator())
        populate(map, "SqlNullableBlob", SqlNullableBlobCreator())

        populate(map, DataType.bool, SqlBoolCreator())
        populate(map, DataType.nullable_bool, SqlNullableBoolCreator())
        populate(map, "SqlBool", SqlBoolCreator())
        populate(map, "SqlNullableBool", SqlNullableBoolCreator())

        populate(map, DataType.int8, SqlByteCreator())
        populate(map, DataType.nullable_int8, SqlNullableByteCreator())
        populate(map, "SqlByte", SqlByteCreator())
        populate(map, "SqlNullableByte", SqlNullableByteCreator())

        populate(map, DataType.int16, SqlSmallIntCreator())
        populate(map, DataType.nullable_int16, SqlNullableSmallIntCreator())
        populate(map, "SqlSmallInt", SqlSmallIntCreator())
        populate(map, "SqlNullableSmallInt", SqlNullableSmallIntCreator())

        populate(map, DataType.int32, SqlIntegerCreator())
        populate(map, DataType.nullable_int32, SqlNullableIntegerCreator())
        populate(map, "SqlInteger", SqlIntegerCreator())
        populate(map, "SqlNullableInteger", SqlNullableIntegerCreator())

        populate(map, DataType.int64, SqlBigIntCreator())
        populate(map, DataType.nullable_int64, SqlNullableBigIntCreator())
        populate(map, "SqlBigInt", SqlBigIntCreator())
        populate(map, "SqlNullableBigInt", SqlNullableBigIntCreator())

        populate(map, DataType.float32, SqlRealCreator())
        populate(map, DataType.nullable_float32, SqlNullableRealCreator())
        populate(map, "SqlReal", SqlRealCreator())
        populate(map, "SqlNullableReal", SqlNullableRealCreator())

        populate(map, DataType.float64, SqlDoubleCreator())
        populate(map, DataType.nullable_float64, SqlNullableDoubleCreator())
        populate(map, "SqlDouble", SqlDoubleCreator())
        populate(map, "SqlNullableDouble", SqlNullableDoubleCreator())

        populate(map, DataType.date, SqlDateCreator())
        populate(map, DataType.nullable_date, SqlNullableDateCreator())
        populate(map, "SqlDate", SqlDateCreator())
        populate(map, "SqlNullableDate", SqlNullableDateCreator())

        populate(map, DataType.time, SqlTimeCreator())
        populate(map, DataType.nullable_time, SqlNullableTimeCreator())
        populate(map, "SqlTime", SqlTimeCreator())
        populate(map, "SqlNullableTime", SqlNullableTimeCreator())

        populate(map, DataType.time_timezone, SqlTimeTzCreator())
        populate(map, DataType.nullable_time_timezone, SqlNullableTimeTzCreator())
        populate(map, "SqlTimeTz", SqlTimeTzCreator())
        populate(map, "SqlNullableTimeTz", SqlNullableTimeTzCreator())

        populate(map, DataType.timestamp, SqlTimestampCreator())
        populate(map, DataType.nullable_timestamp, SqlNullableTimestampCreator())
        populate(map, "SqlTimestamp", SqlTimestampCreator())
        populate(map, "SqlNullableTimestamp", SqlNullableTimestampCreator())

        populate(map, DataType.duration, SqlIntervalCreator())
        populate(map, DataType.nullable_duration, SqlNullableIntervalCreator())
        populate(map, "SqlInterval", SqlIntervalCreator())
        populate(map, "SqlNullableInterval", SqlNullableIntervalCreator())

        map
    }()
    private static func populate(map: ConcurrentHashMap<String, SqlDataCreator>, dataType: DataType, creator: SqlDataCreator) {
        populate(map, dataType.toString(), creator)
    }
    private static func populate(map: ConcurrentHashMap<String, SqlDataCreator>, key: String, creator: SqlDataCreator) {
        map[key] = creator
    }
    private static func genKey(driverName: String, dataType: String): String {
        "${driverName}:${dataType}"
    }
    public static func register(driverName: String, dataType: DataType, creator: SqlDataCreator) {
        register(driverName, dataType.toString(), creator)
    }
    public static func register(driverName: String, sqlTypeName: String, creator: SqlDataCreator) {
        populate(dataCreators, genKey(driverName, sqlTypeName), creator)
    }
    public static func generate(driverName: String, dataType: DataType): SqlDbType {
        generate(driverName, dataType.toString())
    }
    public static func generate(driverName: String, sqlTypeName: String): SqlDbType {
        (dataCreators.get(genKey(driverName, sqlTypeName)) ?? dataCreators[sqlTypeName]).create()
    }
    public static func generate<T>(driverName: String, dataType: DataType, value: T): SqlDbType {
        generate<T>(driverName, dataType.toString(), value)
    }
    public static func generate<T>(driverName: String, sqlTypeName: String, value: T): SqlDbType {
        (dataCreators.get(genKey(driverName, sqlTypeName)) ?? dataCreators[sqlTypeName]).create(value)
    }
    public static func generate(driverName: String, info: ColumnInfo): SqlDbType {
        var sqlTypeName = info.typeName
        if (info.nullable && !sqlTypeName.startsWith("SqlNullable")) {
            sqlTypeName = "SqlNullable${sqlTypeName[3..]}"
        }
        (dataCreators.get(genKey(driverName, sqlTypeName)) ?? dataCreators[sqlTypeName]).create(info)
    }
}
public interface SqlDataCreator {
    func create(): SqlDbType
    func create(value: Any): SqlDbType
    func create(column: ColumnInfo): SqlDbType
}
public class SqlCharCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlChar(String.empty)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: ToString => x.toString()
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => x.toString()
                case _ => throw ORMException("current value must not be none")
            }
            case x: ToString => x.toString()
            case _ => throw ORMException("current value does not match")
        }
        SqlChar(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlChar(String.empty)
    }
}
public class SqlVarcharCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlVarchar(String.empty)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: ToString => x.toString()
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => x.toString()
                case _ => throw ORMException("current value must not be none")
            }
            case x: ToString => x.toString()
            case _ => throw ORMException("current value does not match")
        }
        SqlVarchar(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlVarchar(String.empty)
    }
}
public class SqlBinaryCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlBinary(Array<Byte>())
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Array<Byte> => x
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Array<Byte>> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Array<Byte> => x
            case _ => throw ORMException("current value does not match")
        }
        SqlBinary(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlBinary(Array<Byte>(column.length, repeat: 0))
    }
}
public class SqlVarBinaryCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlVarBinary(Array<Byte>())
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Array<Byte> => x
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Array<Byte>> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Array<Byte> => x
            case _ => throw ORMException("current value does not match")
        }
        SqlVarBinary(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlVarBinary(Array<Byte>(column.length, repeat: 0))
    }
}
public class SqlClobCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlClob(ByteBuffer())
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Array<Byte> =>
                        let s = ByteBuffer()
                        s.write(x)
                        s
                    case x: InputStream => x
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Array<Byte>> => match (x) {
                case Some(x) =>
                    let s = ByteBuffer()
                    s.write(x)
                    s
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<InputStream> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Array<Byte> =>
                let s = ByteBuffer()
                s.write(x)
                s
            case x: InputStream => x
            case _ => throw ORMException("current value does not match")
        }
        SqlClob(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlClob(ByteBuffer())
    }
}
public class SqlBlobCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlBlob(ByteBuffer())
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Array<Byte> =>
                        let s = ByteBuffer()
                        s.write(x)
                        s
                    case x: InputStream => x
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Array<Byte>> => match (x) {
                case Some(x) =>
                    let s = ByteBuffer()
                    s.write(x)
                    s
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<InputStream> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Array<Byte> =>
                let s = ByteBuffer()
                s.write(x)
                s
            case x: InputStream => x
            case _ => throw ORMException("current value does not match")
        }
        SqlBlob(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlBlob(ByteBuffer())
    }
}
public class SqlBoolCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlBool(false)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Bool => x
                    case x: ToString => Bool.parse(x.toString())
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => Bool.parse(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => Bool.parse(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Bool> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Bool => x
            case x: ToString => Bool.parse(x.toString())
            case _ => throw ORMException("current value does not match")
        }
        SqlBool(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlBool(false)
    }
}
public class SqlByteCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlByte(0)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Int8 => x
                    case x: ToString => Int8.parse(x.toString())
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => Int8.parse(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => Int8.parse(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Int8> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Int8 => x
            case x: ToString => Int8.parse(x.toString())
            case _ => throw ORMException("current value does not match")
        }
        SqlByte(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlByte(0)
    }
}
public class SqlSmallIntCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlSmallInt(0)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Int16 => x
                    case x: ToString => Int16.parse(x.toString())
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => Int16.parse(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => Int16.parse(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Int16> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Int16 => x
            case x: ToString => Int16.parse(x.toString())
            case _ => throw ORMException("current value does not match")
        }
        SqlSmallInt(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlSmallInt(0)
    }
}
public class SqlIntegerCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlInteger(0)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Int32 => x
                    case x: ToString => Int32.parse(x.toString())
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => Int32.parse(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => Int32.parse(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Int32> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Int32 => x
            case x: ToString => Int32.parse(x.toString())
            case _ => throw ORMException("current value does not match")
        }
        SqlInteger(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlInteger(0)
    }
}
public class SqlBigIntCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlBigInt(0)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Int64 => x
                    case x: ToString => Int64.parse(x.toString())
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => Int64.parse(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => Int64.parse(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Int64> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Int64 => x
            case x: ToString => Int64.parse(x.toString())
            case _ => throw ORMException("current value does not match")
        }
        SqlBigInt(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlBigInt(0)
    }
}
public class SqlRealCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlReal(0.0)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: ToString => Float32.parse(x.toString())
                    case x: Float32 => x
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => Float32.parse(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => Float32.parse(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Float32> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: ToString => Float32.parse(x.toString())
            case x: Float32 => x
            case _ => throw ORMException("current value does not match")
        }
        SqlReal(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlReal(0.0)
    }
}
public class SqlDoubleCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlDouble(0.0)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: ToString => Float64.parse(x.toString())
                    case x: Float64 => x
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => Float64.parse(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => Float64.parse(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Float64> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: ToString => Float64.parse(x.toString())
            case x: Float64 => x
            case _ => throw ORMException("current value does not match")
        }
        SqlDouble(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlDouble(0.0)
    }
}
public class SqlDateCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        create(DateTime.UnixEpoch)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: ToString => SqlVarchar(x.toString())
                    case x: DateTime => SqlDate(x)
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => SqlVarchar(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => SqlVarchar(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<DateTime> => match (x) {
                case Some(x) => SqlDate(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: ToString => SqlVarchar(x.toString())
            case x: DateTime => SqlDate(x)
            case _ => throw ORMException("current value does not match")
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlDate(DateTime.UnixEpoch)
    }
}
public class SqlTimeCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlTime(DateTime.UnixEpoch)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: ToString => SqlVarchar(x.toString())
                    case x: DateTime => SqlTime(x)
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => SqlVarchar(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => SqlVarchar(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<DateTime> => match (x) {
                case Some(x) => SqlTime(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: ToString => SqlVarchar(x.toString())
            case x: DateTime => SqlTime(x)
            case _ => throw ORMException("current value does not match")
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlTime(DateTime.UnixEpoch)
    }
}
public class SqlTimeTzCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlTimeTz(DateTime.UnixEpoch)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: ToString => SqlVarchar(x.toString())
                    case x: DateTime => SqlTimeTz(x)
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => SqlVarchar(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => SqlVarchar(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<DateTime> => match (x) {
                case Some(x) => SqlTimeTz(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: ToString => SqlVarchar(x.toString())
            case x: DateTime => SqlTimeTz(x)
            case _ => throw ORMException("current value does not match")
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlTimeTz(DateTime.UnixEpoch)
    }
}
public class SqlTimestampCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlTimestamp(DateTime.UnixEpoch)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: ToString => SqlVarchar(x.toString())
                    case x: DateTime => SqlTimestamp(x)
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<String> => match (x) {
                case Some(x) => SqlVarchar(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<ToString> => match (x) {
                case Some(x) => SqlVarchar(x.toString())
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<DateTime> => match (x) {
                case Some(x) => SqlTimestamp(x)
                case _ => throw ORMException("current value must not be none")
            }
            case x: ToString => SqlVarchar(x.toString())
            case x: DateTime => SqlTimestamp(x)
            case _ => throw ORMException("current value does not match")
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlTimestamp(DateTime.UnixEpoch)
    }
}
public class SqlIntervalCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlInterval(Duration.Zero)
    }
    public func create(value: Any): SqlDbType {
        let v = match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: Duration => x
                    case _ => throw ORMException("current value does not match")
                }
                case _ => throw ORMException("current value must not be none")
            }
            case x: Option<Duration> => match (x) {
                case Some(x) => x
                case _ => throw ORMException("current value must not be none")
            }
            case x: Duration => x
            case _ => throw ORMException("current value does not match")
        }
        SqlInterval(v)
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlInterval(Duration.Zero)
    }
}
public class SqlNullableCharCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableChar(None<String>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<String> => SqlNullableChar(x)
            case x: String => SqlNullableChar(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableChar(None<String>)
    }
}
public class SqlNullableVarcharCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableVarchar(None<String>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<String> => SqlNullableVarchar(x)
            case x: String => SqlNullableVarchar(x)
            case x: ToString => SqlNullableVarchar(x.toString())
            case x: Option<ToString> => match (x) {
                case Some(x) => SqlNullableVarchar(x.toString())
                case _ => SqlNullableVarchar(None<String>)
            }
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableVarchar(None<String>)
    }
}
public class SqlNullableBinaryCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableBinary(None<Array<Byte>>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Array<Byte>> => SqlNullableBinary(x)
            case x: Array<Byte> => SqlNullableBinary(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableBinary(None<Array<Byte>>)
    }
}
public class SqlNullableVarBinaryCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableVarBinary(None<Array<Byte>>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Array<Byte>> => SqlNullableVarBinary(x)
            case x: Array<Byte> => SqlNullableVarBinary(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableVarBinary(None<Array<Byte>>)
    }
}
public class SqlNullableClobCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableClob(None<InputStream>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<InputStream> => SqlNullableClob(x)
            case x: InputStream => SqlNullableClob(x)
            case x: Option<DataInputStream> => match (x) {
                case Some(x) => SqlNullableClob(x)
                case _ => SqlNullableClob(None<InputStream>)
            }
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableClob(None<InputStream>)
    }
}
public class SqlNullableBlobCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableBlob(None<InputStream>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<InputStream> => SqlNullableBlob(x)
            case x: InputStream => SqlNullableBlob(x)
            case x: Option<DataInputStream> => match (x) {
                case Some(x) => SqlNullableBlob(x)
                case _ => SqlNullableBlob(None<InputStream>)
            }
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableBlob(None<InputStream>)
    }
}
public class SqlNullableBoolCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableBool(None<Bool>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Bool> => SqlNullableBool(x)
            case x: Bool => SqlNullableBool(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableBool(None<Bool>)
    }
}
public class SqlNullableByteCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableByte(None<Int8>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Int8> => SqlNullableByte(x)
            case x: Int8 => SqlNullableByte(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableByte(None<Int8>)
    }
}
public class SqlNullableSmallIntCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableSmallInt(None<Int16>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Int16> => SqlNullableSmallInt(x)
            case x: Int16 => SqlNullableSmallInt(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableSmallInt(None<Int16>)
    }
}
public class SqlNullableIntegerCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableInteger(None<Int32>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Int32> => SqlNullableInteger(x)
            case x: Int32 => SqlNullableInteger(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableInteger(None<Int32>)
    }
}
public class SqlNullableBigIntCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableBigInt(None<Int64>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Int64> => SqlNullableBigInt(x)
            case x: Int64 => SqlNullableBigInt(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableBigInt(None<Int64>)
    }
}
public class SqlNullableRealCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableReal(None<Float32>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Float32> => SqlNullableReal(x)
            case x: Float32 => SqlNullableReal(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableReal(None<Float32>)
    }
}
public class SqlNullableDoubleCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableDouble(None<Float64>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Float64> => SqlNullableDouble(x)
            case x: Float64 => SqlNullableDouble(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableDouble(None<Float64>)
    }
}
public class SqlNullableDateCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableDate(None<DateTime>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<DateTime> => SqlNullableDate(x)
            case x: Option<String> => SqlNullableVarchar(x)
            case x: Option<ToString> => match (x) {
                case Some(x) => SqlNullableVarchar(x.toString())
                case _ => SqlNullableDate(None<DateTime>)
            }
            case x: DateTime => SqlNullableDate(x)
            case x: ToString => SqlNullableVarchar(x.toString())
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableDate(None<DateTime>)
    }
}
public class SqlNullableTimeCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableTime(None<DateTime>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<DateTime> => SqlNullableTime(x)
            case x: Option<String> => SqlNullableVarchar(x)
            case x: Option<ToString> => match (x) {
                case Some(x) => SqlNullableVarchar(x.toString())
                case _ => SqlNullableTime(None<DateTime>)
            }
            case x: DateTime => SqlNullableTime(x)
            case x: ToString => SqlNullableVarchar(x.toString())
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableTime(None<DateTime>)
    }
}
public class SqlNullableTimeTzCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableTimeTz(None<DateTime>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<DateTime> => SqlNullableTimeTz(x)
            case x: Option<String> => SqlNullableVarchar(x)
            case x: Option<ToString> => match (x) {
                case Some(x) => SqlNullableVarchar(x.toString())
                case _ => SqlNullableTimeTz(None<DateTime>)
            }
            case x: DateTime => SqlNullableTimeTz(x)
            case x: ToString => SqlNullableVarchar(x.toString())
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableTimeTz(None<DateTime>)
    }
}
public class SqlNullableTimestampCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableTimestamp(None<DateTime>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<DateTime> => SqlNullableTimestamp(x)
            case x: Option<String> => SqlNullableVarchar(x)
            case x: Option<ToString> => match (x) {
                case Some(x) => SqlNullableVarchar(x.toString())
                case _ => SqlNullableTimestamp(None<DateTime>)
            }
            case x: DateTime => SqlNullableTimestamp(x)
            case x: ToString => SqlNullableVarchar(x.toString())
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableTimestamp(None<DateTime>)
    }
}
public class SqlNullableIntervalCreator <: SqlDataCreator {
    public func create(): SqlDbType {
        SqlNullableInterval(None<Duration>)
    }
    public func create(value: Any): SqlDbType {
        match (value) {
            case x: Option<Duration> => SqlNullableInterval(x)
            case x: Duration => SqlNullableInterval(x)
            case _ => throw IllegalArgumentException()
        }
    }
    public func create(column: ColumnInfo): SqlDbType {
        SqlNullableInterval(None<Duration>)
    }
}
