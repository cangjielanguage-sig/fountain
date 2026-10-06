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
package fountain::f_config

import std.collection.{HashMap, Map, HashSet}
import std.collection.concurrent.ConcurrentHashMap
import std.env
import std.time.DateTime
import stdx.crypto.crypto.*
import stdx.encoding.hex.*
public import fountain::f_data.DataParsable
public import std.convert.Parsable

/**
 * 不依赖配置文件，所有配置都来自环境变量和命令行参数，命令行参数会覆盖同名环境变量。
 * 本工具不会修改环境变量和命令行参数命名风格，仓颉运行时环境变量都是驼峰命名法，建议用于应用配置的环境变量和命令行参数也采用此风格。
 * 命令行参数需要遵守以下规则
 *   1. --argName=argValue
 *   2. --argName
 *      * 相当于--argName=true
 *   3. -argName argVal
 *   4. -argName
 *      * 相当于-argName true
 * 敏感配置信息使用sm4加密，如果不指定sm4加密参数，会把敏感配置的UTF8字节数组嵌入编译产物。
 * 指定了sm4加密参数，会把敏感配置的密文嵌入编译产物。
 * - sm4Operation SM4 的OperationMode
 * - sm4Padding SM4 的PaddingMode
 * - sm4Key 密钥
 * - sm4Iv IV
 * - sm4Aad 密文填充的AAD
 * - sm4TagSize 密文填充的TagSize
 */
public class Config {
    private static let prefix = 'fountain'
    private static let ARGS = ConcurrentHashMap<String, String>()
    private static let REFRESHER = ConcurrentHashMap<String, () -> Unit>()

    public static const sm4Operation = 'sm4Operation'
    public static const sm4Padding = 'sm4Padding'
    public static const sm4Key = 'sm4Key'
    public static const sm4Iv = 'sm4Iv'
    public static const sm4Aad = 'sm4Aad'
    public static const sm4TagSize = 'sm4TagSize'

    public static const dylibPattern = 'dylibPattern'

    private static let sensitiveMap = ConcurrentHashMap<String, Array<Byte>>()

    static init() {
        for ((k, v) in env.getVariables()) {
            ARGS[k] = v
        }
        let args = env.getCommandLine()[1..]
        var i = 0
        while (i < args.size) {
            let arg = args[i]
            if (arg.startsWith('--')) {
                let (key, val) = 
                if (let Some(idx) <- arg.indexOf('=')) {
                    let key = arg[2..idx].trimAscii()
                    let val = arg[idx + 1..].trimAscii()
                    (key, val)
                } else {
                    let key = arg[2..].trimAscii()
                    (key, 'true')
                }
                ARGS[key] = val
            } else if (arg.startsWith('-')) {
                let key = arg[1..].trimAscii()
                let val = if (i + 1 < args.size) {
                    let val = args[i + 1].trimAscii()
                    if (val.startsWith('-')) {
                        'true'
                    } else {
                        i++
                        val
                    }
                } else {
                    'true'
                }
                ARGS[key] = val
            }
            i++
        }
    }
    private init() {}

