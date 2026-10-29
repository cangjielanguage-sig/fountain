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
package fountain::f_llm.store

import std.collection.ArrayList

/**
 * 13 个预定义人格 key（设计 §7.2）；`custom` 表示用户自定义正文，不在列表内。
 */
public class PredefinedCharacters {
    public static func keys(): ArrayList<String> {
        let keys = ArrayList<String>()
        for(key in [
            'default', 'rigorous', 'friendly', 'blunt', 'imaginative',
            'pragmatic', 'sarcastic', 'coaching', 'gentle', 'sweet',
            'aloof', 'sunny', 'whimsical'
        ]){
            keys.add(key)
        }
        keys
    }

    public static func isKnown(characterKey: String): Bool {
        if(characterKey == 'custom'){
            return true
        }
        for(key in keys()){
            if(key == characterKey){
                return true
            }
        }
        false
    }
}
