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

/** SSTable 状态 */
enum SSTableState <: Equatable<SSTableState> {
    | Writing   // 写入模式：可 write，不可 get/iterator/tailer
    | Readable  // 读取模式：可 get/iterator/tailer，不可 write
    | Closed    // 已关闭：任何操作抛 StoreClosedException

    public operator func ==(other: SSTableState): Bool {
        match ((this, other)) {
            case (Writing, Writing) | (Readable, Readable) | (Closed, Closed) => true
            case _ => false
        }
    }
}
