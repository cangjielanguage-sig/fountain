大模型API
---

# 函数调用
## `fountain::f_llm.FunctionCalling`
```cj
/**
 * 函数调用结果，本模块是fcoder的辅助模块，而fcoder依赖f_egraph定义的事件和流程
 */
public struct FunctionResult {
    /**
     * 函数调用结果
     * @param event 本函数的结果要包装的事件名称
     * @param result 函数调用结果，要么是简单字符串，要么是MARKDOWN格式的文本
     */
    public FunctionResult(
        public prop event!: String,
        public prop result!: String
    ){}
}
/**
 * 此接口的实现必须是类且被fountain::f_bean.macros.Bean修饰
 */
public interface FunctionCalling<T> where T <: DataFields<T> {
    /**
     * JSON SCHEMA形式描述的大模型函数定义
     */
    prop definition: String
    /**
     * 函数名称
     */
    prop name: String
    /**
     * 函数调用
     * @param params 函数参数
     * @return 函数调用结果
     */
    func call(params: T): FunctionResult
}
```