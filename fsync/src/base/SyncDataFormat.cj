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
    public func get(i: Int64): (String, Array<Byte>) {
        (keys[i], values[i])
    }
    public prop size: Int64 {
        get() { keys.size }
    }
}

// Watch 通知值
public enum WatchedValue {
    | Value(Array<Byte>)
    | Deleted
}
