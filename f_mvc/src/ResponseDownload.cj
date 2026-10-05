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
package fountain::f_mvc

public func download(data: File): Unit {
    let fd = FileDownload(multi: false)
    fd.write(data)
}

public func download(data: InputStream, filename: String, length!: Int64 = -1): Unit {
    let fd = FileDownload(multi: false)
    fd.write(filename, data, length: length)
}

public func download(data: Array<Byte>, filename: String): Unit {
    let stream = ByteBuffer()
    stream.write(data)
    download(stream, filename, length: data.size)
}

public func download<C>(data: C): Unit where C <: Iterable<(InputStream, String)> {
    let started = Box<Bool>(false)
    FileDownload(multi: true).exec {
        fd =>
            for (d in data) {
                if (started.value) {
                    fd.next(d[1], '')
                } else {
                    fd.start(d[1])
                    started.value = true
                }
                copy(d[0], {bytes => fd.write(bytes)})
            }
            fd.end()
    }
}

public func download(data: Array<File>): Unit {
    FileDownload(multi: true).exec {
        fd =>
            for (i in 0..data.size) {
                let f = data[i]
                if (i == 0) {
                    fd.start(f.info.name, length: f.info.size)
                } else {
                    fd.next(f.info.name, '', length: f.info.size)
                }
                copy(f, {bytes => fd.write(bytes)})
            }
            fd.end()
    }
}

/**
 * 把 input 的内容复制给 write：每次最多读一个下载缓冲，只写出实际读到的长度。
 * §1.9 / `MVC-4`：原先两处循环直接 `write(buf)`，会把缓冲里超出 read 返回值的脏尾部一起写出。
 */
func copy(input: InputStream, write: (Array<Byte>) -> Unit): Unit {
    let buf = Array<Byte>(MVCConfig.downloadBufferSize, repeat: 0)
    while (let bytes <- input.read(buf) && bytes > 0) {
        write(buf[0..bytes])
    }
}
