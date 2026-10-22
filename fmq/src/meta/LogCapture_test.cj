/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::fmq.meta

import std.collection.ArrayList
import std.io.OutputStream
import std.sync.{AtomicBool, Mutex}
import std.time.DateTime
import fountain::f_io.DummyOutputStream
import fountain::f_log.*

/**
 * 把日志按记录（`\0` 分隔）收集到内存的输出流。
 *
 * f_log 的 facade 是异步的，日志在后台线程落盘，因此断言统一用 [CapturingAppender.waitFor] 轮询。
 */
class CapturingStream <: OutputStream {
    static let lines = ArrayList<String>()
    static let pending = ArrayList<Byte>()
    static let lock = Mutex()

    public func write(buffer: Array<Byte>): Unit {
        synchronized(lock) {
            for (b in buffer) {
                if (b == 0u8) {
                    lines.add(String.fromUtf8(pending.toArray()))
                    pending.clear()
                } else {
                    pending.add(b)
                }
            }
        }
    }

    public func flush(): Unit {}

    static func take(): Array<String> {
        synchronized(lock) {
            lines.toArray()
        }
    }

    static func clear(): Unit {
        synchronized(lock) {
            lines.clear()
            pending.clear()
        }
    }
}

/**
 * 内存日志捕捉器：注册成 f_log appender 后，用例可断言日志内容。
 *
 * 用 `output` 收集格式化后的文本，避免在 f_mq 的源码里引入 `stdx.log` 依赖。
 */
class CapturingAppender <: AbstractLogger {
    private static let installed = AtomicBool(false)
    private static var levelProbe: ?AbstractLogger = None

    init(loggerName: String) {
        super(loggerName, levelProbe.getOrThrow().level, LogPattern.default, DummyOutputStream.THROW_ON_ACCESSING,
            "capture")
        this.output = CapturingStream()
    }

    /** 幂等安装：首次调用注册 appender 并重建已有 logger 的 facade。 */
    static func install(): Unit {
        if (!installed.compareAndSwap(false, true)) {
            return
        }
        // 先拿到一个已存在的 logger 作为级别来源，注册后不再访问 LoggerFactory，避免构造期重入
        levelProbe = Some(LoggerFactory.getLogger("fountain::f_mq.capture.probe"))
        LoggerAppenderCreator.register("capture") {name => [CapturingAppender(name)]}
        LoggerFactory.refresh()
    }

    static func clear(): Unit {
        CapturingStream.clear()
    }

    /** 返回同时包含全部片段的行。 */
    static func find(parts: Array<String>): Array<String> {
        let matched = ArrayList<String>()
        for (line in CapturingStream.take()) {
            var hit = true
            for (part in parts) {
                if (!line.contains(part)) {
                    hit = false
                    break
                }
            }
            if (hit) {
                matched.add(line)
            }
        }
        matched.toArray()
    }

    /** 轮询等待出现同时包含全部片段的一行。 */
    static func waitFor(parts: Array<String>, timeoutMs!: Int64 = 3000): Bool {
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + timeoutMs
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() <= deadline) {
            if (find(parts).size > 0) {
                return true
            }
            sleep(Duration.millisecond * 10)
        }
        find(parts).size > 0
    }
}
