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

import std.io.ByteBuffer
import f_orm.exception.*

//数据库列的数据类型
public enum DataType <: ToString & Hashable & Equatable<DataType> {
    | unknown //
    | bool
    | int8
    | uint8
    | int16
    | uint16
    | int32
    | uint32
    | int64
    | uint64
    | float16
    | float32
    | float64
    | decimal
    | string
    | time
    | date
    | datetime
    | timestamp
    | time_timezone
    | duration
    | char
    | bytes
    | var_bytes
    | blob
    | clob
    | longblob
    | longclob
    | text
    | longtext
    | stream
    | array
    | nullable_bool
    | nullable_int8
    | nullable_uint8
    | nullable_int16
    | nullable_uint16
    | nullable_int32
    | nullable_uint32
    | nullable_int64
    | nullable_uint64
    | nullable_float16
    | nullable_float32
    | nullable_float64
    | nullable_decimal
    | nullable_string
    | nullable_time
    | nullable_date
    | nullable_datetime
    | nullable_timestamp
    | nullable_time_timezone
    | nullable_duration
    | nullable_char
    | nullable_bytes
    | nullable_var_bytes
    | nullable_blob
    | nullable_clob
    | nullable_longblob
    | nullable_longclob
    | nullable_text
    | nullable_longtext
    | nullable_stream

