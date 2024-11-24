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
import std.sync.ReentrantMutex
import log.LogLevel
import f_config.Config
import f_data.*
import f_log.exception.LogException
import f_time.*
import f_util.computeBytes

/**
 *
 */
public class LoggerConfig {
    //日志配置文件路径配置项是logger.conf.path，
    //从启动参数--logger.conf.path -Dlogger.conf.path 和环境变量LOGGER_CONF_PATH之一读取，读取优先级就是前述顺序
    //所有的appender配置项都是logger.conf.appender.${appenderName}.${confItem}
    //confItem 可以是level pattern 等，还可以有Appender特有配置项
    private static const confPrefix = "logger"
    public static const appender = "appender"

    private static let dot = Regex(#"\."#)
    private static let BLANK_SPLITTOR = Regex(#"\s*,\s*"#)
    private init() {
    }
    static init(){
        Config.refresher(confPrefix, LoggerFactory.refresh)
    }
    public static func createFacade(name: String): LoggerAppenderFacade {
        LoggerAppenderCreator.create(name)
    }
    private static func extractAppenders(): Option<Array<String>> {
        if (let Some(appen) <- Config.getString('${confPrefix}_${appender}')) {
            let appenders = BLANK_SPLITTOR.matcher(appen.toAsciiLower()).split()
            Some(appenders)
        } else {
            None<Array<String>>
        }
    }
    public static func getString(appender: String, item: String): Option<String> {
        Config.getString("${confPrefix}_${LoggerConfig.appender}_${appender}_${item}")
    }
    public static func getAppenders(kind: String): Array<String>{
        if(let Some(appenders) <- getString(appender, kind)){
            appenders.split(",")
        }else{
            []
        }
    }
    public static func getLevelConf(appender: String): LogLevel {
        if (let Some(level) <- getString(appender, "level")) {
            return convertLevel(level)
        }
        return LogLevel.INFO
    }
    public static func getPatternConf(appender: String): LogPattern {
        if (let Some(p) <- getString(appender, "pattern")) {
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
        if (let Some(d) <- getString(appender, "sendTimeout")) {
            Duration.tryParse(d).getOrThrow{LogException("${d} is an illegal duration string for ${appender} udp sendTimeout")}
        } else {
            None
        }
    }
    public static func getUnixWriteTimeout(appender: String): ?Duration {
        if (let Some(d) <- getString(appender, "writeTimeout")) {
            Duration.tryParse(d).getOrThrow{LogException("${d} is an illegal duration string for ${appender} unix writeTimeout")}
        } else {
            None
        }
    }
    public static func getTcpSendBufSize(appender: String): ?Int64 {
        if (let Some(s) <- getString(appender, "bufSize")) {
            Int64.tryParse(s).getOrThrow{LogException("${s} is an illegal duration string for ${appender} tcp sendBufSize")}
        } else {
            None
        }
    }
    public static func getUnixBufSize(appender: String): ?Int64 {
        if (let Some(s) <- getString(appender, "bufSize")) {
            Int64.tryParse(s).getOrThrow{LogException("${s} is an illegal duration string for ${appender} unix sendBufSize")}
        } else {
            None
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
