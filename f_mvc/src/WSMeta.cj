/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_mvc

sealed abstract class WSFuncMeta<T> {
    WSFuncMeta(public let name: String, public let mediaType: String, public let responseFrameType: ?WebSocketFrameType){}
    let args = RequestArgMeta()
    var `handle` = {_: T, _: HttpContext, _: HttpRequestPathPatterns, _: WebSocket, _: Array<Byte> => Array<Byte>()}

    public func setHandle<R>(`handle`: (T, HttpContext, HttpRequestPathPatterns, WebSocket, Array<Byte>) -> R): Unit where R <: DataFields<R> {
        this.`handle` = {endpoint, ctx, pattern, ws, payload =>
            let r = `handle`(endpoint, ctx, pattern, ws, payload)
            if(mediaType.isEmpty()){
                match(r){
                    case x: Array<Byte> => x
                    case _ => []
                }
            }else{
                MediaTypes.parse(mediaType).fromDataFields<R>(r)
            }
        }
    }
    public func extract<T>(ctx: HttpContext, name: String, converter: ?AbstractDateTimeConverter, pattern: HttpRequestPathPatterns, ws: WebSocket, payload: Array<Byte>): ?T where T <: DataFields<T> {
        match(args[name]){
            case x: WSDataFrame => x.extract<T>(payload)
            case x => x.extract<T>(name, converter, ctx, pattern, DummyValidator.instance)
        }
    }
}
public class WSOpenMeta<T> <: WSFuncMeta<T> {
    init(name: String){
        super(name, '', None<WebSocketFrameType>)
    }
}
public class WSCloseMeta<T> <: WSFuncMeta<T> {
    init(name: String){
        super(name, '', WebSocketFrameType.CloseWebFrame)
    }
}
public class WSTextMeta<T> <: WSFuncMeta<T> {
    init(name: String, mediaType: String, responseFrameType: WebSocketFrameType){
        super(name, mediaType, responseFrameType)
    }
}
public class WSBinaryMeta<T> <: WSFuncMeta<T> {
    init(name: String, mediaType: String, responseFrameType: WebSocketFrameType){
        super(name, mediaType, responseFrameType)
    }
}
public class WSPingMeta<T> <: WSFuncMeta<T> {
    init(name: String, mediaType: String){
        super(name, mediaType, WebSocketFrameType.PongWebFrame)
    }
}
public class WSPongMeta<T> <: WSFuncMeta<T> {
    init(name: String, mediaType: String){
        super(name, mediaType, None<WebSocketFrameType>)
    }
}
public class WSPingFunc<T> <: WSFuncMeta<T> {
    var duration = Duration.Zero
    init(name: String, mediaType: String){
        super(name, mediaType, WebSocketFrameType.PingWebFrame)
    }
}

/**
 * 包内接缝（bug.md §1.11 / MVC-3 的 B 方案）：只负责「ping 定时器 + 读帧循环 + 退出时取消」的生命周期。
 * 形参不含 `HttpContext`/`WebSocket`，便于用「假帧源 + 计数 ping 动作」做单测。
 *
 * - `readFrame`：取下一帧；stdx 契约里连接结束/被关闭时它**抛异常**（`ConnectionException` /
 *   `SocketException` / `WebSocketException`），不是返回一个哨兵值
 * - `onFrame`：处理一帧；返回 `true` 表示处理方要求结束会话（收到 Close 帧）
 * - `ping` / `interval`：ping 动作与周期；`ping` 为 `None` 表示不启动定时器
 */
func pumpFrames(
    readFrame!: () -> WebSocketFrame,
    onFrame!: (WebSocketFrame) -> Bool,
    ping!: Option<() -> Unit>,
    interval!: Duration
): Unit {
    let timer: ?Timer = if (let Some(action) <- ping) {
        Timer.repeat(interval, interval, action)
    } else {
        None<Timer>
    }
    try {
        while (true) {
            let frame = readFrame()
            if (onFrame(frame)) {
                return
            }
        }
    } finally {
        // bug.md §1.11 / MVC-3：连接以任何方式结束都要取消 ping 定时器 ——
        // ① 收到 Close 帧：onFrame 返回 true ⇒ 正常 return；
        // ② 对端断开 / 连接被关：`WebSocket.read()` 抛 ConnectionException / SocketException /
        //    WebSocketException（见 stdx.net.http 的 WebSocket.read 文档「异常」一节），
        //    异常穿出 while，先经这里取消再向外传播；
        // ③ onFrame 自身抛异常（每帧的 try/catch 只吞「处理帧」的异常，read 的异常不吞）。
        // 原先只在 Close 帧那一条路径上 cancel ⇒ 断网会留下一个持续向已关闭连接写帧的定时器，
        // 且其闭包一直持有 endpoint/ctx/pattern/ws。
        timer?.cancel()
    }
}

