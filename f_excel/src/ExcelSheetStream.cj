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
import std.env
import std.fs.{File, OpenMode, Path, removeIfExists}
import std.io.{InputStream, copy}
import fountain::f_xml.XmlPullParser
import fountain::f_zip.ZipReader

/** 捕获一行（流式通道的 sink）。 */
internal class RowCapture <: RowSink {
    var latest: ?RowData = None

    public func row(data: RowData): Unit {
        latest = Some(data)
    }

    public func merged(ranges: ArrayList<String>): Unit {}
}

/**
 * 逐行迭代器（拉模式）。
 *
 * `next()` 只在被调用时推进 XML 解析；返回 `None` 表示该 sheet 结束（此后 `mergedRanges()` 才有值）。
 */
public class RowReader <: Iterator<RowData> {
    private let parser: XmlPullParser
    private let handler: SheetRowHandler
    private let capture: RowCapture
    private let parsed: ParsedSheet
    private let stream: ExcelSheetStream
    private var finished = false
    private var closed = false

    internal init(
        parser: XmlPullParser,
        handler: SheetRowHandler,
        capture: RowCapture,
        parsed: ParsedSheet,
        stream: ExcelSheetStream
    ) {
        this.parser = parser
        this.handler = handler
        this.capture = capture
        this.parsed = parsed
        this.stream = stream
    }

    public func next(): Option<RowData> {
        if (closed) {
            throw ExcelException("流已关闭")
        }
        while (!finished) {
            match (parser.nextEvent()) {
                case Some(event) => handler.onEvent(event)
                case None => finish()
            }
            if (let Some(row) <- capture.latest) {
                capture.latest = None
                return Some(row)
            }
        }
        None<RowData>
    }

    /** 提前结束本 sheet（不关闭 [ExcelSheetStream]）；幂等。 */
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        if (!finished) {
            finish()
        }
        parser.close()
    }

    /** 流中为空并记 `MergedRangesUnavailable`；流结束后返回实际合并区域。 */
    public func mergedRanges(): ArrayList<String> {
        if (!finished) {
            stream.noteMergesUnavailable()
            return ArrayList<String>()
        }
        parsed.merges
    }

    private func finish(): Unit {
        if (finished) {
            return
        }
        finished = true
        stream.absorb(this.parsed)
    }
}

/**
 * 流式读取通道：逐行拉取，内存与行数无关。
 *
 * `open(path)` 走 `ZipReader(path)` 的 seek；`open(input)` 默认先落临时文件，`spool = false`
 * 时退化为全量缓冲并记 `SpoolDisabled`。
 */
public class ExcelSheetStream {
    private let zip: ZipReader
    private let info: PackageInfo
    private let options: ExcelStreamReadOptions
    private let styles: StylesLite
    private let sst: SharedStringTable
    private let warnings_ = ArrayList<ExcelWarning>()
    private let spoolFile: ?File
    private let spoolDir: ?Path
    private var lastSheet = ""
    private var lastMerges = ArrayList<String>()
    private var closed = false

    private init(
        zip: ZipReader,
        info: PackageInfo,
        options: ExcelStreamReadOptions,
        styles: StylesLite,
        sst: SharedStringTable,
        spoolFile: ?File,
        spoolDir: ?Path
    ) {
        this.zip = zip
        this.info = info
        this.options = options
        this.styles = styles
        this.sst = sst
        this.spoolFile = spoolFile
        this.spoolDir = spoolDir
        for (warning in info.warnings) {
            warnings_.add(warning)
        }
    }

    public static func open(
        path: Path,
        options!: ExcelStreamReadOptions = ExcelStreamReadOptions()
    ): ExcelSheetStream {
        let zip = try {
            ZipReader(path.toString())
        } catch (e: Exception) {
            throw ExcelException("不是有效的 xlsx 文件", e)
        }
        return build(zip, options, None, None)
    }

