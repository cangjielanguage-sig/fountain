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
package fountain::fsync.server

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import std.time.DateTime

/** DateTime.Max 替代：9999-12-31 23:59:59 */
private let MAX_DATETIME = DateTime.parse('9999-12-31T23:59:59')

internal struct WatchEntry {
    let pattern: String
    let expiry: DateTime         // MAX_DATETIME 表示永不超时
    let notify: (Array<Byte>) -> Unit  // 通知回调

    internal init(pattern: String, expiry: DateTime, notify: (Array<Byte>) -> Unit) {
        this.pattern = pattern
        this.expiry = expiry
        this.notify = notify
    }
}

public class WatchManager {
    private let exactWatchers = HashMap<String, ArrayList<WatchEntry>>()
    private let prefixWatchers = HashMap<String, ArrayList<WatchEntry>>()
    private let globWatchers = HashMap<String, ArrayList<WatchEntry>>()
    private let mutex = Mutex()

    public init() {
        // 后台线程每 1 秒清理过期 Watch
        let mgr = this
        spawn {
            while (true) {
                sleep(Duration.second)
                mgr.cleanupExpired()
            }
        }
    }

    public func registerExact(key: String, timeout: Duration, callback: (Array<Byte>) -> Unit): Unit {
        synchronized(mutex) {
            let entries = if (let Some(entries) <- exactWatchers.get(key)) {
                entries
            } else {
                let entries = ArrayList<WatchEntry>()
                exactWatchers[key] = entries
                entries
            }
            entries.add(WatchEntry(key, calcExpiry(timeout), callback))
        }
    }

    public func registerPrefix(prefix: String, timeout: Duration, callback: (Array<Byte>) -> Unit): Unit {
        synchronized(mutex) {
            let entries = if (let Some(entries) <- prefixWatchers.get(prefix)) {
                entries
            } else {
                let entries = ArrayList<WatchEntry>()
                prefixWatchers[prefix] = entries
                entries
            }
            entries.add(WatchEntry(prefix, calcExpiry(timeout), callback))
        }
    }

    public func registerGlob(pattern: String, timeout: Duration, callback: (Array<Byte>) -> Unit): Unit {
        synchronized(mutex) {
            let entries = if (let Some(entries) <- globWatchers.get(pattern)) {
                entries
            } else {
                let entries = ArrayList<WatchEntry>()
                globWatchers[pattern] = entries
                entries
            }
            entries.add(WatchEntry(pattern, calcExpiry(timeout), callback))
        }
    }

    public func unwatch(key: String): Unit {
        synchronized(mutex) {
            exactWatchers.remove(key)
        }
    }

    public func unwatchPrefix(prefix: String): Unit {
        synchronized(mutex) {
            prefixWatchers.remove(prefix)
        }
    }

    public func unwatchGlob(pattern: String): Unit {
        synchronized(mutex) {
            globWatchers.remove(pattern)
        }
    }

    /** 数据变更时通知所有匹配的 Watcher */
    public func notify(key: String, newValue: Array<Byte>): Unit {
        let matched = ArrayList<WatchEntry>()
        synchronized(mutex) {
            // 精确匹配
            if (let Some(entries) <- exactWatchers.get(key)) {
                for (entry in entries) {
                    matched.add(entry)
                }
            }
            // 前缀匹配
            for ((prefix, entries) in prefixWatchers) {
                if (key.startsWith(prefix)) {
                    for (entry in entries) {
                        matched.add(entry)
                    }
                }
            }
            // 通配符匹配
            for ((pattern, entries) in globWatchers) {
                if (keyMatchesGlob(key, pattern)) {
                    for (entry in entries) {
                        matched.add(entry)
                    }
                }
            }
        }
        // 在锁外执行回调，防止死锁
        for (entry in matched) {
            if (DateTime.now() < entry.expiry) {
                try { entry.notify(newValue) } catch (_: Exception) {}
            }
        }
    }

    private func cleanupExpired(): Unit {
        let now = DateTime.now()
        synchronized(mutex) {
            cleanupMap(exactWatchers, now)
            cleanupMap(prefixWatchers, now)
            cleanupMap(globWatchers, now)
        }
    }

    private static func cleanupMap(map: HashMap<String, ArrayList<WatchEntry>>, now: DateTime): Unit {
        let expired = ArrayList<String>()
        for ((key, entries) in map) {
            var i = 0
            while (i < entries.size) {
                if (entries[i].expiry <= now) {
                    entries.remove(at: i)
                } else {
                    i++
                }
            }
            if (entries.isEmpty()) {
                expired.add(key)
            }
        }
        for (key in expired) {
            map.remove(key)
        }
    }

    private static func calcExpiry(timeout: Duration): DateTime {
        if (timeout == Duration.Zero) {
            MAX_DATETIME
        } else {
            DateTime.now() + timeout
        }
    }

    /** 简易通配符匹配（仅支持 *） */
    private static func keyMatchesGlob(key: String, pattern: String): Bool {
        if (pattern == '*') {
            return true
        }
        let parts = pattern.split('*')
        if (parts.size == 1) {
            return key == pattern
        }
        var pos = 0
        for (i in 0..parts.size) {
            let part = parts[i]
            if (part.isEmpty()) {
                continue
            }
            if (i == 0) {
                if (!key.startsWith(part)) { return false }
                pos = part.size
            } else if (i == parts.size - 1) {
                if (!key.endsWith(part)) { return false }
            } else {
                if (let Some(idx) <- key.indexOf(part, pos)) {
                    pos = idx + part.size
                } else {
                    return false
                }
            }
        }
        true
    }
}
