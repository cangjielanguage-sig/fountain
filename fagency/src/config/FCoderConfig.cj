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
package fountain::fagency.config

import fountain::f_config.*
import fountain::f_llm.constant.*

public struct FCoderConfig {
    private init(){}
    public static const FCODER = 'fagency'
    public static const FCODER_SEARCH_ENGINE = FCODER + '_searchEngine'
    public static const FCODER_DEFAULT_SEARCH_ENGINE = MODEL_NAME_GLM_SEARCH_PRO

    public static func getSearchEngine(){
        Config.getString(FCODER_SEARCH_ENGINE) ?? FCODER_DEFAULT_SEARCH_ENGINE
    }
}