    public static func open(
        input: InputStream,
        options!: ExcelStreamReadOptions = ExcelStreamReadOptions()
    ): ExcelSheetStream {
        if (options.spool) {
            let baseDir = match (options.spoolDir) {
                case Some(dir) => dir
                case None => Path(env.getTempDirectory().toString())
            }
            let file = try {
                File.createTemp(baseDir)
            } catch (e: Exception) {
                throw ExcelException("无法创建 spool 临时文件：${baseDir}", e)
            }
            let tempPath = file.info.path
            try {
                copy(input, to: file)
                file.flush()
                file.close()
            } catch (e: Exception) {
                try {
                    file.close()
                } catch (_: Exception) {}
                try {
                    removeIfExists(tempPath)
                } catch (_: Exception) {}
                throw ExcelException("spool 写入失败：${tempPath}", e)
            }
            let zip = try {
                ZipReader(tempPath.toString())
            } catch (e: Exception) {
                throw ExcelException("不是有效的 xlsx 文件", e)
            }
            return build(zip, options, Some(file), Some(tempPath))
        }
        let zip = try {
            ZipReader(input)
        } catch (e: Exception) {
            throw ExcelException("不是有效的 xlsx 文件", e)
        }
        let stream = build(zip, options, None, None)
        stream.warnings_.add(
            ExcelWarning(ExcelWarningKind.SpoolDisabled, "spool=false，输入已退化为全量缓冲")
        )
        stream
    }

    private static func build(
        zip: ZipReader,
        options: ExcelStreamReadOptions,
        spoolFile: ?File,
        spoolDir: ?Path
    ): ExcelSheetStream {
        let info = PackageReader.read(zip)
        var styles = StylesLite.empty()
        if (options.loadStyles) {
            match (zip.read("xl/styles.xml")) {
                case Some(bytes) => styles = StylesLite.load(bytes)
                case None => ()
            }
        }
        var sst = SharedStringTable.empty()
        if (options.loadSharedStrings) {
            match (zip.read("xl/sharedStrings.xml")) {
                case Some(bytes) => sst = SharedStringTable.load(bytes)
                case None => ()
            }
        }
        ExcelSheetStream(zip, info, options, styles, sst, spoolFile, spoolDir)
    }

    public func sheetNames(): Array<String> {
        let out = ArrayList<String>()
        for (entry in info.sheets) {
            out.add(entry.name)
        }
        out.toArray()
    }

    public func rows(sheet: String): ?RowReader {
        if (closed) {
            throw ExcelException("流已关闭")
        }
        for (entry in info.sheets) {
            if (entry.name == sheet) {
                return openReader(entry)
            }
        }
        None<RowReader>
    }

    public func rowsAt(index: Int64): ?RowReader {
        if (closed) {
            throw ExcelException("流已关闭")
        }
        if (index < 0 || index >= Int64(info.sheets.size)) {
            return None<RowReader>
        }
        openReader(info.sheets[index])
    }

    private func openReader(entry: SheetEntry): ?RowReader {
        let stream = match (zip.open(entry.partName)) {
            case Some(value) => value
            case None => return None<RowReader>
        }
        let parser = XmlPullParser(stream)
        let parsed = ParsedSheet()
        let capture = RowCapture()
        let date1904 = match (options.date1904) {
            case Some(v) => v
            case None => info.date1904
        }
        let handler = SheetRowHandler(
            streamOptions(),
            sst,
            entry.name,
            parsed,
            styles,
            Some(date1904),
            capture
        )
        lastSheet = entry.name
        Some(RowReader(parser, handler, capture, parsed, this))
    }

    private func streamOptions(): ExcelReadOptions {
        let converted = ExcelReadOptions()
        converted.autoDetectDate = options.autoDetectDate
        converted.date1904 = Some(match (options.date1904) {
            case Some(v) => v
            case None => info.date1904
        })
        converted.loadStyles = options.loadStyles
        converted.loadSharedStrings = options.loadSharedStrings
        converted.maxRows = options.maxRows
        converted.maxCols = options.maxCols
        converted
    }

    internal func absorb(parsed: ParsedSheet): Unit {
        for (warning in parsed.warnings) {
            warnings_.add(warning)
        }
        lastMerges = parsed.merges
    }

    internal func noteMergesUnavailable(): Unit {
        warnings_.add(
            ExcelWarning(
                ExcelWarningKind.MergedRangesUnavailable,
                "流未结束，合并区域暂不可用",
                sheet: Some(lastSheet)
            )
        )
    }

    /** 流结束后的合并区域（按最后读完的 sheet）。 */
    public func lastMergedRanges(sheet: String): ArrayList<String> {
        if (sheet != lastSheet) {
            return ArrayList<String>()
        }
        lastMerges
    }

    public func warnings(): ArrayList<ExcelWarning> {
        warnings_
    }

    /** 释放条目流、ZIP 与 spool 临时文件；幂等。 */
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        try {
            zip.close()
        } catch (_: Exception) {}
        match (spoolDir) {
            case Some(path) =>
                try {
                    removeIfExists(path, recursive: true)
                } catch (_: Exception) {}
            case None => ()
        }
    }
}
