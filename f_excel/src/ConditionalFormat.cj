/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_excel

import std.collection.ArrayList

/** 条件格式规则类型（ECMA-376 的 13 种 + 常见扩展）。 */
public enum CfRuleType <: Equatable<CfRuleType> & ToString {
    | CellIs
    | Expression
    | ContainsText
    | NotContainsText
    | BeginsWith
    | EndsWith
    | TimePeriod
    | Top10
    | DuplicateValues
    | UniqueValues
    | ColorScale
    | DataBar
    | IconSet
    | ContainsBlanks
    | NotContainsBlanks
    | ContainsErrors
    | NotContainsErrors
    | AboveAverage
    | Unknown(String)

    public func toString(): String {
        match (this) {
            case CellIs => "cellIs"
            case Expression => "expression"
            case ContainsText => "containsText"
            case NotContainsText => "notContainsText"
            case BeginsWith => "beginsWith"
            case EndsWith => "endsWith"
            case TimePeriod => "timePeriod"
            case Top10 => "top10"
            case DuplicateValues => "duplicateValues"
            case UniqueValues => "uniqueValues"
            case ColorScale => "colorScale"
            case DataBar => "dataBar"
            case IconSet => "iconSet"
            case ContainsBlanks => "containsBlanks"
            case NotContainsBlanks => "notContainsBlanks"
            case ContainsErrors => "containsErrors"
            case NotContainsErrors => "notContainsErrors"
            case AboveAverage => "aboveAverage"
            case Unknown(raw) => raw
        }
    }

    public static func parse(text: String): CfRuleType {
        match (text) {
            case "cellIs" => CellIs
            case "expression" => Expression
            case "containsText" => ContainsText
            case "notContainsText" => NotContainsText
            case "beginsWith" => BeginsWith
            case "endsWith" => EndsWith
            case "timePeriod" => TimePeriod
            case "top10" => Top10
            case "duplicateValues" => DuplicateValues
            case "uniqueValues" => UniqueValues
            case "colorScale" => ColorScale
            case "dataBar" => DataBar
            case "iconSet" => IconSet
            case "containsBlanks" => ContainsBlanks
            case "notContainsBlanks" => NotContainsBlanks
            case "containsErrors" => ContainsErrors
            case "notContainsErrors" => NotContainsErrors
            case "aboveAverage" => AboveAverage
            case other => Unknown(other)
        }
    }

    public operator func ==(that: CfRuleType): Bool {
        this.toString() == that.toString()
    }

    public operator func !=(that: CfRuleType): Bool {
        !(this == that)
    }
}

/** `cellIs` 的比较运算符。 */
public enum CfOperator <: Equatable<CfOperator> & ToString {
    | NoOperator
    | LessThan
    | LessThanOrEqual
    | Equal
    | NotEqual
    | GreaterThanOrEqual
    | GreaterThan
    | Between
    | NotBetween

    public func toString(): String {
        match (this) {
            case NoOperator => ""
            case LessThan => "lessThan"
            case LessThanOrEqual => "lessThanOrEqual"
            case Equal => "equal"
            case NotEqual => "notEqual"
            case GreaterThanOrEqual => "greaterThanOrEqual"
            case GreaterThan => "greaterThan"
            case Between => "between"
            case NotBetween => "notBetween"
        }
    }

    public static func parse(text: String): CfOperator {
        match (text) {
            case "lessThan" => LessThan
            case "lessThanOrEqual" => LessThanOrEqual
            case "equal" => Equal
            case "notEqual" => NotEqual
            case "greaterThanOrEqual" => GreaterThanOrEqual
            case "greaterThan" => GreaterThan
            case "between" => Between
            case "notBetween" => NotBetween
            case _ => NoOperator
        }
    }

    public operator func ==(that: CfOperator): Bool {
        this.toString() == that.toString()
    }

    public operator func !=(that: CfOperator): Bool {
        !(this == that)
    }
}

/** 颜色刻度 / 数据条 / 图标集的阈值。 */
public struct Cfvo <: ToString {
    /** `min` / `max` / `num` / `percent` / `percentile` / `formula`。 */
    public let kind: String
    public let value: String

    public init(kind: String, value!: String = "") {
        this.kind = kind
        this.value = value
    }

    public func toString(): String {
        "${this.kind}:${this.value}"
    }
}

