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

import fountain::f_jit.base.LocalType
import fountain::f_jit.base.Version

/**
 * 每函数一份的局部类型表 —— design-m1 §3.3.5、plan-m1 S2.6。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.7：**每槽 1 字节**，覆盖**全部 `nLocals` 槽**（含参数槽
 * `locals[0..nargs-1]`）；`13–255 保留（加载器拒绝）`；值型 0–3 存原始 cell、句柄型 4–12 存
 * 句柄 ID。
 *
 * 合法集**按单元 `verMajor` 分派**（design-m1 §2.3.8 `LocalType.isLegal`）：v1:0–12、
 * v2:0–14、v3:0–19；其余主版本一律拒绝。
 *
 * 用 class 而非 struct：它是**每槽可写**的容器且必须被前端与加载器共享同一实例（struct 会在
 * 赋值处静默浅拷贝成两份表）。
 */
public class LocalTypes {
    private let slots: Array<UInt8>

    /** 申请 `nLocals` 槽，初值 0（`Int64`，§11.7 值型）。 */
    public init(nLocals: Int64) {
        if (nLocals < 0) {
            rejectFormat('局部类型表槽数非法: ${nLocals}')
        }
        this.slots = Array<UInt8>(nLocals, repeat: 0u8)
    }

    /** 从既有字节重建（加载期：code 段内 `localTypesOff` 起的 `nLocals` 字节）。 */
    public static func read(bs: Array<UInt8>): LocalTypes {
        let t = LocalTypes(bs.size)
        for (i in 0..bs.size) {
            t.slots[i] = bs[i]
        }
        t
    }

    /** 槽数（= `FuncEntry.nLocals`）。 */
    public prop size: Int64 {
        get() {
            this.slots.size
        }
    }

    /** 读槽类型码。 */
    public func get(slot: Int64): UInt8 {
        if (slot < 0 || slot >= this.slots.size) {
            rejectFormat('局部槽下标越界: ${slot} / ${this.slots.size}')
        }
        this.slots[slot]
    }

    /** 写槽类型码。 */
    public func set(slot: Int64, t: UInt8): Unit {
        if (slot < 0 || slot >= this.slots.size) {
            rejectFormat('局部槽下标越界: ${slot} / ${this.slots.size}')
        }
        this.slots[slot] = t
    }

    /**
     * 句柄型槽判定（空安全 / 写保护共用，§11.7「句柄型（4–12）槽存句柄 ID」）。
     *
     * 越界槽返回 `false`（不抛）：调用方在**边界扫描**中不应因越界中断。
     */
    public func isHandleSlot(slot: Int64): Bool {
        if (slot < 0 || slot >= this.slots.size) {
            false
        } else {
            LocalType.isHandle(UInt16(this.slots[slot]))
        }
    }

    /** 按 §11.7 写出 `nLocals` 字节（每槽 1 字节）。 */
    public func write(w: ByteWriter): Unit {
        w.wBytes(this.slots)
    }

    /**
     * 加载期校验：长度恰为该函数的 `nLocals`，且每个类型码在 `verMajor` 的合法集内。
     *
     * `verMajor` 缺省取本实现的主版本（`Version.MAJOR`，v1）。
     */
    public func validate(dir: FuncDir, fnId: UInt32): Unit {
        validate(dir, fnId, Version.MAJOR)
    }

    public func validate(dir: FuncDir, fnId: UInt32, verMajor: UInt16): Unit {
        let e = dir.get(fnId)
        if (this.slots.size != Int64(e.nLocals)) {
            rejectFormat('局部类型表长度不符: fnId=${fnId}, 实际 ${this.slots.size}, 目录 nLocals=${e.nLocals}')
        }
        for (i in 0..this.slots.size) {
            let code = UInt16(this.slots[i])
            if (!LocalType.isLegal(code, verMajor)) {
                rejectFormat('非法局部类型码: fnId=${fnId}, slot=${i}, code=${code}, verMajor=${verMajor}（§11.7）')
            }
        }
    }
}
