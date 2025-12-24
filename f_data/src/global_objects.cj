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
public const IGNORE_NOT_MATCHED_VALIDATION: DataConversionFlag = 0x100u64
public const SILENCE: DataConversionFlag = IGNORE_FIELD_NOT_FOUND | IGNORE_FIELD_TYPE_NOT_MATCH |
    IGNORE_FIELD_NOT_CONVERTABLE | IGNORE_NONE
public const DEFAULT_DATA_FLAG: DataConversionFlag = WRAPPING_ON_INT_OVERFLOW | SILENCE
