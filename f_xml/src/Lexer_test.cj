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

@Test
public class Lexer_test {
    @TestCase
    public func selfClosingTag(): Unit {
        @Assert(lexAll("<a/>") == ["START a attrs=0 self=true", "EOF"])
    }

    @TestCase
    public func pairedTag(): Unit {
        @Assert(lexAll("<a></a>") == ["START a attrs=0 self=false", "END a", "EOF"])
    }

    @TestCase
    public func doubleQuotedAttribute(): Unit {
        @Assert(lexAll("<a b=\"1\"/>") == ["START a attrs=1 self=true", "EOF"])
    }

    @TestCase
    public func singleQuotedAttribute(): Unit {
        @Assert(lexAll("<a b='1'/>") == ["START a attrs=1 self=true", "EOF"])
    }

    @TestCase
    public func spaceBeforeSlash(): Unit {
        @Assert(lexAll("<a />") == ["START a attrs=0 self=true", "EOF"])
    }

    @TestCase
    public func textToken(): Unit {
        @Assert(lexAll("hello") == ["TEXT hello", "EOF"])
    }

    /** 五个预定义实体就地解码。 */
    @TestCase
    public func predefinedEntities(): Unit {
        @Assert(lexAll("&lt;&gt;&amp;&quot;&apos;") == ["TEXT <>&\"'", "EOF"])
    }

    @TestCase
    public func decimalCharRef(): Unit {
        @Assert(lexAll("&#65;") == ["TEXT A", "EOF"])
    }

    @TestCase
    public func hexCharRef(): Unit {
        @Assert(lexAll("&#x41;") == ["TEXT A", "EOF"])
    }

    @TestCase
    public func cdataToken(): Unit {
        @Assert(lexAll("<![CDATA[<b>&amp;]]>") == ["CDATA <b>&amp;", "EOF"])
    }

    @TestCase
    public func commentToken(): Unit {
        @Assert(lexAll("<!-- hi -->") == ["COMMENT  hi ", "EOF"])
    }

    @TestCase
    public func piToken(): Unit {
        @Assert(lexAll("<?pi d?>") == ["PI pi|d", "EOF"])
    }

    /** 自定义实体吐 `REF`，交给上层展开。 */
    @TestCase
    public func customEntityRef(): Unit {
        @Assert(lexAll("&foo;") == ["REF foo", "EOF"])
    }

    /** 属性值里的空白归一。 */
    @TestCase
    public func attributeWhitespaceNormalized(): Unit {
        @Assert(lexAll("<a b=\"x\ty\nz\"/>") == ["START a attrs=1 self=true", "EOF"])
    }
}
