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
 * 把池项还给了一个**从来没有过池的键**（`KeyPool.giveBack`）。
 *
 * 这是调用方的错误，池不替它决定处置方式：键一旦被 `get` / `add` 用过就一定有池，
 * `close()` 之后的归还另有兜底（「池已关停」⇒ 立刻销毁），所以走到这里只可能是**还错了键**。
 * 于是池**什么都不做** —— 不归还、不销毁、也不偷偷替这个键建一个池：池项的所有权仍在调用方手里，
 * 由应用层决定销毁、重试还是上报（见 .autocode/bugs/bug-pool.md §2.5 `POOL-10`）。
 *
 * 本类是 `f_base.BaseException` 的子类，因此可以用 `addSuppressed` 把**被顶掉的异常**带上
 * ——典型场景是在 `finally` / `release()` 清理路径里归还，顶掉了正在传播的业务异常：
 *
 * ```
 * var inFlight: ?Exception = None
 * try {
 *     ...
 * } catch (e: Exception) {
 *     inFlight = Some(e)
 *     throw e
 * } finally {
 *     try {
 *         pool.giveBack(key, object)
 *     } catch (e: UnknownKeyException) {
 *         if (let Some(displaced) <- inFlight) {
 *             e.addSuppressed(displaced)    // 别把原来的异常丢了
 *         }
 *         throw e
 *     }
 * }
 * ```
 *
 * 注：仓库内使用的池都是 `Pool<V>`（键为 `Unit` ⇒ `UnitKeyPool`，键永远只有一个），不会抛出本异常；
 * 只有直接用 `KeyPool<K, V>` 且 `K` 非 `Unit` 的应用才可能遇到。
 */
public class UnknownKeyException <: BaseException {
    /**
     * 被还给的那个键，**原样**带出（池不持有它的引用）。
     *
     * 类型是 `Any` 而不是 `K`：`BaseKeyPool` 对键的约束只有 `Hashable & Equatable<K>`（没有 `ToString`，
     * 编译期就不允许把键插进消息文本），而本异常类不应当为了一句错误消息给全库的键类型加约束。
     * 应用层要文本形式自己 `ToString` / `TypeInfo` 处理：
     * ```
     * match (e.key) {
     *     case k: ToString => logger.warn('giveBack to unknown key ${k}')
     *     case _ => logger.warn('giveBack to unknown key (unprintable)')
     * }
     * ```
     */
    public let key: Any
    public init(key: Any) {
        super('giveBack: no pool for the given key — the item was NOT returned and NOT destroyed; return it to the key it was borrowed from')
        this.key = key
    }
}
