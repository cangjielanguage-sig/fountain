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
package fountain::f_egraph.base

import std.ast.*

/**
 * async 表示异步流程，immediate 表示同步流程，StartEvent是类型为Start的事件名
 * async(category, tag): 'StartEvent' => {
 *     task |> {
 *         'out-event' => {
 *              other_task |> {'other-out-event'}
 *         }
 *     }
 *     task1 |> {
 *         event => {task3 |> {END}}
 *         event2 => task4 |> {'in-event'}
 *     }
 *     task2 |> {
 *         END //END 要么是所在花括号的最后一个事件，要么当前花括号没有END
 *     }
 * }
 */
public struct FlowDSLCompiler {
    /**
     * 编译流程编排DSL，返回的是流程的(category, tag)
     */
    public static func compile(dsl: String): (String, String) {
        let tokens = cangjieLex(dsl)
        let flowType = tokens[0]
        if(!(flowType.kind == TokenKind.IDENTIFIER && (flowType.value == 'async' || flowType.value == 'immediate'))){
            throw GraphException('first token kind of dsl must be identifier and first token value must be "async" or "immediate"')
        }else if(tokens[1].kind != TokenKind.LPAREN || tokens[5].kind != TokenKind.RPAREN || tokens[3].kind != TokenKind.COMMA){
            throw GraphException('category and tag of flow must be wrapped by paren and separated by comma')
        }
        let category = tokens[2].value
        let tag = tokens[4].value
        let flow: BaseFlow = if(flowType.value == 'async'){
            AsyncFlow(category: category, tag: tag)
        }else{
            ImmediateFlow(category: category, tag: tag)
        }
        var startEvent = ''
        if(tokens[6].kind == TokenKind.COLON && 
           (tokens[7].kind == TokenKind.IDENTIFIER || tokens[7].kind == TokenKind.STRING_LITERAL || tokens[7].kind == TokenKind.SINGLE_QUOTED_STRING_LITERAL) && 
           tokens[7].value.size > 0 &&
           tokens[8].kind == TokenKind.DOUBLE_ARROW){
            startEvent = tokens[7].value
            flow.registerStart(startEvent)
        }else{
            throw GraphException('start event of flow must be defined after flow definition and before first left curl')
        }
        flow.registerEnd()
        flow.registerError()
        let curls = LinkedList<Unit>()
        for(i in 9 .. tokens.size){
            let token = tokens[i].kind
            if(token == TokenKind.LCURL){
                curls.addLast(())
            }else if(curls.removeLast().isNone()){
                throw GraphException('curls are not closed in dsl ${dsl}')
            }
        }
        if(curls.size > 0){
            throw GraphException('curls are not closed in dsl ${dsl}')
        }
        let tasks = HashMap<String, (Task, HashSet<String>, HashSet<String>)>()
        for(task in lookupList<Task>()){
            tasks[task.name] = (task, HashSet<String>(task.acceptableEvents), HashSet<String>(task.producingEvents))
        }
        let producing = parseProducing(tokens[7 ..])
        compile(flow, tasks, producing)
        flow.removeExceptCurrentTag()
        (category, tag)
    }
    private static func compile(flow: BaseFlow, tasks: HashMap<String, (Task, HashSet<String>, HashSet<String>)>, producing: ProducingDef): Unit {
        for((e, td) in producing.producings){
            compile(flow, tasks, td, e)
        }
    }
    private static func compile(flow: BaseFlow, tasks: HashMap<String, (Task, HashSet<String>, HashSet<String>)>, task: TaskDef, accepts: String): Unit{
        for((taskName, producing) in task.tasks){
            let (task, accepting, actualProducing) = tasks.get(taskName) ?? throw GraphException('task ${taskName} is not defined')
            for(p in producing.producings.keys() where !actualProducing.contains(p)){
                throw GraphException('task ${taskName} is not producing event ${p}')
            }
            if(accepting.contains(accepts)){
                flow.registerTask(task)
            }else{
                throw GraphException('event ${accepts} is not acceptable by task ${taskName}')
            }
            compile(flow, tasks, producing)
        }
    }
    private static func parseProducing(tokens: Tokens): ProducingDef {
        let producing = ProducingDef()
        var i = 0
        while(i < tokens.size) {
            let token = tokens[i]
            match(token.kind){
                case IDENTIFIER | STRING_LITERAL | SINGLE_QUOTED_STRING_LITERAL where i + 1 < tokens.size && tokens[i + 1].kind == TokenKind.DOUBLE_ARROW =>
                    var j = i + 2
                    if(tokens[j].kind == TokenKind.LCURL){
                        let stack = LinkedList<Unit>()
                        stack.addLast(())
                        j++
                        while(j < tokens.size && stack.size > 0){
                            let token = tokens[j]
                            match(token.kind){ 
                                case LCURL => stack.addLast(())
                                case RCURL where stack.removeLast().isNone() => 
                                    throw GraphException('curls are not closed in part of dsl ${tokens}')
                                case _ => ()
                            }
                            j++
                        }
                        if(stack.size > 0){
                            throw GraphException('curls are not closed in part of dsl ${tokens}')
                        }
                        producing.producings[token.value] = parseTask(tokens[i + 3 .. j - 1])
                    }else{
                        throw GraphException('task(s) must be wrapped by {} which follows ${token.value} =>')
                    }
                case IDENTIFIER | STRING_LITERAL | SINGLE_QUOTED_STRING_LITERAL where i + 1 == tokens.size => ()
                case _ => throw GraphException('unexpected token (${token.kind},${token.value}) in part of dsl ${tokens} at index ${i}')
            }
            i++
        }
        producing
    }
    private static func parseTask(tokens: Tokens): TaskDef {
        let task = TaskDef()
        var i = 0
        while(i < tokens.size) {
            let token = tokens[i]
            match(token.kind){
                case IDENTIFIER | STRING_LITERAL | SINGLE_QUOTED_STRING_LITERAL where i + 1 < tokens.size && tokens[i + 1].kind == TokenKind.PIPELINE =>
                    var j = i + 2
                    if(tokens[j].kind == TokenKind.LCURL){
                        let stack = LinkedList<Unit>()
                        stack.addLast(())
                        j++
                        while(j < tokens.size && stack.size > 0){
                            let token = tokens[j]
                            match(token.kind){ 
                                case LCURL => stack.addLast(())
                                case RCURL where stack.removeLast().isNone() => 
                                    throw GraphException('curls are not closed in part of dsl ${tokens}')
                                case _ => ()
                            }
                            j++
                        }
                        if(stack.size > 0){
                            throw GraphException('curls are not closed in part of dsl ${tokens}')
                        }
                        task.tasks[token.value] = parseProducing(tokens[i + 3 .. j - 1])
                    }else{
                        throw GraphException('producing(s) must be wrapped by {} which follows ${token.value} =>')
                    }
                case _ => throw GraphException('unexpected token (${token.kind},${token.value}) in part of dsl ${tokens} at index ${i}')
            }
            i++
        }
        task
    }
}

public struct TaskDef {
    let tasks = HashMap<String, ProducingDef>()
}
public struct ProducingDef {
    let producings = HashMap<String, TaskDef>()
}