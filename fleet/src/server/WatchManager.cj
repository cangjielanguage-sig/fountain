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
package fountain::fleet.server

import std.collection.{ArrayList, HashMap}
import std.sync.{Mutex, Condition, AtomicBool}
import std.time.DateTime

/** Watch 通知 Future：阻塞等待数据变化，可通过 set 从外部唤醒 */
public class WatchFuture {
    private let mutex = Mutex()
    private let cond: Condition
    private var value: ?Array<Byte> = None
    private var done = false

    internal init() {
        cond = synchronized(mutex) { mutex.condition() }
    }

    /** 设置 Watch 结果（由 notify 调用） */
    public func set(data: Array<Byte>): Unit {
        synchronized(mutex) {
            value = data
            done = true
            cond.notifyAll()
        }
    }

    /** 阻塞等待结果 */
    public func get(): Array<Byte> {
        synchronized(mutex) {
            while (!done) { cond.wait() }
            value.getOrThrow()
        }
    }

    /** 带超时等待 */
    public func tryGet(timeout: Duration): ?Array<Byte> {
        let deadline = DateTime.now() + timeout
        synchronized(mutex) {
            while (!done && DateTime.now() < deadline) {
                cond.wait(timeout: deadline - DateTime.now())
            }
            value
        }
    }

    /** 立即获取（非阻塞） */
    public func tryGet(): ?Array<Byte> {
        synchronized(mutex) {
            value
        }
    }
}

internal struct WatchEntry {
    let pattern: String
    let expiry: ?DateTime        // None 表示永不超时
    let future: WatchFuture

    internal init(pattern: String, expiry: ?DateTime, future: WatchFuture) {
        this.pattern = pattern
        this.expiry = expiry
        this.future = future
    }
}

public class WatchManager <: Resource {
    private let exactWatchers = HashMap<String, ArrayList<WatchEntry>>()
    private let prefixWatchers = HashMap<String, ArrayList<WatchEntry>>()
    private let globWatchers = HashMap<String, ArrayList<WatchEntry>>()
    private let mutex = Mutex()
    private let running = AtomicBool(true)

    public init() {
        let runningRef = this.running
        spawn {
            while (runningRef.load()) {
                sleep(Duration.second)
                try {
                    cleanupExpired()
                } catch (_: Exception) {
                    // 清理异常不中断线程
                }
            }
        }
    }

    public func close(): Unit {
        running.store(false)
    }

    public func isClosed(): Bool {
        !running.load()
    }

    public func registerExact(key: String, timeout: Duration): WatchFuture {
        let future = WatchFuture()
        synchronized(mutex) {
            let entries = if (let Some(entries) <- exactWatchers.get(key)) {
                entries
            } else {
                let entries = ArrayList<WatchEntry>()
                exactWatchers[key] = entries
                entries
            }
            entries.add(WatchEntry(key, calcExpiry(timeout), future))
        }
        future
    }

    public func registerPrefix(prefix: String, timeout: Duration): WatchFuture {
        let future = WatchFuture()
        synchronized(mutex) {
            let entries = if (let Some(entries) <- prefixWatchers.get(prefix)) {
                entries
            } else {
                let entries = ArrayList<WatchEntry>()
                prefixWatchers[prefix] = entries
                entries
            }
            entries.add(WatchEntry(prefix, calcExpiry(timeout), future))
        }
        future
    }

    public func registerGlob(pattern: String, timeout: Duration): WatchFuture {
        let future = WatchFuture()
        synchronized(mutex) {
            let entries = if (let Some(entries) <- globWatchers.get(pattern)) {
                entries
            } else {
                let entries = ArrayList<WatchEntry>()
                globWatchers[pattern] = entries
                entries
            }
            entries.add(WatchEntry(pattern, calcExpiry(timeout), future))
        }
        future
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

    public func notify(key: String, newValue: Array<Byte>): Unit {
        let matched = ArrayList<WatchEntry>()
        synchronized(mutex) {
            if (let Some(entries) <- exactWatchers.get(key)) {
                for (entry in entries) {
                    matched.add(entry)
                }
            }
            for ((prefix, entries) in prefixWatchers) {
                if (key.startsWith(prefix)) {
                    for (entry in entries) {
                        matched.add(entry)
                    }
                }
            }
            for ((pattern, entries) in globWatchers) {
                if (keyMatchesGlob(key, pattern)) {
                    for (entry in entries) {
                        matched.add(entry)
                    }
                }
            }
        }
        for (entry in matched) {
            if (entry.expiry.isNone() || DateTime.now() < entry.expiry.getOrThrow()) {
                entry.future.set(newValue)
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
                if (let Some(expiry) <- entries[i].expiry && expiry <= now) {
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

    private static func calcExpiry(timeout: Duration): ?DateTime {
        if (timeout == Duration.Zero) {
            None
        } else {
            DateTime.now() + timeout
        }
    }

    private static func keyMatchesGlob(key: String, pattern: String): Bool {
        if (pattern == '*') { return true }
        let parts = pattern.split('*')
        if (parts.size == 1) { return key == pattern }
        var pos = 0
        for (i in 0..parts.size) {
            let part = parts[i]
            if (part.isEmpty()) { continue }
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
