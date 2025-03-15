/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm

import std.io.InputStream
import std.database.sql.Statement
import std.time.DateTime
import f_base.*
import f_exception.UnreachableException
import f_regex.*

public class SqlArg <: ToString & Hashable & Equatable<SqlArg> {
    private let _hash_: Int64
    SqlArg(
        private let index: Int64,
        let argType: DataType,
        let value: Any
    ) {
        _hash_ = HashBuilder().append(index).append(argType).append(
            match (value) {
                case x: Hashable => x
                case _ => 0
            }
        ).finish()
    }
    init(index: Int64, value: Any) {
        this(index, confirmDataType(value), value)
    }
    public func hashCode(): Int64 {
        _hash_
    }
    public operator func ==(other: SqlArg): Bool {
        _hash_ == other._hash_ && index == other.index && argType == other.argType && this.toString() == other.toString(
        )
    }
    private static func confirmDataType(value: Any): DataType {
        match (value) {
            case _: ?Bool => nullable_bool
            case _: ?Int8 => nullable_int8
            case _: ?UInt8 => nullable_uint8
            case _: ?Int16 => nullable_int16
            case _: ?UInt16 => nullable_uint16
            case _: ?Int32 => nullable_int32
            case _: ?UInt32 => nullable_uint32
            case _: ?Int64 => nullable_int64
            case _: ?UInt64 => nullable_uint64
            case _: ?Float16 => nullable_float16
            case _: ?Float32 => nullable_float32
            case _: ?Float64 => nullable_float64
            case _: ?String => nullable_string
            case _: ?DateTime => nullable_timestamp
            case _: ?Rune => nullable_char
            case _: ?Array<Byte> => nullable_bytes
            case _: ?InputStream => nullable_stream
            case x: ?Any => match (x) {
                case Some(x) => confirmDataType(x)
                case _ => throw ORMException("unrecognized data type")
            }

            case _: Bool => bool
            case _: Int8 => int8
            case _: UInt8 => uint8
            case _: Int16 => int16
            case _: UInt16 => uint16
            case _: Int32 => int32
            case _: UInt32 => uint32
            case _: Int64 => int64
            case _: UInt64 => uint64
            case _: Float16 => float16
            case _: Float32 => float32
            case _: Float64 => float64
            case _: String => string
            case _: DateTime => timestamp
            case _: Rune => char
            case _: Array<Byte> => bytes
            case _: InputStream => stream
            case _ => throw ORMException("unrecognized data type")
        }
    }
    public static func create<T>(index: Int64, argType: DataType, value: ?T) {
        SqlArg(index, argType, value)
    }
    public func toString(): String {
        match (value) {
            case x: Option<Any> => match (x) {
                case Some(x) => match (x) {
                    case x: ToString => "(${index}, ${argType}, Some(${x}))"
                    case _ => "(${index}, ${argType}, _)"
                }
                case _ => "(${index}, ${argType}, None)"
            }
            case x: ToString => "(${index}, ${argType}, ${x})"
            case _ => "(${index}, ${argType}, _)"
        }
    }
}
