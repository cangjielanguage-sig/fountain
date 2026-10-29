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

import std.collection.ArrayList
import std.env
import std.fs.{Directory, File, Path, exists}
import fountain::f_log.LoggerFactory

/**
 * 大条目落盘的临时目录解析。
 *
 * 顺序固定：
 * 1. `ZipWriterOptions.tempDir`（显式指定）
 * 2. 环境变量 `TMPDIR`
 * 3. 系统临时目录
 * 4. 当前工作目录下的 `.fountain_tmp/`（**自动创建**，用于 OHOS 这种没有 `/tmp` 的沙箱）
 *
 * 四级都失败直接抛错，**不降级回内存路径**——那等于把 OOM 风险重新引回来，
 * 而且调用方完全无感。
 */
internal class TempSpill {
    private static let logger = LoggerFactory.getLogger<TempSpill>()

    /** 四级候选目录（按优先级）。抽出来是为了能单独验证顺序。 */
    public static func candidates(options: ZipWriterOptions): ArrayList<Path> {
        let list = ArrayList<Path>()
        if (let Some(d) <- options.tempDir) {
            list.add(d)
        }
        if (let Some(dir) <- env.getVariable("TMPDIR")) {
            if (!dir.isEmpty()) {
                list.add(Path(dir))
            }
        }
        list.add(env.getTempDirectory())
        list.add(fallbackDirectory())
        list
    }

    public static func fallbackDirectory(): Path {
        env.getWorkingDirectory().join(".fountain_tmp")
    }

    /** 按 `options` 解析四级目录后创建临时文件。 */
    public static func createFile(options: ZipWriterOptions, entryName: String, size: Int64): File {
        createIn(candidates(options).toArray(), entryName, size, options.memoryEntryThreshold)
    }

    /** 按给定的候选目录列表创建临时文件；全部失败抛 `ZipException`。 */
    public static func createIn(candidates: Array<Path>, entryName: String, size: Int64, threshold: Int64): File {
        if (candidates.size == 0) {
            throw ZipException("无法创建临时文件，且条目大小 ${size} 超过内存路径阈值 ${threshold}")
        }
        let fallback = fallbackDirectory().toString()
        for (candidate in candidates) {
            try {
                if (!exists(candidate)) {
                    // 只有兜底目录才自动创建：显式给出的目录写不进去，说明调用方的预期已落空，
                    // 此时静默创建一个新目录反而掩盖问题。
                    if (candidate.toString() != fallback) {
                        continue
                    }
                    Directory.create(candidate, recursive: true)
                }
                let file = File.createTemp(candidate)
                logger.debug(
                    "zip: 条目 '${entryName}' ${size} 字节超过内存路径阈值 ${threshold}，落盘到临时文件 ${file.info.path}"
                )
                return file
            } catch (_: Exception) {
                continue
            }
        }
        throw ZipException("无法创建临时文件，且条目大小 ${size} 超过内存路径阈值 ${threshold}")
    }
}
