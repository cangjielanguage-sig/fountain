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
package fountain::fprobe.tui

import std.posix.isatty
import fountain::f_probe.{ProbeErrorCode, ProbeException}

/** 标准输出是否为交互式终端。 */
public interface TtyDetector {
    func isTty(): Bool
}

/** POSIX 标准输出的文件描述符固定为 1。 */
private const STDOUT_FILENO: Int32 = 1

/** 生产实现：直接问 POSIX，不依赖任何 TUI 库。 */
public class StdTtyDetector <: TtyDetector {
    public init() {}

    public func isTty(): Bool {
        isatty(STDOUT_FILENO)
    }
}

/**
 * 控制台模式的前置校验（spec「非 TTY」）。
 *
 * 非 TTY 不能得到可用的 raw mode，直接报错并把用户引向 `resident`，
 * 避免在重定向/CI 环境里输出一堆控制序列。
 */
public func requireTty(detector: TtyDetector): Unit {
    if (!detector.isTty()) {
        throw ProbeException(ProbeErrorCode.CONFIG,
            "标准输出不是 TTY，无法启动 TUI；请改用 `fprobe supervisor resident`")
    }
}
