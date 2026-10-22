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
package fountain::f_jit.base

import fountain::f_base.BaseException

/**
 * 运行期错误载体 —— design-m1 §2.3.1、plan-m1 S1.8、规格 §2「错误码 → 桥侧异常类型映射」。
 *
 * 由桥在**报告组装完成后**构造（被根包 `Report.throwJit` 调用）；覆盖 1–20、23、99 三类错误码
 * 的宿主侧呈现（`0 / -1 / -2` 不抛：OK 走值路径、DEOPT 走解释器、INTERRUPT 抛
 * `InterruptedException`，见 §2 表末行）。
 *
 * **继承 `fountain::f_base.BaseException`**（design D15 / §2.3.1）：
 *
 * 1. 宿主可 `catch (e: BaseException)` 与其它 fountain 模块统一处理（`f_exception` 对该基类有
 *    `public import` 再导出，两种 import 路径等价；本模块统一用 `f_base`）；
 * 2. 报告文本即基类 `message` 语义（构造时 `super(message)` 转发）——因此本类**不重复声明**
 *    `message` 字段（`Exception.message` 是 `public open prop`，子类不可同名覆盖）；
 * 3. 基类的 `init(caused: Exception)` / `init(message, caused)` 变体本期不需要（M2 挂接原始
 *    仓颉异常时再取用）。
 */
public class JitException <: BaseException {
    /** §2 错误码；宿主处置分派、T6/T15 断言依据。 */
    public let code: Int64
    /** code 段绝对字节偏移；`-1` 表示未知（与 `sourcePos` 互证，§9.16）。 */
    public let site: Int64
    /** 出错函数 id（深帧归因：最深失败帧获胜）。 */
    public let fnId: Int64
    /** 站点表查得的源位置；不可得 ⇒ `None`（报告文本；分发入口无文本路径）。 */
    public let sourcePos: ?SourcePos
    /** `code = 99` 时 helper 原始描述（M2 起 21 含完整仓颉栈）。 */
    public let cause: ?String

    /**
     * 五参形式：`cause` 取 `None`。
     *
     * 仓颉（1.3.0）**没有函数默认参数**（默认值只在跨平台 `common/specific` 声明里有定义），
     * 因此 design §2.3.1 草图里的 `cause: ?String = None` 落成**重载**而不是默认实参；
     * 语义与默认值完全一致。
     */
    public init(code: Int64, site: Int64, fnId: Int64, sourcePos: ?SourcePos, message: String) {
        this(code, site, fnId, sourcePos, message, None)
    }

    public init(
        code: Int64,
        site: Int64,
        fnId: Int64,
        sourcePos: ?SourcePos,
        message: String,
        cause: ?String
    ) {
        super(message)
        this.code = code
        this.site = site
        this.fnId = fnId
        this.sourcePos = sourcePos
        this.cause = cause
    }
}
