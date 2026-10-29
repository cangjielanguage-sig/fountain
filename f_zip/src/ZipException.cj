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
package fountain::f_zip

import fountain::f_base.BaseException

/**
 * f_zip 的唯一异常类型。
 *
 * 所有失败都用这一个类，靠 message 区分；message 一律带"期望 / 实际 / 条目名"三要素，
 * 不让调用方看到"解压失败"这种无信息量的文案：
 *
 * - `不是有效的 ZIP 文件（未找到中央目录）`
 * - `中央目录偏移 ${off} 超出文件长度 ${len}`
 * - `不支持压缩方法 ${method}（${name}）`
 * - `不支持加密 ZIP（${name}）`
 * - `CRC 校验失败：期望 ${exp}，实际 ${act}（${name}）`
 * - `解压体积超过上限 ${limit}（${name}）`
 * - `条目数 ${n} 超过上限 ${limit}`
 * - `ZIP64 extra 长度不足：需要 ${need}，实际 ${got}（${name}）`
 * - `缺少 data descriptor（bit 3 置位但数据后无签名）`
 * - `条目 ${name} 写入中断，ZIP 结构不完整`
 * - `条目路径非法：${name}`
 */
public class ZipException <: BaseException {
    public init(message: String) {
        super(message)
    }
}
