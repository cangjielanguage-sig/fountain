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
package fountain::fdbm.route

import std.collection.HashMap
import std.convert.*
import fountain::f_base.*
import fountain::f_dbm.PartitionAlgorithm
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_util.{crc16, crc32, crc64, murmurHash}
import fountain::fdbm.config.SubstringSpec
import fountain::fdbm.exception.FdbmException

/** 按 UTF-8 字符串算 CRC / Murmur 后取模。 */
func bucketOfString(hash: UInt64, databases: Array<String>): String {
    let index = Int64(hash % UInt64(databases.size))
    databases[index]
}

func ensureDatabases(databases: Array<String>): Unit {
    if (databases.isEmpty()) {
        throw FdbmException(DbdErrorCode.PARTITION_CONFIG, 'partition algorithm requires at least one database')
    }
}

/** `'step'`：整数 ID 按步长分段；有效数据域 `[1, N*step]`，越界 `ROUTE_FAILED`。 */
protected class StepPartition <: PartitionAlgorithm {
    private let databases: Array<String>
    private let step: Int64
    private let limit: Int64

    public init(databases: Array<String>, step: Int64) {
        ensureDatabases(databases)
        if (step <= 0) {
            throw FdbmException(DbdErrorCode.PARTITION_CONFIG, 'step must be positive')
        }
        if (step > Int64.Max / databases.size) {
            throw FdbmException(DbdErrorCode.PARTITION_CONFIG, 'N * step overflows Int64')
        }
        this.databases = databases
        this.step = step
        this.limit = step * databases.size
    }

    public prop name: String {
        get() {
            'step'
        }
    }

    public func partition<K>(key: K): String {
        let id = keyAsInt64(key)
        if (id < 1 || id > limit) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'step partition key ${id} is outside [1, ${limit}]')
        }
        databases[(id - 1) / step]
    }

    /**
     * 范围 → 连续分片集合。
     *
     * @return 非空 = 命中的分片；空数组 = 可判定但无解（整段越界/反序）
     */
    public func partitionRange(lo: ?Int64, loInclusive: Bool, hi: ?Int64,
        hiInclusive: Bool): Array<String> {
        var low: Int64 = 1
        match (lo) {
            case Some(value) =>
                if (!loInclusive) {
                    if (value == Int64.Max) {
                        return Array<String>()
                    }
                    low = value + 1
                } else {
                    low = value
                }
            case None => low = 1
        }
        var high: Int64 = limit
        match (hi) {
            case Some(value) =>
                if (!hiInclusive) {
                    if (value == Int64.Min) {
                        return Array<String>()
                    }
                    high = value - 1
                } else {
                    high = value
                }
            case None => high = limit
        }
        if (low < 1) {
            low = 1
        }
        if (high > limit) {
            high = limit
        }
        if (low > high) {
            return Array<String>()
        }
        let start = (low - 1) / step
        let end = (high - 1) / step
        Array<String>(end - start + 1) {i => databases[start + i]}
    }

    private static func keyAsInt64<K>(key: K): Int64 {
        match (key) {
            case value: Int64 => value
            case value: Int32 => Int64(value)
            case value: Int16 => Int64(value)
            case value: Int8 => Int64(value)
            case value: UInt64 => Int64(value)
            case value: UInt32 => Int64(value)
            case value: UInt16 => Int64(value)
            case value: UInt8 => Int64(value)
            case value: String =>
                match (Int64.tryParse(value)) {
                    case Some(parsed) => parsed
                    case None => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                        'step partition key \'${value}\' is not an integer')
                }
            case _ => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'step partition key is not an integer')
        }
    }
}

/** `'hash'` / `'std'`：`key.hashCode()` 取模。 */
protected class HashPartition <: PartitionAlgorithm {
    private let databases: Array<String>
    private let label: String

    public init(databases: Array<String>, hashAlgorithm!: String = 'hash') {
        ensureDatabases(databases)
        this.databases = databases
        this.label = hashAlgorithm
    }

    public prop name: String {
        get() {
            label
        }
    }

    public func partition<K>(key: K): String {
        match (key) {
            case value: Hashable =>
                let hash = value.hashCode()
                let index = ((hash % databases.size) + databases.size) % databases.size
                databases[index]
            case _ => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'hash partition requires a Hashable key')
        }
    }
}

/** CRC 族：`crc16` / `crc32` / `crc64`。 */
protected class CrcPartition <: PartitionAlgorithm {
    private let databases: Array<String>
    private let kind: String

