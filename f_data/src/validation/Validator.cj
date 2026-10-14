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
package fountain::f_data.validation

import std.convert.*
import fountain::f_base.*
import fountain::f_regex.*
import fountain::f_data.base.*

/**
 * 把调用方传入的分隔符按字面量拼进正则：转义正则元字符，
 * 避免 `separator: "."` 被当成「任意字符」、`|`/`(` 等改变校验语义。
 */
private func escapeRegexLiteral(literal: String): String {
    let meta = #'\^$.|?*+()[]{}'#
    let builder = StringGenerator()
    for (c in literal.runes()) {
        if (meta.contains(c.toString())) {
            builder.append(r'\\')
        }
        builder.append(c)
    }
    builder.toString()
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsNotEmpty <: Validator {
    public const init(messageIfNotMatch!: String = '') {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        (value ?? '').size > 0
    }
    public prop description: String {
        get(){
            '必须是非空字符串'
        }
    }
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsNotBlank <: Validator {
    public const init(messageIfNotMatch!: String = '') {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        (value ?? '').trimAsciiBlanks().size > 0
    }
    public prop description: String {
        get(){
            '必须是非空字符串，且不能全部都是空白符'
        }
    }
}
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class StringSize <: Validator {
    public const StringSize(messageIfNotMatch!: String = '', private let min!: Int64 = 0, private let max!: Int64 = 0x7FFF_FFFF_FFFF_FFFF) {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        let v = value ?? ''
        // 修复历史缺陷：min 此前从未参与判定（`v.size >= 0` 恒真），@StringSize[min: N] 实际不生效
        v.size >= min && v.size <= max
    }
    public prop description: String {
        get(){
            '字符串长度必须在${min}到${max}之间'
        }
    }
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsInteger <: Validator {
    public const init(messageIfNotMatch!: String = '') {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        let v = value ?? ''
        Regex.INTEGER.matches(v)
    }
    public prop description: String {
        get(){
            '必须为整数'
        }
    }
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsDecimal <: Validator {
    public const init(messageIfNotMatch!: String = '') {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        let v = value ?? ''
        Regex.DECIMAL.matches(v)
    }
    public prop description: String {
        get(){
            '必须为小数'
        }
    }
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsEmail <: Validator {
    public const init(messageIfNotMatch!: String = '') {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        let v = value ?? ''
        Regex.EMAIL.matches(v)
    }
    public prop description: String {
        get(){
            '必须为电子邮箱'
        }
    }
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsChineseCellPhone <: Validator {
    public const IsChineseCellPhone(
        messageIfNotMatch!: String = '',
        private let withCountryCode!: Bool = false,
        private let countryCodeSeparator!: String = ')'
    ) {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        var rege = ''
        if (withCountryCode) {
            rege = match (countryCodeSeparator) {
                // 字面量 '(' / ')' 此前会被当成捕获组：`(86)1\d{10}` 匹配 "8613..." 却匹配不了 "(86)13..."
                case ')' => '\\(86\\)'
                case x => '86${escapeRegexLiteral(x)}'
            }
        }
        return '^${rege}1\\d{10}'.regex(solid: true).matches(value ?? '')
    }
    public prop description: String {
        get(){
            '必须为中国手机号码'
        }
    }
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsIntegerRange <: Validator {
    public const IsIntegerRange(
        messageIfNotMatch!: String = '',
        private let min!: Int64 = 0,
        private let max!: Int64 = 0x7FFF_FFFF_FFFF_FFFF,
        private let minInclusive!: Bool = true,
        private let maxInclusive!: Bool = false
    ) {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public const init(range: Range<Int64>){
        this(min: range.start, max: range.end, minInclusive: range.hasStart, maxInclusive: range.isClosed || range.hasEnd)
    }
    public func validate(value: ?String): Bool {
        match (Int64.tryParse(value ?? '')) {
            case Some(x) => if (minInclusive) {
                x >= min
            } else {
                x > min
            } && if (maxInclusive) {
                x <= max
            } else {
                x < max
            }
            case _ => false
        }
    }
    public prop description: String {
        get(){
            '必须为整数，且必须满足${min} ${if(minInclusive){'<='}else{'<'}} value ${if(maxInclusive){'<='}else{'<'}} ${max}'
        }
    }
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsBool <: Validator {
    public const init(messageIfNotMatch!: String = '') {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        let val = (value ?? '').toAsciiLower()
        return val == 'true' || val == 'false'
    }
    public prop description: String {
        get(){
            '必须为布尔值'
        }
    }
}
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsDateTime <: Validator {
    public const IsDateTime(
        messageIfNotMatch!: String = '',
        private let format!: String = "yyyy-MM-dd HH:mm:ss"
    ) {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        try {
            DateTime.parse(value ?? '', format)
            true
        } catch (_){
            false
        }
    }
    public prop description: String {
        get(){
            '必须为日期时间'
        }
    }
}
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsDuration <: Validator {
    public const init(messageIfNotMatch!: String = '') {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        // 与 Duration 解析器保持一致：此前用 f_regex 的 DURATION 正则会放行 `1s1s`、`9h10d`（校验过、解析炸）
        match (Duration.tryParse(value ?? '')) {
            case Some(_) => true
            case _ => false
        }
    }
    public prop description: String {
        get(){
            '必须为时间间隔'
        }
    }
}
@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class IsIntegers <: Validator {
    public const IsIntegers(messageIfNotMatch!: String = '', private let separator!: String = ",") {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        '^\\d+(${escapeRegexLiteral(separator)}\\d+)*$'.regex(solid: true).matches(value ?? '')
    }
    public prop description: String {
        get(){
            '必须为${separator}分隔的整数列表'
        }
    }
}

@Annotation[target: [MemberVariable, MemberProperty, Parameter]]
public class DoesMatchRegex <: Validator {
    public const DoesMatchRegex(messageIfNotMatch!: String = '', private let regex!: String) {
        super(messageIfNotMatch: messageIfNotMatch)
    }
    public func validate(value: ?String): Bool {
        this.regex.regex(solid: true).matches(value ?? '')
    }
    public prop description: String {
        get(){
            '必须匹配正则表达式 ${regex}'
        }
    }
}