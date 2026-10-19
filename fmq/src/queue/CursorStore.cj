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
package fountain::fmq.queue

import std.collection.ArrayList
import std.fs.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_io.{ByteBuffer, LogPosition}
import fountain::fmq.meta.MQFileNames

/**
 * 消费位点落盘：`metas/offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor`。
 *
 * 文件内容是两个独立编码的 Int64（段号 + 段内偏移）；写入走「`.tmp` + rename」原子覆盖。
 */
protected class CursorStore {
    private let metaRoot: String

    protected init(metaRoot: String) {
        this.metaRoot = metaRoot
    }

    private func pathOf(topic: String, queueIndex: Int64, group: String): String {
        "${metaRoot}/${MQFileNames.cursorFile(topic, queueIndex, group)}"
    }

    protected func load(topic: String, queueIndex: Int64, group: String): ?LogPosition {
        let path = pathOf(topic, queueIndex, group)
        if (!exists(path)) {
            return None<LogPosition>
        }
        var bytes: Array<Byte> = []
        try {
            bytes = readAll(path)
        } catch (_: Exception) {
            return None<LogPosition>
        }
        let codec = DefaultCodec()
        try {
            let buffer = ByteBuffer(bytes)
            let seq = match (codec.decode<Int64>(buffer)) {
                case Some(v) => v
                case None => return None<LogPosition>
            }
            let offset = match (codec.decode<Int64>(buffer)) {
                case Some(v) => v
                case None => return None<LogPosition>
            }
            Some(LogPosition(seq, offset))
        } catch (_: Exception) {
            None<LogPosition>
        } finally {
            codec.release()
        }
    }

    protected func save(topic: String, queueIndex: Int64, group: String, position: LogPosition): Unit {
        let path = pathOf(topic, queueIndex, group)
        let parent = Path(path).parent
        if (!exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        let codec = DefaultCodec()
        var bytes: Array<Byte> = []
        try {
            codec.encode(position.seq).encode(position.offset)
            bytes = codec.finish().asBytes().getOrThrow()
        } finally {
            codec.release()
        }
        let tmp = "${path}.tmp"
        let file = File.create(tmp)
        try {
            file.write(bytes)
        } finally {
            if (!file.isClosed()) {
                file.close()
            }
        }
        rename(tmp, to: path, overwrite: true)
    }

    /** 删除主题下的全部游标位点。 */
    protected func removeAllOf(topic: String): Unit {
        let dir = "${metaRoot}/offsets/${MQFileNames.escape(topic)}"
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }

    /** 删除某订阅组在各队列上的位点；其它组不受影响。 */
    protected func removeGroup(topic: String, group: String): Unit {
        let dir = "${metaRoot}/offsets/${MQFileNames.escape(topic)}"
        if (!exists(dir)) {
            return
        }
        let fileName = "${MQFileNames.escape(group)}.cursor"
        let queues = ArrayList<String>()
        Directory.walk(dir) {info: FileInfo =>
            if (info.isDirectory()) {
                queues.add(info.path.toString())
            }
            true
        }
        for (queueDir in queues) {
            let path = "${queueDir}/${fileName}"
            if (exists(path)) {
                remove(path)
            }
        }
    }

    private static func readAll(path: String): Array<Byte> {
        let file = File(path, OpenMode.Read)
        try {
            let size = file.info.size
            let bytes = Array<Byte>(size, repeat: 0u8)
            var got = 0i64
            while (got < size) {
                let n = file.read(bytes[got..size])
                if (n <= 0) {
                    break
                }
                got += n
            }
            bytes
        } finally {
            if (!file.isClosed()) {
                file.close()
            }
        }
    }
}
