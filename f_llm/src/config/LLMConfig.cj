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
package fountain::f_llm.config

import std.convert.*
import fountain::f_config.*

public struct LLMConfig {
    private init(){}
    public static const LLM = 'f_llm'
    public static const AUTO = LLM + '_auto'

    public static func isAuto(): Bool {
        Config.getValue<Bool>(AUTO) ?? false
    }
}