public struct CfColorScale <: ToString {
    public let cfvos: ArrayList<Cfvo>
    public let colors: ArrayList<String>

    public init(cfvos: ArrayList<Cfvo>, colors: ArrayList<String>) {
        this.cfvos = cfvos
        this.colors = colors
    }

    public func toString(): String {
        "ColorScale(${this.cfvos.size})"
    }
}

public struct CfDataBar <: ToString {
    public let min: Cfvo
    public let max: Cfvo
    public let color: String
    public let showValue: Bool

    public init(min: Cfvo, max: Cfvo, color: String, showValue!: Bool = true) {
        this.min = min
        this.max = max
        this.color = color
        this.showValue = showValue
    }

    public func toString(): String {
        "DataBar(${this.color})"
    }
}

public struct CfIconSet <: ToString {
    public let name: String
    public let cfvos: ArrayList<Cfvo>
    public let showValue: Bool

    public init(name: String, cfvos: ArrayList<Cfvo>, showValue!: Bool = true) {
        this.name = name
        this.cfvos = cfvos
        this.showValue = showValue
    }

    public func toString(): String {
        "IconSet(${this.name})"
    }
}

/** 条件格式命中时的视觉结果。 */
public struct CfFormat <: ToString {
    public let fill: ?String
    public let fontColor: ?String
    public let bold: Bool
    public let dataBarLength: ?Float64
    public let icon: ?String

    public init(
        fill!: ?String = None,
        fontColor!: ?String = None,
        bold!: Bool = false,
        dataBarLength!: ?Float64 = None,
        icon!: ?String = None
    ) {
        this.fill = fill
        this.fontColor = fontColor
        this.bold = bold
        this.dataBarLength = dataBarLength
        this.icon = icon
    }

    public func toString(): String {
        "CfFormat(fill=${this.fill ?? "-"}, icon=${this.icon ?? "-"})"
    }
}

/** 一条条件格式规则。 */
public struct CfRule <: ToString {
    public let ruleType: CfRuleType
    public let priority: Int64
    public let stopIfTrue: Bool
    public let comparison: CfOperator
    public let formulas: ArrayList<String>
    public let text: ?String
    public let format: ?CfFormat
    public let colorScale: ?CfColorScale
    public let dataBar: ?CfDataBar
    public let iconSet: ?CfIconSet

    public init(
        ruleType: CfRuleType,
        priority!: Int64 = 1,
        stopIfTrue!: Bool = false,
        comparison!: CfOperator = CfOperator.NoOperator,
        formulas!: ArrayList<String> = ArrayList<String>(),
        text!: ?String = None,
        format!: ?CfFormat = None,
        colorScale!: ?CfColorScale = None,
        dataBar!: ?CfDataBar = None,
        iconSet!: ?CfIconSet = None
    ) {
        this.ruleType = ruleType
        this.priority = priority
        this.stopIfTrue = stopIfTrue
        this.comparison = comparison
        this.formulas = formulas
        this.text = text
        this.format = format
        this.colorScale = colorScale
        this.dataBar = dataBar
        this.iconSet = iconSet
    }

    public func toString(): String {
        "CfRule(${this.ruleType}, p=${this.priority})"
    }
}

/** 一组作用于 `sqref` 的规则。 */
public struct ConditionalFormat <: ToString {
    public let range: String
    public let rules: ArrayList<CfRule>

    public init(range: String, rules: ArrayList<CfRule>) {
        this.range = range
        this.rules = rules
    }

    public func toString(): String {
        "ConditionalFormat(${this.range}, ${this.rules.size})"
    }
}

/** `matchedRules` 的命中项。 */
public struct CfMatch <: ToString {
    public let rule: CfRule
    public let format: CfFormat

    public init(rule: CfRule, format: CfFormat) {
        this.rule = rule
        this.format = format
    }

    public func toString(): String {
        "CfMatch(${this.rule.ruleType})"
    }
}

/** `sqref` 可能包含多段（空格分隔）；判断某坐标是否落在任一段内。 */
internal func sqrefContains(sqref: String, row: Int64, col: Int64): Bool {
    for (part in sqref.split(" ")) {
        if (part.isEmpty()) {
            continue
        }
        match (CellRef.parseRange(part)) {
            case Some(range) =>
                let (from, to) = range
                if (row >= from.row && row <= to.row && col >= from.col && col <= to.col) {
                    return true
                }
            case None => ()
        }
    }
    false
}
