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
package fountain::f_xml

import fountain::f_base.BaseException

/**
 * 实体膨胀上限的分类。
 *
 * 调用方据此决定是否可以「降级重试」：
 * - 软阈值 `PerEntity` / `Total`：`Strict` 下抛出后，改用 `Spill` 重试可以成功；
 * - 硬限制 `Depth` / `Declarations` / `HardLimit`：重试必然失败；
 * - `AttributeValue`：属性值不支持溢出，重试同样失败。
 */
public enum EntityLimitKind <: Equatable<EntityLimitKind> & ToString {
    | PerEntity
    | Total
    | Depth
    | Declarations
    | HardLimit
    | AttributeValue

    public operator func ==(that: EntityLimitKind): Bool {
        match ((this, that)) {
            case (PerEntity, PerEntity) => true
            case (Total, Total) => true
            case (Depth, Depth) => true
            case (Declarations, Declarations) => true
            case (HardLimit, HardLimit) => true
            case (AttributeValue, AttributeValue) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case PerEntity => "PerEntity"
            case Total => "Total"
            case Depth => "Depth"
            case Declarations => "Declarations"
            case HardLimit => "HardLimit"
            case AttributeValue => "AttributeValue"
        }
    }
}

/**
 * f_xml 的统一异常。
 *
 * 位置一律 1-based；`line == 0 && column == 0` 明确表示「位置未知」，
 * 不是「第 0 行」——例如 `skipElement()` 前置条件错、`spillDir` 四级全失败这类
 * 与源码位置无关的错误。
 */
public class XmlException <: BaseException {
    /** 出错位置的行号（1-based）；0 表示位置未知。 */
    public let line: Int64

    /** 出错位置的列号（1-based）；0 表示位置未知。 */
    public let column: Int64

    /** 实体上限分类；非实体类错误为 `None`。 */
    public let entityLimitKind: ?EntityLimitKind

    /** 位置未知的便捷构造。 */
    public init(message: String) {
        super(message)
        this.line = 0
        this.column = 0
        this.entityLimitKind = None
    }

    public init(message: String, line: Int64, column: Int64) {
        super(withPosition(message, line, column))
        this.line = line
        this.column = column
        this.entityLimitKind = None
    }

    public init(message: String, line: Int64, column: Int64, kind!: EntityLimitKind) {
        super(withPosition(message, line, column))
        this.line = line
        this.column = column
        this.entityLimitKind = kind
    }

    /** 位置固定拼进消息：调用方读 `message` 就能拿到行列号，不必再拼 `toString()`。 */
    private static func withPosition(message: String, line: Int64, column: Int64): String {
        if (line == 0 && column == 0) {
            message
        } else {
            '${message}（第 ${line} 行第 ${column} 列）'
        }
    }
}
