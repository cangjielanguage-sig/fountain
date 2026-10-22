/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_dbm

import fountain::f_base.BaseException

/**
 * IdGenerator 的配套异常：实现未支持某种 ID 类型时抛出。
 *
 * 与接口同放 f_dbm，保证外部实现与 fdbm 抛出的异常类型一致。
 */
public class IdGeneratorException <: BaseException {
    public init(message: String) {
        super(message)
    }
}

/**
 * fdbm ID 生成器扩展点。
 *
 * 实现至少支持一种：字符串 ID（nextStringId）或整型 ID（nextIntId）；
 * 未支持的方法沿用默认实现，抛 IdGeneratorException。
 */
public interface IdGenerator {
    /** 生成器名，对应 fdbm_idmaker 的配置值。 */
    prop name: String

    /** 生成字符串 ID；默认不支持。 */
    func nextStringId(): String {
        throw IdGeneratorException('${name} does not support string id')
    }

    /** 生成整型 ID；默认不支持。 */
    func nextIntId(): Int64 {
        throw IdGeneratorException('${name} does not support int id')
    }
}
