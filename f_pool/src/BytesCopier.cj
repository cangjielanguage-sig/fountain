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
package fountain::f_pool

import std.io.{InputStream, OutputStream}

public interface BytesCopyTo {
    func copy(to!: OutputStream, closeFromOnEnd!: Bool, closeToOnEnd!: Bool): Unit
    /** 待写字节数；未知（含流式内容）返回 None。 */
    func byteSize(): ?Int64 {
        None<Int64>
    }
    /** 把待写内容整体取出；不支持（含流式内容）返回 None。 */
    func asBytes(): ?Array<Byte> {
        None<Array<Byte>>
    }
}
public interface BytesCopyFrom {
    func copy(from!: InputStream, closeFromOnEnd!: Bool, closeToOnEnd!: Bool): Unit
}

public interface BytesCopier <: BytesCopyTo & BytesCopyFrom {}

/** 可显式释放（归还其内部池项）的资源。实现必须**幂等**。 */
public interface Releasable {
    func release(): Unit
}

public struct PooledBufferBytesCopyTo <: BytesCopyTo { 
    public PooledBufferBytesCopyTo(private let input: InputStream,
                                    private let pool: ArrayPool<Byte>,
                                    private let declaredSize!: Int64 = -1){}
    /** 待写字节数：流式内容本身不可数，但调用方声明过长度时可知（帧的 len 字段需要它）。 */
    public func byteSize(): ?Int64 {
        if (declaredSize >= 0) {
            declaredSize
        } else {
            None<Int64>
        }
    }
    public func copy(to!: OutputStream, closeFromOnEnd!: Bool = true, closeToOnEnd!: Bool = false): Unit {
        func copyTo(buf: Array<Byte>){
            try{
                while(let s <- input.read(buf) && s > 0){
                    to.write(buf[0..s])
                }
            }finally{
                if(closeFromOnEnd && let r: Resource <- input && !r.isClosed()){
                    r.close()
                }
                if(closeToOnEnd && let r: Resource <- to && !r.isClosed()){
                    r.close()
                }
            }
        }
        if(let Some(buf) <- pool.get()){
            try{
                copyTo(buf)
            }finally{
                pool.giveBack(buf)
            }
        }else{
            let buf = Array<Byte>(4096, repeat: 0)
            copyTo(buf)
        }
    }
}
public struct PooledBufferedBytesCopyFrom <: BytesCopyFrom {
    public PooledBufferedBytesCopyFrom(private let output: OutputStream,
                                        private let pool: ArrayPool<Byte>,
                                        private let closeOnEnd!: Bool = true){}
    public func copy(from!: InputStream, closeFromOnEnd!: Bool = false, closeToOnEnd!: Bool = true): Unit {
        func copyTo(buf: Array<Byte>){
            try{
                while(let s <- from.read(buf) && s > 0){
                    output.write(buf[0..s])
                }
            }finally{
                if(closeToOnEnd && let r: Resource <- output && !r.isClosed()){
                    r.close()
                }
                if(closeFromOnEnd && let r: Resource <- from && !r.isClosed()){
                    r.close()
                }
            }
        }
        if(let Some(buf) <- pool.get()){
            try{
                copyTo(buf)
            }finally{
                pool.giveBack(buf)
            }
        }else{
            copyTo(Array<Byte>(4096, repeat: 0))
        }
    }
}
public struct ChainedBytesCopyTo <: BytesCopyTo & Releasable {
    public ChainedBytesCopyTo(private let bytes: Array<BytesCopyTo>){}
    public func copy(to!: OutputStream, closeFromOnEnd!: Bool = true, closeToOnEnd!: Bool = false): Unit {
        for(b in bytes){
            b.copy(to: to, closeFromOnEnd: closeFromOnEnd, closeToOnEnd: false)
        }
        if(closeToOnEnd && let r: Resource <- to && !r.isClosed()){
            r.close()
        }
    }
    /** 待写字节数：任一子项未知则整体未知。 */
    public func byteSize(): ?Int64 {
        var total = 0i64
        for (b in bytes) {
            if (let Some(n) <- b.byteSize()) {
                total += n
            } else {
                return None<Int64>
            }
        }
        total
    }
    /** 整体取出：任一子项不支持则整体不支持。 */
    public func asBytes(): ?Array<Byte> {
        if (let Some(n) <- byteSize()) {
            let out = Array<Byte>(n, repeat: 0u8)
            var off = 0i64
            for (b in bytes) {
                if (let Some(part) <- b.asBytes()) {
                    for (i in 0..part.size) {
                        out[off + i] = part[i]
                    }
                    off += part.size
                } else {
                    return None<Array<Byte>>
                }
            }
            out
        } else {
            None<Array<Byte>>
        }
    }
    /** 释放所有子项占用的池项（幂等）。 */
    public func release(): Unit {
        for(b in bytes){
            if(let r: Releasable <- b){
                r.release()
            }
        }
    }
}