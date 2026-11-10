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
package fountain::f_svg

import fountain::f_base.BaseException

/** `SvgException` 的失败类别。 */
public enum SvgErrorKind <: Equatable<SvgErrorKind> & ToString {
    /** XML 词法 / 结构错误，或根元素不合法。 */
    | Syntax
    /** 属性值语法不合法（颜色、长度、路径……）。 */
    | InvalidValue
    /** 严格模式下遇到不支持的标签。 */
    | Unsupported
    /** 不安全内容（脚本、事件属性、外部引用）。 */
    | Security
    /** 元素数 / 深度 / 实体上限。 */
    | Limit

    public operator func ==(that: SvgErrorKind): Bool {
        match ((this, that)) {
            case (Syntax, Syntax) => true
            case (InvalidValue, InvalidValue) => true
            case (Unsupported, Unsupported) => true
            case (Security, Security) => true
            case (Limit, Limit) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Syntax => "Syntax"
            case InvalidValue => "InvalidValue"
            case Unsupported => "Unsupported"
            case Security => "Security"
            case Limit => "Limit"
        }
    }
}

/**
 * f_svg 的统一异常。
 *
 * 位置一律 1-based；`line == 0 && column == 0` 表示位置未知。
 * `elementPath` 形如 `/svg[1]/g[2]/rect[1]`，由构建器维护。
 */
public class SvgException <: BaseException {
    public let kind: SvgErrorKind
    public let line: Int64
    public let column: Int64
    public let elementPath: ?String

    public init(message: String, kind!: SvgErrorKind = SvgErrorKind.InvalidValue) {
        super(message)
        this.kind = kind
        this.line = 0
        this.column = 0
        this.elementPath = None
    }

    public init(
        message: String,
        line: Int64,
        column: Int64,
        kind!: SvgErrorKind = SvgErrorKind.InvalidValue,
        elementPath!: ?String = None
    ) {
        super(withPosition(message, line, column))
        this.kind = kind
        this.line = line
        this.column = column
        this.elementPath = elementPath
    }

    private static func withPosition(message: String, line: Int64, column: Int64): String {
        if (line == 0 && column == 0) {
            message
        } else {
            '${message}（第 ${line} 行第 ${column} 列）'
        }
    }
}

/** 便携的 InvalidValue 构造。 */
internal func invalidValue(message: String): SvgException {
    SvgException(message, kind: SvgErrorKind.InvalidValue)
}

/** 便携的 Syntax 构造。 */
internal func syntaxError(message: String): SvgException {
    SvgException(message, kind: SvgErrorKind.Syntax)
}
