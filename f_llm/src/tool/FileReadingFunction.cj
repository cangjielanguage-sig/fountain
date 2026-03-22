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
public class FileReadingParams {
    @JsonStringSchema[description:'流程下一步事件的名称']
    private var event: String = ''
    @JsonStringSchema[description:'''
UNIX风格的文件路径，
这个函数是一个应用程序的一部分，本路径会作为配置的可用路径的相对路径，即使大模型返回的参数使用了绝对路径也不会访问整个操作系统的文件系统。''']
    private var path: String = ''
    @JsonStringSchema[description:'与mode配合使用，符合条件的文本行才会返回']
    private var condition: String = ''
    @JsonStringSchema[description: '''
读取文件的模式，与condition配合使用。
### 可选值
- entire: 默认值，返回整个文件，此时condition不生效
- regex: 符合condition所表示的正则表达式的文本行才会返回
- tail: 此时condition必须是整数，返回文件最后的指定行数，返回的行数是condition表示的整数
- head: 此时condition必须是整数，返回文件开头的指定行数，返回的行数是condition表示的整数
- random: 此时condition必须是整数，使用蓄水池算法从文件中随机选择指定行数，返回的行数是condition表示的整数
''']
    private var mode: String = 'entire'
}

@Bean
public class FileReadingFunction <: AbstractFileFunction<FileReadingParams> {
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'readFile'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '读文件'
        }
    }
    /**
     * 写文件的操作
     * @param params 函数参数
     * @return 函数调用结果
     */
    public func call(params: FileReadingParams): FunctionResult {
        var path = genPath(params.path)
        if(!exists(path)){
            throw FunctionCallingException('${path} 文件不存在')
        }
        let content = 
        match(params.mode){
            case 'entire' => String.fromUtf8(File.readFrom(path))
            case 'regex' => 
                let regex = params.condition.regex()
                read(path){line, end => 
                    if(!end && regex.matches(line)){
                        line
                    }else{
                        ''
                    }
                }
            case 'tail' => 
                let lines = Int64.parse(params.condition)
                let list = LinkedList<String>()
                read(path){line, end =>
                    if(list.size < lines && !end){
                        list.addLast(line)
                    }else if(list.size == lines && !end){
                        list.removeFirst()
                        list.addLast(line)
                    }else if(end){
                        let gen = StringGenerator()
                        for(l in list){
                            gen.appendln(l)
                        }
                        return gen.toString()
                    }
                    ''
                }
            case 'head' =>
                let lines = Int64.parse(params.condition)
                let list = ArrayList<String>(lines)
                read(path){line, end => 
                    if(list.size < lines && !end){
                        list.add(line)
                    }else if(end){
                        let gen = StringGenerator()
                        for(l in list){
                            gen.appendln(l)
                        }
                        return gen.toString()
                    }
                    ''
                }
            case 'random' =>
                let lines = Int64.parse(params.condition)
                let list = LinkedList<String>()
                let random = SecureRandom()
                let c = AtomicInt64(0)
                read(path){line, end => 
                    if(list.size < lines && !end){
                        list.addLast(line)
                    }else if(list.size == lines && !end && random.nextInt64(c.load()) < lines){
                        list.removeFirst()
                        list.addLast(line)
                    }else if(end){
                        let gen = StringGenerator()
                        for(l in list){
                            gen.appendln(l)
                        }
                        return gen.toString()
                    }
                    c.fetchAdd(1)
                    ''
                }
            case _ => 'mode参数错误， 可选值有 entire, regex, tail, head, random'
        }
        FunctionResult(
            eventType: EventType.Task,
            event: params.event,
            result: content,
            resultType: ResultType.Text
        )
    }
    private func read(path: Path, predicate: (String, Bool) -> String): String {
        func append(gen: StringGenerator, line: String, end: Bool): Unit {
            if(let l <- predicate(line, end) && l.size > 0){
                gen.appendln(l)
            }
        }
        ResourceManager<File>{File(path, Read)}.call<String>{f => 
            let iterator = StringReader(f).lines()
            let builder = StringGenerator()
            for(line in StringReader(f).lines()){
                append(builder, line, false)
            }
            append(builder, '', true)
            builder.toString()
        }
    }
    
}