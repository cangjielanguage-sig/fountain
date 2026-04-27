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

/** LSM-Tree 条目值。不可变对象。 */
public class EntryValue {
    /** 值，None 表示 tombstone（删除标记） */
    public let value: ?Array<Byte>
    /** 全局单调递增序列号 */
    public let sequence: Int64
    /** 过期时间戳（纳秒），None = 永不过期 */
    public let expireAt: ?Int64

    public init(value: ?Array<Byte>, sequence: Int64, expireAt!: ?Int64 = None) {
        this.value = value
        this.sequence = sequence
        this.expireAt = expireAt
    }
}
