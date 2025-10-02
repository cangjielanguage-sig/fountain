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
package f_log

import std.collection.concurrent.{ArrayBlockingQueue, ConcurrentHashMap}
import std.env
import std.io.OutputStream
import std.time.DateTime
import stdx.log.{LogLevel, LogRecord}
import f_collection.*
import f_io.DummyOutputStream
import f_log.exception.LogException

public abstract class AsyncLogger <: AbstractLogger {
    private static let queueMap = ConcurrentHashMap<String, ArrayBlockingQueue<() -> Unit>>()
    private static let queueOutputMap = ConcurrentHashMap<String, SyncQueueOutputStream>()
    private let timeout: Duration
    private let policy: AsyncTimeoutPolicy
    private let queue: ArrayBlockingQueue<() -> Unit>
    protected let actualOutput: OutputStream
    private let queueTag: String
    public init(
        name: String,
        level: LogLevel,
        pattern: LogPattern,
        output: OutputStream,
        queueTag: String
    ) {
        super(name, level, pattern, confirmDummy(output, LoggerConfig.getAsyncBufSize(), queueTag))
        this.queueTag = queueTag
        this.actualOutput = output
        timeout = LoggerConfig.getAsyncTimeout()
        policy = LoggerConfig.getAsyncTimeoutPolicy()
        this.queue = queueMap.computeIfAbsent(queueTag){
            let bufSize = LoggerConfig.getAsyncBufSize()
            let queue = ArrayBlockingQueue<() -> Unit>(bufSize)
            remove(queue)
            queue
        }
        env.atExit{doClose(output, true, queueTag)}
    }
    public open func isClosed(): Bool {
        if(let r: Resource <- actualOutput){
            r.isClosed()
        }else{
            false
        }
    }
    private static func doClose(output: OutputStream, closable: Bool, tag: String): Unit {
        if(let Some(output) <- queueOutputMap.remove(tag)){
            while(output.queue.size > 0){
                sleep(Duration.Zero)
            }
            sleep(Duration.microsecond * 100)// 等待写线程能够把最后一个字节数组写出
        }
        if(let r: Resource <- output && closable){
            r.close()
        }
    }
    public open func close(): Unit {
        doClose(actualOutput, closable, queueTag)
    }
    private static func confirmDummy(output: OutputStream, bufSize: Int64, tag: String): OutputStream {
        match (output) {
            case _: DummyOutputStream => output
            case _ => 
                let output = SyncQueueOutputStream(bufSize)
                queueOutputMap.put(tag, output)
                output
        }
    }
    private static func remove(queue: ArrayBlockingQueue<() -> Unit>): Unit {
        spawn {
            while (true) {
                try {
                    queue.remove()()
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }
    }
    private func append() {
        let buffer = (super.output as SyncQueueOutputStream).getOrThrow()
        if (buffer.queue.size > 0) {
            append {
                while(let Some(bytes) <- buffer.queue.tryRemove()){
                    this.actualOutput.write(bytes)
                    this.actualOutput.flush()
                }
            }
        }
    }
    public open func log(record: LogRecord): Unit {
        super.log(record)
        append()
    }
    protected func append(fn: () -> Unit): Unit {
        while (!queue.add(fn, timeout)) {
            match (policy) {
                case AlwaysWaiting => continue
                case Discard => return // 忽略
                case Abort => throw LogException("to add for current logger is timeout ${timeout}")
            }
        }
    }
    protected open func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        super.append(level, message, now, ex)
        append()
    }
}
public class SyncQueueOutputStream <: OutputStream {
    internal let queue: ArrayBlockingQueue<Array<Byte>>
    init(bufSize: Int64){
        queue = ArrayBlockingQueue<Array<Byte>>(bufSize * 10)
    }
    public func write(bytes: Array<Byte>): Unit {
        queue.add(bytes)
    }
}