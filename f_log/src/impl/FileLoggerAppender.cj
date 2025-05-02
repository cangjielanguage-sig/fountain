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
import std.sync.{Timer, Mutex, AtomicReference, AtomicUInt64}
import std.time.DateTime
import stdx.compress.zlib.{WrapType, CompressLevel, CompressOutputStream}
import stdx.log.LogLevel
import f_base.*
import f_exception.*
import f_log.output.{RotatableFile, RotatableFileParams}
import f_time.{TimeUnit, ExtendDateTime}

private class FileLoggerAppender <: AsyncLogger {
    private static const LOGGER_NAME = 'file'
    public init(
        name!: String,
        pattern!: LogPattern,
        level!: LogLevel = LogLevel.INFO,
        file!: RotatableFile
    ) {
        super(name, level, pattern, file, file.path)
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
                        .parse(d)) {
                        params.timeunit = u
                    }
                    if (let Some(s) <- LoggerConfig.getString(appender, "rotateSize") && !s.isEmpty()) {
                        params.fileSize = RotatableFile.computeBytes(s)
                    }
                    if (let Some(c) <- LoggerConfig.getString(appender, "compressFormat")) {
                        params.compress = RotatableFile.compressFormat(c)
                    }
                    FileLoggerAppender(
                        name: name,
                        level: LoggerConfig.getLevelConf(appender),
                        pattern: LoggerConfig.getPatternConf(appender),
                        file: if (url.isEmpty()) {
                            RotatableFile(params)
                        } else {
                            RotatableFile(url, params)
                        }
                    )
                }
            }
        }
    }
}

let _ = FileLoggerAppender.register()
