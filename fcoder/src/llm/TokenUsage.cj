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
package fountain::fcoder.llm

import fountain::f_data.macros.*
/*
    "usage": {
        "prompt_tokens": 123,
        "completion_tokens": 123,
        "prompt_tokens_details": {
            "cached_tokens": 123
        },
        "total_tokens": 123
    },
*/

@DataAssist[props fields]
public class TokenUsage {
    @FieldAlias['prompt_tokens']
    private var prompt: Int64 = 0
    @FieldAlias['completion_tokens']
    private var completion: Int64 = 0
    @FieldAlias['total_tokens']
    private var total: Int64 = 0
    private var cached: Int64 = 0
}