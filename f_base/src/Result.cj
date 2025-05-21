/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

public enum Result<T, E> {
    | Ok
    | Ok(T)
    | Err
    | Err(E)
    | None

    public prop isOk: Bool {
        get() {
            match (this) {
                case Ok => true
                case Ok(_) => true
                case _ => false
            }
        }
    }
    public prop isErr: Bool {
        get() {
            match (this) {
                case Err => true
                case Err(_) => true
                case _ => false
            }
        }
    }
    public prop isNone: Bool {
        get(){
            match (this) {
                case None => true
                case _ => false
            }
        }
    }
    public prop withE: Bool {
        get(){
            match(this){
                case Err(_) => true
                case _ => false
            }
        }
    }
    public prop withValue: Bool {
        get(){
            match(this){
                case Ok(_) => true
                case _ => false
            }
        }
    }
    public func result(): ?T {
        match (this) {
            case Ok(v) => v
            case _ => None
        }
    }
    public func err(): ?E {
        match (this) {
            case Err(e) => e
            case _ => None
        }
    }
    public func map<U>(f: (T) -> Result<U, E>): Result<U, E> {
        match (this) {
            case Ok(v) => 
                try{
                    f(v)
                }catch(e: Exception){
                    match(e){
                        case x: E => Err(x)
                        case _ => throw e
                    }
                }
            case Err => return Err
            case Err(e) => return Err(e)
            case None => return None
        }
    }
    public func map<U>(f: (E) -> Result<U, E>): Result<U, E> {
        match(this){
            case Ok => Ok
            case Ok(v: U) => Ok(v)
            case Ok(_) => Ok
            case Err => Err
            case None => None
            case Err(e) => f(e)
        }
    }
    /**
     * 忽略数据和错误信息，只返回Ok Err None
     */
    public func ignore(): Result<T, E> {
        match(this){
            case Ok => Ok
            case Ok(_) => Ok
            case Err => Err
            case None => None
            case Err(_) => Err
        }
    }
    public func filter(predicate: (T) -> Bool): Result<T, E> {
        match (this) {
            case Ok(v) where predicate(v) => this
            case _ => return None
        }
    }
    public func filter(predicate: (E) -> Bool): Result<T, E> {
        match(this){
            case Err(e) where predicate(e) => this
            case _ => None
        }
    }
    public func filterOk(){
        filter{_ => isOk}
    }
    public func filterErr(){
        filter{_ => isErr}
    }
    public func filterNone(){
        filter{_ => isNone}
    }
    public func filterWithE(){
        filter{_ => withE}
    }
    public func filterWithValue(){
        filter{_ => withValue}
    }
    public func flatten<U>(): Result<U, E> {
        match (this) {
            case Ok(v: Result<U, E>) => v
            case Ok => Ok
            case Err => Err
            case Err(e) => Err(e)
            case None => None
        }
    }
    public func transpose<U>(): ?Result<U, E> {
        match(this){
            case Ok(x: ?U) => match(x){
                case Some(y) => Ok(y)
                case _ => None
            }
            case Ok => Ok
            case Err => Err
            case Err(e) => Err(e)
            case None => None
            case Ok(_) => Ok
        }
    }
    public func orDefault(default: T): Result<T, E> {
        match(this){
            case Ok(_) => this
            case _ => Ok(default)
        }
    }
    public func orElse(fn: () -> T): Result<T, E> {
        match(this){
            case Ok(_) => this
            case _ => Ok(fn())
        }
    }
    public func orElse(fn: () -> ?T): Result<T, E> {
        match(this){
            case Ok(_) => this
            case _ => match(fn()){
                case Some(x) => Ok(x)
                case _ => None
            }
    }
    public func mapper<U>(): ResultMapper<T, U, E>{
        ResultMapper<T, U, E>(this)
    }
}
public class ResultMapper<T, U, E> {
    ResultMapper(origin: Result<T, E>){}
    private var resultMap = {_: T => Result<U, E>.Ok}
    private var okMap = {=> Result<U, E>.Ok}
    private var withErrorMap = {e: E => Result<U, E>.Err(e)}
    private var errorMap = {=> Result<U, E>.Err}
    private var noneMap = {=> Result<U, E>.None}
    public func result(f: (T) -> Result<U, E>): ResultMapper<T, U, E> {
        resultMap = f
        this
    }
    public func ok(f: () -> Result<U, E>): ResultMapper<T, U, E> {
        okMap = f
        this
    }
    public func error(f: (E) -> Result<U, E>): ResultMapper<T, U, E> {
        withErrorMap = f
        this
    }
    public func error(f: () -> Result<U, E>): ResultMapper<T, U, E> {
        errorMap = f
        this
    }
    public func none(f: () -> Result<U, E>): ResultMapper<T, U, E> {
        noneMap = f
        this
    }
    public func map(): Result<U, E> {
        match(origin) {
            case Ok => okMap()
            case Ok(v) => resultMap(v)
            case Err => errorMap()
            case Err(e) => exceptionMap(e)
            case None => noneMap()
        }
    }
}