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
package fountain::f_rpc.server

internal class ServerConfig {
    public static const RPC_SERVER_PREFIX = "rpcServer"
    public static const RPC_SERVER_PREFIX_PORT = RPC_SERVER_PREFIX + "_port"
    public static const RPC_SERVER_PORT = RPC_SERVER_PREFIX + '_port'
    public static const RPC_SERVER_BUFFER_QUEUE_SIZE = RPC_SERVER_PREFIX + '_bufferQueueSize'
    public static const RPC_SERVER_CONNECTION_CHECK_DURATION = RPC_SERVER_PREFIX + '_connectionCheckDuration'
    public static const RPC_SERVER_BASE_ADDRESSES = RPC_SERVER_PREFIX + '_baseAddresses'

    public static const RPC_SERVER_RATE_LIMITER_NAME = RPC_SERVER_PREFIX + '_rateLimiterName'
    public static const RPC_SERVER_RATE_LIMITER_MAX_TOKENS = RPC_SERVER_PREFIX + '_maxTokens'
    public static const RPC_SERVER_RATE_LIMITER_TIMEOUT = RPC_SERVER_PREFIX + '_timeout'
    public static const RPC_SERVER_RATE_LIMITER_MAX_WAITINGS = RPC_SERVER_PREFIX + '_maxWaitings'
    public static const RPC_SERVER_RATE_LIMITER_LEAKING_PER_DURATION = RPC_SERVER_PREFIX + '_leakingPerDuration'
    public static const RPC_SERVER_RATE_LIMITER_LEAKING_DURATION = RPC_SERVER_PREFIX + '_leakingDuration'
    public static const RPC_SERVER_RATE_LIMITER_WINDOW = RPC_SERVER_PREFIX + '_window'
    public static const RPC_SERVER_RATE_LIMITER_LIMIT = RPC_SERVER_PREFIX + '_limit'
    public static const RPC_SERVER_RATE_LIMITER_TOKENS = RPC_SERVER_PREFIX + '_tokens'
    public static const RPC_SERVER_RATE_LIMITER_POPULATION_PERIOD = RPC_SERVER_PREFIX + '_populationPeriod'

    public static const ANY_MOMENT_RATE_LIMITER = "anyMomentRateLimiter"
    public static const LEAKING_BUCKET_RATE_LIMITER = "leakingBucketRateLimiter"
    public static const SLIDING_WINDOW_RATE_LIMITER = "slidingWindowRateLimiter"
    public static const TOKEN_BUCKET_RATE_LIMITER = "tokenBucketRateLimiter"

    internal static prop port: Unit16 {
        get(){
            Config.getValue<Int16>(RPC_SERVER_PREFIX_PORT) ?? 1203u16
        }
    }
    internal static prop bufferQueueSize: Int64 {
        get(){
            Config.getValue<Int64>(RPC_SERVER_BUFFER_QUEUE_SIZE) ?? 1000000
        }
    }
    internal static prop connectionCheckDuration: Int64 {
        get(){
            Config.getValue<Int64>(RPC_SERVER_CONNECTION_CHECK_DURATION) ?? 1000
        }
    }
    internal static prop baseAddresses: Array<String> {
        get(){
            Config.getStringArray(RPC_SERVER_BASE_ADDRESSES)
        }
    }
    internal static func rateLimiter(): RateLimiter<Unit> {
        if(let Some(l) <- Config.getString(RPC_SERVER_RATE_LIMITER_NAME)){
            match(l){
                case 'anyMomentRateLimiter' => 
                    let maxTokens = Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_MAX_TOKENS) ?? 1024
                    let timeout = Duration.milisecond * (Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_TIMEOUT) ?? 100)
                    AnyMomentRateLimiter<Unit>(maxTokens: maxTokens, timeout: timeout)
                case 'leakingBucketRateLimiter' =>
                    let timeout = Duration.milisecond * Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_TIMEOUT) ?? 1000
                    let maxWaitings = Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_MAX_WAITINGS) ?? 1024
                    let leakingPerDuration = Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_LEAKING_PER_DURATION) ?? 1
                    let leakingDuration = Duration.milisecond * (Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_LEAKING_DURATION) * 50)
                    LeakingBucketRateLimiter<Unit>(timeout: timeout,
                        maxWaitings: maxWaitings,
                        leakingPerDuration: leakingPerDuration,
                        leakingDuration: leakingDuration)
                case 'slidingWindowRateLimiter' =>
                    let window = Duration.milisecond * (Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_WINDOW) ?? 150)
                    let limit = Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_LIMIT) ?? 1024
                    let timeout = Duration.milisecond * (Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_TIMEOUT) ?? 100)
                    SlidingWindowRateLimiter<Unit>(window: window, limit: limit, timeout: timeout)
                case 'tokenBucketRateLimiter' =>
                    let tokens = Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_TOKENS) ?? 1024
                    let timeout = Duration.milisecond * (Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_TIMEOUT) ?? 100)
                    let populationPeriod = Duration.milisecond * (Config.getValue<Int64>(RPC_SERVER_RATE_LIMITER_POPULATION_PERIOD) ?? 150)
                    TokenBucketRateLimiter<Unit>(tokens: tokens, timeout: timeout, populationPeriod: populationPeriod)
                case _ => UnlimitedRateLimiter<Unit>()
            }
        }
    }
}
/*
    public func anyMomentRateLimiter(maxTokens!: Int64, timeout!: Duration): This 
    public func leakingBucketRateLimiter(timeout!: Duration,
        maxWaitings!: Int64,
        leakingPerDuration!: Int64,
        leakingDuration!: Duration): This 
    public func slidingWindowRateLimiter(window!: Duration, timeout!: Duration, limit!: Int64): This 
    public func tokenBucketRateLimiter(tokens!: Int64, timeout!: Duration, populationPeriod!: Duration): This 
    public func defaultResponse(resp: (MessageID) -> ?Message): This 