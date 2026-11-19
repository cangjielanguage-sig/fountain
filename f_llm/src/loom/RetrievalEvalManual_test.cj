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
package fountain::f_llm.loom

import std.convert.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*

/**
 * 真实模型的检索评测入口。
 *
 * 默认**不执行**（CI 不该依赖本机 embedding 服务）；要跑时设 `fllm_runEval=1`：
 *
 * ```
 * fllm_runEval=1 cjpm test --filter=RetrievalEvalManual_test
 * # 或直接用脚本：eval/run_eval.sh
 * ```
 *
 * 编码器地址取自 `llm_embeddingUrl`（默认 `http://127.0.0.1:8000/v1/embeddings`），
 * 模型名取自 `fllm_evalModel`（默认 `bge-m3`）。
 */
@Test
class RetrievalEvalManual_test {
    private static func enabled(): Bool {
        match(getVariable('fllm_runEval')){
            case Some(value) => value.trimAscii() == '1'
            case None => false
        }
    }

    private static func modelName(): String {
        match(getVariable('fllm_evalModel')){
            case Some(value) => if(value.trimAscii().isEmpty()){ 'bge-m3' }else{ value.trimAscii() }
            case None => 'bge-m3'
        }
    }

    private static func evalDir(): String {
        match(getVariable('fllm_evalDir')){
            case Some(value) => value
            case None => './eval'
        }
    }

    @TestCase
    func testRunAgainstRealEmbedding(): Unit {
        if(!enabled()){
            println('SKIP: 设置 fllm_runEval=1 才跑真实模型评测')
            return
        }
        let meta = InMemoryMetaStore()
        let minScore = match(getVariable('fllm_evalMinScore')){
            case Some(value) => Float64.tryParse(value.trimAscii()) ?? 0.2f64
            case None => 0.2f64
        }
        let outcome = RetrievalEvalRunner.run(meta, evalDir(), modelName(),
                                              minScore: minScore)
        // 测试框架会捕获 stdout，所以报告写文件；脚本直接 cat 它
        let path = '/tmp/fllm_retrieval_eval.txt'
        let file = File(path, OpenMode.Write)
        file.write(outcome.report.toArray())
        file.close()
        println('EVAL_REPORT=${path}')
        // 编码失败会静默退回关键词：此时指标测的是关键词而不是向量，必须判失败
        @Expect(outcome.embedFailures, 0)
    }
}
