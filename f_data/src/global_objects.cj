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

public type DataConversionFlag = UInt64
public const IGNORE_FIELD_NOT_FOUND: DataConversionFlag = 0x1u64
public const IGNORE_FIELD_TYPE_NOT_MATCH: DataConversionFlag = 0x2u64
public const IGNORE_FIELD_NOT_CONVERTABLE: DataConversionFlag = 0x4u64
public const IGNORE_NONE: DataConversionFlag = 0x8u64
public const DEEP: DataConversionFlag = 0x10u64
/**
 * 优先级 WRAPPING > THROWING > SATURATING
 */
public const WRAPPING_ON_INT_OVERFLOW: DataConversionFlag = 0x20u64
public const THROWING_ON_INT_OVERFLOW: DataConversionFlag = 0x40u64
public const SATURATING_ON_INT_OVERFLOW: DataConversionFlag = 0x80u64
public const SILENCE: DataConversionFlag = IGNORE_FIELD_NOT_FOUND | IGNORE_FIELD_TYPE_NOT_MATCH | IGNORE_FIELD_NOT_CONVERTABLE | IGNORE_NONE
public const DEFAULT: DataConversionFlag = WRAPPING_ON_INT_OVERFLOW | SILENCE