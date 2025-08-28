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
package f_log.impl

import std.convert.Parsable
import std.collection.concurrent.ArrayBlockingQueue
import std.fs.{File, Directory, OpenMode}
import std.io.{SeekPosition, OutputStream}
import std.math.MathExtension
import std.sync.{Timer, Mutex, AtomicReference, AtomicUInt64}
import std.time.DateTime
import stdx.compress.zlib.{WrapType, CompressLevel, CompressOutputStream}
import stdx.log.LogLevel
import f_base.*
import f_exception.*
import f_log.output.*
import f_time.{TimeUnit, ExtendDateTime}

private class FileLoggerAppender <: AsyncLogger {
    private static const LOGGER_NAME = 'file'
    public init(
        name!: String,
        pattern!: LogPattern,
        level!: LogLevel = LogLevel.INFO,
        file!: OutputStream
    ) {
        super(name, level, pattern, file, '${LOGGER_NAME}:///${toPath(file)}')
    }
    @When[os == "Linux"]
    private static func toPath(file: OutputStream) {
        match(file){
            case x: RotatableFile => x.path
            case x: RotatableMMapFile => x.path
            case _ => ''
        }
    }
    @When[os != "Linux"]
    private static func toPath(file: OutputStream) {
        match(file){
            case x: RotatableFile => x.path
            case _ => ''
        }
    }
    public static func register(): Unit {
        LoggerAppenderCreator.register(LOGGER_NAME) {
            name =>
            let appenders = LoggerConfig.getAppenders(LOGGER_NAME)
            if (appenders.isEmpty()) {
                [NoneLogAppender.instance]
            } else {
                Array<AbstractLogger>(appenders.size) {
                    i =>
                    let appender = appenders[i]
                    let params = RotatableFileParams()
                    let url = if (let Some(url) <- LoggerConfig.getString(appender, 'url')) {
                        url
                    } else {
                        ''
                    }
                    if (let Some(p) <- LoggerConfig.getString(appender, "path") && !p.isEmpty()) {
                        params.path = p
                    }
                    if (let Some(d) <- LoggerConfig.getString(appender, "rotateDuration") && let Some(u) <- TimeUnit
                        .tryParse(d)) {
                        params.timeunit = u
                    }
                    if (let Some(s) <- LoggerConfig.getString(appender, "rotateSize") && !s.isEmpty()) {
                        params.fileSize = RotatableFile.computeBytes(s)
                    }
                    if (let Some(c) <- LoggerConfig.getString(appender, "compressFormat")) {
                        params.compress = RotatableFile.compressFormat(c)
                    }
                    let mmap = 
                    if(let Some(x) <- LoggerConfig.getString(appender, "mmap") && x.trimAscii().toAsciiLower() == 'true'){
                        true
                    }else{
                        false
                    }
                    let rf = if (url.isEmpty()) {
                        RotatableFile(params)
                    } else {
                        RotatableFile(url, params)
                    }
                    @When[os == "Linux"]
                    let output: OutputStream = if(mmap){
                        rf.mmap()
                    }else{
                        rf
                    }
                    @When[os != "Linux"]
                    let output = rf
                    FileLoggerAppender(
                        name: name,
                        level: LoggerConfig.getLevelConf(appender),
                        pattern: LoggerConfig.getPatternConf(appender),
                        file: output
                    )
                }
            }
        }
    }
}

let _ = FileLoggerAppender.register()
