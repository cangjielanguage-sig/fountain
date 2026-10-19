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

import std.collection.ArrayList
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourcePos
import fountain::f_jit.bytecode.FuncDir
import fountain::f_jit.bytecode.LocalTypes
import fountain::f_jit.bytecode.NameTable
import fountain::f_jit.bytecode.SiteTable

/**
 * 单次诊断转储与报告组装 —— design-m1 §5.3.5、plan-m1 S4.19。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §9 附则 16（v0.18.23 / v0.18.25）：
 *
 * - **fail-fast 收敛时执行单次转储**：凡 `errCode > 0` 的收敛点（`BAIL` / `CHECK_ERR → bail`；
 *   **-1/-2 不转储**），若 `ctx.dbgBase ≠ 0` 且缓冲首格为 0（未填）⇒ 写 `[0]=fnId+1`、
 *   `[1]=nLocals`、拷 `locals[0..nLocals)`：**第一个收敛点获胜**（= 最深失败帧；外层传播帧因哨兵跳过）。
 *   首格存 `fnId+1` 而非 `fnId`：入口函数号合法值为 0，若直接存 fnId 会被误判为「未填」，
 *   0 因此保留为哨兵（§9.16 的实现订正，见 `design-m1.md` §E）；
 * - 缓冲区 = `(2 + maxNLocals) × 8`（max 取目录全域；桥分配 / 清零）；
 * - 报告模板**逐字节冻结**（三引擎逐位比对）：
 *   `（code=N，site=OFF）` ⏎ `  源码行 L:C · fnId=F` ⏎ `  变量: [0] a: Int64 = 42; …`
 *   条目格式：有名字 ⇒ `名字: 类型…`；无名字 ⇒ 直接类型。值型（0–3）按 §11.9 文本化
 *   （Unit 记 `Unit`）；句柄型（4–14）记 `<类型名>#<idx>`（0 ⇒ `#0`；**不取对象**，避免错误
 *   路径二次失败）。M2 的 13/14 沿用同一规则 ⇒ `HostClosure#idx` / `HostObject#idx`（大类名，
 *   不解析注册类名；m2 §5.1）。
 */
public class DbgDump {
    /** 缓冲字数常量：首格哨兵 + fnId + nLocals（nLocals 占 1 格）。 */
    public static const HEADER_WORDS: Int64 = 2

    /** 分配 `(2 + maxNLocals) × 8` 的非托管转储缓冲，首格清零（桥 `call<T>` 第 1 步）。 */
    public static func allocateDump(maxNLocals: Int64): CPointer<Int64> {
        let p = LibC.malloc<Int64>(count: HEADER_WORDS + maxNLocals)
        unsafe {
            p.write(0, 0)
            p.write(1, 0)
        }
        NativeMem.mallocCount = NativeMem.mallocCount + 1
        p
    }

    /** 配对释放（桥 `finally`；T27）。 */
    public static func freeDump(p: CPointer<Int64>): Unit {
        unsafe { LibC.free<Int64>(p) }
        NativeMem.freeCount = NativeMem.freeCount + 1
    }

    /**
     * 单次转储写（失败即返回，绝不抛异常）。
     *
     * 三条跳过条件：`dbgBase = 0`（转储区禁用）、`errCode ≤ 0`（DEOPT / INTERRUPT 不转储）、
     * 首格哨兵非 0（已有更深的失败帧获胜）。
     */
    public static func writeOnce(ctx: JitContext, fnId: Int64, nLocals: Int64, locals: CPointer<Int64>): Unit {
        match (DbgDump.beginDump(ctx, fnId, nLocals)) {
            case Some(p) =>
                unsafe {
                    var i: Int64 = 0
                    while (i < nLocals) {
                        p.write(HEADER_WORDS + i, locals.read(i))
                        i = i + 1
                    }
                }
            case None => ()
        }
    }

    /**
     * **机器码帧**形态的转储写（`@C` 入口专用）：`locals` 指向 `locals[0]`，
     * 后续槽在 −8、−16…（栈向下生长）。
     *
     * 入参全部是原生值（不构造 `JitContext` 托管对象）：`@C` 入口运行在 C2N 边界上，
     * 机器码把 `ctx.dbgBase`、`ctx.errCode` 与帧局部槽地址直接传入。解释器与 JIT
     * 共用同一段「哨兵 → fnId/nLocals → locals」写缓冲逻辑，报告文本因此逐位一致（I7 / T50）。
     */
    public static func writeOnceStackRaw(dump: CPointer<Int64>, errCode: Int64, fnId: Int64,
        nLocals: Int64, locals: CPointer<Int64>): Unit {
        if (errCode <= 0 || dump.isNull()) {
            return
        }
        unsafe {
            if (dump.read(0) != 0) {
                return
            }
            dump.write(0, fnId + 1)
            dump.write(1, nLocals)
            var i: Int64 = 0
            while (i < nLocals) {
                dump.write(HEADER_WORDS + i, locals.read(-i))
                i = i + 1
            }
        }
    }

