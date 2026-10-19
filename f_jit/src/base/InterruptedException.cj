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

import fountain::f_base.BaseException

/**
 * 中断/取消异常（§2 `-2 INTERRUPT`）。
 *
 * 设计文档以「InterruptedException」命名该出口；仓颉 1.3.0 的 std 尚无同名类型，
 * 故由本模块提供（继承 `BaseException`，与 `JitException` 同源，便于宿主统一捕获）。
 */
public class InterruptedException <: BaseException {
    public init(message: String) {
        super(message)
    }
}
