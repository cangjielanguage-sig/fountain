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
package f_io

import std.io.*
import std.fs.*
import std.sync.Timer
import std.time.MonoTime

import f_base.*
import f_io.exception.MMapException

/*
#define PROT_READ   0x1
#define PROT_WRITE  0x2
#define PROT_EXEC   0x4
#define PROT_NONE   0x0
#define MAP_SHARED  0x01
#define MAP_PRIVATE 0x02
#define MAP_FIXED   0x10
#define MAP_ANONYMOUS 0x20
MS_SYNC
MS_ASYNC
MS_INVALIDATE

#define MS_ASYNC        0x0001          /* sync memory asynchronously */
#define MS_INVALIDATE   0x0002          /* invalidate mappings & caches */
#define MS_SYNC         0x0004          /* synchronous memory sync */

  void *mmap(void *start, size_t length, int prot, int flags, int fd, off_t offset);
    int munmap(void *start, size_t length);
    int msync(void *addr, size_t length, int flags);
  
*/
private const PROT_READ: IntNative = 0x1
private const PROT_WRITE: IntNative = 0x2
private const PROT_EXEC: IntNative = 0x4
private const PROT_NONE: IntNative = 0x0
private const MAP_SHARED: IntNative = 0x01
private const MAP_PRIVATE: IntNative = 0x02
//private const MAP_FIXED: IntNative = 0x10
private const MAP_ANONYMOUS: IntNative = 0x20
private const MS_SYNC: IntNative = 0x0004
private const MS_ASYNC: IntNative = 0x001
private const MS_INVALIDATE: IntNative = 0x002

foreign {
    func mmap(start: CPointer<Unit>, length: UIntNative, prot: IntNative, flags: IntNative, fd: IntNative, offset: IntNative): CPointer<Unit>
    func munmap(start: CPointer<Unit>, length: UIntNative): IntNative
    func msync(addr: CPointer<Unit>, length: UIntNative, flags: IntNative): IntNative
}
public enum MMapProt {
    | Read
    | Write
    | Exec
    | None

    public prop value: IntNative {
        get(){
            match (this) {
                case Read => PROT_READ
                case Write => PROT_WRITE
                case Exec => PROT_EXEC
                case None => PROT_NONE
            }
        }
    }
    public operator func |(other: MMapProt): Array<MMapProt> {
        [this, other]
    }
    public operator func |(others: Array<MMapProt>): Array<MMapProt> {
        Array<MMapProt>(others.size + 1){i => 
            if(i == 0){
                this
            }else{
                others[i-1]
            }
        }
    }
}
public interface MMapProtArray {
    operator func |(other: MMapProt): Array<MMapProt>
    operator func |(others: Array<MMapProt>): Array<MMapProt>
    func combine(): IntNative
}
extend Array<MMapProt> <: MMapProtArray {
    public operator func |(other: MMapProt): Array<MMapProt> {
        Array<MMapProt>(this.size + 1){i =>
            if(i < this.size){
                this[i]
            }else{
                other
            }
        }
    }
    public operator func |(others: Array<MMapProt>): Array<MMapProt> {
        Array<MMapProt>(this.size + others.size){i =>
            if(i < this.size){
                this[i]
            }else{
                others[i - this.size]
            }
        }
    }
    public func combine(): IntNative {
        var res: IntNative = 0
        for (prot in this) {
            res |= prot.value
        }
        return res
    }
}
public enum MMapFlag {
    | Shared
    | Private
//    | Fixed
    | Anonymous

    public prop value: IntNative {
        get(){
            match (this) {
                case Shared => MAP_SHARED
                case Private => MAP_PRIVATE
//                case Fixed => MAP_FIXED
                case Anonymous => MAP_ANONYMOUS
            }
        }
    }
}
public enum MSyncFlag {
    | Sync
    | Async
    | Invalidate

    public prop value: IntNative {
        get(){
            match (this) {
                case Sync => MS_SYNC
                case Async => MS_ASYNC
                case Invalidate => MS_INVALIDATE
            }
        }
    }
}
private let NULL_POINTER = CPointer<Unit>()
/**
 * 默认映射字节数
 */
public const DEFAULT_MMAP_BYTES = 1 * 1024 * 1024 * 1024
/**
 * 内存映射文件，本类没有做并发安全处理
 */
