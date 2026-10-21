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
package fountain::f_jit.test

/**
 * 行为级 T 标签。
 *
 * 用法：`@Assert(TCase.hit('T14/handle-pinned', <真实条件>), true)`
 *
 * 目的：让 T 编号**不是注释**——`check_tmap.sh` 先剥掉注释再找 `'T<id>/`，
 * 因此标签必须写进可执行语句，并且与它守卫的那条断言同生共死：
 * 条件不成立则用例失败，标签被删/被改则映射校验失败。
 *
 * `id` 约定为 `T<编号>/<场景>`；空标签属于写错，直接判失败。
 */
public class TCase {

    /** 原样返回 `ok`（供 `@Assert(..., true)` 包裹真实条件）；空 `id` 视为错误。 */
    public static func hit(id: String, ok: Bool): Bool {
        if (id.isEmpty()) {
            return false
        }
        ok
    }
}
