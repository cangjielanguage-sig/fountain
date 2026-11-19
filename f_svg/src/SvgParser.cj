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

import std.io.InputStream
import std.fs.Path
import fountain::f_xml.*

/**
 * SVG 解析入口。
 *
 * 五个重载最终都走同一个 `SvgBuilder`；`XmlException` 在边界包装为
 * `SvgException(kind: Syntax)` 并保留 1-based 行列。
 */
public class SvgParser {
    public static func parse(
        input: InputStream,
        options!: SvgParseOptions = SvgParseOptions()
    ): SvgDocument {
        buildSvgDocument(loadXml({=> XmlParser.parse(input, options: options.xml)}), options)
    }

    public static func parse(
        bytes: Array<Byte>,
        options!: SvgParseOptions = SvgParseOptions()
    ): SvgDocument {
        buildSvgDocument(loadXml({=> XmlParser.parse(bytes, options: options.xml)}), options)
    }

    /** 输入已经是字符：跳过字节嗅探。 */
    public static func parse(
        text: String,
        options!: SvgParseOptions = SvgParseOptions()
    ): SvgDocument {
        buildSvgDocument(loadXml({=> XmlParser.parse(text, options: options.xml)}), options)
    }

    public static func parse(
        path: Path,
        options!: SvgParseOptions = SvgParseOptions()
    ): SvgDocument {
        buildSvgDocument(loadXml({=> XmlParser.parse(path, options: options.xml)}), options)
    }

    /** 复用已解析的 XML DOM。 */
    public static func parse(
        document: XmlDocument,
        options!: SvgParseOptions = SvgParseOptions()
    ): SvgDocument {
        buildSvgDocument(document, options)
    }

    /**
     * 按魔数自动识别 SVGZ：前两字节为 `1F 8B` 时 gzip 解压后解析，否则按字节解析。
     *
     * 命中魔数但解压失败时抛 `Syntax`，不静默回退为文本。
     */
    public static func parseAuto(
        bytes: Array<Byte>,
        options!: SvgParseOptions = SvgParseOptions()
    ): SvgDocument {
        if (bytes.size >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
            parseGzip(bytes, options: options)
        } else {
            parse(bytes, options: options)
        }
    }

    /** 强制按 gzip 解压后解析；非 gzip 输入抛 `Syntax`。 */
    public static func parseGzip(
        bytes: Array<Byte>,
        options!: SvgParseOptions = SvgParseOptions()
    ): SvgDocument {
        let decoded = SvgGzip.decompress(
            bytes,
            maxBytes: options.security.maxDecompressedBytes
        )
        parse(decoded, options: options)
    }

    private static func loadXml(loader: () -> XmlDocument): XmlDocument {
        try {
            loader()
        } catch (error: XmlException) {
            throw SvgException(
                error.message,
                error.line,
                error.column,
                kind: SvgErrorKind.Syntax
            )
        }
    }
}
