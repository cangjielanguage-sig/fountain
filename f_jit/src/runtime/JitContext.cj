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
package fountain::f_jit.runtime

/**
 * 非托管内存的分配 / 释放计数 —— design D6、plan-m1 S4.1（T27 泄漏断言）。
 *
 * ctx（64 B）与诊断转储缓冲 `(2+maxNLocals)×8` 是**全过程仅有的两块 GC 管辖外内存**；
 * design D6 选择「`LibC.malloc` / `LibC.free` + 桥 `finally` 单一收尾机制」的理由之一，
 * 就是让「全路径配对、无泄漏」能被**计数断言**证明。本类就是这个计数器的落点。
 */
public class NativeMem {
    public static var mallocCount: Int64 = 0
    public static var freeCount: Int64 = 0

    /** 计数归零（用例内断言用）。 */
    public static func resetCounters(): Unit {
        mallocCount = 0
        freeCount = 0
    }

    /** 未配对数（> 0 即泄漏）。 */
    public static func outstanding(): Int64 {
        mallocCount - freeCount
    }
}

/**
 * ctx 标志位定义（§1：`flags` bit0=strictFp（**历史位，运行期不读**）、bit1=trace、bit2=hasLoop、…）。
 *
 * 与 `LocalType` / `ErrCode` / `TypeToken` 同族：这是要写进 ctx 的**线上位**，用
 * 「类 + `static const`」承载（design D3）。
 */
public class CtxFlags {
    /** 历史位（X3）：严格浮点已由 `CompileOptions.strictFp` 在产物层表达，运行期不读。 */
    public static const STRICT_FP: Int64 = 1
    /** 执行轨迹（诊断用）。 */
    public static const TRACE: Int64 = 2
    /** 单元内存在回边（`LOOP_BACK`），安全点有意义。 */
    public static const HAS_LOOP: Int64 = 4
}

/**
 * 64 字节非托管上下文 —— design-m1 §5.3.1、plan-m1 S4.1。
 *
 * 布局权威 = `doc/jit-bytecode-m1.md` §1：
 *
 * ```
 * off  size 字段
 * 0    8    errCode   0=OK  -1=DEOPT  -2=INTERRUPT  >0=错误码
 * 8    8    site      当前字节码偏移；未设置=-1
 * 16   8    hwBase    句柄窗口起点
 * 24   8    hwCap     窗口初始容量
 * 32   8    hwTop     窗口已用数
 * 40   8    fnId      函数 id
 * 48   8    flags     bit0=strictFp bit1=trace bit2=hasLoop
 * 56   8    dbgBase   诊断转储区基址（0=禁用）
 * ```
 *
 * **为什么是非托管 + 访问器**（design D6 / §1「ctx 内存机制」）：仓颉 `struct` 不承诺逐字节
 * 布局，而机器码要求 64 B 固定偏移 ⇒ 只能落在非托管内存，并用访问器类读写（不得移动）。
 * 分配 = `LibC.malloc<Int64>(count: 8)`（8 × 8 B = 64 B，与 `cp(): CPointer<Int64>` 同型）；
 * 释放一律在桥 `finally`，不用 `CPointerResource`。
 *
 * **可见性**：`protected` 是 design D2 的结案结论（ctx 布局是机器码 ABI 契约、用户面无消费
 * 路径）。本包源码里写 `public`，由模块内 `protected` 规则收口（仓颉 `protected` = module 级，
 * 兄弟包可见、用户面不可见）；`openspec` 的可见性用例在门面层断言。
 */
public class JitContext {
    public static const OFF_ERR_CODE: Int64 = 0
    public static const OFF_SITE: Int64 = 8
    public static const OFF_HW_BASE: Int64 = 16
    public static const OFF_HW_CAP: Int64 = 24
    public static const OFF_HW_TOP: Int64 = 32
    public static const OFF_FN_ID: Int64 = 40
    public static const OFF_FLAGS: Int64 = 48
    public static const OFF_DBG_BASE: Int64 = 56

    /** ctx 字节长度（§1「64 B，16 B 对齐」）。 */
    public static const SIZE_BYTES: Int64 = 64
    /** `LibC.malloc<Int64>(count: …)` 的个数（8 × 8 B = 64 B）。 */
    public static const WORD_COUNT: Int64 = 8

    private let p: CPointer<Int64>
    /**
     * 诊断转储缓冲的**仓颉侧指针视图**（与 `dbgBase` 指向同一块非托管内存）。
     *
     * `dbgBase`（off 56）是机器码用的整数地址；仓颉侧无法由整数反推 `CPointer`（`CPointer`
     * 的单参构造只接受 `CPointer` / `CFunc`），故成对持有两份视图——二者**始终别名同一内存**。
     */
    private var dumpPtr: CPointer<Int64> = CPointer<Int64>()

    private init(p: CPointer<Int64>) {
        this.p = p
    }

