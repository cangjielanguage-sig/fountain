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
 * 编译缓存键（§8.7 / S5.13）：`(arch, cpuFeatures, bytecodeFingerprint)`。
 *
 * **仅驻内存**——不写磁盘、不含装载地址或时间戳；进程重启后同一键会重新编译，
 * 且机器码逐字节一致（`A64`/`x86` 发射器均无地址相关随机量）。
 */
public class CompileCacheKey <: Hashable & Equatable<CompileCacheKey> {
    /** 指令集名（`x86_64` / `aarch64`）。 */
    public let arch: String
    /** 影响代码生成的 CPU 特性集合（规范序、逗号分隔；空串 = 基线）。 */
    public let cpuFeatures: String
    /** 字节码指纹（`Fingerprint`，S2.16）。 */
    public let fingerprint: UInt64

    public init(arch: String, cpuFeatures: String, fingerprint: UInt64) {
        this.arch = arch
        this.cpuFeatures = cpuFeatures
        this.fingerprint = fingerprint
    }

    public func hashCode(): Int64 {
        '${this.arch}|${this.cpuFeatures}|${this.fingerprint}'.hashCode()
    }

    public operator func ==(other: CompileCacheKey): Bool {
        this.arch == other.arch && this.cpuFeatures == other.cpuFeatures &&
            this.fingerprint == other.fingerprint
    }

    public func toString(): String {
        '${this.arch}/${this.cpuFeatures}/${this.fingerprint}'
    }
}
