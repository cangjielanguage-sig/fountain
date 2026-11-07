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
package fountain::f_llm.llm

import fountain::f_data.macros.*

public const PART_TYPE_TEXT = 'text'
public const PART_TYPE_IMAGE = 'image_url'

/**
 * 多模态消息的一段内容。
 *
 * 只有 OpenAI Chat Completions 的两种形态：文本与图片 URL（可以是 `data:` URI）。
 * 图片细节档位（`detail`）保留 `auto|low|high`，默认 `auto`——让平台自己决定缩放。
 */
@DataAssist[props fields]
public class ContentPart {
    public ContentPart(
        private var `type`: String,
        private var text: String,
        private var imageUrl: String,
        private var detail: String
    ){}

    public init(){
        this(PART_TYPE_TEXT, '', '', '')
    }

    public static func textOf(value: String): ContentPart {
        ContentPart(PART_TYPE_TEXT, value, '', '')
    }

    public static func imageOf(url: String, detail!: String = 'auto'): ContentPart {
        ContentPart(PART_TYPE_IMAGE, '', url, detail)
    }
}
