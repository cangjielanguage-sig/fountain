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

import std.fs.Path

/** 整文档读取选项。 */
public class ExcelReadOptions {
    /** 按 `numFmtId` / 格式串自动识别日期（默认开）。 */
    public var autoDetectDate: Bool = true
    /** `None` = 跟随 `workbookPr.date1904`；`Some` = 以调用方为准。 */
    public var date1904: ?Bool = None
    public var loadStyles: Bool = true
    public var loadSharedStrings: Bool = true
    /** 0 = 不限；超出截断并记 `MaxRowsTruncated`。 */
    public var maxRows: Int64 = 0
    public var maxCols: Int64 = 0
    /** 读整文档时跳过的 sheet。 */
    public var skipSheets: Array<String> = []

    public init() {}
}

/** 流式读取选项（见设计 2.7.2）。 */
public class ExcelStreamReadOptions {
    /** 不可定位输入是否落临时文件（默认 true）；false 退化为全量缓冲并记 `SpoolDisabled`。 */
    public var spool: Bool = true
    public var spoolDir: ?Path = None
    public var loadRowHeight: Bool = true
    public var autoDetectDate: Bool = true
    public var date1904: ?Bool = None
    public var loadStyles: Bool = true
    public var loadSharedStrings: Bool = true
    public var maxRows: Int64 = 0
    public var maxCols: Int64 = 0

    public init() {}
}

/** 写出选项。 */
public class ExcelWriteOptions {
    /** `None` = 跟随文档；流式写取 1900 基准。 */
    public var date1904: ?Bool = None

    public init() {}
}

/** 单张 sheet 的写出选项（M1 只有 `dimension`）。 */
public class SheetWriteOptions {
    /** use range；`None` = 省略 `<dimension>`。 */
    public var dimension: ?String = None

    public init() {}
}
