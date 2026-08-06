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
package fountain::f_io

import std.io.{IOStream, SeekPosition, IOException}
import std.sync.{Mutex, Condition, AtomicBool}
import fountain::f_io.exception.SeekException

public class ByteBuffer <: IOStream {
    private let buffer: Array<Byte>
    private var woffset: Int64 = 0
    private var roffset: Int64 = 0

    public ByteBuffer(
        initialCapacity!: Int64 = 32,
        public let toOverwriteOnClearing!: Bool = false
    ){
        buffer = Array<Byte>(initialCapacity, repeat: 0)
    }

    public init(
        array: Array<Byte>,
        toOverwriteOnClearing!: Bool = false
    ){
        this(initialCapacity: array.size, toOverwriteOnClearing: toOverwriteOnClearing)
        write(array)
    }
    public prop writeOffset: Int64 {
        get(){
            woffset
        }
    }
    public prop readOffset: Int64 {
        get(){
            roffset
        }
    }
    public prop capacity: Int64 {
        get() {
            return buffer.size
        }
    }
    public func bytes(): Array<Byte> {
        buffer[roffset..woffset]
    }
    public func clear(): Unit {
        if (toOverwriteOnClearing){
            buffer[0..woffset].fill(0)
        }
        woffset = 0
        roffset = 0
    }
    public func clone(): ByteBuffer {
        let buffer = ByteBuffer(buffer, toOverwriteOnClearing: toOverwriteOnClearing)
        buffer.roffset = roffset
        buffer.woffset = woffset
        buffer
    }
    private func copy(src: Array<Byte>, dst: Array<Byte>, srcOffset: Int64, dstOffset: Int64, length: Int64){
        src.copyTo(dst, srcOffset, dstOffset, length)
        roffset = 0
        woffset = length
    }
    public func reserve(addition: Int64): Unit {
        if(addition <= 0){
            return
        }
        if(addition + woffset - roffset <= buffer.size){
            copy(buffer, buffer, roffset, 0, woffset - roffset)
        }else{
            let tmp = Array<Byte>(buffer.size + addition, repeat: 0)
            copy(buffer, tmp, roffset, 0, woffset - roffset)
            buffer = tmp
        }
    }
    private func seek(start: Int64, offset: Int64, min: Int64, max: Int64){
        if(let new <- start + offset && new >= min && new <= max){
            new
        }else{
            throw SeekException('${offset} is out of buffer range')
        }
    }
    public func seekReading(pos: SeekPosition): Unit {
        match(pos) {
            case Begin(offset) => roffset = seek(0, offset, 0, woffset)
            case Current(offset) => roffset = seek(roffset, offset, 0, woffset)
            case End(offset) => roffset = seek(buffer.size, offset, 0, woffset)
        }
    }
    public func seekWriting(pos: SeekPosition): Unit {
        match(pos) {
            case Begin(offset) => woffset = seek(0, offset, roffset, buffer.size)
            case Current(offset) => woffset = seek(woffset, offset, roffset, buffer.size)
            case End(offset) => woffset = seek(buffer.size, offset, roffset, buffer.size)
        }
    }
    public func readByte(): ?Byte{
        if(roffset < woffset) {
            let b = buffer[roffset]
            roffset ++
            b
        }else{
            clear()
            None<Byte>
        }
    }
    public func read(buf: Array<Byte>): Int64 {
        if(roffset == woffset){
            return 0
        }
        let bytes = if(let b <- woffset - roffset && b <= buf.size){
            b
        }else{
            buf.size
        }
        copy(buffer, buf, roffset, 0, bytes)
        if(bytes < buf.size){
            clear()
        }
        bytes
    }
    public func writeByte(b: Byte): Unit {
        if(woffset >= buffer.size){
            reserve(buffer.size / 2)
        }
        buffer[woffset] = b
        woffset++
    }
    public func write(buf: Array<Byte>): Unit {
        if(woffset + buf.size >= buffer.size) {
            reserve(buf.size + buffer.size / 2)
        }
        copy(buf, buffer, 0, woffset, buf.size)
        woffset += buf.size
    }
    public func flush(): Unit {}
}

public class SyncByteBuffer <: IOStream {
    private let mutex = Mutex()
    private let condition = synchronized(mutex){mutex.condition()}
    private let buffer: ByteBuffer
    private let end_ = AtomicBool(false)
    
    public init(
        initialCapacity!: Int64 = 32,
        toOverwriteOnClearing!: Bool = false
    ){
        buffer = ByteBuffer(initialCapacity: initialCapacity, toOverwriteOnClearing: toOverwriteOnClearing)
    }
    public init(
        array: Array<Byte>,
        toOverwriteOnClearing!: Bool = false
    ){
        buffer = ByteBuffer(array, toOverwriteOnClearing: toOverwriteOnClearing)
    }
    public prop writeOffset: Int64 {
        get(){
            synchronized(mutex){buffer.writeOffset}
        }
    }
    public prop readOffset: Int64 {
        get(){
            synchronized(mutex){buffer.readOffset}
        }
    }
    public unsafe func bytes(): Array<Byte> {
        buffer.bytes()
    }
    public func clear(): Unit {
        synchronized(mutex){
            buffer.clear()
        }
    }
    public func clone(): ByteBuffer {
        synchronized(mutex){
            buffer.clone()
        }
    }
    public func reserve(addition: Int64): Unit {
        synchronized(mutex){
            buffer.reserve(addition)
        }
    }
    public func seekReading(pos: SeekPosition): Unit {
        synchronized(mutex){ 
            buffer.seekReading(pos)
        }
    }
    public func seekWriting(pos: SeekPosition): Unit {
        synchronized(mutex){ 
            buffer.seekWriting(pos)
        }
    }
    public func readByte(): ?Byte{
        readByte(Duration.Zero)
    }
    public func readByte(timeout: Duration): ?Byte {
        var waited = false
        synchronized (mutex) {
            while (let b <- buffer.readByte()) {
                if (b.isSome()) {
                    return b
                } else if (!end_.load() && !waited) {
                    condition.wait(timeout: timeout)
                    waited = true
                } else {
                    return None<Byte>
                }
            }
            None<Byte>
        }
    }
    public func read(buf: Array<Byte>, timeout: Duration): ?Int64 {
        var waited = false
        synchronized (mutex) {
            while (let bytes <- buffer.read(buf)) {
                if (bytes > 0) {
                    return bytes
                } else if (!end_.load()) {
                    if(timeout == Duration.Zero || waited){
                        return None<Int64>
                    }
                    condition.wait(timeout: timeout)
                    waited = true
                } else {
                    return 0
                }
            }
            0
        }
    }
    public func read(buf: Array<Byte>): Int64 {
        read(buf, Duration.Zero) ?? 0
    }
    public func writeByte(b: Byte): Unit {
        synchronized(mutex){ 
            buffer.writeByte(b)
            condition.notify()
        }
    }
    public func write(bytes: Array<Byte>): Unit {
        synchronized(mutex){ 
            buffer.write(bytes)
            condition.notify()
        }
    }
    public func flush(): Unit {}
    public func end(): Unit {
        synchronized(mutex){ 
            end_.store(true)
            condition.notify()
        }
    }
    public func batch(fn: (ByteBuffer) -> Unit): Unit {
        synchronized(mutex){
            fn(buffer)
        }
    }
}