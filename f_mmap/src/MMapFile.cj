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
package f_mmap

import std.convert.Parsable
import std.io.*
import std.fs.*
import std.process.executeWithOutput
import std.sync.Timer
import std.time.MonoTime
import f_base.*
import f_mmap.exception.MMapException

/**
 * 本包仅支持linux
 */
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
@When[os != "Windows"]
private const PROT_READ: IntNative = 0x1
@When[os != "Windows"]
private const PROT_WRITE: IntNative = 0x2
@When[os != "Windows"]
private const PROT_EXEC: IntNative = 0x4
@When[os != "Windows"]
private const PROT_NONE: IntNative = 0x0
@When[os != "Windows"]
private const MAP_SHARED: IntNative = 0x01
@When[os != "Windows"]
private const MAP_PRIVATE: IntNative = 0x02
// @When[os != "Windows"]
//private const MAP_FIXED: IntNative = 0x10
@When[os != "Windows"]
private const MAP_ANONYMOUS: IntNative = 0x20
@When[os != "Windows"]
private const MS_SYNC: IntNative = 0x0004
@When[os != "Windows"]
private const MS_ASYNC: IntNative = 0x001
@When[os != "Windows"]
private const MS_INVALIDATE: IntNative = 0x002

@When[os != "Windows"]
foreign {
    func mmap(start: CPointer<Unit>, length: UIntNative, prot: IntNative, flags: IntNative, fd: IntNative,
        offset: IntNative): CPointer<Unit>

    func munmap(start: CPointer<Unit>, length: UIntNative): IntNative

    func msync(addr: CPointer<Unit>, length: UIntNative, flags: IntNative): IntNative
}
@When[os != "Windows"]
public enum MMapProt {
    | Read
    | Write
    | Exec
    | None