    /**
     * 在**已有**的非托管 ctx 上包一个访问器（机器码侧回调 / `@C` helper 入口用）。
     *
     * 不拥有该内存：释放仍由桥 `finally` 负责（design D6「释放点不变」）。
     */
    public static func wrap(raw: CPointer<Unit>): JitContext {
        JitContext(unsafe { CPointer<Int64>(raw) })
    }

    /** 挂接诊断转储缓冲（桥 `call<T>` 第 1 步）：同时写入整数基址与指针视图。 */
    public func attachDump(dump: CPointer<Int64>): Unit {
        this.dumpPtr = dump
        this.dbgBase = Int64(dump.toUIntNative())
    }

    /** 转储缓冲的指针视图（`dbgBase = 0` 时为 null 指针）。 */
    public func dumpPointer(): CPointer<Int64> {
        this.dumpPtr
    }

    /**
     * 分配并初始化 ctx（桥三态收尾第 1 步）。
     *
     * 初值按 §8.2 第 1 步：`errCode = 0`、`site = -1`、`hwTop = hwBase`；`hwCap` / `fnId` /
     * `dbgBase` 由桥给出。
     */
    public static func create(hwBase!: Int64, hwCap!: Int64, fnId!: Int64, dbgBase!: Int64): JitContext {
        let p = LibC.malloc<Int64>(count: WORD_COUNT)
        unsafe {
            p.write(0, 0)
            p.write(1, -1)
            p.write(2, hwBase)
            p.write(3, hwCap)
            p.write(4, hwBase)
            p.write(5, fnId)
            p.write(6, 0)
            p.write(7, dbgBase)
        }
        NativeMem.mallocCount = NativeMem.mallocCount + 1
        JitContext(p)
    }

    /** 配对释放（桥 `finally` 义务；T27）。释放前清掉本次调用的 cause 旁路。 */
    public static func free(ctx: JitContext): Unit {
        HostFault.clear(ctx)
        unsafe { LibC.free<Int64>(ctx.p) }
        NativeMem.freeCount = NativeMem.freeCount + 1
    }

    /** 裸指针（传给机器码：`rdi` / `x0`）。 */
    public func cp(): CPointer<Int64> {
        this.p
    }

    /** 错误槽（off 0）。 */
    public mut prop errCode: Int64 {
        get() {
            unsafe { this.p.read(0) }
        }
        set(v) {
            unsafe { this.p.write(0, v) }
        }
    }

    /** 当前站点（off 8；未设置 = -1）。 */
    public mut prop site: Int64 {
        get() {
            unsafe { this.p.read(1) }
        }
        set(v) {
            unsafe { this.p.write(1, v) }
        }
    }

    /** 句柄窗口起点（off 16）。 */
    public mut prop hwBase: Int64 {
        get() {
            unsafe { this.p.read(2) }
        }
        set(v) {
            unsafe { this.p.write(2, v) }
        }
    }

    /** 窗口初始容量（off 24；无分配单元 = 0）。 */
    public mut prop hwCap: Int64 {
        get() {
            unsafe { this.p.read(3) }
        }
        set(v) {
            unsafe { this.p.write(3, v) }
        }
    }

    /** 窗口已用数（off 32；helper 写）。 */
    public mut prop hwTop: Int64 {
        get() {
            unsafe { this.p.read(4) }
        }
        set(v) {
            unsafe { this.p.write(4, v) }
        }
    }

    /** 函数号（off 40）。 */
    public mut prop fnId: Int64 {
        get() {
            unsafe { this.p.read(5) }
        }
        set(v) {
            unsafe { this.p.write(5, v) }
        }
    }

    /** 标志位（off 48；位定义见 `CtxFlags`）。 */
    public mut prop flags: Int64 {
        get() {
            unsafe { this.p.read(6) }
        }
        set(v) {
            unsafe { this.p.write(6, v) }
        }
    }

    /** 诊断转储区基址（off 56；0 = 禁用）。 */
    public mut prop dbgBase: Int64 {
        get() {
            unsafe { this.p.read(7) }
        }
        set(v) {
            unsafe { this.p.write(7, v) }
        }
    }

    /**
     * 每次调用前复位（§8.2 第 1 步）：`errCode = 0`、`site = -1`、`hwTop = hwBase`。
     *
     * `hwBase` / `hwCap` / `fnId` / `dbgBase` 由桥在入口写入，**不**被本方法清零。
     */
    public func resetForCall(): Unit {
        unsafe {
            this.p.write(0, 0)
            this.p.write(1, -1)
            this.p.write(4, this.p.read(2))
        }
    }

    /** 按字节偏移读（供测试与「偏移断言」用例使用）。 */
    public func readAt(off: Int64): Int64 {
        unsafe { this.p.read(off / 8) }
    }

    /** 按字节偏移写（供测试与「偏移断言」用例使用）。 */
    public func writeAt(off: Int64, v: Int64): Unit {
        unsafe { this.p.write(off / 8, v) }
    }
}
