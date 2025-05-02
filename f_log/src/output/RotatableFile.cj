/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_log.output

import std.convert.Parsable
import std.collection.concurrent.ArrayBlockingQueue
import std.fs.{File, Directory, OpenMode, exists, rename, removeIfExists}
import std.io.{SeekPosition, OutputStream}
import std.math.MathExtension
import std.process.Process
import std.sync.{Timer, Mutex, AtomicReference, AtomicUInt64}
import std.time.DateTime
import stdx.compress.zlib.{WrapType, CompressLevel, CompressOutputStream}
import f_base.*
import f_log.exception.LogException
import f_time.{TimeUnit, ExtendDateTime, DateTimeFormatAssist}

public class RotatableFileParams{
    public var path = "${Process.current.workingDirectory}/logs/${Process.current.command}.log"
    public var fileSize = Int64.Max
    public var timeunit = TimeUnit.DAY
    public var compress = LogFileCompressFormat.NonCompression
}
protected class RotatableFile <: OutputStream & Resource{
    private let queue = ArrayBlockingQueue<()->Unit>(1)
    private var rotateTimer = ZERO_TIMER
    private let fileSize: Int64
    private let timeunit: TimeUnit
    private let compress: LogFileCompressFormat
    private let directory: String
    private var file: File

    public init(url: String, params: RotatableFileParams){
        let fileInfo = url["file://".size .. ]
        var idx = fileInfo.indexOf("?") ?? fileInfo.size
        let path = fileInfo[0 .. idx]
        (this.directory, this.file) = createDirIfNeed(path)
        if(idx < fileInfo.size){
            idx = fileInfo.indexOf("rotateSize=") ?? -1
            if (idx > 0) {
                let end = fileInfo.indexOf("&", idx) ?? fileInfo.size
                fileSize = Int64.parse(fileInfo[idx + "rotateSize=".size .. end])
            } else {
                fileSize = params.fileSize
            }
            idx = fileInfo.indexOf("rotateDuration=") ?? -1
            if (idx > 0) {
                let end = fileInfo.indexOf("&", idx) ?? fileInfo.size
                let duration = fileInfo[idx + "rotateDuration=".size .. end]
                timeunit = TimeUnit.tryParse(duration).getOrThrow{LogException("rotateDuration=${duration}")}
            } else {
                timeunit = params.timeunit
            }
            idx = fileInfo.indexOf("compressFormat=") ?? fileInfo.size
            if (idx > 0) {
                let end = fileInfo.indexOf("&", idx) ?? fileInfo.size
                let format = fileInfo[idx + "compressFormat=".size .. end]
                compress = compressFormat(format)
            } else {
                compress = params.compress
            }
        }else{
            fileSize = params.fileSize
            timeunit = params.timeunit
            compress = params.compress
        }
        rotateTimer = createRotateTimer()
    }
    public init(params: RotatableFileParams){
        this.timeunit = params.timeunit
        this.fileSize = params.fileSize
        this.compress = params.compress
        (this.directory, this.file) = createDirIfNeed(params.path)
        rotateTimer = createRotateTimer()
    }
    public func isClosed(): Bool {
        file.isClosed()
    }
    public func close(): Unit {
        file.close()
    }
    protected prop path: String {
        get(){
            this.file.info.path.toString()
        }
    }
    private func createRotateTimer() {
        spawn{
            while(let fn <- queue.dequeue()){
                fn()
            }
        }
        let timer = Timer.after(timeunit.since()) {
            rotateFileIfNeed()
            this.timeunit.since()
        }
        Process.current.atExit{timer.cancel()}
        timer
    }
    private static func createDirIfNeed(path: String){
        let directory = path[0 .. (path.lastIndexOf("/") ?? path.size)]
        if (!exists(directory)) {
            Directory.create(directory, recursive: true)
        }
        (directory, File(path, Append))
    }
    public static func compressFormat(format: String): LogFileCompressFormat {
        match (format) {
            case "None" => LogFileCompressFormat.NonCompression
            case "Deflate(BestSpeed)" | "DeflateFormat(BestSpeed)" => LogFileCompressFormat.Deflate(
                BestSpeed)
            case "Deflate(DefaultCompression)" | "Deflate(Default)" | "Deflate" | "DeflateFormat" | "DeflateFormat(DefaultCompression)" | "DeflateFormat(Default)" => LogFileCompressFormat.
                Deflate(DefaultCompression)
            case "Deflate(BestCompression)" | "DeflateFormat(BestCompression)" => LogFileCompressFormat.
                Deflate(BestCompression)

            case "GZip(BestSpeed)" | "GZipFormat(BestSpeed)" => LogFileCompressFormat.GZip(BestSpeed)
            case "GZip(DefaultCompression)" | "GZip(Default)" | "GZip" | "GZipFormat" | "GZipFormat(DefaultCompression)" | "GZipFormat(Default)" => LogFileCompressFormat.
                GZip(DefaultCompression)
            case "GZip(BestCompression)" | "GZipFormat(BestCompression)" => LogFileCompressFormat.GZip(
                BestCompression)
            case _ => throw IllegalArgumentException(
                "unsupported compress config ${format}. " +
                    " The supported compressing configs are None, Deflate(BestSpeed), DeflateFormat(BestSpeed)," +
                    " Deflate(DefaultCompression), DeflateFormat(Default)," +
                    " DeflateFormat(DefaultCompression), DeflateFormat(Default), Deflate, DeflateFormat," +
                    " Deflate(BestCompression), DeflateFormat(BestCompression)," +
                    " GZip(BestSpeed), GZipFormat(BestSpeed)," +
                    " GZip(DefaultCompression), GZipFormat(Default), GZip, GZipFormat," +
                    " GZipFormat(DefaultCompression), GZipFormat(Default)" +
                    " GZip(BestCompression), GZipFormat(BestCompression)."
            )
        }
    }
    public static func computeBytes(bytes: String): Int64 {
        let b = bytes.trimAscii()
        var unit = b'b'
        var ne = bytes.size
        var bu = bytes[ne - 1]
        if (bu == b'b' || bu == b'B'){
            ne--
            bu = bytes[ne - 1]
            if ((bu >= b'a' && bu <= b'z') || (bu >= b'A' && bu <= b'Z')) {
                ne--
                unit = bu
            }
        } else if ((bu >= b'a' && bu <= b'z') || (bu >= b'A' && bu <= b'Z')) {
            ne--
            unit = bu
        }
        Int64.tryParse(bytes[0 .. ne]).getOrThrow{
            throw IllegalArgumentException("${b} is illegal bytes description, bytes description supports an integer number follows with r'k' 'kbr' 'mr' 'mbr' 'gr' 'gbr' 'tr' 'tbr' 'er' 'eb' or their upper cases")
        } * 1024 **
        match(unit){
            case b'b' | b'B' => 0
            case b'k' | b'K' => 1
            case b'm' | b'M' => 2
            case b'g' | b'G' => 3
            case b't' | b'T' => 4
            case b'p' | b'P' => 5
            case b'e' | b'E' => 6
            case b'z' | b'Z' | b'y' | b'Y' => throw IllegalArgumentException("${b} is overflow for Int64")
            case _ => throw IllegalArgumentException("${unit} is illegal byte unit")
        }
    }

