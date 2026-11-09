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
package fountain::fprobe.report

import std.env.getTempDirectory
import fountain::f_io.*
import fountain::f_time.*
import fountain::f_util.UUID

/** 一个待发送的附件文件。 */
public class Attachment {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        this.name = name
        this.path = path
    }
}

/**
 * 报告批次的临时附件目录（设计 D12）。
 *
 * 每个批次一个目录，文件名固定为 `<node>-<metric>.svg`；发送完成后整体递归
 * 删除。节点名中的路径分隔符会被替换，避免附件跑出批次目录。
 */
public class AttachmentStore {
    public let dir: String
    private let root: Path

    public init(dir: String) {
        this.dir = dir
        this.root = Path(dir)
        if (!exists(this.root)) {
            Directory.create(this.root, recursive: true)
        }
    }

    /** 在系统临时目录下创建唯一批次目录。 */
    public static func createTemp(prefix!: String = "fprobe-report"): AttachmentStore {
        let stamp = DateTime.now().toUnixEpochMillis()
        let uuid = UUID.random().toHexString()
        let short = if (uuid.size >= 8) {
            uuid[0..8]
        } else {
            uuid
        }
        let path = getTempDirectory().join('${prefix}-${stamp}-${short}')
        AttachmentStore(path.toString())
    }

    /** 附件名：节点与指标中的路径分隔符被清洗，指标的点替换为下划线。 */
    public static func fileNameFor(node: String, metric: String): String {
        let safeNode = sanitize(node, "node")
        let safeMetric = sanitize(metric.replace(".", "_"), "metric")
        '${safeNode}-${safeMetric}.svg'
    }

    public func write(node: String, metric: String, svg: String): Attachment {
        writeRaw(fileNameFor(node, metric), svg)
    }

    /** 写入固定文件名的附件（如 `topology.svg`）。 */
    public func writeRaw(name: String, content: String): Attachment {
        let fileName = sanitize(name, "attachment")
        let path = root.join(fileName)
        File.writeTo(path, content.toArray())
        Attachment(fileName, path.toString())
    }

    /** 递归删除整个批次目录；重复调用无副作用。 */
    public func cleanup(): Unit {
        if (!dir.isEmpty()) {
            removeIfExists(dir, recursive: true)
        }
    }

    private static func sanitize(value: String, fallback: String): String {
        var result = value.trimAscii()
        result = result.replace("/", "_").replace("\\", "_").replace(":", "_").replace(" ", "_")
        if (result.isEmpty()) {
            fallback
        } else {
            result
        }
    }
}
