/*
   Copyright (c) 2022 WuJingrun（吴京润）
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_base

import std.io.{OutputStream, StringWriter, ByteBuffer}
import std.collection.ArrayList

public func printStackTrace(exception: Exception, output: OutputStream): Unit {
    printStackTrace(output) {
        buf =>
        buf.write("An exception has occured: ${exception}".unsafeBytes())
        for (stack in exception.getStackTrace()) {
            buf.write(
                "         at ${stack.declaringClass}.${stack.methodName}(${stack.fileName}: ${stack.lineNumber})${OS.current.nextLine}"
                    .unsafeBytes())
        }
    }
}

private func printStackTrace(output: OutputStream, callee: (ByteBuffer) -> Unit) {
    if (let buffer: ByteBuffer <- output) {
        callee(buffer)
    } else {
        let buffer = ByteBuffer()
        callee(buffer)
        output.write(buffer.bytes())
        output.flush()
    }
}

public open class BaseException <: Exception {
    private var caused_ = None<Exception>
    private var suppressed_ = ArrayList<Exception>()

    public init() {}

    public init(message: String) {
        super(message)
    }
    public init(caused: Exception) {
        caused_ = caused
    }
    public init(message: String, caused: Exception) {
        this(message)
        caused_ = caused
    }

    public func addSuppressed(suppressed: Exception): Unit {
        this.suppressed_.add(suppressed)
    }
    public prop caused: Option<Exception> {
        get() {
            caused_
        }
    }
    public prop suppressed: ArrayList<Exception> {
        get() {
            suppressed_
        }
    }
    public func printStackTrace(output: OutputStream): Unit {
        printStackTrace(output) {
            w =>
            printStackTrace(this, w)
            if (let Some(c) <- caused) {
                w.write("Caused by: ".unsafeBytes())
                printStackTrace(c, w)
            }
            if (!suppressed.isEmpty()) {
                w.write("Suppressed: ".unsafeBytes())
                for (s in suppressed) {
                    printStackTrace(s, w)
                }
            }
        }
    }
}
