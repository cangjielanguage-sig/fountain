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
package fountain::f_chart

import fountain::f_base.BaseException

/** `ChartException` 的失败类别。 */
public enum ChartErrorKind <: Equatable<ChartErrorKind> & ToString {
    /** JSON 文本本身无法解析。 */
    | InvalidJson
    /** 必填字段缺失。 */
    | MissingField
    /** 字段类型或取值不合法。 */
    | InvalidValue
    /** `type` 不是当前实现支持的图类型。 */
    | UnsupportedChart

    public operator func ==(that: ChartErrorKind): Bool {
        match ((this, that)) {
            case (InvalidJson, InvalidJson) => true
            case (MissingField, MissingField) => true
            case (InvalidValue, InvalidValue) => true
            case (UnsupportedChart, UnsupportedChart) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case InvalidJson => "InvalidJson"
            case MissingField => "MissingField"
            case InvalidValue => "InvalidValue"
            case UnsupportedChart => "UnsupportedChart"
        }
    }
}

/**
 * f_chart 的统一异常。
 *
 * `path` 使用 `series[0].data[2]` 这类字段路径；非空时会被拼进 `message`，
 * 便于调用方直接从异常文本定位 JSON 中的问题。
 */
public class ChartException <: BaseException {
    public let kind: ChartErrorKind
    public let path: String

    public init(
        message: String,
        kind!: ChartErrorKind = ChartErrorKind.InvalidValue,
        path!: String = ""
    ) {
        super(if (path.isEmpty()) { message } else { "${path}: ${message}" })
        this.kind = kind
        this.path = path
    }
}

/** 供模块内部抛出的 InvalidValue。 */
internal func chartInvalidValue(path: String, message: String): ChartException {
    ChartException(message, kind: ChartErrorKind.InvalidValue, path: path)
}

/** 供模块内部抛出的 MissingField。 */
internal func chartMissingField(path: String): ChartException {
    ChartException("缺少必填字段", kind: ChartErrorKind.MissingField, path: path)
}
