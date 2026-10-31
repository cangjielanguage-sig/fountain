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
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.{File, OpenMode, removeIfExists}
import std.env

/**
 * 恶意样本：全部固定 `EntityOverflowPolicy.Strict`。
 *
 * 用 `Spill` 跑炸弹会先写满磁盘才停，CI 直接炸——所以安全用例不允许用默认策略。
 */
@Test
public class EntitySecurity_test {
    private func strictOptions(): XmlParserOptions {
        XmlParserOptions(
            entityLimits: EntityLimits(overflowPolicy: EntityOverflowPolicy.Strict)
        )
    }

    private func billionLaughsDoc(): String {
        let gen = StringBuilder()
        gen.append("<!DOCTYPE a [<!ENTITY e0 \"lol\">")
        for (i in 1..=8) {
            gen.append("<!ENTITY e${i} \"")
            for (_ in 0..10) {
                gen.append("&e${i - 1};")
            }
            gen.append("\">")
        }
        gen.append("]><a>&e8;</a>")
        gen.toString()
    }

    /** Billion Laughs 在 1 MB 展开量内被中断。 */
    @TestCase
    public func billionLaughs(): Unit {
        let parser = XmlPullParser(text: this.billionLaughsDoc(), options: this.strictOptions())
        var caught = false
        try {
            var done = false
            while (!done) {
                match (parser.nextEvent()) {
                    case Some(_) => ()
                    case None => done = true
                }
            }
        } catch (e: XmlException) {
            caught = true
            @Assert(e.entityLimitKind == Some(EntityLimitKind.Total) ||
                e.entityLimitKind == Some(EntityLimitKind.PerEntity))
        }
        assertTrue(caught, "Billion Laughs 应被拦截")
        assertTrue(parser.totalExpanded() < 1024 * 1024, "已展开 ${parser.totalExpanded()}")
    }

    /**
     * 参数实体版「Billion Laughs」必须在声明期就被拦住。
     *
     * 内部子集里「实体值内含参数实体引用」本身违反 WFC: PEs in Internal Subset，
     * 所以在解析声明时即报错，根本走不到展开阶段。
     */
    @TestCase
    public func parameterBillionLaughs(): Unit {
        let doc = "<!DOCTYPE a [<!ENTITY % a \"%b;\"><!ENTITY % b \"%a;\">%a;]><a/>"
        assertXmlError({=> parseText(doc, options: this.strictOptions())}, "参数实体")
    }

    /** 单实体超长。 */
    @TestCase
    public func singleOversizedEntity(): Unit {
        let body = repeatText("x", 100 * 1024)
        let doc = "<!DOCTYPE a [<!ENTITY e \"${body}\">]><a>&e;</a>"
        let error = assertXmlError({=> parseText(doc, options: this.strictOptions())}, "单实体")
        @Assert(error.entityLimitKind == Some(EntityLimitKind.PerEntity))
    }

    /** 深度边界：16 通过、17 拒绝。 */
    @TestCase
    public func depthBoundary(): Unit {
        @Assert(parseText(entityChain(16, EntityLimits()), options: this.strictOptions()).root.isSome())
        assertXmlError({=> parseText(entityChain(17, EntityLimits()), options: this.strictOptions())}, "深度")
    }

    /** XXE：外部实体引用即报错，且不读文件。 */
    @TestCase
    public func xxeRejected(): Unit {
        let secret = env.getWorkingDirectory().join(".f_xml_xxe_probe.txt")
        try {
            let file = File(secret.toString(), OpenMode.Write)
            file.write("TOP-SECRET".toArray())
            file.close()
            let doc = "<!DOCTYPE a [<!ENTITY x SYSTEM \"file://${secret.toString()}\">]><a>&x;</a>"
            let error = assertXmlError({=> parseText(doc, options: this.strictOptions())}, "外部实体")
            @Assert(error.entityLimitKind.isNone())
            // 文件仍然存在且内容未被解析进文档
            let check = File(secret.toString(), OpenMode.Read)
            let buf = Array<Byte>(16, repeat: 0)
            let n = check.read(buf)
            check.close()
            @Assert(n == 10)
        } finally {
            try {
                removeIfExists(secret)
            } catch (_: Exception) {}
        }
    }

    /** 外部子集不发请求。 */
    @TestCase
    public func externalSubsetNoRequest(): Unit {
        let doc = parseText(
            "<!DOCTYPE a SYSTEM \"http://127.0.0.1:1/x.dtd\"><a/>",
            options: this.strictOptions()
        )
        @Assert(doc.root.isSome())
    }

    /** 超深嵌套不栈溢出。 */
    @TestCase
    public func deepNesting(): Unit {
        let doc = repeatText("<a>", 10000)
        assertXmlError({=> parseText(doc, options: this.strictOptions())}, "嵌套深度")
    }

    /** 超长属性。 */
    @TestCase
    public func oversizedAttribute(): Unit {
        let value = repeatText("x", 2 * 1024 * 1024)
        let doc = "<a b=\"${value}\"/>"
        assertXmlError({=> parseText(doc, options: this.strictOptions())}, "超过上限")
    }
}
