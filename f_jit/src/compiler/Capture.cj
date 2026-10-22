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
package fountain::f_jit.compiler

import std.collection.ArrayList
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourcePos

/**
 * 捕获项的来源分类（m2 §14.7 路径表）。
 *
 * 数值同时用作「严重度」：`VALUE < CONSTANT < PARAMETER < WINDOW`，赋值时取较大者保守降级。
 */
protected class CaptureOrigin {
    /** 值型捕获（`Int64`/`Float64`/`Bool`/`Unit`）：cell 是值本身，恒有效。 */
    public static const VALUE: UInt8 = 0u8
    /** 路径 A 常量捕获（ConstTable 持有）：恒有效。 */
    public static const CONSTANT: UInt8 = 1u8
    /** 路径 B 函数参数捕获（pin）：调用结束失效。 */
    public static const PARAMETER: UInt8 = 2u8
    /** 路径 C 窗口分配捕获：窗口重置后失效。 */
    public static const WINDOW: UInt8 = 3u8

    public static func name(o: UInt8): String {
        match (o) {
            case 0u8 => '值型'
            case 1u8 => '路径 A 常量'
            case 2u8 => '路径 B 参数'
            case 3u8 => '路径 C 窗口分配'
            case _ => '未知'
        }
    }

    public static func isInvalidIfEscapes(o: UInt8): Bool {
        o == PARAMETER || o == WINDOW
    }
}

/** 单个捕获项（名字 + 槽类型 + 来源）。 */
protected class CaptureEntry {
    public let name: String
    public let typeCode: UInt16
    public let origin: UInt8

    public init(name: String, typeCode: UInt16, origin: UInt8) {
        this.name = name
        this.typeCode = typeCode
        this.origin = origin
    }

    /** 句柄型且非常量（路径 B/C）⇒ 进入提升组（m2 §14.1/14.2）。 */
    public func needsPromotion(): Bool {
        LocalType.isHandle(this.typeCode) && this.origin != CaptureOrigin.CONSTANT &&
            this.origin != CaptureOrigin.VALUE
    }
}

/**
 * 闭包静态捕获描述符（m2 §14.8：**不写入 `.fbc`**，只作前端/桥的伴随静态知识）。
 *
 * `entries` 的形状与 `closure_new` 的捕获项一一对应；`escaping` 表示该闭包出现在返回位置
 * （仅「跨桥返回」方向开放）。
 */
protected class CaptureDescriptor {
    public let pos: SourcePos
    public let escaping: Bool
    public let entries: Array<CaptureEntry>

    public init(pos: SourcePos, escaping: Bool, entries: Array<CaptureEntry>) {
        this.pos = pos
        this.escaping = escaping
        this.entries = entries.clone()
    }

    /** 路径 B/C 捕获项（第 0 步白名单拒绝面）。 */
    public func invalidEntries(): Array<CaptureEntry> {
        var out = ArrayList<CaptureEntry>()
        for (e in this.entries) {
            if (CaptureOrigin.isInvalidIfEscapes(e.origin)) {
                out.add(e)
            }
        }
        out.toArray()
    }

    /**
     * 句柄型捕获集（第 1 步提升组的内容）。
     *
     * 路径 A 常量不入组（§14.2 规则 3）；值型捕获不入组。
     */
    public func handleCaptureNames(): Array<String> {
        var out = ArrayList<String>()
        for (e in this.entries) {
            if (e.needsPromotion()) {
                out.add(e.name)
            }
        }
        out.toArray()
    }

    public func describe(): String {
        var s = ''
        for (i in 0..this.entries.size) {
            if (i > 0) {
                s = s + ', '
            }
            let e = this.entries[i]
            s = s + '${e.name}:${CaptureOrigin.name(e.origin)}'
        }
        s
    }
}
