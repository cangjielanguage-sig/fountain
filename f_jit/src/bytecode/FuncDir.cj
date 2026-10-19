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
package fountain::f_jit.bytecode

import std.collection.ArrayList
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.Version

/**
 * 函数目录 —— design-m1 §3.3.4、plan-m1 S2.4 / S2.5。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.7：
 *
 * ```
 * FuncDir   { count: u32, funcs: [FuncEntry] }
 * FuncEntry = { fnId: u32, codeOff: u32, codeLen: u32, localTypesOff: u32,
 *               nargs: u16, nLocals: u16, maxStack: u16, retType: u16, flags: u16 }   // 恒 26 B
 * ```
 *
 * `codeOff / codeLen / localTypesOff` 均相对 **code 段起点**（故目录、局部类型表与函数体同处
 * code 段，一并纳入 crc32，§11.7 末句）。`frameSize` 由 §3.1 公式在加载期算出，不进目录。
 */

/** `FuncEntry.flags` 的取值域（design-m1 §3.3.4：只放常量的命名空间类，design D3）。 */
public class FuncFlags {
    /**
     * bit0 = 函数含变更型 helper（H43–H48）/ 预定义 helper（user helper，§8.4）/
     * `CALL_CLOSURE`（§8.6）调用（§11.7）。
     *
     * 桥的**防御性 DEOPT 检查依据**（§9.15③）：含变更型调用的函数重放会把容器变更执行两遍，
     * 故汇编期禁用 deopt 源，加载期据此标记。
     */
    public static const MUTATION: UInt16 = 1u16
}

/**
 * 函数目录条目，恒 26 B。
 *
 * 用 `struct`：定长只读目录项、值语义、无身份，目录内连续存储（design-m1 §3.3.4）。
 */
public struct FuncEntry {
    /** 函数 id（`CALL_FUNC` 目标；单元内唯一）。 */
    public let fnId: UInt32
    /** 函数体相对 code 段起点的字节偏移。 */
    public let codeOff: UInt32
    /** 函数体字节长度。 */
    public let codeLen: UInt32
    /** 该函数的局部类型表相对 code 段起点的字节偏移。 */
    public let localTypesOff: UInt32
    /** 形参个数（= 参数槽个数 `locals[0..nargs-1]`）。 */
    public let nargs: UInt16
    /** 局部槽总数。 */
    public let nLocals: UInt16
    /** 操作数栈最大深度（帧计算，§3.1）。 */
    public let maxStack: UInt16
    /** 返回类型（`LocalType` 编码，合法值 0–12，§11.7）。 */
    public let retType: UInt16
    /** `FuncFlags` 位域。 */
    public let flags: UInt16

    public init(
        fnId: UInt32,
        codeOff: UInt32,
        codeLen: UInt32,
        localTypesOff: UInt32,
        nargs: UInt16,
        nLocals: UInt16,
        maxStack: UInt16,
        retType: UInt16,
        flags: UInt16
    ) {
        this.fnId = fnId
        this.codeOff = codeOff
        this.codeLen = codeLen
        this.localTypesOff = localTypesOff
        this.nargs = nargs
        this.nLocals = nLocals
        this.maxStack = maxStack
        this.retType = retType
        this.flags = flags
    }

    /** 条目定长（§11.7「恒 26 B」）：4+4+4+4 + 2*5 = 26。 */
    public static const SIZE: Int64 = 26

    /** 按 §11.7 字段顺序写出 26 字节（显式小端，§11.2）。 */
    public func write(w: ByteWriter): Unit {
        w.wU32(this.fnId)
        w.wU32(this.codeOff)
        w.wU32(this.codeLen)
        w.wU32(this.localTypesOff)
        w.wU16(this.nargs)
        w.wU16(this.nLocals)
        w.wU16(this.maxStack)
        w.wU16(this.retType)
        w.wU16(this.flags)
    }

    /** 按同一顺序读回 26 字节。 */
    public static func read(r: ByteReader): FuncEntry {
        let fnId = r.u32()
        let codeOff = r.u32()
        let codeLen = r.u32()
        let localTypesOff = r.u32()
        let nargs = r.u16()
        let nLocals = r.u16()
        let maxStack = r.u16()
        let retType = r.u16()
        let flags = r.u16()
        FuncEntry(fnId, codeOff, codeLen, localTypesOff, nargs, nLocals, maxStack, retType, flags)
    }
}

/**
 * 函数目录容器（class：`add` / `get` / `find` / `size` / `validate`）。
 *
 * 用 class 是因为它有**可变状态且必须被共享**（若用 struct，赋值处会被静默浅拷贝成两份目录）。
 */
public class FuncDir {
    private let entries: ArrayList<FuncEntry>

    public init() {
        this.entries = ArrayList<FuncEntry>()
    }

    /** 已登记条目数。 */
    public prop size: Int64 {
        get() {
            this.entries.size
        }
    }

    /** 按下标取条目（顺序 = 登记顺序，序列化依据）。 */
    public func at(i: Int64): FuncEntry {
        if (i < 0 || i >= this.entries.size) {
            rejectFormat('函数目录下标越界: ${i} / ${this.entries.size}')
        }
        this.entries[i]
    }

    /** 按 `fnId` 取条目；不存在 ⇒ 拒绝（`CALL_FUNC` 解析失败即容器格式错误）。 */
    public func get(fnId: UInt32): FuncEntry {
        match (find(fnId)) {
            case Some(e) => e
            case None => rejectFormat('函数号不在目录中: fnId=${fnId}')
        }
    }

    /** 按 `fnId` 查找；未命中返回 `None`（调用方决定是否拒绝）。 */
    public func find(fnId: UInt32): ?FuncEntry {
        for (e in this.entries) {
            if (e.fnId == fnId) {
                return Some(e)
            }
        }
        None
    }

    /** 登记条目；重复 `fnId` ⇒ 拒绝（目录解析必须唯一）。 */
    public func add(e: FuncEntry): Unit {
        if (find(e.fnId).isSome()) {
            rejectFormat('函数目录重复 fnId: ${e.fnId}')
        }
        this.entries.add(e)
    }

    /**
     * 加载期校验（§11.7「加载器校验其结构」）：
     *
     * 1. 每条 `codeOff + codeLen <= codeLen`（code 段长度）；
     * 2. 每条 `localTypesOff + nLocals <= codeLen`（局部类型表在 code 段内）；
     * 3. `entryFn` 必须命中目录中某个 `fnId`（§11.7「容器头 `entryFn` 必须命中目录」）。
     */
    public func validate(codeLen: UInt32, entryFn: UInt32, verMajor!: UInt16 = Version.MAJOR): Unit {
        for (e in this.entries) {
            if (e.codeOff > codeLen || e.codeLen > codeLen - e.codeOff) {
                rejectFormat('函数体越界: fnId=${e.fnId}, codeOff=${e.codeOff}, codeLen=${e.codeLen}, 段长=${codeLen}')
            }
            let typesEnd = e.localTypesOff + UInt32(e.nLocals)
            if (e.localTypesOff > codeLen || typesEnd > codeLen) {
                rejectFormat(
                    '局部类型表越界: fnId=${e.fnId}, localTypesOff=${e.localTypesOff}, nLocals=${e.nLocals}, 段长=${codeLen}')
            }
            if (!LocalType.isLegal(e.retType, verMajor)) {
                rejectFormat(
                    '非法返回类型: fnId=${e.fnId}, retType=${e.retType}（verMajor=${verMajor}，§11.7）')
            }
        }
        if (find(entryFn).isNone()) {
            rejectFormat('入口函数号不在目录中: entryFn=${entryFn}')
        }
    }
}
