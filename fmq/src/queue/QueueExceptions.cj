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
package fountain::fmq.queue

import fountain::f_base.BaseException

/**
 * 段内容损坏：长度头非法、记录被截断、段文件缺失。
 *
 * 与「读完了」严格区分：`stats` 必须把它转成 `ERROR(INTERNAL)`，`consume` 必须记 WARN 并
 * 返回空，绝不能静默当成「0 条积压」。
 */
public class QueueCorruptionException <: BaseException {
    public init(message: String) {
        super(message)
    }

    public init(caused: Exception) {
        super(caused)
    }

    public init(message: String, caused: Exception) {
        super(message, caused)
    }
}

