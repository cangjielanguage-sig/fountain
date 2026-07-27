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
    FileDownload(multi: true).write{fd => 
        for (d in data) {
            if(started.value){
                fd.next(d[1], '')
            }else{
                fd.start(d[1])
                started.value = true
            }
            let buf = Array<Byte>(1024, repeat: 0)
            while(let bytes <- d[0].read(buf) && bytes > 0){
                fd.write(buf)
            }
        }
        fd.end()
    }
}

public func download(data: Array<File>): Unit {
    FileDownload(multi: true).write{fd => 
        for(i in 0 .. data.size){
            let f = data[i]
            if(i == 0){
                fd.start(f.info.name, length: f.info.size)
            }else{
                fd.next(f.info.name, '', length: f.info.size)
            }
            let buf = Array<Byte>(1024, repeat: 0)
            while(let bytes <- f.read(buf) && bytes > 0){
                fd.write(buf)
            }
        }
        fd.end()
    }
}
