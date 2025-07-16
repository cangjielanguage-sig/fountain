/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_mvc

public func download(ctx: HttpContext, data: File): Unit {
    let fd = FileDownload(ctx, multi: false)
    fd.write(data)
}

public func download(ctx: HttpContext, data: InputStream, filename: String, length!: Int64 = -1): Unit {
    let fd = FileDownload(ctx, multi: false)
    fd.write(filename, data, length: length)
}

public func download(ctx: HttpContext, data: Array<Byte>, filename: String): Unit {
    let stream = ByteBuffer()
    stream.write(data)
    download(ctx, stream, filename, length: data.size)
}

public func download<C>(ctx: HttpContext, data: C): Unit where C <: Iterable<(InputStream, String)> {
    let fd = FileDownload(ctx, multi: true)
    for (d in data) {
        fd.write(d[1], d[0])
    }
}

public func download(ctx: HttpContext, data: Array<File>): Unit {
    let fd = FileDownload(ctx, multi: true)
    for (d in data) {
        fd.write(d)
    }
}