public class MMapFile <: Resource & IOStream {
    private let fd: IntNative
    private var writePointer = NULL_POINTER
    private var readPointer = NULL_POINTER
    private var readOffset_ = 0i64
    private var writeOffset_ = 0i64
    private var readStart = 0i64
    private var writeStart = 0i64
    private var dirtyStart = 0i64// 脏数据起始位置，相对于文件开头是offset + dirtyStart
    private var dirtyBytes = 0i64// 脏数据大小
    private var lastSync = MonoTime.now()
    private var syncTimer: Timer = ZERO_TIMER
    private var factReadMapLength = 0i64
    public MMapFile(
        private let file: File,
        private let prots: Array<MMapProt>,
        private let offset!: Int64 = 0,
        private let mapLength!: Int64 = DEFAULT_MMAP_BYTES,
        private let syncBytes!: Int64 = DEFAULT_MMAP_BYTES,
        private let syncDuration!: Duration = Duration.second
    ){
        this.fd = file.fileDescriptor.fileHandle
        factReadMapLength = if(file.length < offset + mapLength){
            file.length - offset
        }else{
            mapLength
        }
        readStart = offset
        writeStart = offset
        writePointer = map(offset, mapLength)
        readPointer = map(offset, factReadMapLength)
        syncTimer = Timer.repeat(syncDuration, syncDuration, {=>
            try{
                sync()
            }catch(e: Exception){
                e.printStackTrace()
            }
        })
    }
    public func isClosed(){
        file.isClosed()
    }
    private func map(offset: Int64, length: Int64){
        unsafe{
            mmap(NULL_POINTER, UIntNative(length), prots.combine(), MMapFlag.Shared.value, fd, IntNative(offset))
        }
    }
    private func unmap(pointer: CPointer<Unit>, length: Int64){
        if(pointer.toUIntNative() != NULL_POINTER.toUIntNative()){
            unsafe{
                let pr = pointer.asResource()
                munmap(pointer, UIntNative(length))
                if(!pr.isClosed()){
                    pr.close()
                }
            }
        }
    }
    private func sync(pointer: CPointer<Unit>, length: Int64){
        unsafe{
            msync(pointer + dirtyStart, UIntNative(length), MSyncFlag.Sync.value)
        }
    }
    public func sync(){
        if(dirtyBytes > 0){
            sync(writePointer, dirtyBytes)
            lastSync = MonoTime.now()
            dirtyStart += dirtyBytes
            dirtyBytes = 0
        }
    }
    private func extract(ex: ?MMapException, caused: Exception){
        match(ex){
            case Some(e) => e.addSuppressed(caused)
                e
            case _ => MMapException(caused)
        }
    }
    /**
     * 相对文件开头的读偏移量
     */
    public prop readOffset: Int64 {
        get(){
            readStart + readOffset_
        }
    }
    /**
     * 相对文件开头的写偏移量
     */
    public prop writeOffset: Int64 {
        get(){
            writeStart + writeOffset_
        }
    }
    public func close(){
        syncTimer.cancel()
        var ex = None<MMapException>
        try{
            sync()
        }catch(e: Exception){
            ex = extract(ex, e)
        }
        try{
            unmap(writePointer, mapLength)
        }catch(e: Exception){
            ex = extract(ex, e)
        }
        try{
            unmap(readPointer, mapLength)
        }catch(e: Exception){
            ex = extract(ex, e)
        }
        try{
            file.close()
        }catch(e: Exception){
            ex = extract(ex, e)
        }
        if(let Some(e) <- ex){
            throw e
        }
    }
    public prop length: Int64 {
        get(){
            file.length
        }
    }
    /**
     * seek 时如果允许映射同步到磁盘，会先同步数据再创建新映射，新的映射指针指向seek参数指定的偏移量。
     * offset 是从当前打开文件开头的偏移量，文件也会跟随执行seek偏移
     * length 是新的映射内存字节数
     */
    public func seekWrite(offset: Int64): Unit {
        sync()
        if(offset + mapLength > this.length){
            file.seek(Begin(offset + mapLength - 1))
            file.write([b'0'])//必须写入一字节长度才会真的改变
            file.flush()
        }
        unmap(writePointer, this.mapLength)
        file.seek(Begin(offset))
        writeStart = offset
        writePointer = map(offset, mapLength)
        writeOffset_ = 0
    }
    public func seekRead(offset: Int64): Unit {
        let len = 
        if(offset > this.length){
            throw MMapException('offset exceeds file size, offset: ${offset}')
        }else if(offset + mapLength > this.length){
            this.length - offset
        }else{
            mapLength
        }
        unmap(readPointer, this.factReadMapLength)
        factReadMapLength = len
        readStart = offset
        readPointer = map(offset, len)
        readOffset_ = 0
    }
    public func read(buffer: Array<Byte>): Int64 {
        let bs = buffer.size
        if(readOffset_ + bs > this.factReadMapLength){
            seekRead(offset + readOffset_)
            read(buffer)
        }else{
            let len =
            if(bs < factReadMapLength){
                bs
            }else{
                factReadMapLength
            }
            unsafe{
                let bp = CPointer<UInt8>(readPointer) + readOffset_
                for(i in 0 .. len){
                    buffer[i] = bp.read(i)
                    readOffset_++
                }
                len
            }
        }
    }
    public func write(buffer: Array<Byte>): Unit {
        let bs = buffer.size
        if(bs == 0){
            return
        }else if(writeOffset_ + bs > mapLength){
            seekWrite(offset + writeOffset_)
            writeOffset_ = 0
        }
        unsafe{
            let bp = CPointer<UInt8>(writePointer) + writeOffset_
            for(i in 0 .. bs){
                bp.write(i, buffer[i])
                writeOffset_++
                dirtyBytes++
            }
        }
        if(dirtyBytes > syncBytes){
            sync()
        }
    }
}

public interface ToMMap {
    /**
     * 用此函数创建的内存映射文件只有读写两个prot，与当前File实例的可读可写属性一致
     */
    func mmap(offset: Int64, mapLength: Int64, syncBytes!: Int64, syncDuration!: Duration): MMapFile
}
extend File <: ToMMap {
    public func mmap(offset: Int64, mapLength: Int64, 
                     syncBytes!: Int64 = DEFAULT_MMAP_BYTES, syncDuration!: Duration = Duration.second): MMapFile {
        let prots = if(this.canRead() && this.canWrite()){
            [MMapProt.Read, MMapProt.Write]
        }else if(this.canRead()){
            [MMapProt.Read]
        }else if(this.canWrite()){
            [MMapProt.Write]
        }else{
            throw IOException("file ${canonicalize(this.info.path)} cannot be read and written")
        }
        MMapFile(this, prots, offset: offset, mapLength: mapLength, syncBytes: syncBytes, syncDuration: syncDuration)
    }
}