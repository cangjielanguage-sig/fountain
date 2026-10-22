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
package fountain::fdbm.config

import std.collection.{ArrayList, HashMap, Map}

/** 一个物理节点（设计 §3.3）：`fdbm_db` 的一项 + 该节点的驱动/库/凭据。 */
protected class DatabaseNodeConfig {
    public let name: String
    public let host: String
    public let port: UInt16
    public let driverName: String
    public let databases: Array<String>
    public let username: String
    public let password: String

    public init(name: String, host: String, port: UInt16, driverName: String,
        databases: Array<String>, username: String, password: String) {
        this.name = name
        this.host = host
        this.port = port
        this.driverName = driverName
        this.databases = databases
        this.username = username
        this.password = password
    }

    /** `<driver>://user:pwd@host:port/database`（凭据按 URL 规则 % 编码）。 */
    public func url(database: String): String {
        let userInfo = if (username.isEmpty() && password.isEmpty()) {
            ''
        } else if (password.isEmpty()) {
            '${percentEncode(username)}@'
        } else {
            '${percentEncode(username)}:${percentEncode(password)}@'
        }
        '${driverName}://${userInfo}${host}:${port}/${percentEncode(database)}'
    }
}

/** 连接池参数（设计 §3.4），与 `f_dbpool.DatabasePool` 的构造参数一一对应。 */
protected class PoolConfig {
    public let initSize: Int64
    public let minSize: Int64
    public let maxSize: Int64
    public let checkOnCreation: Bool
    public let checkOnBorrowing: Bool
    public let checkOnReturning: Bool
    public let idleTimeout: Duration
    public let connectionLife: Duration
    public let checkInterval: Duration
    public let connectTimeout: Duration
    public let maxWaiting: Duration
    public let checkSql: String

    public init(initSize!: Int64 = 1, minSize!: Int64 = 1, maxSize!: Int64 = 1,
        checkOnCreation!: Bool = false, checkOnBorrowing!: Bool = true, checkOnReturning!: Bool = false,
        idleTimeout!: Duration = Duration.Zero, connectionLife!: Duration = Duration.second * 86400,
        checkInterval!: Duration = Duration.second * 300, connectTimeout!: Duration = Duration.millisecond * 50,
        maxWaiting!: Duration = Duration.millisecond * 30000, checkSql!: String = 'select 1') {
        this.initSize = initSize
        this.minSize = minSize
        this.maxSize = maxSize
        this.checkOnCreation = checkOnCreation
        this.checkOnBorrowing = checkOnBorrowing
        this.checkOnReturning = checkOnReturning
        this.idleTimeout = idleTimeout
        this.connectionLife = connectionLife
        this.checkInterval = checkInterval
        this.connectTimeout = connectTimeout
        this.maxWaiting = maxWaiting
        this.checkSql = checkSql
    }
}

/** 节点/库的读写权重（设计 §3.3）：`0` 表示不参与该方向。 */
protected class NodeWeight {
    public let write: Int64
    public let read: Int64

    public init(write!: Int64 = 1, read!: Int64 = 1) {
        this.write = write
        this.read = read
    }

    public func canWrite(): Bool {
        write > 0
    }

    public func canRead(): Bool {
        read > 0
    }
}

/** 负载均衡配置：算法 + 节点级/库级权重（库级优先）。 */
protected class LoadBalanceConfig {
    public let algorithm: String
    private let weights: Map<String, NodeWeight>

    public init(algorithm!: String = 'random', weights!: Map<String, NodeWeight> = HashMap<String, NodeWeight>()) {
        this.algorithm = algorithm
        this.weights = weights
    }

    /** 先查 `<node>__<database>`，再查 `<node>`，都没有 → 1/1。 */
    public func weight(node: String, database: String): NodeWeight {
        let qualified = '${node}__${database}'
        if (let Some(found) <- weights.get(qualified)) {
            return found
        }
        if (let Some(found) <- weights.get(node)) {
            return found
        }
        NodeWeight()
    }

}

/** 子串分库参数（`fdbm_partition_substr__<table>`）。 */
protected class SubstringSpec {
    public let start: Int64
    public let length: Int64
    public let hash: String

    public init(start: Int64, length: Int64, hash: String) {
        this.start = start
        this.length = length
        this.hash = hash
    }
}

/** 分库规则（`fdbm_partition__<table>`）。 */
protected class PartitionRuleConfig {
    public let database: String
    public let table: String
    public let algorithm: String
    public let column: String
    public let substr: ?SubstringSpec

    public init(database: String, table: String, algorithm: String, column: String,
        substr!: ?SubstringSpec = None) {
        this.database = database
        this.table = table
        this.algorithm = algorithm
        this.column = column
        this.substr = substr
    }
}

/** 全局表（`fdbm_global__<table>`）。 */
protected class GlobalTableConfig {
    public let database: String
    public let table: String

    public init(database: String, table: String) {
        this.database = database
        this.table = table
    }
}

/** 分库缓存（设计 §3.1）。 */
protected class CacheConfig {
    public let enabled: Bool
    public let expire: ?Duration
    public let size: Int64
    public let path: String

    public init(enabled: Bool, expire: ?Duration, size: Int64, path: String) {
        this.enabled = enabled
        this.expire = expire
        this.size = size
        this.path = path
    }
}

/** ID 生成器（`fdbm_idmaker`）。 */
protected class IdMakerConfig {
    public let kind: String
    public let arg: ?String

    public init(kind: String, arg!: ?String = None) {
        this.kind = kind
        this.arg = arg
    }
}

/** URL 中的单项 % 编码：除 unreserved 字符外一律编码。 */
func percentEncode(value: String): String {
    let bytes = value.toArray()
    let out = ArrayList<Byte>()
    for (byte in bytes) {
        if (isUnreserved(byte)) {
            out.add(byte)
        } else {
            out.add(0x25) // '%'
            out.add(hexDigit(byte >> 4))
            out.add(hexDigit(byte & 0x0F))
        }
    }
    String.fromUtf8(out.toArray())
}

private func isUnreserved(byte: UInt8): Bool {
    (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
        (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
}

private func hexDigit(nibble: UInt8): UInt8 {
    if (nibble < 10) {
        nibble + 0x30
    } else {
        nibble - 10 + 0x41
    }
}
