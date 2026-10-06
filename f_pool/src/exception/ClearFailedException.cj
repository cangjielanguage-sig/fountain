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
package fountain::f_pool.exception

import fountain::f_base.BaseException

/**
 * 归还前的 `clear` 回调抛了异常（`KeyPool.giveBack`，`clearOnReturning = true`）。
 *
 * `clear` 抛异常是**应用层回调的 BUG**，池不替它兜底：这次 `giveBack` **不算归还** ——
 * 不销毁、不结清记账、不进池，池项的状态与调用 `giveBack` 之前完全一样，**对象所有权仍在调用方手里**。
 * 应用层应捕获本异常，决定是修好条件后**重试** `giveBack`（重试成功则额度照常结清），
 * 还是自己销毁这个对象。
 *
 * 被顶掉的那个回调异常挂在 `suppressed` 上（本类是 `f_base.BaseException` 的子类，自带
 * `addSuppressed` / `suppressed` / 带 `Suppressed:` 的 `printStackTrace`）：
 *
 * ```
 * try {
 *     pool.giveBack(key, object)
 * } catch (e: ClearFailedException) {
 *     for (cause in e.suppressed) {          // 回调里到底报了什么，别丢
 *         logger.warn('clear callback failed', cause)
 *     }
 * }
 * ```
 *
 * 与 `UnknownKeyException`（§2.5 `POOL-10`）同一口径：`giveBack` 抛异常 ⇒ 对象**没归还**。
 */
public class ClearFailedException <: BaseException {
    /**
     * 归还时用的那个键，**原样**带出（池不持有它的引用）。
     *
     * 类型是 `Any` 而不是 `K`：`BaseKeyPool` 对键的约束只有 `Hashable & Equatable<K>`（没有 `ToString`，
     * 编译期就不允许把键插进消息文本），应用层要文本自己 `match (e.key) { case k: ToString => … }`。
     */
    public let key: Any
    public init(key: Any) {
        super('giveBack: the clear callback failed — the item was NOT returned; its ownership is still with the caller')
        this.key = key
    }
}
