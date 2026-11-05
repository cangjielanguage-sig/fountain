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
import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.base64.*

internal func m3RedPng(width: Int64, height: Int64): Array<Byte> {
    let bitmap = SvgBitmap(width, height)
    bitmap.fill(SvgColor(255, 0, 0, alpha: 1.0))
    bitmap.toPngBytes()
}

internal func m3KeepDoc(body: String, width!: Int64 = 100, height!: Int64 = 100): SvgDocument {
    SvgParser.parse(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"${width}\" height=\"${height}\">${body}</svg>",
        options: SvgParseOptions(security: SvgSecurityOptions(unsafePolicy: SvgUnsafePolicy.Keep))
    )
}

internal func m3PngDataUri(bytes: Array<Byte>): String {
    "data:image/png;base64," + toBase64String(bytes)
}

internal class M3CountingProvider <: SvgImageResourceProvider {
    var calls: Int64 = 0
    let bytes: Array<Byte>
    let accept: String

    init(bytes: Array<Byte>, accept!: String = "mem://") {
        this.bytes = bytes
        this.accept = accept
    }

    public func resolve(href: String): ?Array<Byte> {
        this.calls++
        if (href.startsWith(this.accept)) {
            return Some(this.bytes)
        }
        None
    }
}

@Test
public class SvgImageResource_test {
    /** data URI 解析与 base64 校验。 */
    @TestCase
    public func dataUriDecoding(): Unit {
        let resource = SvgImageResource(budget: SvgDecodeBudget(1024))
        let uri = m3PngDataUri(m3RedPng(1, 1))
        let bitmap = resource.load(uri).getOrThrow()
        @Assert(bitmap.width == 1 && bitmap.height == 1)
        @Assert(bitmap.pixels == [255, 0, 0, 255])

        @Assert(resource.load("data:image/gif;base64,R0lGODlh").isNone())
        @Assert(resource.load("data:image/png;base64,!!!!").isNone())
        @Assert(resource.load("mem://red").isNone())
    }

    /** base64 长度上限在解码前检查。 */
    @TestCase
    public func base64Limit(): Unit {
        let resource = SvgImageResource(budget: SvgDecodeBudget(1024))
        let error = expectSvgException(
            {=> resource.loadDataUri("data:image/png;base64,AAAA", maxBase64Length: 3)}
        )
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** provider 调用与单次缓存。 */
    @TestCase
    public func providerCaching(): Unit {
        let provider = M3CountingProvider(m3RedPng(2, 2))
        let resource = SvgImageResource(provider: provider, budget: SvgDecodeBudget(1024))
        let first = resource.load("mem://a").getOrThrow()
        let second = resource.load("mem://a").getOrThrow()
        @Assert(first.pixels == second.pixels)
        @Assert(provider.calls == 1)
        @Assert(resource.load("mem://b").isSome())
        @Assert(provider.calls == 2)
    }

    /** 累计解码像素预算。 */
    @TestCase
    public func decodeBudget(): Unit {
        let provider = M3CountingProvider(m3RedPng(2, 2))
        let resource = SvgImageResource(provider: provider, budget: SvgDecodeBudget(5))
        @Assert(resource.load("mem://a").isSome())
        let error = expectSvgException({=> resource.load("mem://b")})
        @Assert(error.kind == SvgErrorKind.Limit)
    }
}
