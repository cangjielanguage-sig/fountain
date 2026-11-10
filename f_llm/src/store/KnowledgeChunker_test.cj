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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class KnowledgeChunkerTest {

    @TestCase
    func testShortContentIsSingleChunk(): Unit {
        let chunks = KnowledgeChunker.split('短文本', maxChars: 100)
        @Expect(chunks.size, 1)
        @Expect(chunks[0], '短文本')
    }

    @TestCase
    func testLongContentIsSplitWithOverlap(): Unit {
        let content = '0123456789'
        let chunks = KnowledgeChunker.split(content, maxChars: 4, overlap: 1)
        // 4 字符一窗、步进 3：0123 / 3456 / 6789
        @Expect(chunks.size, 3)
        @Expect(chunks[0], '0123')
        @Expect(chunks[1], '3456')
        @Expect(chunks[2], '6789')
    }

    /** 中文按字符切块：不抛异常，每块不超过 400 字符 */
    @TestCase
    func testChineseLongContentSplitsByChars(): Unit {
        let builder = StringBuilder()
        for (i in 0..1000) {
            builder.append('汉')
        }
        let content = builder.toString()

        let chunks = KnowledgeChunker.split(content, maxChars: 400, overlap: 50)

        @Expect(chunks.size > 1, true)
        let expectedFirst = StringBuilder()
        for (i in 0..400) {
            expectedFirst.append('汉')
        }
        @Expect(chunks[0], expectedFirst.toString())
        for (chunk in chunks) {
            // 400 个汉字 = 1200 字节，超过就说明窗口按错了单位
            @Expect(Int64(chunk.size) <= 1200, true)
        }
    }

    @TestCase
    func testEmptyContentYieldsNothing(): Unit {
        @Expect(KnowledgeChunker.split('').size, 0)
    }

    @TestCase
    func testIllegalArgumentsRejected(): Unit {
        var thrown = 0
        try{
            KnowledgeChunker.split('abc', maxChars: 0)
        }catch(_: IllegalArgumentException){
            thrown++
        }
        try{
            KnowledgeChunker.split('abc', maxChars: 4, overlap: 4)
        }catch(_: IllegalArgumentException){
            thrown++
        }
        @Expect(thrown, 2)
    }

    @TestCase
    func testSearchTermsSplitAndDedup(): Unit {
        let terms = KnowledgeSearch.terms(' 记忆   检索 记忆 ')
        @Expect(terms.size, 2)
        @Expect(terms[0], '记忆')
        @Expect(terms[1], '检索')
    }

    @TestCase
    func testScoreCountsOccurrences(): Unit {
        let terms = ArrayList<String>(['检索'])
        @Expect(KnowledgeSearch.score('检索与检索', terms), 2.0f64)
        @Expect(KnowledgeSearch.score('无关内容', terms), 0.0f64)
    }

    @TestCase
    func testRankSortsByScoreThenIdSeq(): Unit {
        let hits = ArrayList<KnowledgeHit>()
        hits.add(KnowledgeHit('b', 0, 'x', 1.0f64))
        hits.add(KnowledgeHit('a', 2, 'x', 1.0f64))
        hits.add(KnowledgeHit('a', 0, 'x', 3.0f64))
        let ranked = KnowledgeSearch.rank(hits, 2)
        @Expect(ranked.size, 2)
        @Expect(ranked[0].docId, 'a')
        @Expect(ranked[0].seq, 0)
        @Expect(ranked[1].docId, 'a')
    }
}
