/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

extend Int8 <: DataFields<Int8> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToInt8()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toInt8(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toInt8(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toInt8(strategy: saturating)
            case _: DataNone => None<Int8>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Int8>()}')
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToInt8()
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt8(strategy: wrapping)
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt8(strategy: throwing)
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt8(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Int8>()}')
            case _ => None<Int8>
        }
    }
}

extend UInt8 <: DataFields<UInt8> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToUInt8()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUInt8(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUInt8(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUInt8(strategy: saturating)
            case _: DataNone => None<UInt8>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UInt8>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToUInt8()
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt8(strategy: wrapping)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt8(strategy: throwing)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt8(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UInt8>()}')
            case _ => None<UInt8>
        }
    }
}

extend Int16 <: DataFields<Int16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToInt16()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toInt16(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toInt16(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toInt16(strategy: saturating)
            case _: DataNone => None<Int16>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Int16>()}')
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToInt16()
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt16(strategy: wrapping)
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt16(strategy: throwing)
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt16(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Int16>()}')
            case _ => None<Int16>
        }
    }
}

extend UInt16 <: DataFields<UInt16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToUInt16()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUInt16(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUInt16(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUInt16(strategy: saturating)
            case _: DataNone => None<UInt16>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UInt16>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToUInt16()
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt16(strategy: wrapping)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt16(strategy: throwing)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt16(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UInt16>()}')
            case _ => None<UInt16>
        }
    }
}

extend Int32 <: DataFields<Int32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToInt32()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toInt32(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toInt32(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toInt32(strategy: saturating)
            case _: DataNone => None<Int32>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Int32>()}')
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToInt32()
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt32(strategy: wrapping)
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt32(strategy: throwing)
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt32(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Int32>()}')
            case _ => None<Int32>
        }
    }
}

extend UInt32 <: DataFields<UInt32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToUInt32()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUInt32(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUInt32(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUInt32(strategy: saturating)
            case _: DataNone => None<UInt32>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UInt32>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToUInt32()
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt32(strategy: wrapping)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt32(strategy: throwing)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt32(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UInt32>()}')
            case _ => None<UInt32>
        }
    }
}

extend Int64 <: DataFields<Int64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToInt64()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toInt64(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toInt64(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toInt64(strategy: saturating)
            case _: DataNone => None<Int64>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Int64>()}')
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToInt64()
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt64(strategy: wrapping)
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt64(strategy: throwing)
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toInt64(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Int64>()}')
            case _ => None<Int64>
        }
    }
}

extend UInt64 <: DataFields<UInt64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToUInt64()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUInt64(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUInt64(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUInt64(strategy: saturating)
            case _: DataNone => None<UInt64>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UInt64>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToUInt64()
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt64(strategy: wrapping)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt64(strategy: throwing)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUInt64(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UInt64>()}')
            case _ => None<UInt64>
        }
    }
}

extend IntNative <: DataFields<IntNative> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToIntNative()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toIntNative(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toIntNative(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toIntNative(strategy: saturating)
            case _: DataNone => None<IntNative>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<IntNative>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToIntNative()
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toIntNative(strategy: wrapping)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toIntNative(strategy: throwing)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toIntNative(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<IntNative>()}')
            case _ => None<IntNative>
        }
    }
}

extend UIntNative <: DataFields<UIntNative> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => x.tryToUIntNative()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUIntNative(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUIntNative(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUIntNative(strategy: saturating)
            case _: DataNone => None<UIntNative>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UIntNative>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataReal(x.toString().trimAscii()).tryToUIntNative()
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUIntNative(strategy: wrapping)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUIntNative(strategy: throwing)
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString().trimAscii()).toUIntNative(strategy: saturating)
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UIntNative>()}')
            case _ => None<UIntNative>
        }
    }
}

extend Float64 <: DataFields<Float64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal => x.tryToFloat64()
            case _: DataNone => None<Float64>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Float64>()}')
            case x: DataString where #'^(-?((\d+(\.\d+)?|\.\d+)(-?[eE]\d+)?|0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]+)?(-?[pP]\d+)?))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataReal(x.toString().trimAscii()).tryToFloat64()
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Float64>()}')
            case _ => None<Float64>
        }
    }
}

extend Float32 <: DataFields<Float32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal => x.tryToFloat32()
            case _: DataNone => None<Float32>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Float32>()}')
            case x: DataString where #'^(-?((\d+(\.\d+)?|\.\d+)(-?[eE]\d+)?|0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]+)?(-?[pP]\d+)?))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataReal(x.toString().trimAscii()).tryToFloat32()
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Float32>()}')
            case _ => None<Float32>
        }
    }
}

extend Float16 <: DataFields<Float16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal => x.tryToFloat16()
            case _: DataNone => None<Float16>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Float16>()}')
            case x: DataString where #'^(-?((\d+(\.\d+)?|\.\d+)(-?[eE]\d+)?|0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]+)?(-?[pP]\d+)?))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataReal(x.toString().trimAscii()).tryToFloat16()
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Float16>()}')
            case _ => None<Float16>
        }
    }
}

extend BigInt <: DataFields<BigInt> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal => x.tryToBigInt()
            case _: DataNone => None<BigInt>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<BigInt>()}')
            case x: DataString where #'^(-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataReal(x.toString().trimAscii()).tryToBigInt()
            case _ => None<BigInt>
        }
    }
}

extend Decimal <: DataFields<Decimal> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        match (data) {
            case x: DataReal => x.tryToDecimal()
            case _: DataNone => None<Decimal>
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Decimal>()}')
            case x: DataString where #'^(-?((\d+(\.\d+)?|\.\d+)(-?[eE]\d+)?|0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]+)?(-?[pP]\d+)?))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataReal(x.toString().trimAscii()).tryToDecimal()
            case _ => None<Decimal>
        }
    }
}
