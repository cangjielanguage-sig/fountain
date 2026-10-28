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
package fountain::f_zip

/**
 * 读取侧的四道上限（可覆盖的只读配置）。
 *
 * - `maxEntrySize`：单条目解压上限，超了中断并报错，**不返回部分数据**
 * - `maxTotalSize`：**每个 `ZipReader` 实例**的累计解压上限，不是进程级全局闸门；
 *   要限制一次批量导入的总量，调用方得自己持配额再逐次传入
 * - `maxEntries`：中央目录条目数上限，**只服务读取**，在解析中央目录的过程中就拒绝
 * - `ratioWarnThreshold`：压缩比告警阈值，只记 warning，不拦截
 *
 * 计数一律按**实际解压出的字节**累加，不采信 header 里的 `uncompressedSize`。
 */
public struct ZipLimits {
    /** 单条目解压上限，默认 512 MB。 */
    public let maxEntrySize: Int64
    /** 每个 reader 实例的累计解压上限，默认 2 GB。 */
    public let maxTotalSize: Int64
    /** 中央目录可接受的条目数上限，默认 65535。 */
    public let maxEntries: Int64
    /** 压缩比告警阈值，默认 1000（只告警）。 */
    public let ratioWarnThreshold: Int64

    public init(
        maxEntrySize!: Int64 = 512 * 1024 * 1024,
        maxTotalSize!: Int64 = 2 * 1024 * 1024 * 1024,
        maxEntries!: Int64 = 65535,
        ratioWarnThreshold!: Int64 = 1000
    ) {
        this.maxEntrySize = maxEntrySize
        this.maxTotalSize = maxTotalSize
        this.maxEntries = maxEntries
        this.ratioWarnThreshold = ratioWarnThreshold
    }
}