    public init(databases: Array<String>, kind: String) {
        ensureDatabases(databases)
        this.databases = databases
        this.kind = kind
    }

    public prop name: String {
        get() {
            kind
        }
    }

    public func partition<K>(key: K): String {
        let text = match (key) {
            case value: ToString => value.toString()
            case _ => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                '${kind} partition requires a ToString key')
        }
        if (kind == 'crc16') {
            return bucketOfString(UInt64(crc16(text)), databases)
        }
        if (kind == 'crc32') {
            return bucketOfString(UInt64(crc32(text)), databases)
        }
        bucketOfString(crc64(text), databases)
    }
}

/** Murmur3 x128：取低 64 位后取模。 */
protected class MurmurPartition <: PartitionAlgorithm {
    private let databases: Array<String>

    public init(databases: Array<String>) {
        ensureDatabases(databases)
        this.databases = databases
    }

    public prop name: String {
        get() {
            'murmur'
        }
    }

    public func partition<K>(key: K): String {
        let text = match (key) {
            case value: ToString => value.toString()
            case _ => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'murmur partition requires a ToString key')
        }
        let hash = murmurHash(text).hashCode()
        let index = ((hash % databases.size) + databases.size) % databases.size
        databases[index]
    }
}

/** `'substr'`：取 `[start, start+length)` 的 Unicode 码点子串再哈希。 */
protected class SubstringPartition <: PartitionAlgorithm {
    private let databases: Array<String>
    private let spec: SubstringSpec

    public init(databases: Array<String>, spec: SubstringSpec) {
        ensureDatabases(databases)
        if (spec.start < 0 || spec.length < 0) {
            throw FdbmException(DbdErrorCode.CONFIG, 'substr start/length must not be negative')
        }
        this.databases = databases
        this.spec = spec
    }

    public prop name: String {
        get() {
            'substr'
        }
    }

    public func partition<K>(key: K): String {
        let text = match (key) {
            case value: ToString => value.toString()
            case _ => throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'substr partition requires a ToString key')
        }
        let runes = text.toRuneArray()
        if (spec.start >= runes.size) {
            throw FdbmException(DbdErrorCode.ROUTE_FAILED,
                'substr key \'${text}\' is shorter than start ${spec.start}')
        }
        let end = if (spec.length == 0 || spec.length > runes.size - spec.start) {
            runes.size
        } else {
            spec.start + spec.length
        }
        let sub = String(runes[spec.start..end])
        if (spec.hash == 'std' || spec.hash == 'hash') {
            let hash = sub.hashCode()
            let index = ((hash % databases.size) + databases.size) % databases.size
            return databases[index]
        }
        if (spec.hash == 'crc16') {
            return bucketOfString(UInt64(crc16(sub)), databases)
        }
        if (spec.hash == 'crc32') {
            return bucketOfString(UInt64(crc32(sub)), databases)
        }
        if (spec.hash == 'crc64') {
            return bucketOfString(crc64(sub), databases)
        }
        let hash = murmurHash(sub).hashCode()
        let index = ((hash % databases.size) + databases.size) % databases.size
        databases[index]
    }
}

/**
 * 算法工厂：先查自定义，再查内置；未知/缺参数 → `PARTITION_CONFIG`。
 *
 * 「自定义优先」**不再承担覆盖语义**：启动自检（`FdbmConfig.validate`）已拒绝与内置重名的扩展，
 * 因此这里命中自定义时名称必然是非内置名。
 */
protected struct PartitionAlgorithmFactory {
    public static func create(name: String, databases: Array<String>, step: Int64,
        substr: ?SubstringSpec, custom: HashMap<String, PartitionAlgorithm>): PartitionAlgorithm {
        if (let Some(algorithm) <- custom.get(name)) {
            return algorithm
        }
        if (name == 'step') {
            return StepPartition(databases, step)
        }
        if (name == 'hash' || name == 'std') {
            return HashPartition(databases, hashAlgorithm: name)
        }
        if (name == 'crc16' || name == 'crc32' || name == 'crc64') {
            return CrcPartition(databases, name)
        }
        if (name == 'murmur') {
            return MurmurPartition(databases)
        }
        if (name == 'substr') {
            match (substr) {
                case Some(spec) => return SubstringPartition(databases, spec)
                case None => throw FdbmException(DbdErrorCode.PARTITION_CONFIG,
                    'substr algorithm requires fdbm_partition_substr__<table>')
            }
        }
        throw FdbmException(DbdErrorCode.PARTITION_CONFIG, 'unknown partition algorithm \'${name}\'')
    }
}
