## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

大模型API
开发者只需要关注组织文化、智能体、技能描述和FunctionCalling，以及事件定义和编排。
大模型每次都要返回一个函数调用，每个函数调用都要返回一个事件数据和事件名；智能体按照函数调用的返回构造并向框架发送新事件。
智能体访问大模型前可以按照指定的上下文策略裁剪或压缩上下文。
---
