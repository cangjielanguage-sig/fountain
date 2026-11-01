/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_protocol.default

public class MessageID <: Hashable & Equatable<MessageID> & ToString {
    public static let pidgen: ProcessID = CurrentProcessID.instance
    private let hash: Int64
    public MessageID(
        public let time!: DateTime = DateTime.now(),
        public let pid!: Int64 = pidgen.value,
        public let tid!: Int64 = Thread.currentThread.id,
        public let hostId!: Int64 = ProtocolConfig.getProtocolHostId()
    ){
        // hostId 必填：`(pid, tid, 时间戳)` 只在单机内唯一，跨机器 pid/tid 会重复（容器里都是 1），
        // 集群维度只能由 hostId 提供；配 0 等于放弃跨节点唯一性，直接拒绝而不是静默降级
        if (hostId == 0) {
            throw IllegalArgumentException(
                "MessageID.hostId must not be 0: set '${ProtocolConfig.protocol_hostId}' to a unique id per host in the cluster")
        }
        // 用绝对时刻算hash：同一时刻不管在哪一侧以什么时区表示（本地/UTC），都必须是同一个id
        hash = HashBuilder().append(hostId).append(pid).append(tid)
            .append(time.toUnixTimeStamp().toNanoseconds()).build()
    }
    public func hashCode(): Int64 {
        hash
    }
    public operator func ==(other: MessageID): Bool {
        this.hash == other.hash && 
        this.hostId == other.hostId &&
        this.pid == other.pid && 
        this.tid == other.tid &&
        this.time.toUnixTimeStamp() == other.time.toUnixTimeStamp()
    }
    public func toString(): String {
        // 23 位时间戳固定按 UTC 墙钟输出：`time` 可能是本地时区实例，
        // 直接 format 会让同一绝对时刻在不同时区产生不同 id（A02）。
        let utc = DateTime.fromUnixTimeStamp(time.toUnixTimeStamp())
        '${pid}_${tid}_${hostId}_${utc.format("yyyyMMddHHmmssSSS")}'
    }
}
