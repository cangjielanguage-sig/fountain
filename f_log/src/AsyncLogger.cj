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

import std.collection.concurrent.{ArrayBlockingQueue, ConcurrentHashMap}
import std.io.{OutputStream, ByteBuffer}
import std.sync.Mutex
import std.time.DateTime

import stdx.log.{LogLevel, LogRecord}

import f_log.exception.LogException

public abstract class AsyncLogger <: AbstractLogger {
    private static let queueMap = ConcurrentHashMap<String, ArrayBlockingQueue<() -> Unit>>()
    private static let mutex = Mutex()
    private let timeout: Duration
    private let policy: AsyncTimeoutPolicy
    private let queue: ArrayBlockingQueue<() -> Unit>
    private let output_: OutputStream
    public init(
        name: String,
        level: LogLevel,
        pattern: LogPattern,
        output: OutputStream,
        queueTag: String
    ) {
        super(name, level, pattern, confirmDummy(output))
        this.output_ = output
        timeout = LoggerConfig.getAsyncTimeout()
        policy = LoggerConfig.getAsyncTimeoutPolicy()
        this.queue = 
        synchronized(mutex){//确保一个日志写入目标只有一个队列和一个消费线程
            if(let Some(q) <- queueMap.get(queueTag)){
                q
            }else{
                let bufSize = LoggerConfig.getAsyncBufSize()
                let queue = ArrayBlockingQueue<() -> Unit>(bufSize)
                queueMap[queueTag] = queue
                dequeue(queue)
                queue
            }
        }
    }
    private static func confirmDummy(output: OutputStream): OutputStream {
        match(output){
            case _: DummyOutputStream => output
            case _ => ByteBuffer()
        }
    }
    private static func dequeue(queue: ArrayBlockingQueue<() -> Unit>): Unit {
        spawn {
            while (true) {
                try{
                    queue.dequeue()()
                }catch(e: Exception){
                    e.printStackTrace()
                }
            }
        }
    }
    private func append(){
        let buffer = (super.output as ByteBuffer).getOrThrow()
        if(buffer.remainLength > 0){
            super.output = ByteBuffer()
            append{
                this.output_.write(buffer.bytes())
                this.output_.flush()
            }
        }
    }
    public open func log(record: LogRecord): Unit {
        super.log(record)
        append()
    }
    protected func append(fn: () -> Unit): Unit {
        while (!queue.enqueue(fn, timeout)) {
            match (policy) {
                case AlwaysWaiting => continue
                case Discard => return // 忽略
                case Abort => throw LogException("to enqueue for current logger is timeout ${timeout}")
            }
        }
    }
    protected open func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        super.append(level, message, now, ex)
        append()
    }
}
