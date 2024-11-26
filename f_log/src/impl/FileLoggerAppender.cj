/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_log.impl

import std.convert.Parsable
import std.collection.concurrent.ArrayBlockingQueue
import std.fs.{File, Directory, OpenMode}
import std.io.SeekPosition
import std.math.MathExtension
import std.sync.{Timer, ReentrantMutex, AtomicReference, AtomicUInt64}
import std.time.DateTime
import compress.zlib.{WrapType, CompressLevel, CompressOutputStream}

import log.LogLevel

import f_base.*
import f_exception.*
import f_log.output.{RotatableFile, RotatableFileParams}
import f_time.{TimeUnit, ExtendDateTime}

let _ = FileLoggerAppender.register()
private class FileLoggerAppender <: AsyncLogger {
    public init(
        name!: String,
        pattern!: LogPattern,
        level!: LogLevel = LogLevel.INFO,
        file!: RotatableFile
    ) {
        super(name, level, pattern, file)
    }

    public static func register(): Unit {
        LoggerAppenderCreator.register("file") {
            name =>
            let appenders = LoggerConfig.getAppenders("file")
            if(appenders.isEmpty()){
                [NoneLogAppender.instance]
            }else{
                Array<AbstractLogger>(appenders.size){i =>
                    let appender = appenders[i]
                    let params = RotatableFileParams()
                    if (let Some(p) <- LoggerConfig.getString(appender, "path")) {
                        if (p != String.empty) {
                            params.path = p
                        }
                    }
                    if (let Some(d) <- LoggerConfig.getString(appender, "rotate.duration")) {
                        if (let Some(u) <- TimeUnit.parse(d)) {
                            params.timeunit = u
                        }
                    }
                    if (let Some(s) <- LoggerConfig.getString(appender, "rotate.size")) {
                        if (s != String.empty) {
                            params.fileSize = RotatableFile.computeBytes(s)
                        }
                    }
                    if (let Some(c) <- LoggerConfig.getString(appender, "compress.format")) {
                        params.compress = RotatableFile.compressFormat(c)
                    }
                    FileLoggerAppender(
                        name: name,
                        level: LoggerConfig.getLevelConf(appender),
                        pattern: LoggerConfig.getPatternConf(appender),
                        file: RotatableFile(params)
                    )
                }
            }
        }
    }
}
