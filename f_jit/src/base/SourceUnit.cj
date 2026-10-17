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
package fountain::f_jit.base

/**
 * 分发入口输入 —— design-m1 §2.3.5、plan-m1 S1.7、规格 §8 / §11.6。
 *
 * | 成员 | 意义 |
 * |---|---|
 * | `raw: Array<UInt8>` | 已加载 `.fbc` 容器字节（v0.18.25 起四段：code / const / site / name；§8.2 注释里的「三段」是旧版遗留，**以 §11.6 为准**） |
 * | `entryFn: UInt32` | **期望**入口函数 id；须与容器头 `entryFn` 一致，否则加载期拒绝（§11.7「容器头 `entryFn` 必须命中目录中某个 `fnId`，否则加载期拒绝」） |
 *
 * `entryFn` 与容器头不一致的拒绝路径在 S2.15 / S6.9 联测（plan-m1 S1.7 明写），本步只交付值类型。
 */
public struct SourceUnit {
    /** 已加载 `.fbc` 容器字节。 */
    public let raw: Array<UInt8>
    /** 期望入口函数 id（须与容器头 `entryFn` 一致）。 */
    public let entryFn: UInt32

    public init(raw: Array<UInt8>, entryFn: UInt32) {
        this.raw = raw
        this.entryFn = entryFn
    }
}
