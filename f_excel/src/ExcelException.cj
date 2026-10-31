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

import fountain::f_base.BaseException

/**
 * f_excel 的统一异常。
 *
 * 读取侧尽量宽容（坏格降级 + warning），写入侧严格（产出非法文件宁可当场报错）——
 * 这条原则的落点就是本异常：只有"无法继续"的路径才用它。
 */
public open class ExcelException <: BaseException {
    public init(message: String) {
        super(message)
    }

    public init(message: String, caused: Exception) {
        super(message, caused)
    }
}

/** 告警分类：不打断解析，只记录发生了什么降级。 */
public enum ExcelWarningKind <: Equatable<ExcelWarningKind> & ToString {
    | MissingRowIndex
    | MissingCellRef
    | InvalidCellRef
    | RowOrderViolation
    | SharedStringIndexOutOfRange
    | NumberParseFailed
    | UnknownCellType
    | DateSerial60
    | UnsupportedTimeFormat
    | SharedFormulaUnsupported
    | ArrayFormulaUnsupported
    | IndexDegraded
    | AutoDetectDateDisabled
    | DateBaseMismatch
    | StylesMissing
    | SheetSkipped
    | SheetEntryMissing
    | MaxRowsTruncated
    | MaxColsTruncated
    | SpoolDisabled
    | ControlCharStripped
    | NumberFormatNotSupportedInM1
    | MergedRangesUnavailable

    public operator func ==(that: ExcelWarningKind): Bool {
        match ((this, that)) {
            case (MissingRowIndex, MissingRowIndex) => true
            case (MissingCellRef, MissingCellRef) => true
            case (InvalidCellRef, InvalidCellRef) => true
            case (RowOrderViolation, RowOrderViolation) => true
            case (SharedStringIndexOutOfRange, SharedStringIndexOutOfRange) => true
            case (NumberParseFailed, NumberParseFailed) => true
            case (UnknownCellType, UnknownCellType) => true
            case (DateSerial60, DateSerial60) => true
            case (UnsupportedTimeFormat, UnsupportedTimeFormat) => true
            case (SharedFormulaUnsupported, SharedFormulaUnsupported) => true
            case (ArrayFormulaUnsupported, ArrayFormulaUnsupported) => true
            case (IndexDegraded, IndexDegraded) => true
            case (AutoDetectDateDisabled, AutoDetectDateDisabled) => true
            case (DateBaseMismatch, DateBaseMismatch) => true
            case (StylesMissing, StylesMissing) => true
            case (SheetSkipped, SheetSkipped) => true
            case (SheetEntryMissing, SheetEntryMissing) => true
            case (MaxRowsTruncated, MaxRowsTruncated) => true
            case (MaxColsTruncated, MaxColsTruncated) => true
            case (SpoolDisabled, SpoolDisabled) => true
            case (ControlCharStripped, ControlCharStripped) => true
            case (NumberFormatNotSupportedInM1, NumberFormatNotSupportedInM1) => true
            case (MergedRangesUnavailable, MergedRangesUnavailable) => true
            case _ => false
        }
    }

    public operator func !=(that: ExcelWarningKind): Bool {
        !(this == that)
    }

    public func toString(): String {
        match (this) {
            case MissingRowIndex => "MissingRowIndex"
            case MissingCellRef => "MissingCellRef"
            case InvalidCellRef => "InvalidCellRef"
            case RowOrderViolation => "RowOrderViolation"
            case SharedStringIndexOutOfRange => "SharedStringIndexOutOfRange"
            case NumberParseFailed => "NumberParseFailed"
            case UnknownCellType => "UnknownCellType"
            case DateSerial60 => "DateSerial60"
            case UnsupportedTimeFormat => "UnsupportedTimeFormat"
            case SharedFormulaUnsupported => "SharedFormulaUnsupported"
            case ArrayFormulaUnsupported => "ArrayFormulaUnsupported"
            case IndexDegraded => "IndexDegraded"
            case AutoDetectDateDisabled => "AutoDetectDateDisabled"
            case DateBaseMismatch => "DateBaseMismatch"
            case StylesMissing => "StylesMissing"
            case SheetSkipped => "SheetSkipped"
            case SheetEntryMissing => "SheetEntryMissing"
            case MaxRowsTruncated => "MaxRowsTruncated"
            case MaxColsTruncated => "MaxColsTruncated"
            case SpoolDisabled => "SpoolDisabled"
            case ControlCharStripped => "ControlCharStripped"
            case NumberFormatNotSupportedInM1 => "NumberFormatNotSupportedInM1"
            case MergedRangesUnavailable => "MergedRangesUnavailable"
        }
    }
}

/** 一条告警。`sheet` / `ref` 只在能定位时给出。 */
public class ExcelWarning <: ToString {
    public let kind: ExcelWarningKind
    public let message: String
    public let sheet: ?String
    public let ref: ?CellRef

    public init(kind: ExcelWarningKind, message: String, sheet!: ?String = None, ref!: ?CellRef = None) {
        this.kind = kind
        this.message = message
        this.sheet = sheet
        this.ref = ref
    }

    public func toString(): String {
        let location = match (this.sheet) {
            case Some(name) => match (this.ref) {
                case Some(r) => " [${name}!${r}]"
                case None => " [${name}]"
            }
            case None => match (this.ref) {
                case Some(r) => " [${r}]"
                case None => ""
            }
        }
        "${this.kind}: ${this.message}${location}"
    }
}
