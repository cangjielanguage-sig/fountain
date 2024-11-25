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

import std.collection.concurrent.ArrayBlockingQueue
import std.io.OutputStream
import std.time.DateTime

import log.{LogLevel, LogRecord}

import f_log.exception.LogException

public abstract class AsyncLogger <: AbstractLogger {
    protected let queue: ArrayBlockingQueue<() -> Unit>
    private let timeout: Duration
    private let policy: AsyncTimeoutPolicy
    public init(
        name: String,
        level: LogLevel,
        pattern: LogPattern,
        output: OutputStream
    ) {
        super(name, level, pattern, output)
        let bufSize = LoggerConfig.getAsyncBufSize()
        timeout = LoggerConfig.getAsyncTimeout()
        policy = LoggerConfig.getAsyncTimeoutPolicy()
        queue = ArrayBlockingQueue<() -> Unit>(bufSize)
        dequeue(queue)
    }
    private static func dequeue(queue: ArrayBlockingQueue<() -> Unit>){
        spawn {
            while (true) {
                queue.dequeue()()
            }
        }
    }
    public open func log(record: LogRecord): Unit {
        append{super.log(record)}
    }
    protected func append(fn: () -> Unit) {
        while (!queue.enqueue(fn, timeout)) {
            match (policy) {
                case AlwaysWaiting => continue
                case Discard => return // 忽略
                case Abort => throw LogException("to enqueue for current logger is timeout ${timeout}")
            }
        }
    }
    protected open func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        append { => super.append(level, message, now, ex)}
    }
}
