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

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap

public class LoggerAppenderCreator {
    private static let creators = ConcurrentHashMap<String, (String) -> Array<AbstractLogger>>()

    public static func register(kind: String, creator: (String) -> Array<AbstractLogger>) {
        creators.put(kind, creator)
    }
    public static func create(name: String): LoggerAppenderFacade {
        let loggers = ArrayList<AbstractLogger>()
        for ((_, creator) in creators) {
            for (logger in creator(name) where !(logger is NoneLogAppender)) {
                loggers.append(logger)
            }
        }
        LoggerAppenderFacade(name, loggers.toArray())
    }
}
