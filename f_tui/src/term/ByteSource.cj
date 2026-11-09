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
package fountain::f_tui.term

/// 字节来源（stdin）。测试注入假实现覆盖拆包、超时与 EOF。
public interface ByteSource {
    /// 在超时内读取一个字节；超时或 EOF 返回 `None`。
    func read(timeoutMs: Int64): Option<UInt8>
}

/// 基于 `PosixFfi.readByte` 的 `stdin` 字节来源。
public class StdinByteSource <: ByteSource {
    private let ffi: PosixFfi
    private let fd: Int32

    public init(ffi: PosixFfi, fd: Int32) {
        this.ffi = ffi
        this.fd = fd
    }

    public func read(timeoutMs: Int64): Option<UInt8> {
        ffi.readByte(fd, timeoutMs)
    }
}