    private static func genTime(timeunit: TimeUnit, current: DateTime): String {
        match (timeunit) {
            case DAY => current.addDays(-1).toString("yyyyMMdd")
            case HOUR => current.addHours(-1).toString("yyyyMMddHH")
            case WEEK => current.addWeeks(-1).toString("yyyyMMddWW")
            case MINUTE => current.addMinutes(-1).toString("yyyyMMddHHmm")
            case MONTH => current.addMonths(-1).toString("yyyyMM")
            case YEAR => current.addYears(-1).toString("yyyy")
            case SECOND => current.addSeconds(-1).toString("yyyyMMddHHMMss")
            case _ => current.addNanoseconds(-1).toString("yyyyMMddHHmmssSSS")
        }
    }
    private let fileLock = Mutex()
    private func rotateFileIfNeed() {
        synchronized(fileLock) {//此处不能使用双重检查锁，否则可能导致一个线程试图向另一个线程已经重命名的文件导致写失败
            let current = timeunit.trim(DateTime.now())
            let (need, file) = needRotate(current)
            if (need) {
                let originPath = file.info.path.toString()
                try {
                    let time = genTime(timeunit, current)
                    let path = "${originPath}.${time}"
                    try {
                        file.close()
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                    try {
                        rename(originPath, to: path, overwrite: true)
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                    compressAndDeleteOld(path)
                } catch (e: Exception) {
                    e.printStackTrace()
                }
                if(!exists(originPath)){
                    this.file = File(originPath, Append)
                }
            }
        }
    }
    private func needRotate(current: DateTime) {
        let file = this.file
        let fileInfo = file.info
        (fileInfo.creationTime < current || fileInfo.size >= fileSize, file)
    }
    private func closeFile(file: ?File): Unit {
        if (let Some(f) <- file) {
            if (f.isClosed()) {
                return
            }
            try {
                f.close()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
    private func doCompress(path: String, ext: String, wrap: WrapType, level: CompressLevel) {
        var f = None<File>
        var compressedFile = None<File>
        try {
            f = File(path, Read)
            let fsize = f?.length ?? 0
            if (fsize == 0) {
                return
            }
            compressedFile = File("${path}${ext}", Write)
            let compressedOutput = CompressOutputStream(
                compressedFile.getOrThrow(),
                wrap: wrap,
                compressLevel: level
            )
            try {
                f?.seek(Begin(0))
                var buf = Array<Byte>(if (fsize >= 1024 ** 2) {
                    1024 ** 2
                } else {
                    fsize
                }, repeat: 0)
                var readLen = 0
                do {
                    readLen = f?.read(buf) ?? 0
                    if (readLen > 0) {
                        compressedOutput.write(buf[0..readLen])
                    }
                } while (readLen == buf.size)
            } catch (e: Exception) {
                e.printStackTrace()
            } finally {
                try {
                    compressedOutput.close()
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            closeFile(f)
            closeFile(compressedFile)
            removeIfExists(path)
        }
    }
    private func compressAndDeleteOld(path: String) {
        queue.enqueue({=>
            match (compress) {
                case Deflate(level) => doCompress(path, ".lz", DeflateFormat, level)
                case GZip(level) => doCompress(path, ".gz", GzipFormat, level)
                case NonCompression => return
            }
        })
    }
    public func write(buffer: Array<Byte>): Unit {
        rotateFileIfNeed()
        file.write(buffer)
    }
    public func flush(): Unit {
        file.flush()
    }
}

public enum LogFileCompressFormat {
    | NonCompression
    | Deflate(CompressLevel)
    | GZip(CompressLevel)
}
