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

import std.fs.Path

/**
 * `add()` 走内存路径的条目大小上限，超过则落临时文件。
 *
 * 默认值按 `os` **编译期分档**：
 *
 * | 平台 | 默认 | 理由 |
 * | --- | --- | --- |
 * | Linux（服务器 / 桌面） | 64 MB | 可用堆通常几 GB，64 MB 条目峰值 128 MB 占比很小 |
 * | OHOS（手机 / 平板）/ 其他 | 16 MB | 可用堆常在 512 MB~2 GB，16 MB 条目峰值 32 MB 已占手机 3~6% |
 *
 * 不探测可用内存：那会让同一份代码在开发机与现场走不同路径，bug 只在一边出现。
 * 容器场景由调用方显式指定。
 */
// 与另一份保持同步
// 注意：鸿蒙的 os 也是 "Linux"（env 才是 'ohos'），所以这里必须带上 env，
// 否则 OHOS 会误拿服务器档的 64 MB。
@When[os == "Linux" && env == "gnu"]
private func defaultMemoryEntryThreshold(): Int64 {
    64 * 1024 * 1024
}

// 与另一份保持同步
@When[os != "Linux" || env != "gnu"]
private func defaultMemoryEntryThreshold(): Int64 {
    16 * 1024 * 1024
}

/**
 * 写入选项。**可变类**：预设只是"一次性设好一组默认值的便捷构造"，不是不可变模板，
 * 拿到之后可以随便改，下次取到的仍是新实例。
 */
public class ZipWriterOptions {
    /** `add()` 走内存路径的条目大小上限；超过则落临时文件后走流式路径。 */
    public var memoryEntryThreshold: Int64
    /** 临时目录；`None` 表示按"选项 → TMPDIR → 系统临时目录 → ./.fountain_tmp"四级解析。 */
    public var tempDir: ?Path
    /** 压缩方法，默认 Deflate；已经压过的数据（JPEG / MP4 / ZIP）用 Stored 更省 CPU。 */
    public var method: CompressionMethod

    public init(
        memoryEntryThreshold!: Int64 = defaultMemoryEntryThreshold(),
        tempDir!: ?Path = None,
        method!: CompressionMethod = CompressionMethod.Deflate
    ) {
        this.memoryEntryThreshold = memoryEntryThreshold
        this.tempDir = tempDir
        this.method = method
    }

    /** 服务器档：64 MB。 */
    public static func forServer(): ZipWriterOptions {
        ZipWriterOptions(memoryEntryThreshold: 64 * 1024 * 1024)
    }

    /** 低内存档：8 MB。真机测堆水位后再调。 */
    public static func forLowMemory(): ZipWriterOptions {
        ZipWriterOptions(memoryEntryThreshold: 8 * 1024 * 1024)
    }
}
