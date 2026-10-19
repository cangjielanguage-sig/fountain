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
package fountain::f_jit

import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.InterruptedException
import fountain::f_jit.base.JitException
import fountain::f_jit.runtime.HostFault
import fountain::f_jit.runtime.JitContext

/**
 * S6.4 三态收尾（§8.2.3）：
 *
 * | errCode | 出口 |
 * |---|---|
 * | `0` | 值路径（解包由调用方完成） |
 * | `-1 DEOPT` | 解释器透明重跑（宿主不可见） |
 * | `-2 INTERRUPT` | `InterruptedException` |
 * | `>0` | `JitException`（原码 / 原 site / 报告文本） |
 *
 * `Replay` 为非预期异常时兜底转 99（实现缺陷信号），**绝不让其它异常类型逃逸**。
 */
protected class JitReport {
    /** 按错误槽抛出对应异常；`errCode == 0/-1` 属调用方分派，不在此列。 */
    public static func throwJit(ctx: JitContext, report: String): Nothing {
        let code = ctx.errCode
        if (code == ErrCode.INTERRUPT) {
            throw InterruptedException('调用被中断（-2，§2）')
        }
        if (code == ErrCode.HOST_EXCEPTION) {
            // 宿主异常：桥负责打印**完整仓颉栈**（原始异常对象经 cause 旁路带出）。
            match (HostFault.exceptionOf(ctx)) {
                case Some(ex) => ex.printStackTrace()
                case None => ()
            }
            match (HostFault.takeCause(ctx)) {
                case Some(c) => throw JitException(code, ctx.site, ctx.fnId, None, report, c)
                case None => throw JitException(code, ctx.site, ctx.fnId, None, report)
            }
        }
        throw JitException(code, ctx.site, ctx.fnId, None, report)
    }

    /** 三态收尾：成功返回值、DEOPT 重跑、其余按 `throwJit` 抛出。 */
    public static func finish(ctx: JitContext, retCell: Int64, replay: () -> Int64,
        report: String): Int64 {
        let code = ctx.errCode
        if (code == 0) {
            return retCell
        }
        if (code == ErrCode.DEOPT) {
            try {
                return replay()
            } catch (e: JitException) {
                throw e
            } catch (e: InterruptedException) {
                throw e
            } catch (e: Exception) {
                throw JitException(ErrCode.HELPER_PANIC, -1, ctx.fnId, None,
                    'DEOPT 重跑异常（兜底 99）', e.toString())
            }
        }
        JitReport.throwJit(ctx, report)
    }
}
