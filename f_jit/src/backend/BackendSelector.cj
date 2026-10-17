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

import fountain::f_base.Arch
import fountain::f_base.OS
import fountain::f_jit.base.DiagCode
import fountain::f_jit.base.DiagnosticLevel
import fountain::f_jit.base.DiagnosticsSink
import fountain::f_jit.base.Engine
import fountain::f_jit.base.JitMode

/**
 * 引擎选择（design §6.3.4、§12.1、plan S5.3）。
 *
 * | 模式 | Linux + 支持指令集 | 其他 |
 * |---|---|---|
 * | `Off` | Interp | Interp |
 * | `Auto` / `Force` | Jit + 对应后端 | Interp（`Warn/JitFallback`，绝不报错） |
 *
 * 当前指令集支持集 = 仓颉 SDK for Linux 的支持集（x86_64 / aarch64）。
 */
public class BackendSelector {
    /** 按当前平台选择。 */
    protected static func select(mode: JitMode, diag: DiagnosticsSink): (Engine, ?Backend) {
        BackendSelector.selectFor(mode, OS.current, Arch.current, diag)
    }

    /** 可注入 OS/Arch 的矩阵入口（测试用；语义与 `select` 完全一致）。 */
    protected static func selectFor(mode: JitMode, os: OS, arch: Arch,
        diag: DiagnosticsSink): (Engine, ?Backend) {
        if (mode == JitMode.Off) {
            return (Engine.Interp, None)
        }
        if (!os.isLinux) {
            diag.diag(DiagnosticLevel.Warn, DiagCode.JitFallback,
                '非 Linux 平台（${os}）：JIT 不可用，降级解释器（§12.1）')
            return (Engine.Interp, None)
        }
        match (arch) {
            case Arch.x86_64 => (Engine.Jit, Some(BackendX86_64()))
            case Arch.aarch64 => (Engine.Jit, Some(BackendAArch64()))
        }
    }
}

/** x86_64 后端（P5.4–P5.8 落地；当前为契约占位）。 */
internal class BackendX86_64 <: Backend {
    public prop name: String {
        get() {
            'x86_64'
        }
    }

    public func abiSummary(): String {
        'CTX=r15 FP=rbp SP=rsp RETV=rax TMP=r10/r11'
    }

    public func entryThunkBase(): Int64 {
        0
    }

    public func entryThunkFor(fnId: UInt32): Int64 {
        0
    }
}

/** AArch64 后端（P5.9 落地；当前为契约占位）。 */
internal class BackendAArch64 <: Backend {
    public prop name: String {
        get() {
            'aarch64'
        }
    }

    public func abiSummary(): String {
        'CTX=x19 FP=x29 SP=sp RETV=x0 TMP=x9/x10'
    }

    public func entryThunkBase(): Int64 {
        0
    }

    public func entryThunkFor(fnId: UInt32): Int64 {
        0
    }
}
