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
package fountain::f_llm.tool

import std.process.*
import fountain::f_bean.macros.*
import fountain::f_data.macros.*

@DataAssist[props fields]
public class Command {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'完整的操作系统控制台命令']
    private var command: String = ''
}

@Bean
public class CommandFunction <: FunctionCalling<Command> {
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'command'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '执行操作系统控制台命令'
        }
    }
    /**
     * @param params 命令参数
     * @return 函数调用结果
     */
    public func call(params: Command): FunctionResult {
        let cmd = params.command.split(' ')
        let (code, stdout, stderr) = executeWithOutput(cmd[0], cmd[1..], 
            workingDirectory: LLMConfig.getFileSandboxPath(),
            stdOut: Inherit, stdErr: Inherit)
        let output = String.fromUtf8(if(code == 0){
            stdout
        }else{
            stderr
        })
        let content = '''
命令执行结果
===
- 进程退出码：${code}
- 输出内容：
${output}
        '''
        FunctionResult(event: params.nextEvent, result: content)
    }
}