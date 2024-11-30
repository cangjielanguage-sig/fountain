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
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<Int8> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToInt8())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt8(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt8(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt8(strategy: saturating))
            case _: DataNone => DataOption<Int8>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Int8>()}')
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToInt8())
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt8(strategy: wrapping))
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt8(strategy: throwing))
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt8(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Int8>()}')
            case _ => DataOption<Int8>.NONE
        }
    }
}

extend UInt8 <: DataFields<UInt8> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<UInt8> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToUInt8())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt8(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt8(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt8(strategy: saturating))
            case _: DataNone => DataOption<UInt8>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UInt8>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToUInt8())
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt8(strategy: wrapping))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt8(strategy: throwing))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt8(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UInt8>()}')
            case _ => DataOption<UInt8>.NONE
        }
    }
}

extend Int16 <: DataFields<Int16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<Int16> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToInt16())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt16(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt16(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt16(strategy: saturating))
            case _: DataNone => DataOption<Int16>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Int16>()}')
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToInt16())
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt16(strategy: wrapping))
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt16(strategy: throwing))
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt16(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Int16>()}')
            case _ => DataOption<Int16>.NONE
        }
    }
}

extend UInt16 <: DataFields<UInt16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<UInt16> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToUInt16())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt16(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt16(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt16(strategy: saturating))
            case _: DataNone => DataOption<UInt16>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UInt16>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToUInt16())
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt16(strategy: wrapping))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt16(strategy: throwing))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt16(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UInt16>()}')
            case _ => DataOption<UInt16>.NONE
        }
    }
}

extend Int32 <: DataFields<Int32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<Int32> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToInt32())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt32(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt32(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt32(strategy: saturating))
            case _: DataNone => DataOption<Int32>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Int32>()}')
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToInt32())
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt32(strategy: wrapping))
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt32(strategy: throwing))
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt32(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Int32>()}')
            case _ => DataOption<Int32>.NONE
        }
    }
}

extend UInt32 <: DataFields<UInt32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<UInt32> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToUInt32())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt32(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt32(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt32(strategy: saturating))
            case _: DataNone => DataOption<UInt32>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UInt32>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToUInt32())
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt32(strategy: wrapping))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt32(strategy: throwing))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt32(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UInt32>()}')
            case _ => DataOption<UInt32>.NONE
        }
    }
}

extend Int64 <: DataFields<Int64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<Int64> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToInt64())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt64(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt64(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toInt64(strategy: saturating))
            case _: DataNone => DataOption<Int64>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Int64>()}')
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToInt64())
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt64(strategy: wrapping))
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt64(strategy: throwing))
            case x: DataString where #'^-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toInt64(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Int64>()}')
            case _ => DataOption<Int64>.NONE
        }
    }
}

extend UInt64 <: DataFields<UInt64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<UInt64> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToUInt64())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt64(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt64(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUInt64(strategy: saturating))
            case _: DataNone => DataOption<UInt64>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UInt64>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToUInt64())
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt64(strategy: wrapping))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt64(strategy: throwing))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUInt64(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UInt64>()}')
            case _ => DataOption<UInt64>.NONE
        }
    }
}

extend IntNative <: DataFields<IntNative> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<IntNative> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToIntNative())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toIntNative(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toIntNative(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toIntNative(strategy: saturating))
            case _: DataNone => DataOption<IntNative>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<IntNative>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToIntNative())
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toIntNative(strategy: wrapping))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toIntNative(strategy: throwing))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toIntNative(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<IntNative>()}')
            case _ => DataOption<IntNative>.NONE
        }
    }
}

extend UIntNative <: DataFields<UIntNative> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<UIntNative> {
        match (data) {
            case x: DataReal where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(x.tryToUIntNative())
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUIntNative(strategy: wrapping))
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUIntNative(strategy: throwing))
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(x.toUIntNative(strategy: saturating))
            case _: DataNone => DataOption<UIntNative>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<UIntNative>()}')
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => DataOption(DataReal(x.toString().trimAscii()).tryToUIntNative())
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUIntNative(strategy: wrapping))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUIntNative(strategy: throwing))
            case x: DataString where #'^(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+)$'#.regex(solid: true).matched(x.toString().trimAscii()) && (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataOption(DataReal(x.toString().trimAscii()).toUIntNative(strategy: saturating))
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<UIntNative>()}')
            case _ => DataOption<UIntNative>.NONE
        }
    }
}

extend Float64 <: DataFields<Float64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<Float64> {
        match (data) {
            case x: DataReal => DataOption(x.tryToFloat64())
            case _: DataNone => DataOption<Float64>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Float64>()}')
            case x: DataString where #'^(-?((\d+(\.\d+)?|\.\d+)(-?[eE]\d+)?|0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]+)?(-?[pP]\d+)?))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataOption(DataReal(x.toString().trimAscii()).tryToFloat64())
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Float64>()}')
            case _ => DataOption<Float64>.NONE
        }
    }
}

extend Float32 <: DataFields<Float32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<Float32> {
        match (data) {
            case x: DataReal => DataOption(x.tryToFloat32())
            case _: DataNone => DataOption<Float32>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Float32>()}')
            case x: DataString where #'^(-?((\d+(\.\d+)?|\.\d+)(-?[eE]\d+)?|0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]+)?(-?[pP]\d+)?))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataOption(DataReal(x.toString().trimAscii()).tryToFloat32())
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Float32>()}')
            case _ => DataOption<Float32>.NONE
        }
    }
}

extend Float16 <: DataFields<Float16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<Float16> {
        match (data) {
            case x: DataReal => DataOption(x.tryToFloat16())
            case _: DataNone => DataOption<Float16>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Float16>()}')
            case x: DataString where #'^(-?((\d+(\.\d+)?|\.\d+)(-?[eE]\d+)?|0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]+)?(-?[pP]\d+)?))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataOption(DataReal(x.toString().trimAscii()).tryToFloat16())
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted ${TypeInfos.get<Float16>()}')
            case _ => DataOption<Float16>.NONE
        }
    }
}

extend BigInt <: DataFields<BigInt> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<BigInt> {
        match (data) {
            case x: DataReal => DataOption(x.tryToBigInt())
            case _: DataNone => DataOption<BigInt>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<BigInt>()}')
            case x: DataString where #'^(-?(\d+|0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataOption(DataReal(x.toString().trimAscii()).tryToBigInt())
            case _ => DataOption<BigInt>.NONE
        }
    }
}

extend Decimal <: DataFields<Decimal> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): DataOption<Decimal> {
        match (data) {
            case x: DataReal => DataOption(x.tryToDecimal())
            case _: DataNone => DataOption<Decimal>.NONE
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('(${data}) does not match ${TypeInfos.get<Decimal>()}')
            case x: DataString where #'^(-?((\d+(\.\d+)?|\.\d+)(-?[eE]\d+)?|0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]+)?(-?[pP]\d+)?))$'#.regex(solid: true).matched(x.toString().trimAscii()) => DataOption(DataReal(x.toString().trimAscii()).tryToDecimal())
            case _ => DataOption<Decimal>.NONE
        }
    }
}
