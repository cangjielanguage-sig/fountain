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
package fountain::fsync.base

import std.io.{ByteBuffer, InputStream, SeekPosition}
import fountain::f_codec.{Decoder}
import fountain::f_codec.default.DefaultCodec
import fountain::f_data.*
import fountain::f_data.macros.*

// REGISTER / PUBLISH 请求体
@DataAssist[props fields]
public class SyncData {
    private var key: String = ''
    private var version: Int64 = 0
    private var value: Array<Byte> = []

    public init() {}
    public init(key: String, version: Int64, value: Array<Byte>) {
        this.key = key
        this.version = version
        this.value = value
    }

    /** 编码泛型值 T，返回编码后的字节（避免外部手动编码） */
    public static func encodeValue<T>(key: String, version: Int64, value: T): SyncData where T <: DataFields<T> {
        let buf = ByteBuffer()
        DefaultCodec().encode(value).finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let size = buf.seek(SeekPosition.End(0))
        buf.seek(SeekPosition.Begin(0))
        let raw = Array<Byte>(size, repeat: 0u8)
        buf.read(raw)
        SyncData(key, version, raw)
    }
    public static func encodeValue<T>(key: String, value: T): SyncData where T <: DataFields<T> {
        SyncData.encodeValue<T>(key, 0, value)
    }

    /** 从字节解码泛型值 T */
    public func decodeValue<T>(): ?T where T <: DataFields<T> {
        DefaultCodec().decode<T>(ByteBuffer(value))
    }
}

// GET 响应体
@DataAssist[props fields]
public class ValueData {
    private var value: ?Array<Byte> = None

    public init() {}
    public init(value: ?Array<Byte>) {
        this.value = value
    }
}

// Watch 注册
@DataAssist[props fields]
public class WatchData {
    private var key: String = ''
    private var timeout: Duration = Duration.Zero

    public init() {}
    public init(key: String, timeout!: Duration = Duration.Zero) {
        this.key = key
        this.timeout = timeout
    }
}

// Watch 变更通知
@DataAssist[props fields]
public class WatchNotifyData {
    private var key: String = ''
    private var value: ?Array<Byte> = None

    public init() {}
    public init(key: String, value: ?Array<Byte>) {
        this.key = key
        this.value = value
    }
}

// PREFIX / GLOB 请求
@DataAssist[props fields]
public class PatternData {
    private var pattern: String = ''

    public init() {}
    public init(pattern: String) {
        this.pattern = pattern
    }
}

// DEREGISTER / GET 请求
@DataAssist[props fields]
public class KeyData {
    private var key: String = ''

    public init() {}
    public init(key: String) {
        this.key = key
    }
}

// 扫描结果条目
@DataAssist[props fields]
public class ScanEntry {
    private var key: String = ''
    private var value: Array<Byte> = []

    public init() {}
    public init(key: String, value: Array<Byte>) {
        this.key = key
        this.value = value
    }
}

// 扫描结果列表（避免 ArrayList<ScanEntry> 泛型编解码问题）
@DataAssist[props fields]
public class ScanResult {
    private var keys: ArrayList<String> = ArrayList<String>()
    private var values: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()

    public init() {}
    public func add(key: String, value: Array<Byte>): Unit {
        keys.add(key)
        values.add(value)
    }
    public prop size: Int64 {
        get() { keys.size }
    }

    /** 将 values[index] 解码为类型 T，返回 (key, T) */
    public func decode<T>(index: Int64): ?(String, T) where T <: DataFields<T> {
        if (index < 0 || index >= keys.size) { return None }
        let buf = ByteBuffer(values[index])
        let decoder = DefaultCodec()
        if (let Some(v) <- decoder.decode<T>(buf)) {
            (keys[index], v)
        } else {
            None
        }
    }
}

// Watch 通知值
public enum WatchedValue {
    | Value(Array<Byte>)
    | Deleted
}
