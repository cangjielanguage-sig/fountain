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
package fountain::fcoder.model.po

import std.time.DateTime
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_orm.*
import fountain::f_orm.macros.*
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

@DataAssist[fields]
@QueryMappersGenerator[table: llm_token_usage]
public class TokenUsage {
    @ORMField['llm_id']
    private var llmId: Int64 = 0
    @ORMField['prompt_tokens']
    private var prompt: Int64 = 0
    @ORMField['completion_tokens']
    private var completion: Int64 = 0
    @ORMField['total_tokens']
    private var total: Int64 = 0
    @ORMField['cached_tokens']
    private var cached: Int64 = 0
    @ORMField['usage_time']
    private var usageTime: Int64 = {=>
        let now = DateTime.now()
        now.year * 100000000 + now.month.toInteger() * 1000000 + now.dayOfMonth * 10000 + now.hour * 100 + now.minute
    }()
}