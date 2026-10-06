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

import fountain::f_bean.macros.*
import fountain::f_data.macros.*

@DataAssist[props fields]
public class FileWritingParams {
    @JsonStringSchema[description:'流程下一步事件的名称']
    private var event: String = ''
    @JsonStringSchema[description:'''
UNIX风格的文件路径。
这个函数是一个应用程序的一部分，本路径会作为配置的可用路径的相对路径，即使大模型返回的参数使用了绝对路径也不会访问整个操作系统的文件系统。''']
    private var path: String = ''
    @JsonStringSchema[description:'待写入的文件内容']
    private var content: String = ''
    @JsonStringSchema[description: '''
文件写入方式, 默认为 append, 可选值有 append, truncate。
如果content是空串，而指定了truncate，则会把文件清空。
如果文件不存在会自动创建新文件。''']
    private var mode: String = 'append'
}

@Bean
public class FileWritingFunction <: AbstractFileFunction<FileWritingParams> {
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'writeFile'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '写文件，写成功返回OK，否则返回错误原因'
        }
    }
    /**
     * 写文件的操作
     * @param params 函数参数
     * @return 函数调用结果
     */
    public func call(params: FileWritingParams): FunctionResult {
        var path = genPath(params.path)
        if(!exists(path)){
            File.create(path)
        }
        var result = 'OK'
        match(params.mode){
            case 'append' => File.appendTo(path, params.content.unsafeBytes())
            case 'truncate' => File.writeTo(path, params.content.unsafeBytes())
            case _ => result = 'mode参数错误， 可选值有 append, truncate'
        }
        FunctionResult(
            eventType: EventType.Task,
            event: params.event,
            result: result,
            resultType: ResultType.Text
        )
    }
}