    public static func refresher(prefix: String, fn: () -> Unit): Unit {
        REFRESHER['${prefix}_'] = fn
    }
    /**
     * ifAbsent是true，只有当前配置项不存在时才添加，否则用新的配置覆盖旧的
     */
    public static func set<T>(tuples: Array<(String, T)>, ifAbsent!: Bool = false): Unit where T <: ToString {
        let set = HashSet<String>()
        for (tpl in tuples) {
            let name = tpl[0]
            if (!ifAbsent) {
                ARGS[name] = tpl[1].toString()
            } else if(ARGS.addIfAbsent(name, tpl[1].toString()).isSome()) {
                continue
            }
            if (let Some(x) <- name.indexOf('_')) {
                set.add(name[0..x])
            } else {
                set.add(name)
            }
        }
        for ((prefix, fn) in REFRESHER) {
            for (k in set where k.startsWith(prefix) || k.startsWith('${Config.prefix}_${prefix}')) {
                fn()
                break
            }
        }

    }
    /**
     * 得到相同前缀的配置项
     */
    public static func getAll(prefix: String): Map<String, String> {
        func matches(k: String){
            prefix.isEmpty() || k.startsWith('${prefix}_') || k.startsWith('${Config.prefix}_${prefix}_')
        }
        let map = HashMap<String, String>()
        for ((k, v) in ARGS where matches(k)) {
            map[k.replace('${Config.prefix}_', '')] = v
        }
        for((k, v) in sensitiveMap where matches(k)){
            let view = map.entryView(k.replace('${Config.prefix}_', ''))
            if(view.value.isNone()){
                view.value = sensitive2Str(v)
            }
        }
        map
    }
    public static func getAll(): Map<String, String> {
        getAll('')
    }
    private static func sensitive2Str(bytes: Array<Byte>){
        if(bytes.size == 0){
            return ''
        }else if(let Some(sm4) <- getSM4()){
            bytes |> sm4.decrypt
        }else{
            bytes
        } |> String.fromUtf8
    }
    /**
     * 得到名是key的配置项
     */
    public static func getString(key: String): ?String {
        if (let Some(v) <- ARGS.get(key)) {
            v
        } else if (let Some(v) <- ARGS.get("${prefix}_${key}")){
            v
        } else if (let Some(v) <- sensitiveMap.get(key)){
            sensitive2Str(v)
        } else if (let Some(v) <- sensitiveMap.get("${prefix}_${key}")){
            sensitive2Str(v)
        } else {
            None<String>
        }
    }

    public static func getValue<T>(key: String, parser: (String) -> ?T): ?T {
        if (let Some(x) <- getString(key)) {
            parser(x)
        } else {
            None<T>
        }
    }
    public static func getValue<T>(key: String): ?T where T <: Parsable<T> {
        getValue<T>(key) {s => T.tryParse(s)}
    }
    public static func getStringArray(key: String, delim!: String = ','): Array<String> {
        if (let Some(x) <- getString(key)) {
            let arr = x.split(delim, removeEmpty: true)
            Array<String>(arr.size) {i => arr[i].trimAscii()}
        } else {
            []
        }
    }
    public static func getValues<T>(key: String, delim!: String = ',', parser!: (String) -> T): Array<T> {
        let arr = getStringArray(key, delim: delim)
        Array<T>(arr.size) {i => parser(arr[i])}
    }
    public static func getValues<T>(key: String, delim!: String = ','): Array<T> where T <: Parsable<T> {
        getValues<T>(key, delim: delim) {s => T.parse(s)}
    }
    private static func parseDateTime(s: String, format: String) {
        if (format.isEmpty()) {
            DateTime.parse(s)
        } else {
            DateTime.parse(s, format)
        }
    }
    public static func getDateTime(key: String, format!: String = ''): ?DateTime {
        getValue<DateTime>(key) {s => parseDateTime(s, format)}
    }
    public static func getDateTimes(key: String, format!: String = '', delim!: String = ','): Array<DateTime> {
        getValues<DateTime>(key, delim: delim) {s => parseDateTime(s, format)}
    }
    public static func getData<T>(key: String): ?T where T <: DataParsable<T> {
        getValue<T>(key) {s => T.tryParse(s)}
    }
    public static func getDatas<T>(key: String, delim!: String = ','): Array<T> where T <: DataParsable<T> {
        getValues<T>(key, delim: delim) {s => T.parse(s)}
    }
    public static func getDuration(key: String): ?Duration {
        getData<Duration>(key)
    }
    public static func getDurations(key: String, delim!: String = ','): Array<Duration> {
        getDatas<Duration>(key, delim: delim)
    }
    public static func bufferSize(bufferKey: String, default: Int64, debugging: Bool): Int64 {
        if (let Some(x) <- Config.getValue<Int>(bufferKey)) {
            if (x > 0 && debugging) {
                return x
            } else if (x <= 0) {
                return default
            } else if (((x - 1) & x) == 0) {
                return x
            }
            var s = 1
            while (s < x) {
                s <<= 1
            }
            if (s >= default) {
                s
            } else {
                default
            }
        } else {
            default
        }
    }
    public static func getSM4(): ?SM4 {
        let sm4conf = Config.sm4conf
        let key = sm4conf.key
        if(key.isEmpty()){
            return None<SM4>
        }
        let iv = sm4conf.iv
        let aad = sm4conf.aad
        let operation = sm4conf.operation
        let padding = sm4conf.padding
        let tagSize = sm4conf.tagSize
        SM4(match(operation){
            case 'CBC' => OperationMode.CBC
            case 'CFB' => OperationMode.CFB
            case 'CTR' => OperationMode.CTR
            case 'GCM' => OperationMode.GCM
            case 'OFB' => OperationMode.OFB
            case _ => throw IllegalArgumentException("${operation} is not a legal sm4 OperationMode, and ECB is not safe to use, so it is not supported")
        }, key, iv: iv, paddingMode: match(padding){
            case 'NoPadding' => PaddingMode.NoPadding
            case 'PKCS7Padding' => PaddingMode.PKCS7Padding
            case _ => throw IllegalArgumentException("${padding} is not a legal sm4 PaddingMode, only NoPadding and PKCS7Padding are supported")
        }, aad: aad, tagSize: tagSize)
    }
    public static func registerSensitive(key: String, value: Array<Byte>): Unit {
        sensitiveMap[key] = value
    }
    protected static prop sm4conf: SM4Conf {
        get(){
            SM4Conf(sensitiveMap)
        }
    }
    public static func getDylibPattern(): String {
        getString(dylibPattern) ?? ''
    }
}

