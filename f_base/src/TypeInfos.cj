/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_base

import std.collection.concurrent.ConcurrentHashMap
import std.sync.ReentrantMutex
public import std.math.numeric.{BigInt, Decimal}
public import std.time.DateTime

public class TypeInfos {
    private static let INFOS = ConcurrentHashMap<String, TypeInfo>()
    private static let MUTEX = ReentrantMutex()

    public static let INT8_TYPE = TypeInfo.of<Int8>()
    public static let UINT8_TYPE = TypeInfo.of<UInt8>()
    public static let INT16_TYPE = TypeInfo.of<Int16>()
    public static let UINT16_TYPE = TypeInfo.of<UInt16>()
    public static let INT32_TYPE = TypeInfo.of<Int32>()
    public static let UINT32_TYPE = TypeInfo.of<UInt32>()
    public static let INT64_TYPE = TypeInfo.of<Int64>()
    public static let UINT64_TYPE = TypeInfo.of<UInt64>()
    public static let INTNATIVE_TYPE = TypeInfo.of<IntNative>()
    public static let UINTNATIVE_TYPE = TypeInfo.of<UIntNative>()
    public static let FLOAT16_TYPE = TypeInfo.of<Float16>()
    public static let FLOAT32_TYPE = TypeInfo.of<Float32>()
    public static let FLOAT64_TYPE = TypeInfo.of<Float64>()
    public static let STRING_TYPE = TypeInfo.of<String>()
    public static let RUNE_TYPE = TypeInfo.of<Rune>()
    public static let BOOL_TYPE = TypeInfo.of<Bool>()
    public static let UNIT_TYPE = TypeInfo.of<Unit>()
    public static let BIGINT_TYPE = TypeInfo.of<BigInt>()
    public static let DECIMAL_TYPE = TypeInfo.of<Decimal>()
    public static let DURATION_TYPE = TypeInfo.of<Duration>()
    public static let DATETIME_TYPE = TypeInfo.of<DateTime>()
    public static let BYTEARRAY_TYPE = TypeInfo.of<Array<Byte>>()
    public static let BYTE_TYPE = UINT8_TYPE
    public static let OBJECT_TYPE = TypeInfo.of<Object>()
    public static let ANY_TYPE = TypeInfo.of<Any>()

    public static func getTypeInfo(qualifiedName: String): TypeInfo {
        if (let Some(x) <- INFOS.get(qualifiedName)) {
            x
        } else {
            synchronized(MUTEX){
                if(let Some(x) <- INFOS.get(qualifiedName)) {
                    x
                } else {
                    let info = TypeInfos.getTypeInfo(qualifiedName)
                    INFOS[qualifiedName] = info
                    info
                }
            }
        }
    }
    public static func getGenericTypes(qualifiedName: String): Array<TypeInfo> {
        let idx = qualifiedName.indexOf("<")
        if (let Some(i) <- idx) {
            let generics = qualifiedName[i .. qualifiedName.size - 1]
            let types = parseParameterTypes(generics)
            types
        } else {
            []
        }
    }
}