/**
 * 包内接缝（§3.1 / `MVC-C6(b)`）：数据帧（Text/Binary）到达时的处置 —— 需要结束会话时返回日志用原因，否则 `None`。
 * 触发条件：①`pendingPayload`（上一条载荷未消费完又来数据帧）；②`!hasMeta`（该帧类型没配 meta）。
 * 修前形态：一律返回 `None`（不关连接），行为与改造前一致 —— 由 `doExec` 抛 `WSException` 走 catch-and-continue，
 * 会话继续、每条这样的消息各付一次异常 + 一条 ERROR 日志。修后：返回原因 ⇒ 记一条日志、`ws.closeConn()`、
 * `return true` 停止读帧（与同文件「未知帧类型」的既有处置一致）。
 * 单测：`WSMeta_test.testDataFrameCloseReason` 钉住这两条「该关」的判定。
 */
func dataFrameCloseReason(metaType: String, pendingPayload: Bool, hasMeta: Bool): ?String {
    if (pendingPayload) {
        return 'current payload is not empty'
    }
    if (!hasMeta) {
        return '${metaType} meta for ws is not specified'
    }
    None<String>
}

public class WSMeta<T> where T <: Object {
    private let log = LoggerFactory.getLogger<WSMeta<T>>()
    var pattern = None<HttpRequestPathPatterns>
    private var openMeta_ = None<WSOpenMeta<T>>
    private var closeMeta_ = None<WSCloseMeta<T>>
    private var textMeta_ = None<WSTextMeta<T>>
    private var binaryMeta_ = None<WSBinaryMeta<T>>
    private var pingMeta_ = None<WSPingMeta<T>>
    private var pongMeta_ = None<WSPongMeta<T>>
    private var pingFunc_ = None<WSPingFunc<T>>

    var `handle` = {_:T, _: HttpContext, _: HttpRequestPathPatterns => ()}

    public func setHandle(fn: (T, HttpContext, HttpRequestPathPatterns) -> Unit): Unit {
        `handle` = fn
    }

    public prop openMeta: ?WSOpenMeta<T> {
        get(){
            openMeta_
        }
    }
    public prop closeMeta: ?WSCloseMeta<T> {
        get(){
            closeMeta_
        }
    }
    public prop textMeta: ?WSTextMeta<T> {
        get(){
            textMeta_
        }
    }
    public prop binaryMeta: ?WSBinaryMeta<T> {
        get(){
            binaryMeta_
        }
    }
    public prop pingMeta: ?WSPingMeta<T> {
        get(){
            pingMeta_
        }
    }
    public prop pongMeta: ?WSPongMeta<T> {
        get(){
            pongMeta_
        }
    }
    public prop pingFunc: ?WSPingFunc<T> {
        get(){
            pingFunc_
        }
    }

