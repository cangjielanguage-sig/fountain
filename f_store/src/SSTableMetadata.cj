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
package fountain::f_store

/** SSTable 元数据 */
class SSTableMetadata {
    let minKey: ByteArray
    let maxKey: ByteArray
    let entryCount: Int64
    let level: Int64
    let sequenceStart: Int64
    let sequenceEnd: Int64
    let filePath: String

    init(minKey: ByteArray, maxKey: ByteArray, entryCount: Int64, level: Int64,
         sequenceStart: Int64, sequenceEnd: Int64, filePath: String) {
        this.minKey = minKey
        this.maxKey = maxKey
        this.entryCount = entryCount
        this.level = level
        this.sequenceStart = sequenceStart
        this.sequenceEnd = sequenceEnd
        this.filePath = filePath
    }
}
