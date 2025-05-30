/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_log

import std.convert.Parsable
import std.regex.Regex
import std.sync.Mutex
import stdx.log.LogLevel
import f_config.Config
import f_data.*
import f_log.exception.LogException
import f_time.*
import f_util.computeBytes

/**
 *
 */
public class LoggerConfig {
    //所有的appender配置项都是fountain_logger_appender_${appenderName}_${confItem}
    //confItem 可以是level pattern 等，还可以有Appender特有配置项
    private static const confPrefix = "logger"
    public static const appender = "appender"

    private static let BLANK_SPLITTOR = Regex(#"\s*,\s*"#)
    private init() {
    }
    static init(){
        Config.refresher(confPrefix, LoggerFactory.refresh)
    }
    public static func createFacade(name: String): LoggerAppenderFacade {
        LoggerAppenderCreator.create(name)
    }

    public static func getString(appender: String, item: String): Option<String> {
        Config.getString("${confPrefix}_${appender}_${item}")
    }
    public static func getAppenders(kind: String): Array<String>{
        if(let Some(appenders) <- getString(appender, kind)){
            appenders.split(",")
        }else{
            []
        }
    }
    private static func appenderKeyPart(appender: String){
        '${LoggerConfig.appender}_${appender}'
    }
    public static func getLevelConf(appender: String): LogLevel {
        if (let Some(level) <- getString(appenderKeyPart(appender), "level")) {
            return convertLevel(level)
        }
        return LogLevel.INFO
    }
    public static func getPatternConf(appender: String): LogPattern {
        if (let Some(p) <- getString(appenderKeyPart(appender), "pattern")) {
            return LogPattern(p)
        }
        return LogPattern.default
    }
    public static func getAsyncBufSize(): Int64 {
        Config.getData<Int64>("loggerAsyncBufsize") ?? 1
    }
    public static func getAsyncTimeout(): Duration {
        if(let Some(d) <- Config.getString("loggerAsyncTimeout")){
            let timeout = Duration.tryParse(d).getOrThrow{LogException("illegal async timeout duration ${d}")}
            if (timeout == Duration.Zero) {
                Duration.Max
            } else {
                timeout
            }
        }else{
            Duration.Max
        }
    }
    public static func getAsyncTimeoutPolicy(): AsyncTimeoutPolicy {
        if(let Some(p) <- Config.getString("loggerAsyncTimeoutPolicy")) {
            match(p.toAsciiLower()){
                case "discard" => Discard
                case "abort" => Abort
                case _ => AlwaysWaiting
            }
        } else {
            AlwaysWaiting
        }
    }
    public static func getUdpSendTimeout(appender: String): ?Duration {
        if (let Some(d) <- getString(appenderKeyPart(appender), "sendTimeout")) {
            Duration.tryParse(d).getOrThrow{LogException("${d} is an illegal duration string for ${appender} udp sendTimeout")}
        } else {
            None<Duration>
        }
    }
    public static func getUnixWriteTimeout(appender: String): ?Duration {
        if (let Some(d) <- getString(appenderKeyPart(appender), "writeTimeout")) {
            Duration.tryParse(d).getOrThrow{LogException("${d} is an illegal duration string for ${appender} unix writeTimeout")}
        } else {
            None<Duration>
        }
    }
    public static func getTcpSendBufSize(appender: String): ?Int64 {
        if (let Some(s) <- getString(appenderKeyPart(appender), "bufSize")) {
            Int64.tryParse(s).getOrThrow{LogException("${s} is an illegal duration string for ${appender} tcp sendBufSize")}
        } else {
            None<Int64>
        }
    }
    public static func getUnixBufSize(appender: String): ?Int64 {
        if (let Some(s) <- getString(appenderKeyPart(appender), "bufSize")) {
            Int64.tryParse(s).getOrThrow{LogException("${s} is an illegal duration string for ${appender} unix sendBufSize")}
        } else {
            None<Int64>
        }
    }
    private static func convertLevel(level: String): LogLevel {
        match (level.toAsciiUpper()) {
            case "OFF" => LogLevel.OFF
            case "ERROR" => LogLevel.ERROR
            case "WARN" => LogLevel.WARN
            case "INFO" => LogLevel.INFO
            case "DEBUG" => LogLevel.DEBUG
            case "TRACE" => LogLevel.TRACE
            case "ALL" => LogLevel.ALL
            case _ => LogLevel.INFO
        }
        
    }
}
