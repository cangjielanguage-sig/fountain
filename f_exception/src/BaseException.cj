/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_exception

import std.io.{OutputStream, StringWriter}
import std.collection.ArrayList

public func printStackTrace<O>(exception: Exception, output: O): Unit where O <: OutputStream {
    printStackTrace<O>(exception, StringWriter<O>(output))
}

public func printStackTrace<O>(exception: Exception, writer: StringWriter<O>): Unit where O <: OutputStream {
    writer.writeln("An exception has occured: ${exception}")
    for (stack in exception.getStackTrace()) {
        writer.writeln(
            "         at ${stack.declaringClass}.${stack.methodName}(${stack.fileName}: ${stack.lineNumber})"
        )
    }
    writer.flush()
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

    public func printStackTrace<O>(output: O): Unit where O <: OutputStream {
        this.printStackTrace(StringWriter<O>(output))
    }
    public func printStackTrace<O>(writer: StringWriter<O>): Unit where O <: OutputStream {
        printStackTrace<O>(this, writer)
        if (let Some(c) <- caused) {
            writer.write("Caused by: ")
            if (let cp: BaseException <- c) {
                cp.printStackTrace<O>(writer)
            } else {
                printStackTrace<O>(c, writer)
            }
        }
        if (!suppressed.isEmpty()) {
            writer.write("Suppressed: ")
        }
        for (s in suppressed) {
            if (let se: BaseException <- s) {
                se.printStackTrace<O>(writer)
            } else {
                printStackTrace<O>(s, writer)
            }
        }
    }
}