    public func upgrade(ctx: HttpContext, 
                        subProtocols!: Array<String> = [],
                        origins!: Array<String> = [],
                        userFunc!: (HttpRequest) -> HttpHeaders = {_ => HttpHeaders()}): WebSocket{
        WebSocket.upgradeFromServer(ctx, 
                                    subProtocols: ArrayList<String>(subProtocols), 
                                    origins: ArrayList<String>(origins),
                                    userFunc: userFunc)
    }
    public static func writeText<T>(ws: WebSocket, data: T, mediaType!: String): Unit where T <: DataFields<T> {
        ws.write(TextWebFrame, MediaTypes.parse(mediaType).fromDataFields(data))
    }
    public static func writeText(ws: WebSocket, data: String, charset!: Charset): Unit {
        ws.write(TextWebFrame, charset.newEncoder().encode(data))
    }
    public static func writeBinary<T>(ws: WebSocket, data: T, mediaType!: String): Unit where T <: DataFields<T> {
        writeBinary(ws, MediaTypes.parse(mediaType).fromDataFields(data))
    }
    public static func close(ws: WebSocket, status!: ?UInt16 = None, reason!: String = ''): Unit {
        ws.writeCloseFrame(status: status, reason: reason)
        ws.closeConn()
    }
    public static func writeBinary(ws: WebSocket, data: Array<UInt8>): Unit {
        ws.write(BinaryWebFrame, data)
    }
    public func exec(endpoint: T, ctx: HttpContext, pattern: HttpRequestPathPatterns, ws: WebSocket): Unit {
        openMeta_?.`handle`(endpoint, ctx, pattern, ws, [])
        // 闭包里不能改写捕获的局部 var ⇒ 帧处理状态用 Box 持有（与 FileDownload 的 started 同法）
        let bytes = Box<ArrayList<Byte>>(ArrayList<Byte>())
        let frameType = Box<Option<WebSocketFrameType>>(None<WebSocketFrameType>)
        func doExec(payload: Array<Byte>, fin: Bool, frameType: ?WebSocketFrameType, bytes: ArrayList<Byte>){
            if(let Some(ft) <- frameType){
                bytes.add(all: payload)
                if(fin){
                    func doExec<M>(meta: ?M, metaType: String) where M <: WSFuncMeta<T>  {
                        let m = meta.getOrThrow{WSException('${metaType} meta for ws is not specified')}
                        let resp = m.`handle`(endpoint, ctx, pattern, ws, bytes.unsafeData())
                        match(m.responseFrameType){
                            case Some(t) => match(t){
                                case TextWebFrame | BinaryWebFrame => ws.write(t, resp)
                                case _ => throw WSException('response of ${ctx.request.url} for ${m.name} must be TextWebFrame or BinaryWebFrame')
                            }
                            case _ => throw WSException('${ctx.request.url} for ${m.name} is not be specified frame type')
                        }
                    }
                    match(ft){
                        case TextWebFrame => doExec(textMeta_, "text")
                        case BinaryWebFrame => doExec(binaryMeta_, "binary")
                        case _ => return bytes
                    }
                    return ArrayList<Byte>()
                }
            }
            bytes
        }
        let pingAction: Option<() -> Unit> = if(let Some(f) <- pingFunc_) {
            let h = f.`handle`
            Some({=>
                // 加固（§1.11 / MVC-3）：在途 ping 撞上已关闭的连接时，异常不能抛进定时器线程；
                // 连接真正结束时由 pumpFrames 的 finally 取消该定时器。
                try {
                    ws.writePingFrame(h(endpoint, ctx, pattern, ws, []))
                } catch (_: Exception) {
                }
            })
        } else {
            None<() -> Unit>
        }
        let pingInterval = if(let Some(f) <- pingFunc_) { f.duration } else { Duration.Zero }
        pumpFrames(
            readFrame: {=> ws.read()},
            onFrame: {frame =>
                try{
                    match(frame.frameType){
                        case TextWebFrame | BinaryWebFrame =>
                            let (metaType, hasMeta) = match (frame.frameType) {
                                case TextWebFrame => ('text', textMeta_.isSome())
                                case _ => ('binary', binaryMeta_.isSome())
                            }
                            if (let Some(reason) <- dataFrameCloseReason(metaType, !bytes.value.isEmpty(), hasMeta)) {
                                // §3.1 / MVC-C6(b)：该关就关 —— 不再「抛异常 → catch → 会话继续」（每条消息一次异常 + 一条日志）
                                log.error{'${reason}'}
                                ws.closeConn()
                                return true
                            }
                            frameType.value = frame.frameType
                            bytes.value = doExec(frame.payload, frame.fin, frameType.value, bytes.value)
                        case ContinuationWebFrame =>
                            bytes.value = doExec(frame.payload, frame.fin, frameType.value, bytes.value)
                        case PingWebFrame =>
                            if(let Some(ping) <- pingMeta_){
                                let payload = ping.`handle`(endpoint, ctx, pattern, ws, frame.payload)
                                ws.writePongFrame(payload)
                            }else{
                                ws.writePongFrame(frame.payload)
                            }
                        case PongWebFrame =>
                            if(let Some(pong) <- pongMeta_){
                                pong.`handle`(endpoint, ctx, pattern, ws, frame.payload)
                            }
                        case CloseWebFrame =>
                            try{
                                if(let Some(c) <- closeMeta_){
                                    let payload = c.`handle`(endpoint, ctx, pattern, ws, frame.payload)
                                    if(!payload.isEmpty()){
                                        ws.write(CloseWebFrame, payload)
                                    }
                                }else{
                                    ws.write(CloseWebFrame, frame.payload)
                                }
                            }catch(e: Exception){
                                log.error(e){'error on handling close ${toBase64String(frame.payload)}'}
                            }
                            ws.closeConn()
                            return true
                        case _ =>
                            log.error{'unsupport frame ${frame.frameType}'}
                            ws.closeConn()
                    }
                }catch(e: Exception){
                    log.error(e){'error on handling ${frame.frameType}; frame: ${toBase64String(frame.payload)}'}
                }
                false
            },
            ping: pingAction,
            interval: pingInterval
        )
    }
    
