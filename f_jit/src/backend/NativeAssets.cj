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
package fountain::f_jit.backend

/**
 * JIT 产物内的两块**非 GC 内存**（design §12.4 模板 B/C、§8.7 资产清点）：
 *
 * - `FnTable`：`CALL_FUNC` / `CALL_CLOSURE` 的间接跳转目标表（`fnTable[fid] = entry`）；
 * - `ConstMirror`：常量句柄镜像（连续 8 B 数组，`PUSH_KH` 的取数处；基址烘焙进机器码）。
 *
 * 生命周期与 `JitFunction` 同生共死；分配/释放计数供 T27/T29 断言无泄漏。
 */
public class NativeAssets {
    private static var allocs: Int64 = 0
    private static var frees: Int64 = 0

    internal static func onAlloc(): Unit {
        NativeAssets.allocs = NativeAssets.allocs + 1
    }

    internal static func onFree(): Unit {
        NativeAssets.frees = NativeAssets.frees + 1
    }

    /** 未释放资产数。 */
    public static func liveCount(): Int64 {
        NativeAssets.allocs - NativeAssets.frees
    }

    /** 测试用：清零计数。 */
    public static func resetCounters(): Unit {
        NativeAssets.allocs = 0
        NativeAssets.frees = 0
    }
}

/** 函数入口表（非 GC；`fid` 为下标，元素为 8 B 入口地址）。 */
public class FnTable {
    private var p: CPointer<Int64>
    private var n: Int64
    private var freed: Bool

    private init(p: CPointer<Int64>, n: Int64) {
        this.p = p
        this.n = n
        this.freed = false
    }

    /** 分配 `n` 个入口槽（清零）；失败 → None。 */
    public static func alloc(n: Int64): ?FnTable {
        if (n <= 0) {
            return None
        }
        let p = LibC.malloc<Int64>(count: n)
        if (p.isNull()) {
            return None
        }
        unsafe {
            for (i in 0..n) {
                p.write(i, 0)
            }
        }
        NativeAssets.onAlloc()
        Some(FnTable(p, n))
    }

    /** 基址（已释放 → 0）。 */
    public func base(): Int64 {
        if (this.freed) {
            0
        } else {
            Int64(this.p.toUIntNative())
        }
    }

    /** 槽数。 */
    public func size(): Int64 {
        if (this.freed) {
            0
        } else {
            this.n
        }
    }

    /** 写入入口；越界 / 已释放 → false。 */
    public func set(fid: UInt32, entry: Int64): Bool {
        if (this.freed || Int64(fid) >= this.n) {
            return false
        }
        unsafe {
            this.p.write(Int64(fid), entry)
        }
        true
    }

    /** 读取入口；越界 / 已释放 → 0。 */
    public func entry(fid: UInt32): Int64 {
        if (this.freed || Int64(fid) >= this.n) {
            return 0
        }
        unsafe {
            this.p.read(Int64(fid))
        }
    }

    /** 释放；幂等。 */
    public func free(): Unit {
        if (this.freed) {
            return
        }
        unsafe {
            LibC.free<Int64>(this.p)
        }
        this.p = CPointer<Int64>()
        this.n = 0
        this.freed = true
        NativeAssets.onFree()
    }
}

/** 常量句柄镜像（非 GC；连续 8 B，`PUSH_KH idx` 读 `base + 8*idx`）。 */
public class ConstMirror {
    private var p: CPointer<Int64>
    private var n: Int64
    private var freed: Bool

    private init(p: CPointer<Int64>, n: Int64) {
        this.p = p
        this.n = n
        this.freed = false
    }

    /** 按 `handleIds` 建镜像；空数组或分配失败 → base 0 的空镜像。 */
    public static func build(ids: Array<Int64>): ConstMirror {
        if (ids.size == 0) {
            return ConstMirror(CPointer<Int64>(), 0)
        }
        let p = LibC.malloc<Int64>(count: ids.size)
        if (p.isNull()) {
            return ConstMirror(CPointer<Int64>(), 0)
        }
        unsafe {
            for (i in 0..ids.size) {
                p.write(i, ids[i])
            }
        }
        NativeAssets.onAlloc()
        ConstMirror(p, ids.size)
    }

    /** 基址（可烘焙进机器码立即数；空 / 已释放 → 0）。 */
    public func base(): Int64 {
        if (this.freed) {
            0
        } else {
            Int64(this.p.toUIntNative())
        }
    }

    /** 常量个数。 */
    public func size(): Int64 {
        if (this.freed) {
            0
        } else {
            this.n
        }
    }

    /** 读第 `i` 个句柄；越界 / 已释放 → 0。 */
    public func at(i: Int64): Int64 {
        if (this.freed || i < 0 || i >= this.n) {
            return 0
        }
        unsafe {
            this.p.read(i)
        }
    }

    /** 释放；幂等（空镜像不计数）。 */
    public func free(): Unit {
        if (this.freed) {
            return
        }
        if (!this.p.isNull()) {
            unsafe {
                LibC.free<Int64>(this.p)
            }
            NativeAssets.onFree()
        }
        this.p = CPointer<Int64>()
        this.n = 0
        this.freed = true
    }
}
