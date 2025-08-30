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
package f_rx

import f_concurrent.{RateLimiter, AnyMomentRateLimiter, LeakingBucketRateLimiter, SlidingWindowRateLimiter, TokenBucketRateLimiter}

public class RateLimiterBackPressure<T> <: BackPressure<T> {
    public RateLimiterBackPressure(scheduler: SingleScheduler<T>, 
        private let limiter: RateLimiter<Unit>,
        private let policy!: BackPressure<T> = CurrentThread<T>()){
        super.scheduler = scheduler
    }
    public init(limiter: RateLimiter<Unit>, policy!: BackPressure<T> = CurrentThread<T>()){
        this.limiter = limiter
        this.policy = policy
    }
    public static func tokenBucket(scheduler: SingleScheduler<T>, tokens!: Int64, timeout!: Duration, populationPeriod!: Duration, policy!: BackPressure<T> = CurrentThread<T>()): RateLimiterBackPressure<T> {
        RateLimiterBackPressure<T>(scheduler, TokenBucketRateLimiter<Unit>(tokens: tokens, timeout: timeout, populationPeriod: populationPeriod), policy: policy)
    }
    public static func tokenBucket(tokens!: Int64, timeout!: Duration, populationPeriod!: Duration, policy!: BackPressure<T> = CurrentThread<T>()){
        RateLimiterBackPressure<T>(TokenBucketRateLimiter<Unit>(tokens: tokens, timeout: timeout, populationPeriod: populationPeriod), policy: policy)
    }
    public static func slidingWindow(scheduler: SingleScheduler<T>, window!: Duration, timeout!: Duration, limit!: Int64, policy!: BackPressure<T> = CurrentThread<T>()){
        RateLimiterBackPressure<T>(scheduler, SlidingWindowRateLimiter<Unit>(window: window, timeout: timeout, limit: limit), policy: policy)
    }
    public static func slidingWindow(window!: Duration, timeout!: Duration, limit!: Int64, policy!: BackPressure<T> = CurrentThread<T>()){
        RateLimiterBackPressure<T>(SlidingWindowRateLimiter<Unit>(window: window, timeout: timeout, limit: limit), policy: policy)
    }
    public static func leakingBucket(scheduler: SingleScheduler<T>, timeout!: Duration, maxWaitings!: Int64, leakingPerDuration!: Int64, leakingDuration!: Duration, policy!: BackPressure<T> = CurrentThread<T>()){
        RateLimiterBackPressure<T>(scheduler, LeakingBucketRateLimiter<Unit>(timeout: timeout, maxWaitings: maxWaitings, leakingPerDuration: leakingPerDuration, leakingDuration: leakingDuration), policy: policy)
    }
    public static func leakingBucket(timeout!: Duration, maxWaitings!: Int64, leakingPerDuration!: Int64, leakingDuration!: Duration, policy!: BackPressure<T> = CurrentThread<T>()){
        RateLimiterBackPressure<T>(LeakingBucketRateLimiter<Unit>(timeout: timeout, maxWaitings: maxWaitings, leakingPerDuration: leakingPerDuration, leakingDuration: leakingDuration), policy: policy)
    }
    public static func anyMoment(scheduler: SingleScheduler<T>, maxTokens!: Int64, timeout!: Duration, policy!: BackPressure<T> = CurrentThread<T>()){
        RateLimiterBackPressure<T>(scheduler, AnyMomentRateLimiter<Unit>(maxTokens: maxTokens, timeout: timeout), policy: policy)
    }
    public static func anyMoment(maxTokens!: Int64, timeout!: Duration, policy!: BackPressure<T> = CurrentThread<T>()){
        RateLimiterBackPressure<T>(AnyMomentRateLimiter<Unit>(maxTokens: maxTokens, timeout: timeout), policy: policy)
    }
    
    protected func schedule(state: SingleSchedulerState<T>): Unit {
        limiter.exec(None<Unit>){
            policy.schedule(state)
        }
    }
    protected func clone(): BackPressure<T> {
        let bp = RateLimiterBackPressure<T>(this.limiter, policy: policy)
        bp.scheduler_ = this.scheduler_
        bp
    }
}