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
package fountain::f_data.base

public type DataConversionFlag = UInt64

public const IGNORE_FIELD_NOT_FOUND: DataConversionFlag = 1 << 0
public const IGNORE_FIELD_TYPE_NOT_MATCH: DataConversionFlag = 1 << 1
public const IGNORE_FIELD_NOT_CONVERTABLE: DataConversionFlag = 1 << 2
public const IGNORE_NONE: DataConversionFlag = 1 << 3
public const DEEP: DataConversionFlag = 1 << 4
/**
 * 溢出策略的优先级：WRAPPING > THROWING > SATURATING。
 * 三者都优先于 SILENCE 里的 IGNORE_FIELD_NOT_CONVERTABLE —— 显式传入策略时不会被 IGNORE 吞掉
 * （判定见 ignoreNotConvertable）。
 */
public const WRAPPING_ON_INT_OVERFLOW: DataConversionFlag = 1 << 5
public const THROWING_ON_INT_OVERFLOW: DataConversionFlag = 1 << 6
public const SATURATING_ON_INT_OVERFLOW: DataConversionFlag = 1 << 7

/**
 * 忽略验证
 */
public const IGNORE_VALIDATION: DataConversionFlag = 1 << 8
/**
 * 忽略未匹配的验证
 */
public const IGNORE_NOT_MATCHED_VALIDATION: DataConversionFlag = 1 << 9
public const SILENCE: DataConversionFlag = IGNORE_FIELD_NOT_FOUND | IGNORE_FIELD_TYPE_NOT_MATCH |
    IGNORE_FIELD_NOT_CONVERTABLE | IGNORE_NONE
/**
 * 默认 flag = SILENCE：越界或不可转换一律落 None，**不回绕、不饱和、不抛异常**。
 * 需要回绕（`300` → Int8 得 44）时显式传 WRAPPING_ON_INT_OVERFLOW，饱和/抛异常同理。
 * 历史坑：旧值写成 `WRAPPING_ON_INT_OVERFLOW | SILENCE`，但各数值类型的 IGNORE 分支排在
 * 策略分支之前，WRAPPING 实际从未生效；修正策略优先级（见 ignoreNotConvertable）后若继续夹带
 * 该位，会让默认行为从「None」变成「回绕」（例如 f_orm 的 JSON→PO 会写入回绕值），故剥离。
 */
public const DEFAULT_DATA_FLAG: DataConversionFlag = SILENCE

/**
 * IGNORE_FIELD_NOT_CONVERTABLE 是否应生效：仅当调用方没有显式传入溢出策略时。
 * 数值类型的 tryFromData 用它替代裸的 `(flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0` 判定，
 * 保证 `WRAPPING_ON_INT_OVERFLOW | SILENCE` 这类组合下策略不被 IGNORE 静默吞掉。
 */
internal func ignoreNotConvertable(flag: DataConversionFlag): Bool {
    (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 &&
        (flag & (WRAPPING_ON_INT_OVERFLOW | THROWING_ON_INT_OVERFLOW | SATURATING_ON_INT_OVERFLOW)) == 0
}
