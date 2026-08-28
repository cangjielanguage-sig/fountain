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
package fountain::f_rpc.base

import fountain::f_aspect.*
import fountain::f_bean.{BeanFactory, BeanMeta}
import fountain::f_log.LoggerFactory

@AspectRoute[FuncAnnotationRouteRule("fountain::f_mvc.PostMapping") | FuncAnnotationRouteRule("fountain::f_mvc.PutMapping") | FuncAnnotationRouteRule("fountain::f_mvc.GetMapping") | FuncAnnotationRouteRule("fountain::f_mvc.DeleteMapping") | FuncAnnotationRouteRule("fountain::f_mvc.PatchMapping")]
@BeanMeta
public class ControllerTraceAspect <: Aspect {
    private static let log = LoggerFactory.getLogger<ControllerTraceAspect>()
    static init(){
        BeanFactory.instance.register<ControllerTraceAspect>({=> ControllerTraceAspect()})
    }

    private init(){}

    public func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        log.debug('ControllerTraceAspect.proceed start')
        try{
            point(funcInfo.args)
        }finally{
            ServiceMeta.clearCurrentTrace()
            log.debug('ControllerTraceAspect.proceed end')
        }
    }
}