    public prop value: IntNative {
        get() {
            match (this) {
                case Read => PROT_READ
                case Write => PROT_WRITE
                case Exec => PROT_EXEC
                case None => PROT_NONE
            }
        }
    }
    operator func &(prot: IntNative): Bool {
        (this.value & prot) != 0
    }
    public operator func |(other: MMapProt): Array<MMapProt> {
        [this, other]
    }
    public operator func |(others: Array<MMapProt>): Array<MMapProt> {
        Array<MMapProt>(others.size + 1) {
            i => if (i == 0) {
                this
            } else {
                others[i - 1]
            }
        }
    }
}
@When[os != "Windows"]
public interface MMapProtArray {
    operator func |(other: MMapProt): Array<MMapProt>
    operator func |(others: Array<MMapProt>): Array<MMapProt>
    func combine(): IntNative
}
@When[os != "Windows"]
extend Array<MMapProt> <: MMapProtArray {
    public operator func |(other: MMapProt): Array<MMapProt> {
        Array<MMapProt>(this.size + 1) {
            i => if (i < this.size) {
                this[i]
            } else {
                other
            }
        }
    }
    public operator func |(others: Array<MMapProt>): Array<MMapProt> {
        Array<MMapProt>(this.size + others.size) {
            i => if (i < this.size) {
                this[i]
            } else {
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
@When[os != "Windows"]
public enum MMapFlag <: Equatable<MMapFlag> & Equatable<IntNative> {
    | Shared
    | Private
    // | Fixed
    | Anonymous

    public prop value: IntNative {
        get() {
            match (this) {
                case Shared => MAP_SHARED
                case Private => MAP_PRIVATE
                // case Fixed => MAP_FIXED
                case Anonymous => MAP_ANONYMOUS
            }
        }
    }
    public operator func ==(other: MMapFlag): Bool {
        this == other.value
    }
    public operator func ==(other: IntNative): Bool {
        this.value == other
    }
    public prop isShared: Bool {
        get() {
            this == Shared
        }
    }
    public prop isPrivate: Bool {
        get() {
            this == Private
        }
    }
    public prop isAnonymous: Bool {
        get() {
            this == Anonymous
        }
    }
}
@When[os != "Windows"]
public enum MSyncFlag {
    | Sync
    | Async
    | Invalidate

    public prop value: IntNative {
        get() {
            match (this) {
                case Sync => MS_SYNC
                case Async => MS_ASYNC
                case Invalidate => MS_INVALIDATE
            }
        }
    }
}

/**
 * 默认映射字节数
 */
@When[os != "Windows"]
public const DEFAULT_MMAP_BYTES = 1 * 1024 * 1024 * 1024
/**
 * 内存映射文件，本类没有做并发安全处理
 * 写映射区每次重定位都是mapLength大小
 * 读映射区每次重定位按照mapLength和this.length - offset的大小动态决定
 * 如果file是zeroValue<File>()，按照Anonymous初始化，且offset不生效。
 * 如果file不是zeroValue<File>()，且file.length - offset < mapLength, 文件又以只读方式打开，会抛出异常；此时如果文件可写会自动延长文件长度
 */
@When[os != "Windows"]
public class MMapFile <: Resource & IOStream {
    private static let zeroFile = unsafe{zeroValue<File>()}
    private static let ANONYMOUS_FD = IntNative(-1)
    private let fd: IntNative
    private let pointer: CPointer<Unit>
    private var readOffset_ = 0i64
    private var writeOffset_ = 0i64
    private var dirtyStart = 0i64 // 脏数据起始位置，相对于文件开头是offset + dirtyStart
    private var dirtyBytes = 0i64 // 脏数据大小
    private let readable_: Bool
    private let writable_: Bool
    private var closed = false
    MMapFile(
        private let file: File,
        private let prots: Array<MMapProt>,
        private let flag!: MMapFlag = MMapFlag.Private,
        private let offset!: Int64 = 0,
        private let mapLength!: Int64 = DEFAULT_MMAP_BYTES
    ) {
        let protBits = prots.combine()
        readable_ = MMapProt.Read & protBits
        writable_ = MMapProt.Write & protBits
        let flags: IntNative
        (this.fd, flags) = if (!isZeroFile(file)) {
            if (offset + mapLength > file.length && writable_) {
                file.seek(Begin(offset + mapLength - 1))
                file.write([b'0']) //必须写入一字节长度才会真的改变
                file.flush()
            }else{
                throw MMapException('file ${file.info.path} is not writable but the file length - offset(${file.length} - ${offset}) is less than mapLength ${mapLength}')
            }
            (file.fileDescriptor.fileHandle, flag.value)
        } else {
            (ANONYMOUS_FD, flag.value | MMapFlag.Anonymous.value)
        }
        pointer = unsafe {
            mmap(nullptr, UIntNative(mapLength), protBits, flags, fd,
                if (fd == ANONYMOUS_FD) {
                    0
                } else {
                    IntNative(offset)
                })
        }
    }
    public static func anonymous(prots: Array<MMapProt>, flag!: MMapFlag = MMapFlag.Private, mapLength!: Int64 = DEFAULT_MMAP_BYTES){
        MMapFile(zeroFile, prots, flag: flag, mapLength: mapLength)
    }
    private static func isZeroFile(file: File) {
        refEq(file, zeroFile)
    }
    private func isNullPointer(pointer: CPointer<Unit>) {
        pointer.toUIntNative() == nullptr.toUIntNative()
    }
    public prop isReadable: Bool {
        get() {
            readable_
        }
    }
    public prop isWritable: Bool {
        get() {
            writable_
        }
    }
    public prop isSyncable: Bool {
        get() {
            !(this.flag.isPrivate || this.isAnonymous)
        }
    }
    public prop isAnonymous: Bool {
        get(){
            this.fd == ANONYMOUS_FD
        }
    }
    /**
     * 同步内存映射区域到磁盘，取消映射，不关闭文件
     */
    public func syncAndUnmap(): Unit {
        sync()
        unmap()
    }
    private func unmap() {
        unsafe {
            let pr = pointer.asResource()
            munmap(pointer, UIntNative(mapLength))
            try {
                if (!pr.isClosed()) {
                    pr.close()
                }
            } catch (_) {}
        }
    }
    
    /**
     * 使用指定的flag将未同步数据同步到磁盘。
     */
    public func sync(flag: MSyncFlag) {
        if (!isSyncable) {
            throw MMapException("current mmap can not sync, due to it is Anonymous or Private.")
        }
        unsafe {
            let syncStart = (dirtyStart / MEM_PAGE_SIZE) * MEM_PAGE_SIZE
            msync(pointerOffset(syncStart), UIntNative(dirtyBytes + dirtyStart % MEM_PAGE_SIZE), flag.value)
        }
    }
    private func sync(pointer: CPointer<Unit>, length: Int64) {
        sync(MSyncFlag.Sync)
    }
    private func sync() {
        if (dirtyBytes > 0 && isSyncable) {
            sync(pointer, dirtyBytes)
            dirtyStart += dirtyBytes
            dirtyBytes = 0
        }
    }
    private func extract(ex: ?MMapException, caused: Exception) {
        match (ex) {
            case Some(e) =>
                e.addSuppressed(caused)
                e
            case _ => MMapException(caused)
        }
    }
    /**
     * 使用指定参数重映射。offset是文件开头的偏移量。mapLength是映射的内存大小，默认是当前的mapLength
     */
    public func remap(offset: Int64, mapLength!: Int64 = this.mapLength, flag!: MMapFlag = this.flag): MMapFile {
        sync()
        unmap()
        if (isAnonymous) {
            MMapFile(file, prots, flag: flag, offset: offset, mapLength: mapLength)
        } else {
            file.mmap(offset, mapLength, flag: flag)
        }
    }
    /**
     * 相对文件开头的读偏移量
     */
    public prop readOffset: Int64 {
        get() {
            offset + readOffset_
        }
    }
    /**
     * 相对文件开头的写偏移量
     */
    public prop writeOffset: Int64 {
        get() {
            offset + writeOffset_
        }
    }
    public func isClosed() {
        closed
    }
    /**
     * 同步内存映射区域到磁盘，取消映射，关闭文件
     */
    public func close() {
        closed = true
        var ex = None<MMapException>
        try {
            sync()
        } catch (e: Exception) {
            ex = extract(ex, e)
        }
        try {
            unmap()
        } catch (e: Exception) {
            ex = extract(ex, e)
        }
        try {
            if (!isAnonymous) {
                file.close()
            }
        } catch (e: Exception) {
            ex = extract(ex, e)
        }
        if (let Some(e) <- ex) {
            throw e
        }
    }
    /**
     * 映射内存的大小
     */
    public prop length: Int64 {
        get() {
            mapLength
        }
    }
    private func checkWritable() {
        if (!isWritable) {
            if (isAnonymous) {
                throw MMapException('current MMapFile is not writable and it is Anonymous')
            }
            throw MMapException('current MMapFile is not writable ${file.info.path}')
        }
    }
    private func checkReadable() {
        if (!isReadable) {
            if (isAnonymous) {
                throw MMapException('current MMapFile is not readable and it is Anonymous')
            }
            throw MMapException('current MMapFile is not readable ${file.info.path}')
        }
    }
    private unsafe func pointerOffset(offset: Int64) {
        CPointer<Unit>(CPointer<Byte>(this.pointer) + offset)
    }
    private func opsize(size: Int64, offset: Int64, len: Int64) {
        if (let s <- len - offset && s < size) {
            s
        } else {
            size
        }
    }
    /**
     * 返回值是当前映射的内存区域min(剩余可读字节数, buffer.size)
     */
    public func read(buffer: Array<Byte>): Int64 {
        checkReadable()
        let size = opsize(buffer.size, readOffset_, if (isWritable) {
            writeOffset_
        } else {
            mapLength
        })
        if (size == 0) {
            return 0
        }
        unsafe {
            let bufferAddr = acquireArrayRawData(buffer)
            let bufferPtr = bufferAddr.pointer
            memcopy(CPointer<Unit>(bufferPtr), pointerOffset(readOffset_), UIntNative(size))
            releaseArrayRawData(bufferAddr)
        }
        readOffset_ += size
        size
    }
    /**
     * 如果映射的内存区域剩余可写字节数小于buffer.size会抛出异常
     */
    public func write(buffer: Array<Byte>): Unit {
        checkWritable()
        let size = opsize(buffer.size, writeOffset_, mapLength)
        if (size < buffer.size) {
            throw MMapException("remainder mmapped size is too small, remainder: ${size}, buffer.size: ${buffer.size}")
        }
        unsafe {
            let bufferAddr = acquireArrayRawData(buffer)
            let bufferPtr = bufferAddr.pointer
            memcopy(pointerOffset(writeOffset_), CPointer<Unit>(bufferPtr), UIntNative(size))
            releaseArrayRawData(bufferAddr)
        }
        writeOffset_ += size
        size
    }
    /**
     * 使用MSyncFlag.Sync将未同步数据同步到磁盘，如果当前映射是Anonmous则抛出异常
     */
    public func flush(): Unit {
        sync()
    }
}
@When[os != "Windows"]
public interface ToMMap {
    /**
     * 用此函数创建的内存映射文件只有读写两个prot，与当前File实例的可读可写属性一致。File扩展此接口
     */
    func mmap(offset: Int64, mapLength: Int64, flag!: MMapFlag): MMapFile
}
@When[os != "Windows"]
extend File <: ToMMap {
    public func mmap(offset: Int64, mapLength: Int64, flag!: MMapFlag = MMapFlag.Private): MMapFile {
        let prots = if (this.canRead() && this.canWrite()) {
            [MMapProt.Read, MMapProt.Write]
        } else if (this.canRead()) {
            [MMapProt.Read]
        } else if (this.canWrite()) {
            [MMapProt.Write]
        } else {
            throw IOException("file ${canonicalize(this.info.path)} cannot be read and written")
        }
        MMapFile(this, prots, offset: offset, mapLength: mapLength, flag: flag)
    }
}
