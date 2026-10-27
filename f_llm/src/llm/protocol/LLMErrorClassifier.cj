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
package fountain::f_llm.llm.protocol

/**
 * HTTP 状态码分类：决定「换一个平台再试」还是「立即失败」。
 *
 * 4xx 里除 429 之外一律不转移——参数错、模型不存在、内容被拒，换平台也一样错；
 * 转移只会让第一个错误被第二个错误盖住，排障更慢。
 */
public struct LLMErrorClassifier {
    private init(){}

    public static func isRetryable(status: Int64): Bool {
        match(status){
            case 408 => true       // 请求超时
            case 409 => true       // 冲突（偶发并发写）
            case 425 => true       // too early
            case 429 => true       // 限流
            case _ => status >= 500
        }
    }

    public static func isFatal(status: Int64): Bool {
        !isRetryable(status)
    }
}
