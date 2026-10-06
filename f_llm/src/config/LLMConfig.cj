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
package fountain::f_llm.config

import std.convert.*
import std.env.*
import std.fs.{Path, exists, Directory}
import fountain::f_config.*

public struct LLMConfig {
    private init(){}
    public static const LLM = 'llm'
    public static const AUTO = LLM + '_auto'
    public static const FILE_SANDBOX_PATH = LLM + '_fileSandboxPath'
    public static const LLM_ACCESS_TRYING_COUNT = LLM + '_accessTryingCount'
    public static const LLM_ACCESS_TRYING_ELAPSED = LLM + '_accessTryingElapsed'
    public static const LLM_FAITHFUL_MEMORY_PATH = LLM + '_faithfulMemoryPath'
    public static const LLM_MAKING_MEMORY = LLM + '_makingMemory'
    public static const SUMMARISING_MODEL = LLM + '_summarisingModel'
    public static const SUMMARISING_ACTION_KIND = LLM + '_summarisingActionKind'

    public static func isAuto(): Bool {
        Config.getValue<Bool>(AUTO) ?? false
    }
    private static func getPath(key: String, join!: String = ''){
        var path =  if(let Some(p) <- Config.getString(key)){
            Path(p)
        }else{
            getWorkingDirectory()
        }
        if(join.size > 0){
            path = path.join(join)
        }
        if(!exists(path)){
            Directory.create(path, recursive: true)
        }
        path
    }
    public static func getFileSandboxPath(): Path {
        getPath(FILE_SANDBOX_PATH)
    }
    public static func getLLMAccessTryingCount(): Int64 {
        Config.getValue<Int64>(LLM_ACCESS_TRYING_COUNT) ?? Int64.Max
    }
    public static func getLLMAccessTryingElapsed(): Duration {
        Duration.second * (Config.getValue<Int64>(LLM_ACCESS_TRYING_ELAPSED) ?? Int64.Max)
    }
    public static func getFaithfulMemoryPath(): Path {
        getPath(LLM_FAITHFUL_MEMORY_PATH, join: '.memory')
    }
    public static func getMakingMemory(): Bool {
        Config.getValue<Bool>(LLM_MAKING_MEMORY) ?? false
    }
    public static func getSummarisingModel(): String {
        Config.getString(SUMMARISING_MODEL) ?? 'glm-4.7-flash'
    }
    public static func getSummarisingActionKind(): String {
        Config.getString(SUMMARISING_ACTION_KIND) ?? ''
    }
}