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
    let writer = StringWriter(output)
    writer.write("An exception has occured: ")
    writer.write(exception.toString())
    writer.write('\n')
    for (stack in exception.getStackTrace()) {
        writer.write("         at ")
        writer.write(stack.declaringClass)
        writer.write(".")
        writer.write(stack.methodName)
        writer.write("(")
        writer.write(stack.fileName)
        writer.write(": ")
        writer.write(stack.lineNumber)
        writer.write(")\n")
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
        this.suppressed_.append(suppressed)
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

    public func printStackTrace<O>(writer: O): Unit where O <: OutputStream {
        printStackTrace(this, writer)
        let causedBy = unsafe{"Caused by: ".rawData()}
        if (let Some(c) <- caused) {
            writer.write(causedBy)
            if (let cp: BaseException <- c) {
                cp.printStackTrace(writer)
            } else {
                printStackTrace(c, writer)
            }
        }
        if (!suppressed.isEmpty()) {
            writer.write(unsafe{"Suppressed: \n".rawData()})
        }
        for (s in suppressed) {
            if (let se: BaseException <- s) {
                se.printStackTrace(writer)
            } else {
                printStackTrace(s, writer)
            }
        }
    }
}