    /** 托管数组形态的转储写（解释器帧的局部槽是 `Array<Int64>`）。 */
    public static func writeOnce(ctx: JitContext, fnId: Int64, locals: Array<Int64>): Unit {
        match (DbgDump.beginDump(ctx, fnId, locals.size)) {
            case Some(p) =>
                unsafe {
                    var i: Int64 = 0
                    while (i < locals.size) {
                        p.write(HEADER_WORDS + i, locals[i])
                        i = i + 1
                    }
                }
            case None => ()
        }
    }

    /** 三条跳过条件集中在此：`dbgBase=0`、`errCode≤0`、首格哨兵非 0。 */
    private static func beginDump(ctx: JitContext, fnId: Int64, nLocals: Int64): ?CPointer<Int64> {
        if (ctx.dbgBase == 0 || ctx.errCode <= 0) {
            return None
        }
        unsafe {
            let p = ctx.dumpPointer()
            if (p.read(0) != 0) {
                return None
            }
            p.write(0, fnId + 1)
            p.write(1, nLocals)
            Some(p)
        }
    }

    /**
     * 组装报告（§9.16 模板逐字节冻结）。
     *
     * `site = -1` ⇒ 无行号、无变量（只有首行）；`dump` 为 null（或首格为 0）⇒ 只有行号。
     */
    public static func report(
        code: Int64,
        site: Int64,
        fnId: Int64,
        types: LocalTypes,
        siteTable: SiteTable,
        nameTable: NameTable,
        dump: CPointer<Int64>
    ): String {
        var out = '（code=${code}，site=${site}）'
        if (site < 0) {
            return out
        }
        // 源码行
        match (siteTable.lookup(site)) {
            case Some(pos) => out = out + '\n  源码行 ${pos.line}:${pos.column} · fnId=${fnId}'
            case None => out = out + '\n  源码行 - · fnId=${fnId}'
        }
        // 变量清单
        unsafe {
            let p = dump
            if (p.read(0) == 0) {
                return out
            }
            let dumpFnId = p.read(0) - 1
            let n = p.read(1)
            var items = ArrayList<String>()
            var i: Int64 = 0
            while (i < n) {
                let cell = p.read(HEADER_WORDS + i)
                items.add('[${i}] ' + slotText(nameTable, dumpFnId, i, types.get(i), cell))
                i = i + 1
            }
            out + '\n  变量: ' + joinItems(items)
        }
    }

    /** 无转储缓冲的报告（防御分支：`dbgBase = 0`）。 */
    public static func report(
        code: Int64,
        site: Int64,
        fnId: Int64,
        types: LocalTypes,
        siteTable: SiteTable
    ): String {
        var out = '（code=${code}，site=${site}）'
        if (site < 0) {
            return out
        }
        match (siteTable.lookup(site)) {
            case Some(pos) => out + '\n  源码行 ${pos.line}:${pos.column} · fnId=${fnId}'
            case None => out + '\n  源码行 - · fnId=${fnId}'
        }
    }

    /** 单个局部槽的文本（名字 + 类型 + 值）。 */
    internal static func slotText(nameTable: NameTable, fnId: Int64, slot: Int64, typeCode: UInt8, cell: Int64): String {
        let tname = LocalType.name(UInt16(typeCode))
        var head = ''
        match (nameTable.lookup(UInt32(fnId), UInt32(slot))) {
            case Some(nm) => head = '${nm}: '
            case None => head = ''
        }
        if (UInt16(typeCode) <= LocalType.UNIT) {
            // 值型（0–3）：按 §11.9 文本化；Unit 记 `Unit`
            var v = ''
            match (UInt16(typeCode)) {
                case 0u16 => v = TextFormat.i64(cell)
                case 1u16 => v = TextFormat.f64(Float64.fromBits(UInt64(cell)))
                case 2u16 => v = TextFormat.bool(cell != 0)
                case _ => v = 'Unit'
            }
            return head + '${tname} = ${v}'
        }
        // 句柄型（4–14）：`<类型名>#<idx>` —— 不取对象（13/14 同样只用大类名，m2 §5.1）
        head + '${tname}#${HandleTable.idxOf(cell)}'
    }

    internal static func joinItems(items: ArrayList<String>): String {
        var out = ''
        var i: Int64 = 0
        for (it in items) {
            if (i > 0) {
                out = out + '; '
            }
            out = out + it
            i = i + 1
        }
        out
    }
}

/**
 * 机器码 BAIL 块的 `@C` 转储入口（T50）。
 *
 * `x0 = ctx`、`x1 = fnId`、`x2 = nLocals`、`x3 = &locals[0]`；后续局部槽在 `−8、−16…`。
 * 与 H01–H72 一样，本方法不把异常抛回机器码（转储失败一律静默返回）。
 */
@C
public func jit_dump(dump: CPointer<Int64>, errCode: Int64, fnId: Int64, nLocals: Int64,
    locals: CPointer<Int64>): Int64 {
    DbgDump.writeOnceStackRaw(dump, errCode, fnId, nLocals, locals)
    0
}