    public static func valueOf(value: String): DataType {
        match (value) {
            case "unknown" => unknown
            case "bool" => bool
            case "int8" => int8
            case "uint8" => uint8
            case "int16" => int16
            case "uint16" => uint16
            case "int32" => int32
            case "uint32" => uint32
            case "int64" => int64
            case "uint64" => uint64
            case "float16" => float16
            case "float32" => float32
            case "float64" => float64
            case "decimal" => decimal
            case "string" => string
            case "time" => time
            case "date" => date
            case "datetime" => datetime
            case "timestamp" => timestamp
            case "time_timezone" => time_timezone
            case "duration" => duration
            case "char" => char
            case "bytes" => bytes
            case "var_bytes" => var_bytes
            case "blob" => blob
            case "longblob" => longblob
            case "clob" => clob
            case "longclob" => longclob
            case "text" => text
            case "longtext" => longtext
            case "stream" => stream
            case "array" => array
            case "nullable_bool" => nullable_bool
            case "nullable_int8" => nullable_int8
            case "nullable_uint8" => nullable_uint8
            case "nullable_int16" => nullable_int16
            case "nullable_uint16" => nullable_uint16
            case "nullable_int32" => nullable_int32
            case "nullable_uint32" => nullable_uint32
            case "nullable_int64" => nullable_int64
            case "nullable_uint64" => nullable_uint64
            case "nullable_float16" => nullable_float16
            case "nullable_float32" => nullable_float32
            case "nullable_float64" => nullable_float64
            case "nullable_decimal" => nullable_decimal
            case "nullable_string" => nullable_string
            case "nullable_time" => nullable_time
            case "nullable_date" => nullable_date
            case "nullable_datetime" => nullable_datetime
            case "nullable_timestamp" => nullable_timestamp
            case "nullable_time_timezone" => nullable_time_timezone
            case "nullable_duration" => nullable_duration
            case "nullable_char" => nullable_char
            case "nullable_bytes" => nullable_bytes
            case "nullable_var_bytes" => nullable_var_bytes
            case "nullable_blob" => nullable_blob
            case "nullable_clob" => nullable_clob
            case "nullable_longblob" => nullable_longblob
            case "nullable_longclob" => nullable_longclob
            case "nullable_text" => nullable_text
            case "nullable_longtext" => nullable_longtext
            case "nullable_stream" => nullable_stream
            case _ => throw ORMException("not supported for DataType ${value}")
        }
    }
    public func toString(): String {
        match (this) {
            case unknown => "unknown"
            case bool => "bool"
            case int8 => "int8"
            case uint8 => "uint8"
            case int16 => "int16"
            case uint16 => "uint16"
            case int32 => "int32"
            case uint32 => "uint32"
            case int64 => "int64"
            case uint64 => "uint64"
            case float16 => "float16"
            case float32 => "float32"
            case float64 => "float64"
            case decimal => "decimal"
            case string => "string"
            case time => "time"
            case date => "date"
            case datetime => "datetime"
            case timestamp => "timestamp"
            case time_timezone => "time_timezone"
            case duration => "duration"
            case char => "char"
            case bytes => "bytes"
            case var_bytes => "var_bytes"
            case blob => "blob"
            case longblob => "longblob"
            case clob => "clob"
            case longclob => "longclob"
            case text => "text"
            case longtext => "longtext"
            case stream => "stream"
            case array => "array"
            case nullable_bool => "nullable_bool"
            case nullable_int8 => "nullable_int8"
            case nullable_uint8 => "nullable_uint8"
            case nullable_int16 => "nullable_int16"
            case nullable_uint16 => "nullable_uint16"
            case nullable_int32 => "nullable_int32"
            case nullable_uint32 => "nullable_uint32"
            case nullable_int64 => "nullable_int64"
            case nullable_uint64 => "nullable_uint64"
            case nullable_float16 => "nullable_float16"
            case nullable_float32 => "nullable_float32"
            case nullable_float64 => "nullable_float64"
            case nullable_decimal => "nullable_decimal"
            case nullable_string => "nullable_string"
            case nullable_time => "nullable_time"
            case nullable_date => "nullable_date"
            case nullable_datetime => "nullable_datetime"
            case nullable_timestamp => "nullable_timestamp"
            case nullable_time_timezone => "nullable_time_timezone"
            case nullable_duration => "nullable_duration"
            case nullable_char => "nullable_char"
            case nullable_bytes => "nullable_bytes"
            case nullable_var_bytes => "nullable_var_bytes"
            case nullable_blob => "nullable_blob"
            case nullable_clob => "nullable_clob"
            case nullable_longblob => "nullable_longblob"
            case nullable_longclob => "nullable_longclob"
            case nullable_text => "nullable_text"
            case nullable_longtext => "nullable_longtext"
            case nullable_stream => "nullable_stream"
        }
    }
    public func hashCode(): Int64 {
        toString().hashCode()
    }
    public operator func ==(other: DataType): Bool {
        match ((this, other)) {
            case (unknown, unknown) => true
            case (bool, bool) => true
            case (int8, int8) => true
            case (uint8, uint8) => true
            case (int16, int16) => true
            case (uint16, uint16) => true
            case (int32, int32) => true
            case (uint32, uint32) => true
            case (int64, int64) => true
            case (uint64, uint64) => true
            case (float16, float16) => true
            case (float32, float32) => true
            case (float64, float64) => true
            case (string, string) => true
            case (time, time) => true
            case (date, date) => true
            case (datetime, datetime) => true
            case (timestamp, timestamp) => true
            case (time_timezone, time_timezone) => true
            case (duration, duration) => true
            case (char, char) => true
            case (bytes, bytes) => true
            case (var_bytes, var_bytes) => true
            case (blob, blob) => true
            case (longblob, longblob) => true
            case (clob, clob) => true
            case (longclob, longclob) => true
            case (text, text) => true
            case (longtext, longtext) => true
            case (stream, stream) => true
            case (array, array) => true
            case (nullable_bool, nullable_bool) => true
            case (nullable_int8, nullable_int8) => true
            case (nullable_uint8, nullable_uint8) => true
            case (nullable_int16, nullable_int16) => true
            case (nullable_uint16, nullable_uint16) => true
            case (nullable_int32, nullable_int32) => true
            case (nullable_uint32, nullable_uint32) => true
            case (nullable_int64, nullable_int64) => true
            case (nullable_uint64, nullable_uint64) => true
            case (nullable_float16, nullable_float16) => true
            case (nullable_float32, nullable_float32) => true
            case (nullable_float64, nullable_float64) => true
            case (nullable_string, nullable_string) => true
            case (nullable_time, nullable_time) => true
            case (nullable_date, nullable_date) => true
            case (nullable_datetime, nullable_datetime) => true
            case (nullable_timestamp, nullable_timestamp) => true
            case (nullable_time_timezone, nullable_time_timezone) => true
            case (nullable_duration, nullable_duration) => true
            case (nullable_char, nullable_char) => true
            case (nullable_bytes, nullable_bytes) => true
            case (nullable_var_bytes, nullable_var_bytes) => true
            case (nullable_blob, nullable_blob) => true
            case (nullable_clob, nullable_clob) => true
            case (nullable_longblob, nullable_longblob) => true
            case (nullable_longclob, nullable_longclob) => true
            case (nullable_text, nullable_text) => true
            case (nullable_longtext, nullable_longtext) => true
            case (nullable_stream, nullable_stream) => true
            case _ => false
        }
    }
}
