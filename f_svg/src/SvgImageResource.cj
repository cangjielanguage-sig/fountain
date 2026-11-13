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
package fountain::f_svg

import std.collection.*
import stdx.encoding.base64.*

/** `<image>` 的采样质量。 */
public enum SvgImageRendering <: Equatable<SvgImageRendering> & ToString {
    | Auto
    | OptimizeQuality
    | Pixelated
    | OptimizeSpeed

    public operator func ==(that: SvgImageRendering): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (OptimizeQuality, OptimizeQuality) => true
            case (Pixelated, Pixelated) => true
            case (OptimizeSpeed, OptimizeSpeed) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case OptimizeQuality => "optimizeQuality"
            case Pixelated => "pixelated"
            case OptimizeSpeed => "optimizeSpeed"
        }
    }

    internal static func fromName(name: String): ?SvgImageRendering {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "optimizequality" => Some(OptimizeQuality)
            case "pixelated" => Some(Pixelated)
            case "optimizespeed" => Some(OptimizeSpeed)
            case _ => None
        }
    }
}

/**
 * `<image>` 外部资源提供者。
 *
 * 由调用方实现并承担安全责任；`f_svg` 不会自行联网或读取文件系统。
 * 返回 `None` 表示不提供该资源。
 */
public interface SvgImageResourceProvider {
    func resolve(href: String): ?Array<Byte>
}


/** `data:image/png;base64,` 文本长度上限。 */
internal let SVG_MAX_BASE64_LENGTH: Int64 = 32 * 1024 * 1024
private let SVG_DATA_PNG_PREFIX = "data:image/png;base64,"

/**
 * 单次渲染的图像资源解析器。
 *
 * 只接受 `data:image/png;base64,` 与显式注入的 `SvgImageResourceProvider`；
 * 解码结果按 `href` 原文缓存，实例生命周期即一次 render，跨 render 不复用。
 * 结构 / 数值错误降级为 `None`，`Limit` 继续向上抛。
 */
internal class SvgImageResource {
    private let provider: ?SvgImageResourceProvider
    private let budget: SvgDecodeBudget
    private let decoded = HashMap<String, SvgBitmap>()
    private let missing = HashMap<String, Bool>()

    init(provider!: ?SvgImageResourceProvider = None, budget!: SvgDecodeBudget) {
        this.provider = provider
        this.budget = budget
    }

    /** 解析并解码；不可用时返回 `None`。 */
    func load(href: String): ?SvgBitmap {
        match (this.decoded.get(href)) {
            case Some(bitmap) => return Some(bitmap)
            case None => ()
        }
        match (this.missing.get(href)) {
            case Some(_) => return None
            case None => ()
        }
        let lower = href.toAsciiLower()
        if (lower.size > SVG_DATA_PNG_PREFIX.size &&
            lower[0..SVG_DATA_PNG_PREFIX.size] == SVG_DATA_PNG_PREFIX) {
            match (this.loadDataUri(href)) {
                case Some(bitmap) => return Some(bitmap)
                case None =>
                    this.missing[href] = true
                    return None
            }
        }
        let bytes = match (this.resourceBytes(href)) {
            case Some(value) => value
            case None =>
                this.missing[href] = true
                return None
        }
        try {
            let bitmap = SvgPngDecoder.decode(bytes, budget: this.budget)
            this.decoded[href] = bitmap
            Some(bitmap)
        } catch (error: SvgException) {
            if (error.kind == SvgErrorKind.Limit) {
                throw error
            }
            this.missing[href] = true
            None
        }
    }

    /** 仅解析 `data:image/png;base64,`；超长抛 `Limit`。 */
    func loadDataUri(text: String, maxBase64Length!: Int64 = SVG_MAX_BASE64_LENGTH): ?SvgBitmap {
        if (maxBase64Length <= 0) {
            throw invalidValue("base64 长度上限必须为正，实际 ${maxBase64Length}")
        }
        let lower = text.toAsciiLower()
        if (lower.size <= SVG_DATA_PNG_PREFIX.size ||
            lower[0..SVG_DATA_PNG_PREFIX.size] != SVG_DATA_PNG_PREFIX) {
            return None
        }
        let payload = text[SVG_DATA_PNG_PREFIX.size..].trimAscii()
        if (Int64(payload.size) > maxBase64Length) {
            throw SvgException(
                "data URI base64 长度 ${payload.size} 超过上限 ${maxBase64Length}",
                kind: SvgErrorKind.Limit
            )
        }
        let bytes = match (fromBase64String(payload)) {
            case Some(value) => value
            case None => return None
        }
        try {
            let bitmap = SvgPngDecoder.decode(bytes, budget: this.budget)
            this.decoded[text] = bitmap
            Some(bitmap)
        } catch (error: SvgException) {
            if (error.kind == SvgErrorKind.Limit) {
                throw error
            }
            None
        }
    }

    private func resourceBytes(href: String): ?Array<Byte> {
        match (this.provider) {
            case Some(value) => value.resolve(href)
            case None => None
        }
    }
}
