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

// TODO(M3-5): data URI 解析与单次渲染缓存。