protected struct SM4Conf{
    SM4Conf(
        private let sensitiveMap: ConcurrentHashMap<String, Array<Byte>>
    ){}
    private func getString(key: String): ?String {
        if(let Some(bytes) <- sensitiveMap.get(key)){
            String.fromUtf8(bytes)
        }else if (let Some(v) <- Config.getString(key)){
            v
        }else{
            None<String>
        }
    }
    private func getBytes(key: String): ?Array<Byte> {
        if(let Some(bytes) <- sensitiveMap.get(key)){
            bytes
        }else if (let Some(v) <- Config.getString(key)){
            fromHexString(v)
        }else{
            []
        }
    }
    protected prop operation: String {
        get(){
            return getString(Config.sm4Operation) ?? 'CBC'
        }
    }
    protected prop padding: String {
        get(){
            return getString(Config.sm4Padding) ?? 'PKCS7Padding'
        }
    }
    protected prop key: Array<Byte> {
        get(){
            if(let Some(bytes) <- getBytes(Config.sm4Key)){
                if(bytes.size == 16 || bytes.size == 0){
                    bytes
                }else{
                    throw IllegalArgumentException("size of orm config item ${Config.sm4Key} is not 16")
                }
            }else{
                throw IllegalArgumentException("orm config item ${Config.sm4Key} is not a legal hex string or is not be specified or its size is not 16")
            }
        }
    }
    protected prop iv: Array<Byte> {
        get(){
            if(let Some(bytes) <- getBytes(Config.sm4Iv)){
                match(operation){
                    case 'CBC' | 'OFB' | 'CFB' where bytes.size != 16 => throw IllegalArgumentException("size 16 of orm config item ${Config.sm4Iv} is suggested for OperationMode.CBC, OperationMode.OFB and OperationMode.CFB.")
                    case 'GCM' where bytes.size != 12 => throw IllegalArgumentException("size 12 of orm config item ${Config.sm4Iv} is suggested for OperationMode.GCM")
                    case 'CBC' | 'OFB' | 'CFB' | 'GCM' => bytes
                    case _ => throw IllegalArgumentException("${operation} is not a legal sm4 OperationMode, and ECB is not safe to use, so it is not supported.")
                }
            }else{
                throw IllegalArgumentException("orm config item ${Config.sm4Iv} is not a legal hex string or is not be specified.")
            }
        }
    }
    protected prop aad: Array<Byte> {
        get(){
            getBytes(Config.sm4Aad) ?? []
        }
    }
    protected prop tagSize: Int64 {
        get(){
            (getString(Config.sm4TagSize) ?? '16') |> Int64.parse
        }
    }
}