    private func doExtractArgOption<P, M>(meta: ?M, ctx: HttpContext, name: String): ?P where P <: DataFields<P>, M <: WSFuncMeta<T> {
        let val = meta?.args.extract<P>(ctx, name, pattern)
        match(val){
            case Some(x) => x
            case _ => None<P>
        }
    }
    private func doExtractArg<P, M>(meta: ?M, ctx: HttpContext, name: String): P where P <: DataFields<P>, M <: WSFuncMeta<T> {
        doExtractArgOption<P, M>(meta, ctx, name).getOrThrow()
    }
    private func doExtractArg<P, M>(meta: ?M, ctx: HttpContext, name: String, default: P): P where P <: DataFields<P>, M <: WSFuncMeta<T> {
        doExtractArgOption<P, M>(meta, ctx, name) ?? default
    }

    public func extractOpenArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(openMeta_, ctx, name)
    }
    public func extractOpenArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(openMeta_, ctx, name, default)
    }
    public func extractCloseArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(closeMeta_, ctx, name)
    }
    public func extractCloseArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(closeMeta_, ctx, name, default)
    }
    public func extractTextArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(textMeta_, ctx, name)
    }
    public func extractTextArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(textMeta_, ctx, name, default)
    }
    public func extractBinaryArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(binaryMeta_, ctx, name)
    }
    public func extractBinaryArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(binaryMeta_, ctx, name, default)
    }
    public func extractPingArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(pingMeta_, ctx, name)
    }
    public func extractPingArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(pingMeta_, ctx, name, default)
    }
    public func extractPongArg<T>(ctx: HttpContext, name: String): T where T <: DataFields<T> {
        doExtractArg(pongMeta_, ctx, name)
    }
    public func extractPongArg<T>(ctx: HttpContext, name: String, default: T): T where T <: DataFields<T> {
        doExtractArg(pongMeta_, ctx, name, default)
    }

    public static func generate() : WSMeta<T> {
        let endpointClass = TypeInfo.of<T>()
        let meta = WSMeta<T>()
        for(function in endpointClass.instanceFunctions) {
            let funcName = function.name
            let funcMeta = 
            if(let Some(annotation) <- function.findAnnotation<OnWSOpen>()){
                let m = WSOpenMeta<T>(funcName)
                meta.openMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<OnWSClose>()){
                let m = WSCloseMeta<T>(funcName)
                meta.closeMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<OnWSBinary>()){
                let m = WSBinaryMeta<T>(funcName, annotation.mediaType, annotation.responseFrameType)
                meta.binaryMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<OnWSText>()){
                let m = WSTextMeta<T>(funcName, annotation.mediaType, annotation.responseFrameType)
                meta.textMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<OnWSPing>()){
                let m = WSPingMeta<T>(funcName, annotation.mediaType)
                meta.pingMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<OnWSPong>()){
                let m = WSPongMeta<T>(funcName, '')
                meta.pongMeta_ = m
                m
            }else if(let Some(annotation) <- function.findAnnotation<WSPing>()){
                let f = WSPingFunc<T>(funcName, annotation.mediaType)
                f.duration = Duration.parse(annotation.duration)
                meta.pingFunc_ = f
                f
            }else{
                continue
            }
            for (param in function.parameters) {
                let pname = param.name
                var toThrow = true
                for (annotation in param.annotations where annotation is ControllerFuncParam) {
                    funcMeta.args[pname] = (annotation as ControllerFuncParam).getOrThrow()
                    toThrow = false
                    break
                }
                if(toThrow){
                    throw WSException(
                        'parameter of controller function must be with one and only one Annotation as @RequestBody or @RequestParam or @RequestHeader or @PathVariable or @MultipartFormData')
                }
            }
        }
        meta
    }
}