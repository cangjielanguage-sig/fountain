/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_io

internal import std.io.{InputStream, OutputStream}

public func pipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit where I <: InputStream, O <: OutputStream {
    let buf = Array<Byte>(bufferSize, repeat: 0)
    while(let len <- input.read(buf) && len > 0){
        output.write(buf[0 .. len])
    }
}

public func asyncPipe<I, O>(input!: I, output!: O, bufferSize!: Int64 = 4096): Unit where I <: InputStream, O <: OutputStream {
    spawn{
        pipe<I, O>(input: input, output: output, bufferSize: bufferSize)
    }
}