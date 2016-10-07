#lang s-exp "stlc+prim.rkt"
(require "../tests/rackunit-typechecking.rkt")

3
(+ 1 2)
(+ (+ 1 0) 2)
(λ ([x : Int]) (+ 1 x))
((λ ([x : Int]) (+ 1 x)) 2)
((λ ([f : (→ Int Int Int)]) (f 1 2)) +)
((λ ([f : (→ Int Int Int)]) (f 1 2)) (λ ([x : Int][y : Int]) (+ x y)))
(λ ([x : Int]) (λ ([y : Int]) (λ ([f : (→ Int Int Int)]) (f x y))))
((((λ ([x : Int]) (λ ([y : Int]) (λ ([f : (→ Int Int Int)]) (f x y)))) 1) 2) +)
;; type errs
(typecheck-fail
 ((λ ([f : (→ Int Int)]) (f 1 2)) +) ; TYERR: wrong number of args
 #:with-msg 
 "f: wrong number of arguments: expected 1, given 2.*expected.*Int")
(typecheck-fail
 ((λ ([x : Int]) (+ x 1)) +) ; TYERR: expected Int, given (→ Int Int Int)
 #:with-msg "expected Int, given \\(→ Int Int Int\\)")