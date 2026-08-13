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

protected import std.reflect.*
protected import std.time.MonoTime

protected import fountain::f_base.*
protected import fountain::f_config.*
protected import fountain::f_io.ByteBuffer
protected import fountain::f_bean.*
protected import fountain::f_data.*
protected import fountain::f_data

public const UNSUPPORTED_COMMAND = 'UnsupportedCommand'
public const OVERFEEDING = 'Client is overfeeding'

protected import fountain::f_log.*
protected let rpclog = LoggerFactory.getLogger('rpc')

private func logmsg(id: MessageID, label: String, command: Command, message: String){
    '[FOUNTAIN_RPC.${label}.${command}] ${id}; ${message}'
}
private func logmsg<T>(id: MessageID, label: String, command: Command, message: T): String where T <: ToData {
    logmsg(id, label, command, JsonValue.from(message.toData()).toString())
}
private func logmsg<T>(id: MessageID, label: String, command: Command, message: () -> T): String where T <: ToData {
    logmsg(id, label, command, message())
}
protected func errorLog(id: MessageID, label: String, command: Command, message: String): Unit {
    rpclog.error(logmsg(id, label, command, message))
}
protected func errorLog<T>(id: MessageID, label: String, command: Command, message: T): Unit where T <: ToData {
    rpclog.error(logmsg(id, label, command, message))
}
protected func debugLog<T>(id: MessageID, label: String, command: Command, message: () -> T): Unit where T <: ToData {
    rpclog.debug{logmsg(id, label, command, message)}
}
protected func infoLog<T>(id: MessageID, label: String, command: Command, message: () -> T): Unit where T <: ToData {
    rpclog.info{logmsg(id, label, command, message)}
}
