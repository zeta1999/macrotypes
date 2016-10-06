#lang turnstile
(require racket/fixnum racket/flonum)

(extends "ext-stlc.rkt" #:except #%app λ → + - * void = zero? sub1 add1 not let let* and #%datum begin
          #:rename [~→ ~ext-stlc:→])
(require (rename-in (only-in "sysf.rkt" inst) [inst sysf:inst]))
(require (only-in "ext-stlc.rkt" →?))
(require (only-in "sysf.rkt" ~∀ ∀ ∀? Λ))
(reuse × tup proj define-type-alias #:from "stlc+rec-iso.rkt")
(require (only-in "stlc+rec-iso.rkt" ~× ×?)) ; using current-type=? from here
(provide (rename-out [ext-stlc:and and] [ext-stlc:#%datum #%datum]))
(reuse member length reverse list-ref cons nil isnil head tail list #:from "stlc+cons.rkt")
(require (prefix-in stlc+cons: (only-in "stlc+cons.rkt" list cons nil)))
(require (only-in "stlc+cons.rkt" ~List List? List))
(provide List)
(reuse ref deref := Ref #:from "stlc+box.rkt")
(require (rename-in (only-in "stlc+reco+var.rkt" tup proj ×)
           [tup rec] [proj get] [× ××]))
(provide rec get ××)
;; for pattern matching
(require (prefix-in stlc+cons: (only-in "stlc+cons.rkt" list)))
(require (prefix-in stlc+tup: (only-in "stlc+tup.rkt" tup)))

(provide → →/test =>/test match2 define-type)

(provide define-typeclass define-instance)

;; ML-like language + ad-hoc polymorphism
;; - top level recursive functions
;; - user-definable algebraic datatypes
;; - pattern matching
;; - (local) type inference
;;
;; - type classes

(define-type-constructor => #:arity > 0)

;; type class helper fns
(begin-for-syntax
  (define (mk-app-err-msg stx #:expected [expected-τs #'()]
                              #:given [given-τs #'()]
                              #:note [note ""]
                              #:name [name #f]
                              #:action [other #f])
    (syntax-parse stx
      #;[(app . rst)
         #:when (not (equal? '#%app (syntax->datum #'app)))
         (mk-app-err-msg (syntax/loc stx (#%app app . rst))
                         #:expected expected-τs
                         #:given given-τs
                         #:note note
                         #:name name)]
      [(app e_fn e_arg ...)
       (define fn-name
         (if name name
             (format "function ~a"
                     (syntax->datum (or (get-orig #'e_fn) #'e_fn)))))
       (define action (if other other "applying"))
       (string-append
        (format "~a (~a:~a):\nType error "
                (syntax-source stx) (syntax-line stx) (syntax-column stx))
        action " "
        fn-name ". " note "\n"
        (format "  Expected: ~a argument(s) with type(s): " (stx-length expected-τs))
        (types->str expected-τs) "\n"
        "  Given:\n"
        (string-join
         (map (λ (e t) (format "    ~a : ~a" e t)) ; indent each line
              (syntax->datum #'(e_arg ...))
              (if (stx-length=? #'(e_arg ...) given-τs)
                  (stx-map type->str given-τs)
                  (stx-map (lambda (e) "?") #'(e_arg ...))))
         "\n")
        "\n")]))
  (define (type-hash-code tys) ; tys should be fully expanded
    (equal-hash-code (syntax->datum (if (syntax? tys) tys #`#,tys))))
  (define (mangle o tys)
    (format-id o "~a~a" o (type-hash-code tys)))
  ;; pattern expander for type class
  (define-syntax ~TC
    (pattern-expander
     (syntax-parser
       [(_ [generic-op ty-concrete-op] (~and ooo (~literal ...)))
        #'(_ (_ (_ generic-op) ty-concrete-op) ooo)]
       [(_ . ops+tys) 
        #:with expanded (generate-temporary)
        #'(~and expanded
            (~parse (_ (_ (_ gen-op) ty-op) (... ...)) 
                    #'expanded)
            (~parse ops+tys #'((gen-op ty-op) (... ...))))])))
  (define-syntax ~TC-base
    (pattern-expander
     (syntax-parser
      [(_ . pat)
       #:with expanded (generate-temporary)
       #'(~and expanded
              (~parse ((~TC . pat) . _) (flatten-TC #'expanded)))])))
  (define-syntax ~TCs
    (pattern-expander
     (syntax-parser
      ;; pat should be of shape ([op ty] ...)
      [(_ pat (~and ooo (~literal ...)))
       #:with expanded (generate-temporary)
       ;; (stx-map (compose remove-dups flatten-TC) #'expanded) 
       ;;  produces [List [List [List op+ty]]]
       ;; - inner [List op+ty] is from the def of a TC
       ;; - second List is from the flattened subclass TCs
       ;; - outer List is bc this pattern matces multiple TCs
       ;; This pattern expander collapses the inner two Lists
       #'(~and expanded
              (~parse (((~TC [op ty] (... ...)) (... ...)) ooo)
                      (stx-map (compose remove-dups flatten-TC) #'expanded))
              (~parse (pat ooo) #'(([op ty] (... ...) (... ...)) ooo)))])))
  (define (flatten-TC TC)
    (syntax-parse TC
      [(~=> sub-TC ... base-TC)
       (cons #'base-TC (stx-appendmap flatten-TC #'(sub-TC ...)))]))
  (define (remove-dups TCs)
    (syntax-parse TCs
      [() #'()]
      [(TC . rst)
       (cons #'TC (stx-filter (lambda (s) (not (typecheck? s #'TC))) (remove-dups #'rst)))])))
;; type inference constraint solving
(begin-for-syntax 
  ;; matching possibly polymorphic types
  (define-syntax ~?∀
    (pattern-expander
     (lambda (stx)
       (syntax-case stx ()
         [(?∀ vars-pat body-pat)
          #'(~or (~∀ vars-pat body-pat)
                 (~and (~not (~∀ _ _))
                       (~parse vars-pat #'())
                       body-pat))]))))

  ;; type inference constraint solving
  (define (compute-constraint τ1-τ2)
    (syntax-parse τ1-τ2
      [(X:id τ) #'((X τ))]
      [((~Any tycons1 τ1 ...) (~Any tycons2 τ2 ...))
       #:when (typecheck? #'tycons1 #'tycons2)
       (compute-constraints #'((τ1 τ2) ...))]
      ; should only be monomorphic?
      [((~∀ () (~ext-stlc:→ τ1 ...)) (~∀ () (~ext-stlc:→ τ2 ...)))
       (compute-constraints #'((τ1 τ2) ...))]
      [_ #'()]))
  (define (compute-constraints τs) 
    (stx-appendmap compute-constraint τs))

  (define (solve-constraint x-τ)
    (syntax-parse x-τ
      [(X:id τ) #'((X τ))]
      [_ #'()]))
  (define (solve-constraints cs)
    (stx-appendmap compute-constraint cs))
  
  (define (lookup x substs)
    (syntax-parse substs
      [((y:id τ) . rst)
       #:when (free-identifier=? #'y x)
       #'τ]
      [(_ . rst) (lookup x #'rst)]
      [() #f]))

  ;; find-unsolved-Xs : (Stx-Listof Id) Constraints -> (Listof Id)
  ;; finds the free Xs that aren't constrained by cs
  (define (find-unsolved-Xs Xs cs)
    (for/list ([X (in-list (stx->list Xs))]
               #:when (not (lookup X cs)))
      X))

  ;; lookup-Xs/keep-unsolved : (Stx-Listof Id) Constraints -> (Listof Type-Stx)
  ;; looks up each X in the constraints, returning the X if it's unconstrained
  (define (lookup-Xs/keep-unsolved Xs cs)
    (for/list ([X (in-list (stx->list Xs))])
      (or (lookup X cs) X)))

  ;; solve for Xs by unifying quantified fn type with the concrete types of stx's args
  ;;   stx = the application stx = (#%app e_fn e_arg ...)
  ;;   tyXs = input and output types from fn type
  ;;          ie (typeof e_fn) = (-> . tyXs)
  ;; It infers the types of arguments from left-to-right,
  ;; and it short circuits if it's done early.
  ;; It returns list of 3 values if successful, else throws a type error
  ;;  - a list of the arguments that it expanded
  ;;  - a list of the the un-constrained type variables
  ;;  - the constraints for substituting the types
  (define (solve Xs tyXs stx)
    (syntax-parse tyXs
      [(τ_inX ... τ_outX)
       ;; generate initial constraints with expected type and τ_outX
       #:with expected-ty (get-expected-type stx)
       (define initial-cs
         (if (syntax-e #'expected-ty)
             (compute-constraint (list #'τ_outX ((current-type-eval) #'expected-ty)))
             #'()))
       (syntax-parse stx
         [(_ e_fn . args)
          (define-values (as- cs)
              (for/fold ([as- null] [cs initial-cs])
                        ([a (in-list (syntax->list #'args))]
                         [tyXin (in-list (syntax->list #'(τ_inX ...)))]
                         #:break (empty? (find-unsolved-Xs Xs cs)))
                (define/with-syntax [a- ty_a] (infer+erase a))
                (values 
                 (cons #'a- as-)
                 (stx-append cs (compute-constraint (list tyXin #'ty_a))))))

         (list (reverse as-) (find-unsolved-Xs Xs cs) cs)])]))

  (define (raise-app-poly-infer-error stx expected-tys given-tys e_fn)
    (type-error #:src stx
     #:msg (mk-app-err-msg stx #:expected expected-tys #:given given-tys
            #:note (format "Could not infer instantiation of polymorphic function ~a."
                           (syntax->datum (get-orig e_fn))))))

  ;; instantiate polymorphic types
  ;; inst-type : (Listof Type) (Listof Id) Type -> Type
  ;; Instantiates ty with the tys-solved substituted for the Xs, where the ith
  ;; identifier in Xs is associated with the ith type in tys-solved
  (define (inst-type tys-solved Xs ty)
    (substs tys-solved Xs ty))
  
  ;; inst-type/cs : (Stx-Listof Id) Constraints Type-Stx -> Type-Stx
  ;; Instantiates ty, substituting each identifier in Xs with its mapping in cs.
  (define (inst-type/cs Xs cs ty)
    (define tys-solved (lookup-Xs/keep-unsolved Xs cs))
    (inst-type tys-solved Xs ty))
  ;; inst-types/cs : (Stx-Listof Id) Constraints (Stx-Listof Type-Stx) -> (Listof Type-Stx)
  ;; the plural version of inst-type/cs
  (define (inst-types/cs Xs cs tys)
    (stx-map (lambda (t) (inst-type/cs Xs cs t)) tys))

  ;; compute unbound tyvars in one unexpanded type ty
  (define (compute-tyvar1 ty)
    (syntax-parse ty
      [X:id #'(X)]
      [() #'()]
      [(C t ...) (stx-appendmap compute-tyvar1 #'(t ...))]))
  ;; computes unbound ids in (unexpanded) tys, to be used as tyvars
  (define (compute-tyvars tys)
    (define Xs (stx-appendmap compute-tyvar1 tys))
    (filter 
     (lambda (X) 
       (with-handlers
        ([exn:fail:syntax:unbound? (lambda (e) #t)]
         [exn:fail:type:infer? (lambda (e) #t)])
        (let ([X+ ((current-type-eval) X)])
          (not (or (tyvar? X+) (type? X+))))))
     (stx-remove-dups Xs))))

;; define --------------------------------------------------
;; for function defs, define infers type variables
;; - since the order of the inferred type variables depends on expansion order,
;;   which is not known to programmers, to make the result slightly more
;;   intuitive, we arbitrarily sort the inferred tyvars lexicographically
(define-typed-syntax define/tc #:export-as define
  [(_ x:id e) ≫
   [⊢ e ≫ e- ⇒ τ]
   #:with y (generate-temporary)
   --------
   [≻ (begin-
        (define-syntax- x (make-rename-transformer (⊢ y : τ)))
        (define- y e-))]]
  ; explicit "forall"
  [(_ Ys (f:id [x:id (~datum :) τ] ... (~or (~datum ->) (~datum →)) τ_out) 
      e_body ... e) ≫
   #:when (brace? #'Ys)
   ;; TODO; remove this code duplication
   #:with g (add-orig (generate-temporary #'f) #'f)
   #:with e_ann (syntax/loc #'e (add-expected e τ_out))
   #:with (τ+orig ...) (stx-map (λ (t) (add-orig t t)) #'(τ ... τ_out))
   ;; TODO: check that specified return type is correct
   ;; - currently cannot do it here; to do the check here, need all types of
   ;;  top-lvl fns, since they can call each other
   #:with (~and ty_fn_expected (~∀ _ (~ext-stlc:→ _ ... out_expected))) 
          ((current-type-eval) #'(∀ Ys (ext-stlc:→ τ+orig ...)))
   --------
   [≻ (begin-
        (define-syntax- f (make-rename-transformer (⊢ g : ty_fn_expected)))
        (define- g
          (Λ Ys (ext-stlc:λ ([x : τ] ...) (ext-stlc:begin e_body ... e_ann)))))]]
  ;; alternate type sig syntax, after parameter names
  [(_ (f:id x:id ...) (~datum :) ty ... (~or (~datum ->) (~datum →)) ty_out . b) ≫
   --------
   [≻ (define/tc (f [x : ty] ... -> ty_out) . b)]]
  [(_ (f:id [x:id (~datum :) τ] ... ; no TC
            (~or (~datum ->) (~datum →)) τ_out)
      e_body ... e) ≫
   #:with (~and Ys (Y ...)) (compute-tyvars #'(τ ... τ_out))
   #:with g (add-orig (generate-temporary #'f) #'f)
   #:with e_ann (syntax/loc #'e (add-expected e τ_out)) ; must be macro bc t_out may have unbound tvs
   #:with (τ+orig ...) (stx-map (λ (t) (add-orig t t)) #'(τ ... τ_out))
   ;; TODO: check that specified return type is correct
   ;; - currently cannot do it here; to do the check here, need all types of
   ;;  top-lvl fns, since they can call each other
   #:with ty_fn_expected
          (set-stx-prop/preserved 
           ((current-type-eval) #'(∀ Ys (ext-stlc:→ τ+orig ...)))
           'orig
           (list #'(→ τ+orig ...)))
   --------
   [≻ (begin-
        (define-syntax- f (make-rename-transformer (⊢ g : ty_fn_expected)))
        (define- g
          (Λ Ys (ext-stlc:λ ([x : τ] ...) (ext-stlc:begin e_body ... e_ann)))))]]
  [(_ (f:id [x:id (~datum :) τ] ... 
            (~seq #:where TC ...)
            (~or (~datum ->) (~datum →)) τ_out)
      e_body ... e) ≫
   #:with (~and Ys (Y ...)) (compute-tyvars #'(τ ... τ_out))
   #:with g (add-orig (generate-temporary #'f) #'f)
   #:with e_ann (syntax/loc #'e (add-expected e τ_out)) ; must be macro bc t_out may have unbound tvs
   #:with (τ+orig ...) (stx-map (λ (t) (add-orig t t)) #'(τ ... τ_out))
   ;; TODO: check that specified return type is correct
   ;; - currently cannot do it here; to do the check here, need all types of
   ;;  top-lvl fns, since they can call each other
   #:with (~and ty_fn_expected (~∀ _ (~=> _ ... (~ext-stlc:→ _ ... out_expected))))
          (syntax-property 
              ((current-type-eval) #'(∀ Ys (=> TC ... (ext-stlc:→ τ+orig ...))))
            'orig
            (list #'(→ τ+orig ...)))
   --------
   [≻ (begin-
        (define-syntax- f (make-rename-transformer (⊢ g : ty_fn_expected)))
        #,(quasisyntax/loc stx
            (define- g
              ;(Λ Ys (ext-stlc:λ ([x : τ] ...) (ext-stlc:begin e_body ... e_ann)))))])
              (liftedλ {Y ...} ([x : τ] ... #:where TC ...) 
                       #,(syntax/loc #'e_ann (ext-stlc:begin e_body ... e_ann))))))]])

;; define-type -----------------------------------------------
;; TODO: should validate τ as part of define-type definition (before it's used)
;; - not completely possible, since some constructors may not be defined yet,
;;   ie, mutually recursive datatypes
;; for now, validate types but punt if encountering unbound ids
(define-syntax (define-type stx)
  (syntax-parse stx
    [(_ Name:id . rst)
     #:with NewName (generate-temporary #'Name)
     #:with Name2 (add-orig #'(NewName) #'Name)
     #`(begin-
         (define-type Name2 . #,(subst #'Name2 #'Name #'rst))
         (stlc+rec-iso:define-type-alias Name Name2))]
    [(_ (Name:id X:id ...)
        ;; constructors must have the form (Cons τ ...)
        ;; but the first ~or clause accepts 0-arg constructors as ids;
        ;; the ~and is a workaround to bind the duplicate Cons ids (see Ryan's email)
        (~and (~or (~and IdCons:id 
                        (~parse (Cons [fld (~datum :) τ] ...) #'(IdCons)))
                   (Cons [fld (~datum :) τ] ...)
                   (~and (Cons τ ...)
                         (~parse (fld ...) (generate-temporaries #'(τ ...)))))) ...)
     ;; validate tys
     #:with (ty_flat ...) (stx-flatten #'((τ ...) ...))
     #:with (_ _ (_ _ (_ _ (_ _ ty+ ...))))
            (with-handlers 
              ([exn:fail:syntax:unbound?
                (λ (e) 
                  (define X (stx-car (exn:fail:syntax-exprs e)))
                  #`(lambda () (let-syntax () (let-syntax () (#%app void unbound)))))])
              (expand/df 
                #`(lambda (X ...)
                    (let-syntax 
                      ([Name 
                        (syntax-parser 
                         [(_ X ...) (mk-type #'void)]
                         [stx 
                          (type-error 
                           #:src #'stx
                           #:msg 
                           (format "Improper use of constructor ~a; expected ~a args, got ~a"
                                   (syntax->datum #'Name) (stx-length #'(X ...))
                                   (stx-length (stx-cdr #'stx))))])]
                       [X (make-rename-transformer (⊢ X #%type))] ...)
                      (void ty_flat ...)))))
     #:when (or (equal? '(unbound) (syntax->datum #'(ty+ ...)))
                (stx-map 
                  (lambda (t+ t) (unless (type? t+)
                              (type-error #:src t
                                          #:msg "~a is not a valid type" t)))
                  #'(ty+ ...) #'(ty_flat ...)))
     #:with NameExpander (format-id #'Name "~~~a" #'Name)
     #:with NameExtraInfo (format-id #'Name "~a-extra-info" #'Name)
     #:with (StructName ...) (generate-temporaries #'(Cons ...))
     #:with ((e_arg ...) ...) (stx-map generate-temporaries #'((τ ...) ...))
     #:with ((e_arg- ...) ...) (stx-map generate-temporaries #'((τ ...) ...))
     #:with ((τ_arg ...) ...) (stx-map generate-temporaries #'((τ ...) ...))
     #:with ((exposed-acc ...) ...)
            (stx-map 
              (λ (C fs) (stx-map (λ (f) (format-id C "~a-~a" C f)) fs))
              #'(Cons ...) #'((fld ...) ...))
     #:with ((acc ...) ...) (stx-map (λ (S fs) (stx-map (λ (f) (format-id S "~a-~a" S f)) fs))
                                     #'(StructName ...) #'((fld ...) ...))
     #:with (Cons? ...) (stx-map mk-? #'(StructName ...))
     #:with (exposed-Cons? ...) (stx-map mk-? #'(Cons ...))
     #`(begin-
         (define-syntax- (NameExtraInfo stx)
           (syntax-parse stx
             [(_ X ...) #'(('Cons 'StructName Cons? [acc τ] ...) ...)]))
         (define-type-constructor Name
           #:arity = #,(stx-length #'(X ...))
           #:extra-info 'NameExtraInfo
           #:no-provide)
         (struct- StructName (fld ...) #:reflection-name 'Cons #:transparent) ...
         (define-syntax- (exposed-acc stx) ; accessor for records
           (syntax-parse stx
            [_:id (⊢ acc (∀ (X ...) (ext-stlc:→ (Name X ...) τ)))]
            [(o . rst) ; handle if used in fn position
             #:with app (datum->syntax #'o '#%app)
             #`(app 
                #,(assign-type #'acc #'(∀ (X ...) (ext-stlc:→ (Name X ...) τ))) 
                . rst)])) ... ...
         (define-syntax- (exposed-Cons? stx) ; predicates for each variant
           (syntax-parse stx
            [_:id (⊢ Cons? (∀ (X ...) (ext-stlc:→ (Name X ...) Bool)))]
            [(o . rst) ; handle if used in fn position
             #:with app (datum->syntax #'o '#%app)
             #`(app 
                #,(assign-type #'Cons? #'(∀ (X ...) (ext-stlc:→ (Name X ...) Bool))) 
                . rst)])) ...
         (define-typed-syntax Cons
           ; no args and not polymorphic
           [C:id ≫
            #:when (and (stx-null? #'(X ...)) (stx-null? #'(τ ...)))
            --------
            [≻ (C)]]
           ; no args but polymorphic, check inferred type
           [C:id ⇐ : (NameExpander τ-expected-arg (... ...)) ≫
            #:when (stx-null? #'(τ ...))
            --------
            [⊢ (StructName)]]
           [_:id ≫
            #:when (not (stx-null? #'(τ ...)))
            --------
            [⊢ StructName ⇒ (∀ (X ...) (ext-stlc:→ τ ... (Name X ...)))]] ; HO fn
           [(C τs e_arg ...) ≫
            #:when (brace? #'τs) ; commit to this clause
            #:with {~! τ_X:type (... ...)} #'τs
            #:with (τ_in:type (... ...)) ; instantiated types
                   (stx-map
                    (λ (t) (substs #'(τ_X.norm (... ...)) #'(X ...) t))
                    #'(τ ...))
            ;; e_arg* is only used to get the ellipses to align
            #:with (τ_arg ...) #'(τ_in.norm (... ...))
;            #:with (e_arg* (... ...)) #'(e_arg ...)
            [⊢ e_arg ≫ e_arg- ⇐ τ_arg] ...
 ;           #:with (e_arg- ...) #'(e_arg*- (... ...))
            --------
            [⊢ (StructName e_arg- ...) ⇒ (Name τ_X.norm (... ...))]]
           [(C . args) ≫ ; no type annotations, must infer instantiation
            #:with StructName/ty
            (set-stx-prop/preserved
             (⊢ StructName : (∀ (X ...) (ext-stlc:→ τ ... (Name X ...))))
             'orig
             (list #'C))
            --------
            [≻ (mlish:#%app StructName/ty . args)]])
         ...)]))

;; match --------------------------------------------------
(begin-for-syntax
  (define (get-ctx pat ty)
    (unify-pat+ty (list pat ty)))
  (define (unify-pat+ty pat+ty)
    (syntax-parse pat+ty
     [(pat ty) #:when (brace? #'pat) ; handle root pattern specially (to avoid some parens)
      (syntax-parse #'pat
        [{(~datum _)} #'()]
        [{(~literal stlc+cons:nil)}  #'()]
        [{A:id} ; disambiguate 0-arity constructors (that don't need parens)
         #:when (get-extra-info #'ty)
         #'()]
        ;; comma tup syntax always has parens
        [{(~and ps (p1 (unq p) ...))}
         #:when (not (stx-null? #'(p ...)))
         #:when (andmap (lambda (u) (equal? u 'unquote)) (syntax->datum #'(unq ...)))
         (unify-pat+ty #'(ps ty))]
        [{p ...} 
         (unify-pat+ty #'((p ...) ty))])] ; pair
      [((~datum _) ty) #'()]
      [((~or (~literal stlc+cons:nil)) ty) #'()]
      [(A:id ty) ; disambiguate 0-arity constructors (that don't need parens)
       #:with (_ (_ (_ C) . _) ...) (get-extra-info #'ty)
       #:when (member (syntax->datum #'A) (syntax->datum #'(C ...)))
       #'()]
      [(x:id ty)  #'((x ty))]
      [((p1 (unq p) ...) ty) ; comma tup stx
       #:when (not (stx-null? #'(p ...)))
       #:when (andmap (lambda (u) (equal? u 'unquote)) (syntax->datum #'(unq ...)))
       #:with (~× t ...) #'ty
       #:with (pp ...) #'(p1 p ...)
       (unifys #'([pp t] ...))]
      [(((~literal stlc+tup:tup) p ...) ty) ; tup
       #:with (~× t ...) #'ty
       (unifys #'([p t] ...))]
      [(((~literal stlc+cons:list) p ...) ty) ; known length list
       #:with (~List t) #'ty
       (unifys #'([p t] ...))]
     [(((~seq p (~datum ::)) ... rst) ty) ; nicer cons stx
      #:with (~List t) #'ty
       (unifys #'([p t] ... [rst ty]))]
      [(((~literal stlc+cons:cons) p ps) ty) ; arb length list
       #:with (~List t) #'ty
       (unifys #'([p t] [ps ty]))]
      [((Name p ...) ty)
       #:with (_ (_ Cons) _ _ [_ _ τ] ...)
              (stx-findf
                (syntax-parser
                 [(_ 'C . rst) 
                  (equal? (syntax->datum #'Name) (syntax->datum #'C))])
                (stx-cdr (get-extra-info #'ty)))
       (unifys #'([p τ] ...))]
      [p+t #:fail-when #t (format "could not unify ~a" (syntax->datum #'p+t))
       #'()]))
  (define (unifys p+tys) (stx-appendmap unify-pat+ty p+tys))
  
  (define (compile-pat p ty)
    (syntax-parse p
     [pat #:when (brace? #'pat) ; handle root pattern specially (to avoid some parens)
      (syntax-parse #'pat
        [{(~datum _)} #'_]
        [{(~literal stlc+cons:nil)}  (syntax/loc p (list))]
        [{A:id} ; disambiguate 0-arity constructors (that don't need parens)
         #:when (get-extra-info ty)
         (compile-pat #'(A) ty)]
        ;; comma tup stx always has parens
        [{(~and ps (p1 (unq p) ...))}
         #:when (not (stx-null? #'(p ...)))
         #:when (andmap (lambda (u) (equal? u 'unquote)) (syntax->datum #'(unq ...)))
         (compile-pat #'ps ty)]
        [{pat ...} (compile-pat (syntax/loc p (pat ...)) ty)])]
     [(~datum _) #'_]
     [(~literal stlc+cons:nil) ; nil
      #'(list)]
     [A:id ; disambiguate 0-arity constructors (that don't need parens)
      #:with (_ (_ (_ C) . _) ...) (get-extra-info ty)
      #:when (member (syntax->datum #'A) (syntax->datum #'(C ...)))
      (compile-pat #'(A) ty)]
     [x:id p]
     [(p1 (unq p) ...) ; comma tup stx
      #:when (not (stx-null? #'(p ...)))
      #:when (andmap (lambda (u) (equal? u 'unquote)) (syntax->datum #'(unq ...)))
      #:with (~× t ...) ty
      #:with (p- ...) (stx-map (lambda (p t) (compile-pat p t)) #'(p1 p ...) #'(t ...))
      #'(list p- ...)]
     [((~literal stlc+tup:tup) . pats)
      #:with (~× . tys) ty
      #:with (p- ...) (stx-map (lambda (p t) (compile-pat p t)) #'pats #'tys)
      (syntax/loc p (list p- ...))]
     [((~literal stlc+cons:list) . ps)
      #:with (~List t) ty
      #:with (p- ...) (stx-map (lambda (p) (compile-pat p #'t)) #'ps)
      (syntax/loc p (list p- ...))]
     [((~seq pat (~datum ::)) ... last) ; nicer cons stx
      #:with (~List t) ty
      #:with (p- ...) (stx-map (lambda (pp) (compile-pat pp #'t)) #'(pat ...))
      #:with last- (compile-pat #'last ty)
      (syntax/loc p (list-rest p- ... last-))]
     [((~literal stlc+cons:cons) p ps)
      #:with (~List t) ty
      #:with p- (compile-pat #'p #'t)
      #:with ps- (compile-pat #'ps ty)
      #'(cons p- ps-)]
     [(Name . pats)
      #:with (_ (_ Cons) (_ StructName) _ [_ _ τ] ...)
             (stx-findf
               (syntax-parser
                [(_ 'C . rst) 
                 (equal? (syntax->datum #'Name) (syntax->datum #'C))])
               (stx-cdr (get-extra-info ty)))
      #:with (p- ...) (stx-map compile-pat #'pats #'(τ ...))
      (syntax/loc p (StructName p- ...))]))

  ;; pats = compiled pats = racket pats
  (define (check-exhaust pats ty)
    (define (else-pat? p)
      (syntax-parse p [(~literal _) #t] [_ #f]))
    (define (nil-pat? p)
      (syntax-parse p
        [((~literal list)) #t]
        [_ #f]))
    (define (non-nil-pat? p)
      (syntax-parse p
        [((~literal list-rest) . rst) #t]
        [((~literal cons) . rst) #t]
        [_ #f]))
    (define (tup-pat? p)
      (syntax-parse p
        [((~literal list) . _) #t] [_ #f]))
    (cond
     [(or (stx-ormap else-pat? pats) (stx-ormap identifier? pats)) #t]
     [(List? ty) ; lists
      (unless (stx-ormap nil-pat? pats)
        (error 'match2 (let ([last (car (stx-rev pats))])
                         (format "(~a:~a) missing nil clause for list expression"
                                 (syntax-line last) (syntax-column last)))))
      (unless (stx-ormap non-nil-pat? pats)
        (error 'match2 (let ([last (car (stx-rev pats))])
                         (format "(~a:~a) missing clause for non-empty, arbitrary length list"
                                 (syntax-line last) (syntax-column last)))))
      #t]
     [(×? ty) ; tuples
      (unless (stx-ormap tup-pat? pats)
        (error 'match2 (let ([last (car (stx-rev pats))])
                         (format "(~a:~a) missing pattern for tuple expression"
                                 (syntax-line last) (syntax-column last)))))
      (syntax-parse pats
        [((_ p ...) ...)
         (syntax-parse ty
           [(~× t ...)
            (apply stx-andmap 
                   (lambda (t . ps) (check-exhaust ps t)) 
                   #'(t ...) 
                   (syntax->list #'((p ...) ...)))])])]
     [else ; algebraic datatypes
      (syntax-parse (get-extra-info ty)
        [(_ (_ (_ C) (_ Cstruct) . rst) ...)
         (syntax-parse pats
           [((Cpat _ ...) ...)
            (define Cs (syntax->datum #'(C ...)))
            (define Cstructs (syntax->datum #'(Cstruct ...)))
            (define Cpats (syntax->datum #'(Cpat ...)))
            (unless (set=? Cstructs Cpats)
              (error 'match2
                (let ([last (car (stx-rev pats))])
                  (format "(~a:~a) clauses not exhaustive; missing: ~a"
                          (syntax-line last) (syntax-column last)
                          (string-join      
                            (for/list ([C Cs][Cstr Cstructs] #:unless (member Cstr Cpats))
                              (symbol->string C))
                            ", ")))))
            #t])]
        [_ #t])]))

  ;; TODO: do get-ctx and compile-pat in one pass
  (define (compile-pats pats ty)
    (stx-map (lambda (p) (list (get-ctx p ty) (compile-pat p ty))) pats))
  )

(define-typed-syntax match2
  [(_ e (~datum with) . clauses) ≫
   #:fail-unless (not (null? (syntax->list #'clauses))) "no clauses"
   [⊢ e ≫ e- ⇒ τ_e]
   #:with ([(~seq p ...) (~datum ->) e_body] ...) #'clauses
   #:with (pat ...) (stx-map ; use brace to indicate root pattern
                     (lambda (ps) (syntax-parse ps [(pp ...) (syntax/loc stx {pp ...})]))
                     #'((p ...) ...))
   #:with ([(~and ctx ([x ty] ...)) pat-] ...) (compile-pats #'(pat ...) #'τ_e)
   #:with ty-expected (get-expected-type stx)
   [[x ≫ x- : ty] ... ⊢ [(add-expected e_body ty-expected) ≫ e_body- ⇒ ty_body]] ...
   #:when (check-exhaust #'(pat- ...) #'τ_e)
   ----
   [⊢ (match- e- [pat- (let- ([x- x] ...) e_body-)] ...) ⇒ (⊔ ty_body ...)]])

(define-typed-syntax match #:datum-literals (with)
   [(_ e with . clauses) ≫
    #:fail-when (null? (syntax->list #'clauses)) "no clauses"
    [⊢ e ≫ e- ⇒ τ_e]
    #:with t_expect (syntax-property stx 'expected-type) ; propagate inferred type
    #:with out
    (cond
     [(×? #'τ_e) ;; e is tuple
      (syntax-parse/typed-syntax #'clauses
       [([x ... (~datum ->) e_body]) ≫
        #:with (~× ty ...) #'τ_e
        #:fail-unless (stx-length=? #'(ty ...) #'(x ...))
                      "match clause pattern not compatible with given tuple"
        [[x ≫ x- : ty] ... ⊢ (add-expected e_body t_expect) ≫ e_body- ⇒ ty_body]
        #:with (acc ...) (for/list ([(a i) (in-indexed (syntax->list #'(x ...)))])
                           #`(lambda (s) (list-ref s #,(datum->syntax #'here i))))
        #:with z (generate-temporary)
        --------
        [⊢ (let- ([z e-])
             (let- ([x- (acc z)] ...) e_body-))
           ⇒ ty_body]])]
     [(List? #'τ_e) ;; e is List
      (syntax-parse/typed-syntax #'clauses
       [([(~or (~and (~and xs [x ...]) (~parse rst (generate-temporary)))
               (~and (~seq (~seq x (~datum ::)) ... rst:id) (~parse xs #'())))
          (~datum ->) e_body] ...+) ≫
        #:fail-unless (stx-ormap 
                        (lambda (xx) (and (brack? xx) (zero? (stx-length xx)))) 
                        #'(xs ...)) 
                      "match: missing empty list case"
        #:fail-when (and (stx-andmap brack? #'(xs ...))
                         (= 1 (stx-length #'(xs ...))))
                    "match: missing non-empty list case"
        #:with (~List ty) #'τ_e
        [[x ≫ x- : ty] ... [rst ≫ rst- : (List ty)]
         ⊢ (add-expected e_body t_expect) ≫ e_body- ⇒ ty_body]  ...
        #:with (len ...) (stx-map (lambda (p) #`#,(stx-length p)) #'((x ...) ...))
        #:with (lenop ...) (stx-map (lambda (p) (if (brack? p) #'=- #'>=-)) #'(xs ...))
        #:with (pred? ...) (stx-map
                            (lambda (l lo) #`(λ- (lst) (#,lo (length- lst) #,l)))
                            #'(len ...) #'(lenop ...))
        #:with ((acc1 ...) ...) (stx-map 
                                    (lambda (xs)
                                      (for/list ([(x i) (in-indexed (syntax->list xs))])
                                        #`(lambda (lst) (list-ref lst #,(datum->syntax #'here i)))))
                                  #'((x ...) ...))
        #:with (acc2 ...) (stx-map (lambda (l) #`(lambda (lst) (list-tail lst #,l))) #'(len ...))
        --------
        [⊢ (let- ([z e-])
             (cond- 
              [(pred? z)
               (let- ([x- (acc1 z)] ... [rst- (acc2 z)]) e_body-)] ...))
           ⇒ (⊔ ty_body ...)]])]
     [else  ;; e is variant
      (syntax-parse/typed-syntax #'clauses
       [([Clause:id x:id ... 
             (~optional (~seq #:when e_guard) #:defaults ([e_guard #'(ext-stlc:#%datum . #t)]))
             (~datum ->) e_c_un] ...+) ≫ ; un = unannotated with expected ty
        ;; length #'clauses may be > length #'info, due to guards
        #:with info-body (get-extra-info #'τ_e)
        #:with (_ (_ (_ ConsAll) . _) ...) #'info-body
        #:fail-unless (set=? (syntax->datum #'(Clause ...))
                             (syntax->datum #'(ConsAll ...)))
                      (type-error #:src stx
                       #:msg (string-append
                              "match: clauses not exhaustive; missing: "
                              (string-join      
                                (map symbol->string
                                     (set-subtract 
                                       (syntax->datum #'(ConsAll ...))
                                       (syntax->datum #'(Clause ...))))
                                ", ")))
        #:with ((_ _ _ Cons? [_ acc τ] ...) ...)
               (map ; ok to compare symbols since clause names can't be rebound
                (lambda (Cl) 
                  (stx-findf
                      (syntax-parser
                        [(_ 'C . rst) (equal? Cl (syntax->datum #'C))])
                    (stx-cdr #'info-body))) ; drop leading #%app
                (syntax->datum #'(Clause ...)))
        ;; this commented block experiments with expanding to unsafe ops
        ;; #:with ((acc ...) ...) (stx-map 
        ;;                         (lambda (accs)
        ;;                          (for/list ([(a i) (in-indexed (syntax->list accs))])
        ;;                            #`(lambda (s) (unsafe-struct*-ref s #,(datum->syntax #'here i)))))
        ;;                         #'((acc-fn ...) ...))
        #:with (e_c ...+) (stx-map (lambda (ec) (add-expected-ty ec #'t_expect)) #'(e_c_un ...))
        [[x ≫ x- : τ] ... ⊢ [e_guard ≫ e_guard- ⇐ Bool] 
                             [e_c ≫ e_c- ⇒ τ_ec]] ...
        #:with z (generate-temporary) ; dont duplicate eval of test expr
        --------
        [⊢ (let- ([z e-])
             (cond- 
              [(and- (Cons? z) 
                     (let- ([x- (acc z)] ...) e_guard-))
               (let- ([x- (acc z)] ...) e_c-)] ...))
           ⇒ (⊔ τ_ec ...)]])])
    --------
    [≻ out]])

(define-syntax → ; wrapping →
  (syntax-parser
    [(_ ty ... #:TC TC ...)
     #'(∀ () (=> TC ... (ext-stlc:→ ty ...)))]
    [(_ Xs . rst)
     #:when (brace? #'Xs)
     #:with (X ...) #'Xs
     (syntax-property 
       #'(∀ (X ...)  (ext-stlc:→ . rst))
       'orig (list #'(→ . rst)))]
    [(_ . rst) (set-stx-prop/preserved #'(∀ () (ext-stlc:→ . rst)) 'orig (list #'(→ . rst)))]))
; special arrow that computes free vars; for use with tests
; (because we can't write explicit forall
(define-syntax →/test 
  (syntax-parser
    [(_ (~and Xs (X:id ...)) . rst)
     #:when (brace? #'Xs)
     #'(∀ (X ...) (ext-stlc:→ . rst))]
    [(_ . rst)
     #:with Xs (compute-tyvars #'rst)
     #'(∀ Xs (ext-stlc:→ . rst))]))

(define-syntax =>/test 
  (syntax-parser
    [(_ . (~and rst (TC ... (_arr . tys_arr))))
     #:with Xs (compute-tyvars #'rst)
     #'(∀ Xs (=> TC ... (ext-stlc:→ . tys_arr)))]))

; redefine these to use lifted →
(define-primop + : (→ Int Int Int))
(define-primop - : (→ Int Int Int))
(define-primop * : (→ Int Int Int))
(define-primop max : (→ Int Int Int))
(define-primop min : (→ Int Int Int))
(define-primop void : (→ Unit))
(define-primop = : (→ Int Int Bool))
(define-primop <= : (→ Int Int Bool))
(define-primop >= : (→ Int Int Bool))
(define-primop < : (→ Int Int Bool))
(define-primop > : (→ Int Int Bool))
(define-primop modulo : (→ Int Int Int))
(define-primop zero? : (→ Int Bool))
(define-primop sub1 : (→ Int Int))
(define-primop add1 : (→ Int Int))
(define-primop not : (→ Bool Bool))
(define-primop abs : (→ Int Int))
(define-primop even? : (→ Int Bool))
(define-primop odd? : (→ Int Bool))

;; λ --------------------------------------------------------------------------

; all λs have type (∀ (X ...) (→ τ_in ... τ_out)), even monomorphic fns
(define-typed-syntax liftedλ #:export-as λ
  [(_ ([x:id (~datum :) ty] ... #:where TC ...) body) ≫
   #:with (X ...) (compute-tyvars #'(ty ...))
   --------
   [≻ (liftedλ {X ...} ([x : ty] ... #:where TC ...) body)]]
  ;; TODO: I dont think this works for nested lambdas
  ;; ie, this will will re-infer tyvars X that should be bound by outer lam
  ;; - tyvars need to be bound in 2nd expand/df
  ;; - This is fixed in master by Alex
  [(_ (~and Xs (X ...)) ([x:id (~datum :) ty] ... #:where TC ...) body) ≫
   #:when (brace? #'Xs)
   #:with (_ Xs+
           (_ () (_ () (_ () (_ () ; 2 let-stx = 4 let-values
            (_ (_ _ TC+ ...) 
               (_ _ ty+ ...)
               (_ op-tmps+
                (_ () (_ ()
                 ((~literal #%expression)
                  (_ xs+
                   (_ () (_ () body+)))))))))))))
           (expand/df
            #'(lambda (X ...) 
                (let-syntax 
                 ([X (make-rename-transformer (assign-type #'X #'#%type))] ...)
                 (let-syntax
                  ;; must have this inner macro bc body of lambda may require
                  ;; ops defined by TC to be bound
                  ([a (syntax-parser [(_)
                    (syntax-parse (expand/df #'(void TC ...)) ; must expand in ctx of Xs
                      [(_ _ .
                        (~and (TC+ (... ...)) 
                              (~TCs ([op-sym ty-op] (... ...)) (... ...))))
                       ;; here, * suffix = flattened list
                       ;; op* ... = op-sym ... with proper ctx, and then flattened
                       #:with (op* (... ...))
                              (stx-appendmap 
                                (lambda (os tc)
                                  (stx-map (lambda (o) (format-id tc "~a" o)) os))
                                #'((op-sym (... ...)) (... ...)) #'(TC ...))
                       #:with (op-tmp* (... ...)) (generate-temporaries #'(op* (... ...)))
                       #:with (ty-op* (... ...)) (stx-flatten #'((ty-op (... ...)) (... ...)))
                       #:with ty-in-tagsss
                              (stx-map 
                               (syntax-parser
                                [(~∀ _ fa-body)
                                 (get-type-tags
                                  (syntax-parse #'fa-body
                                   [(~ext-stlc:→ in (... ...) _) #'(in (... ...))]
                                   [(~=> _ (... ...) (~ext-stlc:→ in (... ...) _)) #'(in (... ...))]))])
                               #'(ty-op* (... ...)))
                         #:with (mangled-op (... ...)) (stx-map mangle #'(op* (... ...)) #'ty-in-tagsss)
                         #:with (y (... ...)) #'(x ...)
                         #:with (_ _ ty+ (... ...)) (expand/df #'(void ty ...))
                         #:with res
                         (expand/df 
                          #'(lambda (op-tmp* (... ...))
                             (let-syntax 
                              ([mangled-op 
                                (make-rename-transformer (assign-type #'op-tmp* #'ty-op*))] (... ...))
                              (lambda (y (... ...))
                               (let-syntax
                                ([y (make-rename-transformer (assign-type #'y #'ty+))] (... ...))
                                body)))))
                         #'((void TC+ (... ...)) (void ty+ (... ...)) res)])])])
                      (a)))))
   #:with ty-out (typeof #'body+)
   #:with ty-out-expected (get-expected-type #'body+)
   #:fail-unless (or (not (syntax-e #'ty-out-expected))
                     (typecheck? #'ty-out #'ty-out-expected))
                 (type-error #:src #'body
                  #:msg "Body has type ~a, expected/given: ~a"
                  #'ty-out #'ty-out-expected)
   --------
   [⊢ (λ- op-tmps+ (λ- xs+ body+)) 
      ⇒ (∀ Xs+ (=> TC+ ... (ext-stlc:→ ty+ ... ty-out)))]]
  [(_ ([x:id (~datum :) ty] ...) body) ≫ ; no TC
   #:with (X ...) (compute-tyvars #'(ty ...))
   #:with (~∀ () (~ext-stlc:→ _ ... body-ty)) (get-expected-type stx)
   --------
   [≻ (Λ (X ...) (ext-stlc:λ ([x : ty] ...) (add-expected body body-ty)))]]
  [(_ ([x:id (~datum :) ty] ...) body) ≫ ; no TC, ignoring expected-type
   #:with (X ...) (compute-tyvars #'(ty ...))
   --------
   [≻ (Λ (X ...) (ext-stlc:λ ([x : ty] ...) body))]]
  [(_ (x:id ...+) body) ≫
   #:with (~?∀ Xs expected) (get-expected-type stx)
   #:do [(unless (→? #'expected)
           (type-error #:src stx #:msg "λ parameters must have type annotations"))]
   #:with (~ext-stlc:→ arg-ty ... body-ty) #'expected
   #:do [(unless (stx-length=? #'[x ...] #'[arg-ty ...])
           (type-error #:src stx #:msg
                       (format "expected a function of ~a arguments, got one with ~a arguments"
                               (stx-length #'[arg-ty ...] #'[x ...]))))]
   --------
   [≻ (Λ Xs (ext-stlc:λ ([x : arg-ty] ...) #,(add-expected-ty #'body #'body-ty)))]]
  #;[(_ args body)
   #:with (~∀ () (~ext-stlc:→ arg-ty ... body-ty)) (get-expected-type stx)
   #`(Λ () (ext-stlc:λ args #,(add-expected-ty #'body #'body-ty)))]
  #;[(_ (~and x+tys ([_ (~datum :) ty] ...)) . body)
   #:with Xs (compute-tyvars #'(ty ...))
   ;; TODO is there a way to have λs that refer to ids defined after them?
   #'(Λ Xs (ext-stlc:λ x+tys . body))])


;; #%app --------------------------------------------------
(define-typed-syntax mlish:#%app #:export-as #%app
  [(_ e_fn . e_args) ≫
;   #:when (printf "app: ~a\n" (syntax->datum #'(e_fn . e_args)))
   ;; ) compute fn type (ie ∀ and →) 
   [⊢ e_fn ≫ e_fn- ⇒ (~and ty_fn (~∀ Xs ty_fnX))]
   --------
   [≻ 
    #,(cond 
       [(stx-null? #'Xs)
        (define/with-syntax tyX_args
          (syntax-parse #'ty_fnX
            [(~ext-stlc:→ . tyX_args) #'tyX_args]))
        (syntax-parse #'(e_args tyX_args)
          [((e_arg ...) (τ_inX ... _))
           #:fail-unless (stx-length=? #'(e_arg ...) #'(τ_inX ...))
           (mk-app-err-msg stx #:expected #'(τ_inX ...) 
                           #:note "Wrong number of arguments.")
           #:with e_fn/ty (⊢ e_fn- : (ext-stlc:→ . tyX_args))
           #'(ext-stlc:#%app e_fn/ty (add-expected e_arg τ_inX) ...)])]
       [else
     (syntax-parse #'ty_fnX
      ;; TODO: combine these two clauses
      ;; no typeclasses, duplicate code for now --------------------------------
      [(~ext-stlc:→ . tyX_args) 
       ;; ) solve for type variables Xs
       (define/with-syntax ((e_arg1- ...) (unsolved-X ...) cs) (solve #'Xs #'tyX_args stx))
       ;; ) instantiate polymorphic function type
       (syntax-parse (inst-types/cs #'Xs #'cs #'tyX_args)
        [(τ_in ... τ_out) ; concrete types
         ;; ) arity check
         #:fail-unless (stx-length=? #'(τ_in ...) #'e_args)
                       (mk-app-err-msg stx #:expected #'(τ_in ...)
                        #:note "Wrong number of arguments.")
         ;; ) compute argument types; re-use args expanded during solve
         #:with ([e_arg2- τ_arg2] ...) (let ([n (stx-length #'(e_arg1- ...))])
                                        (infers+erase 
                                        (stx-map add-expected-ty 
                                          (stx-drop #'e_args n) (stx-drop #'(τ_in ...) n))))
         #:with (τ_arg1 ...) (stx-map typeof #'(e_arg1- ...))
         #:with (τ_arg ...) #'(τ_arg1 ... τ_arg2 ...)
         #:with (e_arg- ...) #'(e_arg1- ... e_arg2- ...)
         ;; ) typecheck args
         #:fail-unless (typechecks? #'(τ_arg ...) #'(τ_in ...))
                       (mk-app-err-msg stx 
                        #:given #'(τ_arg ...)
                        #:expected 
                        (stx-map 
                          (lambda (tyin) 
                            (define old-orig (get-orig tyin))
                            (define new-orig
                              (and old-orig
                                   (substs 
                                       (stx-map get-orig (lookup-Xs/keep-unsolved #'Xs #'cs)) #'Xs old-orig
                                       (lambda (x y) 
                                         (equal? (syntax->datum x) (syntax->datum y))))))
                            (syntax-property tyin 'orig (list new-orig)))
                          #'(τ_in ...)))
         #:with τ_out* (if (stx-null? #'(unsolved-X ...))
                           #'τ_out
                           (syntax-parse #'τ_out
                             [(~?∀ (Y ...) τ_out)
                              (unless (→? #'τ_out)
                                (raise-app-poly-infer-error stx #'(τ_in ...) #'(τ_arg ...) #'e_fn))
                              #'(∀ (unsolved-X ... Y ...) τ_out)]))
         (⊢ (#%app- e_fn- e_arg- ...) : τ_out*)])]
      ;; handle type class constraints ----------------------------------------
      [(~=> TCX ... (~ext-stlc:→ . tyX_args))
       ;; ) solve for type variables Xs
       (define/with-syntax ((e_arg1- ...) (unsolved-X ...) cs) (solve #'Xs #'tyX_args stx))
       ;; ) instantiate polymorphic function type
       (syntax-parse (inst-types/cs #'Xs #'cs #'((TCX ...) tyX_args))
         [((TC ...) (τ_in ... τ_out)) ; concrete types
          #:with (~TCs ([generic-op ty-concrete-op] ...) ...) #'(TC ...)
          #:with (op ...)
                 (stx-appendmap
                   (lambda (gen-ops conc-op-tys TC)
                     (map 
                       (lambda (o tys)
                         (with-handlers 
                           ([exn:fail:syntax:unbound? 
                             (lambda (e)
                               (type-error #:src stx
                                #:msg 
                                (format 
                                 (string-append
                                     "~a instance undefined. "
                                   "Cannot instantiate function with constraints "
                                   "~a with:\n  ~a")
                                 (type->str
                                  (let* 
                                   ([old-orig (get-orig TC)]
                                    [new-orig
                                     (and 
                                      old-orig
                                      (substs (stx-map get-orig (lookup-Xs/keep-unsolved #'Xs #'cs)) #'Xs old-orig
                                              (lambda (x y) 
                                               (equal? (syntax->datum x) 
                                                       (syntax->datum y)))))])
                                   (syntax-property TC 'orig (list new-orig))))
                                 (types->str #'(TCX ...))
                                 (string-join
                                 (stx-map 
                                   (lambda (X ty-solved)
                                     (string-append (type->str X) " : " (type->str ty-solved)))
                                   #'Xs (lookup-Xs/keep-unsolved #'Xs #'cs)) ", "))))])
                         (lookup-op o tys)))
                       (stx-map (lambda (o) (format-id stx "~a" o #:source stx)) gen-ops)
                       (stx-map
                         (syntax-parser
                           [(~∀ _ (~ext-stlc:→ ty_in ... _)) #'(ty_in ...)])
                         conc-op-tys)))
                   #'((generic-op ...) ...) #'((ty-concrete-op ...) ...) #'(TC ...))
          ;; ) arity check
          #:fail-unless (stx-length=? #'(τ_in ...) #'e_args)
                        (mk-app-err-msg stx #:expected #'(τ_in ...)
                                        #:note "Wrong number of arguments.")
          ;; ) compute argument types; re-use args expanded during solve
          #:with ([e_arg2- τ_arg2] ...) (let ([n (stx-length #'(e_arg1- ...))])
                                          (infers+erase 
                                              (stx-map add-expected-ty 
                                                (stx-drop #'e_args n) (stx-drop #'(τ_in ...) n))))
          #:with (τ_arg1 ...) (stx-map typeof #'(e_arg1- ...))
          #:with (τ_arg ...) #'(τ_arg1 ... τ_arg2 ...)
          #:with (e_arg- ...) #'(e_arg1- ... e_arg2- ...)
          ;; ) typecheck args
          #:fail-unless (typechecks? #'(τ_arg ...) #'(τ_in ...))
                        (mk-app-err-msg stx 
                         #:given #'(τ_arg ...)
                         #:expected 
                         (stx-map 
                             (lambda (tyin) 
                               (define old-orig (get-orig tyin))
                               (define new-orig
                                 (and old-orig
                                      (substs 
                                          (stx-map get-orig (lookup-Xs/keep-unsolved #'Xs #'cs)) #'Xs old-orig
                                          (lambda (x y) 
                                            (equal? (syntax->datum x) (syntax->datum y))))))
                               (syntax-property tyin 'orig (list new-orig)))
                           #'(τ_in ...)))
         #:with τ_out* (if (stx-null? #'(unsolved-X ...))
                           #'τ_out
                           (syntax-parse #'τ_out
                             [(~?∀ (Y ...) τ_out)
                              (unless (→? #'τ_out)
                                (raise-app-poly-infer-error stx #'(τ_in ...) #'(τ_arg ...) #'e_fn))
                              #'(∀ (unsolved-X ... Y ...) τ_out)]))
          (⊢ ((#%app- e_fn- op ...) e_arg- ...) : τ_out*)])])])]]
  [(_ e_fn . e_args) ≫ ; err case; e_fn is not a function
   [⊢ e_fn ≫ e_fn- ⇒ τ_fn]
   --------
   [#:error 
    (type-error #:src stx 
                #:msg (format "Expected expression ~a to have → type, got: ~a"
                              (syntax->datum #'e_fn) (type->str #'τ_fn)))]])


;; cond and other conditionals
(define-typed-syntax cond
  [(_ [(~or (~and (~datum else) (~parse test #'(ext-stlc:#%datum . #t)))
            test)
       b ... body] ...+) ⇐ τ_expected ≫
   [⊢ test ≫ test- ⇐ Bool] ...
   [⊢ (begin b ... body) ≫ body- ⇐ τ_expected] ...
   --------
   [⊢ (cond- [test- body-] ...)]]
  [(cond [(~or (~and (~datum else) (~parse test #'(ext-stlc:#%datum . #t)))
               test)
          b ... body] ...+) ≫
   [⊢ test ≫ test- ⇐ Bool] ...
   [⊢ (begin b ... body) ≫ body- ⇒ τ_body] ...
   --------
   [⊢ (cond- [test- body-] ...) ⇒ (⊔ τ_body ...)]])
(define-typed-syntax when
  [(_ test body ...) ≫
   [⊢ test ≫ test- ⇒ _] ; non-false true
   [⊢ body ≫ body- ⇒ _] ...
   --------
   [⊢ (when- test- body- ... (void-)) ⇒ Unit]])
(define-typed-syntax unless
  [(_ test body ...) ≫
   [⊢ test ≫ test- ⇒ _]
   [⊢ body ≫ body- ⇒ _] ...
   --------
   [⊢ (unless- test- body- ... (void-)) ⇒ Unit]])

;; sync channels and threads
(define-type-constructor Channel)

(define-typed-syntax make-channel
  [(_ (~and tys {ty})) ≫
   #:when (brace? #'tys)
   --------
   [⊢ (make-channel-) ⇒ (Channel ty)]])
(define-typed-syntax channel-get
  [(_ c) ⇐ ty ≫
   [⊢ c ≫ c- ⇐ (Channel ty)]
   --------
   [⊢ (channel-get- c-)]]
  [(_ c) ≫
   [⊢ c ≫ c- ⇒ (~Channel ty)]
   --------
   [⊢ (channel-get- c-) ⇒ ty]])
(define-typed-syntax channel-put
  [(_ c v) ≫
   [⊢ c ≫ c- ⇒ (~Channel ty)]
   [⊢ v ≫ v- ⇐ ty]
   --------
   [⊢ (channel-put- c- v-) ⇒ Unit]])

(define-base-type Thread)

;; threads
(define-typed-syntax (thread th) ≫
  [⊢ th ≫ th- ⇒  (~∀ () (~ext-stlc:→ τ_out))]
  --------
  [⊢ (thread- th-) ⇒ Thread])

(define-primop random : (→ Int Int))
(define-primop integer->char : (→ Int Char))
(define-primop string->list : (→ String (List Char)))
(define-primop string->number : (→ String Int))
(define-typed-syntax number->string
  [_:id ≫
   --------
   [⊢ number->string- ⇒ (→ Int String)]]
  [(_ n) ≫
   --------
   [≻ (number->string n (ext-stlc:#%datum . 10))]]
  [(_ n rad) ≫
   [⊢ n ≫ n- ⇐ Int]
   [⊢ rad ≫ rad- ⇐ Int]
   --------
   [⊢ (number->string- n rad) ⇒ String]])

(define-primop string : (→ Char String))
(define-primop sleep : (→ Int Unit))
(define-primop string=? : (→ String String Bool))
(define-primop string<? : (→ String String Bool))
(define-primop string<=? : (→ String String Bool))
(define-primop string>? : (→ String String Bool))
(define-primop string>=? : (→ String String Bool))
(define-primop char=? : (→ Char Char Bool))
(define-primop char<? : (→ Char Char Bool))
(define-primop char<=? : (→ Char Char Bool))
(define-primop char>? : (→ Char Char Bool))
(define-primop char>=? : (→ Char Char Bool))

(define-typed-syntax string-append
  [(_ str ...) ≫
   [⊢ str ≫ str- ⇐ String] ...
   --------
   [⊢ (string-append- str- ...) ⇒ String]])

;; vectors
(define-type-constructor Vector)

(define-typed-syntax vector
  [(_ (~and tys {ty})) ≫
   #:when (brace? #'tys)
   --------
   [⊢ (vector-) ⇒ (Vector ty)]]
  [(_ v ...) ⇐ (Vector ty) ≫
   [⊢ v ≫ v- ⇐ ty] ...
   --------
   [⊢ (vector- v- ...)]]
  [(_ v ...) ≫
   [⊢ v ≫ v- ⇒ ty] ...
   #:when (same-types? #'(ty ...))
   #:with one-ty (stx-car #'(ty ...))
   --------
   [⊢ (vector- v- ...) ⇒ (Vector one-ty)]])
(define-typed-syntax make-vector
  [(_ n) ≫
   --------
   [≻ (make-vector n (ext-stlc:#%datum . 0))]]
  [(_ n e) ≫
   [⊢ n ≫ n- ⇐ Int]
   [⊢ e ≫ e- ⇒ ty]
   --------
   [⊢ (make-vector- n- e-) ⇒ (Vector ty)]])
(define-typed-syntax (vector-length e) ≫
  [⊢ e ≫ e- ⇒ (~Vector _)]
  --------
  [⊢ (vector-length- e-) ⇒ Int])
(define-typed-syntax vector-ref
  [(_ e n) ⇐ ty ≫
   [⊢ e ≫ e- ⇐  (Vector ty)]
   [⊢ n ≫ n- ⇐  Int]
   --------
   [⊢ (vector-ref- e- n-)]]
  [(_ e n) ≫
   [⊢ e ≫ e- ⇒ (~Vector ty)]
   [⊢ n ≫ n- ⇐ Int]
   --------
   [⊢ (vector-ref- e- n-) ⇒ ty]])
(define-typed-syntax (vector-set! e n v) ≫
  [⊢ e ≫ e- ⇒ (~Vector ty)]
  [⊢ n ≫ n- ⇐ Int]
  [⊢ v ≫ v- ⇐ ty]
  --------
  [⊢ (vector-set!- e- n- v-) ⇒ Unit])
(define-typed-syntax (vector-copy! dest start src) ≫
  [⊢ dest ≫ dest- ⇒ (~Vector ty)]
  [⊢ start ≫ start- ⇐ Int]
  [⊢ src ≫ src- ⇐ (Vector ty)]
  --------
  [⊢ (vector-copy!- dest- start- src-) ⇒ Unit])

;; sequences and for loops

(define-type-constructor Sequence)

(define-typed-syntax in-range
  [(_ end) ≫
   --------
   [≻ (in-range (ext-stlc:#%datum . 0) end (ext-stlc:#%datum . 1))]]
  [(_ start end) ≫
   --------
   [≻ (in-range start end (ext-stlc:#%datum . 1))]]
  [(_ start end step) ≫
   [⊢ start ≫ start- ⇐ Int]
   [⊢ end ≫ end- ⇐ Int]
   [⊢ step ≫ step- ⇐ Int]
   --------
   [⊢ (in-range- start- end- step-) ⇒ (Sequence Int)]])

(define-typed-syntax in-naturals
 [(_) ≫
  --------
  [≻ (in-naturals (ext-stlc:#%datum . 0))]]
 [(_ start) ≫
  [⊢ start ≫ start- ⇐ Int]
  --------
  [⊢ (in-naturals- start-) ⇒ (Sequence Int)]])


(define-typed-syntax (in-vector e) ≫
  [⊢ e ≫ e- ⇒ (~Vector ty)]
  --------
  [⊢ (in-vector- e-) ⇒ (Sequence ty)])

(define-typed-syntax (in-list e) ≫
  [⊢ e ≫ e- ⇒ (~List ty)]
  --------
  [⊢ (in-list- e-) ⇒  (Sequence ty)])

(define-typed-syntax (in-lines e) ≫
  [⊢ e ≫ e- ⇐ String]
  --------
  [⊢ (in-lines- (open-input-string- e-)) ⇒ (Sequence String)])

(define-typed-syntax (for ([x:id e]...) b ...+) ≫
  [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
  [[x ≫ x- : ty] ... ⊢ [b ≫ b- ⇒ _] ...]
  --------
  [⊢ (for- ([x- e-] ...) b- ...) ⇒ Unit])
(define-typed-syntax (for* ([x:id e]...) b ...+) ≫
  [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
  [[x ≫ x- : ty] ... ⊢ [b ≫ b- ⇒ _] ...]
  --------
  [⊢ (for*- ([x- e-] ...) b- ...) ⇒ Unit])

(define-typed-syntax (for/list ([x:id e]...) body) ≫
  [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
  [[x ≫ x- : ty] ... ⊢ [body ≫ body- ⇒ ty_body]]
  --------
  [⊢ (for/list- ([x- e-] ...) body-) ⇒ (List ty_body)])
(define-typed-syntax (for/vector ([x:id e]...) body) ≫
  [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
  [[x ≫ x- : ty] ... ⊢ [body ≫ body- ⇒ ty_body]]
  --------
  [⊢ (for/vector- ([x- e-] ...) body-) ⇒ (Vector ty_body)])
(define-typed-syntax (for*/vector ([x:id e]...) body) ≫
  [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
  [[x ≫ x- : ty] ... ⊢ [body ≫ body- ⇒ ty_body]]
  --------
  [⊢ (for*/vector- ([x- e-] ...) body-) ⇒ (Vector ty_body)])
(define-typed-syntax (for*/list ([x:id e]...) body) ≫
  [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
  [[x ≫ x- : ty] ... ⊢ [body ≫ body- ⇒ ty_body]]
  --------
  [⊢ (for*/list- ([x- e-] ...) body-) ⇒ (List ty_body)])
(define-typed-syntax for/fold
  [(_ ([acc init]) ([x:id e] ...) body) ⇐ τ_expected ≫
   [⊢ init ≫ init- ⇐ τ_expected]
   [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
   [[acc ≫ acc- : τ_expected] [x ≫ x- : ty] ... ⊢ body ≫ body- ⇐ τ_expected]
   --------
   [⊢ (for/fold- ([acc- init-]) ([x- e-] ...) body-)]]
  [(_ ([acc init]) ([x:id e] ...) body) ≫
   [⊢ init ≫ init- ⇒ : τ_init]
   [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
   [[acc ≫ acc- : τ_init] [x ≫ x- : ty] ... ⊢ body ≫ body- ⇐ τ_init]
   --------
   [⊢ (for/fold- ([acc- init-]) ([x- e-] ...) body-) ⇒ τ_init]])

(define-typed-syntax (for/hash ([x:id e]...) body) ≫
   [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
   [[x ≫ x- : ty] ... ⊢ body ≫ body- ⇒ (~× ty_k ty_v)]
   --------
   [⊢ (for/hash- ([x- e-] ...)
       (let- ([t body-])
         (values- (car- t) (cadr- t)))) ⇒ (Hash ty_k ty_v)])

(define-typed-syntax 
  (for/sum 
    ([x:id e]... 
     (~optional (~seq #:when guard) #:defaults ([guard #'#t])))
    body) ≫
   [⊢ e ≫ e- ⇒ (~Sequence ty)] ...
   [[x ≫ x- : ty] ... ⊢ [guard ≫ guard- ⇒ _] [body ≫ body- ⇐ Int]]
   --------
   [⊢ (for/sum- ([x- e-] ... #:when guard-) body-) ⇒ Int])

; printing and displaying
(define-typed-syntax (printf str e ...) ≫
  [⊢ str ≫ s- ⇐ String]
  [⊢ e ≫ e- ⇒ ty] ...
  --------
  [⊢ (printf- s- e- ...) ⇒ Unit])
(define-typed-syntax (format str e ...) ≫
  [⊢ str ≫ s- ⇐ String]
  [⊢ e ≫ e- ⇒ ty] ...
  --------
  [⊢ (format- s- e- ...) ⇒ String])
(define-typed-syntax (display e) ≫
  [⊢ e ≫ e- ⇒ _]
  --------
  [⊢ (display- e-) ⇒ Unit])
(define-typed-syntax (displayln e) ≫
  [⊢ e ≫ e- ⇒ _]
  --------
  [⊢ (displayln- e-) ⇒ Unit])
(define-primop newline : (→ Unit))

(define-typed-syntax list->vector
  [(_ e) ⇐ (~Vector ty) ≫
   [⊢ e ≫ e- ⇐ (List ty)]
   --------
   [⊢ (list->vector- e-)]]
  [(_ e) ≫
   [⊢ e ≫ e- ⇒ (~List ty)]
   --------
   [⊢ (list->vector- e-) ⇒ (Vector ty)]])

(define-typed-syntax let
  [(_ name:id (~datum :) ty:type ~! ([x:id e] ...) b ... body) ≫
   [⊢ e ≫ e- ⇒ ty_e] ...
   [[name ≫ name- : (→ ty_e ... ty.norm)] [x ≫ x- : ty_e] ...
    ⊢ [b ≫ b- ⇒ _] ... [body ≫ body- ⇐ ty.norm]]
   --------
   [⊢ (letrec- ([name- (λ- (x- ...) b- ... body-)])
        (name- e- ...))
       ⇒ ty.norm]]
  [(_ ([x:id e] ...) body ...) ≫
   --------
   [≻ (ext-stlc:let ([x e] ...) (begin body ...))]])
(define-typed-syntax (let* ([x:id e] ...) body ...) ≫
  --------
  [≻ (ext-stlc:let* ([x e] ...) (begin body ...))])

(define-typed-syntax begin
  [(_ body ... b) ⇐ τ_expected ≫
   [⊢ body ≫ body- ⇒ _] ...
   [⊢ b ≫ b- ⇐ τ_expected]
   --------
   [⊢ (begin- body- ... b-)]]
  [(_ body ... b) ≫
   [⊢ body ≫ body- ⇒ _] ...
   [⊢ b ≫ b- ⇒ τ]
   --------
   [⊢ (begin- body- ... b-) ⇒ τ]])

;; hash
(define-type-constructor Hash #:arity = 2)

(define-typed-syntax (in-hash e) ≫
  [⊢ e ≫ e- ⇒ (~Hash ty_k ty_v)]
  --------
  [⊢ (hash-map- e- list-) ⇒ (Sequence (stlc+rec-iso:× ty_k ty_v))])

; mutable hashes
(define-typed-syntax hash
  [(_ (~and tys {ty_key ty_val})) ≫
   #:when (brace? #'tys)
   --------
   [⊢ (make-hash-) ⇒ (Hash ty_key ty_val)]]
  [(_ (~seq k v) ...) ≫
   [⊢ k ≫ k- ⇒ ty_k] ...
   [⊢ v ≫ v- ⇒ ty_v] ...
   #:when (same-types? #'(ty_k ...))
   #:when (same-types? #'(ty_v ...))
   #:with ty_key (stx-car #'(ty_k ...))
   #:with ty_val (stx-car #'(ty_v ...))
   --------
   [⊢ (make-hash- (list- (cons- k- v-) ...)) ⇒ (Hash ty_key ty_val)]])
(define-typed-syntax (hash-set! h k v) ≫
  [⊢ h ≫ h- ⇒ (~Hash ty_k ty_v)]
  [⊢ k ≫ k- ⇐ ty_k]
  [⊢ v ≫ v- ⇐ ty_v]
  --------
  [⊢ (hash-set!- h- k- v-) ⇒ Unit])
(define-typed-syntax hash-ref
  [(_ h k) ≫
   [⊢ h ≫ h- ⇒ (~Hash ty_k ty_v)]
   [⊢ k ≫ k- ⇐ ty_k]
   --------
   [⊢ (hash-ref- h- k-) ⇒ ty_v]]
  [(_ h k fail) ≫
   [⊢ h ≫ h- ⇒ (~Hash ty_k ty_v)]
   [⊢ k ≫ k- ⇐ ty_k]
   [⊢ fail ≫ fail- ⇐ (→ ty_v)]
   --------
   [⊢ (hash-ref- h- k- fail-) ⇒ ty_val]])
(define-typed-syntax (hash-has-key? h k) ≫
  [⊢ h ≫ h- ⇒ (~Hash ty_k _)]
  [⊢ k ≫ k- ⇐ ty_k]
  --------
  [⊢ (hash-has-key?- h- k-) ⇒ Bool])

(define-typed-syntax (hash-count h) ≫
  [⊢ h ≫ h- ⇒ (~Hash _ _)]
  --------
  [⊢ (hash-count- h-) ⇒ Int])

(define-base-type String-Port)
(define-base-type Input-Port)
(define-primop open-output-string : (→ String-Port))
(define-primop get-output-string : (→ String-Port String))
(define-primop string-upcase : (→ String String))

(define-typed-syntax write-string
 [(_ str out) ≫
  --------
  [≻ (write-string str out (ext-stlc:#%datum . 0) (string-length str))]]
 [(_ str out start end) ≫
  [⊢ str ≫ str- ⇐ String]
  [⊢ out ≫ out- ⇐ String-Port]
  [⊢ start ≫ start- ⇐ Int]
  [⊢ end ≫ end- ⇐ Int]
  --------
  [⊢ (begin- (write-string- str- out- start- end-) (void-)) ⇒ Unit]])

(define-typed-syntax (string-length str) ≫
  [⊢ str ≫ str- ⇐ String]
  --------
  [⊢ (string-length- str-) ⇒ Int])
(define-primop make-string : (→ Int String))
(define-primop string-set! : (→ String Int Char Unit))
(define-primop string-ref : (→ String Int Char))
(define-typed-syntax string-copy!
  [(_ dest dest-start src) ≫
   --------
   [≻ (string-copy!
       dest dest-start src (ext-stlc:#%datum . 0) (string-length src))]]
  [(_ dest dest-start src src-start src-end) ≫
   [⊢ dest ≫ dest- ⇐ String]
   [⊢ src ≫ src- ⇐ String]
   [⊢ dest-start ≫ dest-start- ⇐ Int]
   [⊢ src-start ≫ src-start- ⇐ Int]
   [⊢ src-end ≫ src-end- ⇐ Int]
   --------
   [⊢ (string-copy!- dest- dest-start- src- src-start- src-end-) ⇒ Unit]])

(define-primop fl+ : (→ Float Float Float))
(define-primop fl- : (→ Float Float Float))
(define-primop fl* : (→ Float Float Float))
(define-primop fl/ : (→ Float Float Float))
(define-primop fl= : (→ Float Float Bool))
(define-primop flsqrt : (→ Float Float))
(define-primop flceiling : (→ Float Float))
(define-primop inexact->exact : (→ Float Int))
(define-primop exact->inexact : (→ Int Float))
(define-primop char->integer : (→ Char Int))
(define-primop real->decimal-string : (→ Float Int String))
(define-primop fx->fl : (→ Int Float))
(define-typed-syntax (quotient+remainder x y) ≫
  [⊢ x ≫ x- ⇐ Int]
  [⊢ y ≫ y- ⇐ Int]
  --------
  [⊢ (let-values- ([[a b] (quotient/remainder- x- y-)])
       (list- a b))
     ⇒ (stlc+rec-iso:× Int Int)])
(define-primop quotient : (→ Int Int Int))

(define-typed-syntax (set! x:id e) ≫
  [⊢ x ≫ x- ⇒ ty_x]
  [⊢ e ≫ e- ⇐ ty_x]
  --------
  [⊢ (set!- x e-) ⇒ Unit])

(define-typed-syntax (provide-type ty ...) ≫
  --------
  [≻ (provide- ty ...)])

(define-typed-syntax (provide x:id ...) ≫
  [⊢ x ≫ x- ⇒ ty_x] ...
  ; TODO: use hash-code to generate this tmp
  #:with (x-ty ...) (stx-map (lambda (y) (format-id y "~a-ty" y)) #'(x ...))
  --------
  [≻ (begin-
       (provide- x ...)
       (stlc+rec-iso:define-type-alias x-ty ty_x) ...
       (provide- x-ty ...))])
(define-typed-syntax (require-typed x:id ... #:from mod) ≫
  #:with (x-ty ...) (stx-map (lambda (y) (format-id y "~a-ty" y)) #'(x ...))
  #:with (y ...) (generate-temporaries #'(x ...))
  --------
  [≻ (begin-
       (require- (rename-in (only-in mod x ... x-ty ...) [x y] ...))
       (define-syntax x (make-rename-transformer (assign-type #'y #'x-ty))) ...)])

(define-base-type Regexp)
(define-primop regexp-match : (→ Regexp String (List String)))
(define-primop regexp : (→ String Regexp))

(define-typed-syntax (equal? e1 e2) ≫
  [⊢ e1 ≫ e1- ⇒ ty1]
  [⊢ e2 ≫ e2- ⇐ ty1]
  --------
  [⊢ (equal?- e1- e2-) ⇒ Bool])

(define-typed-syntax (read-int) ≫
  --------
  [⊢ (let- ([x (read-)])
       (cond- [(exact-integer?- x) x]
              [else (error- 'read-int "expected an int, given: ~v" x)]))
          ⇒ Int])

(define-typed-syntax (inst e ty ...) ≫
  [⊢ (sysf:inst e ty ...) ≫ e- ⇒ ty_e]
  --------
  [⊢ e- ⇒ #,(cond
             [(→? #'ty_e) #'(∀ () ty_e)]
             [(=>? #'ty_e) #'(∀ () ty_e)]
             [else #'ty_e])])

(begin-for-syntax
 ;; - this function should be wrapped with err handlers,
 ;; for when an op with the specified generic op and input types does not exist,
 ;; otherwise, will get "unbound id" err with internal mangled id
 ;; - gen-op must be identifier, eg should already have proper context
 ;; and mangled-op is selected based on input types,
 ;; ie, dispatch to different concrete fns based on input tpyes
 ;; TODO: currently using input types only, but sometimes may need output type
 ;; eg, Read typeclass, this is currently unsupported
 ;; - need to use expected-type?
 (define (lookup-op gen-op tys)
  (define (transfer-gen-op-ctx o) (format-id gen-op "~a" o))
  (define (transfer-gen-op-ctxs os) (stx-map transfer-gen-op-ctx os))
  (syntax-parse tys
   ;; TODO: for now, only handle uniform tys, ie tys must be all
   ;;  tycons or all base types or all tyvars
   ;; tycon --------------------------------------------------
   ;; - recur on ty-args
   [(((~literal #%plain-app) tycon
     ((~literal #%plain-lambda) _ _ ty-arg ...)) ...)
    ;; 1) look up concrete op corresponding to generic op and input tys
    #:with mangled (mangle gen-op #'(tycon ...))
    #:with [conc-op ty-conc-op] (infer+erase #'mangled)
    ;; compute sub-ops based on TC constraints (will include gen-op --- for smaller type)
    #:with (~∀ Xs (~=> TC ... (~ext-stlc:→ . ty-args))) #'ty-conc-op
    #:with (~TCs ([op _] ...) ...) #'(TC ...) ; order matters, must match order of arg types
    #:with ((sub-op ...) ...) (stx-map transfer-gen-op-ctxs #'((op ...) ...))
    ;; drop the TCs in result type, the proper subops are already applied
    #:with ty-conc-op-noTC #'(∀ Xs (ext-stlc:→ . ty-args))
    ;; recursively call lookup-op for each subop and input ty-args
    (⊢ (conc-op 
         #,@(apply stx-appendmap (lambda (ops . tys) (stx-map (lambda (o) (lookup-op o tys)) ops))
                   #'((sub-op ...) ...)
                   (syntax->list #'((ty-arg ...) ...))))
       : ty-conc-op-noTC)]
   ;; base type --------------------------------------------------
   [(((~literal #%plain-app) tag) ...) (expand/df (mangle gen-op #'(tag ...)))]
   ;; tyvars --------------------------------------------------
   [_ (expand/df (mangle gen-op tys))]))
 (define (get-fn-ty-in-tags ty-fn)
   (syntax-parse ty-fn
     [(~∀ _ (~ext-stlc:→ ty_in ... _))
      (get-type-tags #'(ty_in ...))]))
 (define (TC-exists? TC #:ctx [ctx TC]) ; throws exn if fail
   (syntax-parse TC
     [(~TC-base [gen-op ty-op] . _) ; only need 1st op
      (with-handlers 
        ([exn:fail:syntax:unbound? 
           (lambda (e) 
             (type-error #:src ctx
                         #:msg "No instance defined for ~a" TC))])
      (expand/df
        (mangle (format-id ctx "~a" #'gen-op)
                (get-fn-ty-in-tags #'ty-op))))]))
 (define (TCs-exist? TCs #:ctx [ctx TCs])
   (stx-map (lambda (tc) (TC-exists? tc #:ctx ctx)) TCs)))

;; adhoc polymorphism
;; TODO: make this a formal type?
;; - or at least define a pattern expander - DONE 2016-05-01
;; A TC is a #'(=> subclassTC ... ([generic-op gen-op-ty] ...))
(define-syntax (define-typeclass stx)
  (syntax-parse stx
    [(~or (_ TC ... (~datum =>) (Name X ...) [op (~datum :) ty] ...)
          (~and (_ (Name X ...) [op (~datum :) ty] ...) ; no subclass
                (~parse (TC ...) #'())))
     #'(begin-
         (define-syntax- (op stx)
           (syntax-parse stx
             [(o . es)
              #:with ([e- ty_e] (... ...)) (infers+erase #'es)
              #:with out-op 
                     (with-handlers 
                       ([exn:fail:syntax:unbound? 
                         (lambda (e) 
                           (type-error #:src #'o
                            #:msg (format 
                                   "~a operation undefined for input types: ~a"
                                   (syntax->datum #'o) 
                                   (types->str #'(ty_e (... ...))))))])
                       (lookup-op #'o #'(ty_e (... ...))))
              #:with app (datum->syntax #'o '#%app)
              (datum->syntax stx (cons #'app (cons #'out-op #'(e- (... ...)))))])) ...
         (define-syntax- (Name stx)
           (syntax-parse stx
             [(_ X ...) 
              (add-orig 
                #`(=> TC ... #,(mk-type #'(('op ty) ...)))
                #'(Name X ...))])))]))

(define-typed-syntax define-instance
  ;; base type, possibly with subclasses  ------------------------------------
  [(_ (Name ty ...) [generic-op concrete-op] ...) ≫
   [⊢ (Name ty ...) ≫ 
      (~=> TC ... (~TC [generic-op-expected ty-concrete-op-expected] ...)) ⇒ _]
   #:when (TCs-exist? #'(TC ...) #:ctx stx)
   #:fail-unless (set=? (syntax->datum #'(generic-op ...)) 
                        (syntax->datum #'(generic-op-expected ...)))
                 (type-error #:src stx
                  #:msg (format "Type class instance ~a incomplete, missing: ~a"
                          (syntax->datum #'(Name ty ...))
                          (string-join
                           (map symbol->string 
                                (set-subtract 
                                 (syntax->datum #'(generic-op-expected ...)) 
                                 (syntax->datum #'(generic-op ...))))
                           ", ")))
   ;; sort, using order from define-typeclass
   #:with ([generic-op-sorted concrete-op-sorted] ...) 
          (stx-map
           (lambda (expected-op) 
             (stx-findf
              (lambda (gen+conc) 
                (equal? (syntax->datum (stx-car gen+conc)) 
                        (syntax->datum expected-op)))
              #'([generic-op concrete-op] ...)))
           #'(generic-op-expected ...))
   ;; typecheck type of given concrete-op with expected type from define-typeclass
   [⊢ concrete-op-sorted ≫ concrete-op+ ⇐ ty-concrete-op-expected] ...
   ;; generate mangled name from tags in input types
   #:with (ty_in-tags ...) 
          (stx-map 
           (syntax-parser
             [(~∀ _ (~ext-stlc:→ ty_in ... _))
              (get-type-tags #'(ty_in ...))])
           #'(ty-concrete-op-expected ...))
   ;; use input types
   #:with (mangled-op ...) (stx-map mangle #'(generic-op ...) #'(ty_in-tags ...))
  --------
  [≻ (begin-
        (define-syntax- (mangled-op stx) 
          (syntax-parse stx 
            [_:id (assign-type #'concrete-op+ #'ty-concrete-op-expected)]))
         ...)]]
  ;; tycon, possibly with subclasses -----------------------------------------
  [(_ TC ... (~datum =>) (Name ty ...) [generic-op concrete-op] ...) ≫
   #:with (X ...) (compute-tyvars #'(ty ...))
   ;; ok to drop TCsub ...? I think yes
   ;; - the same TCsubs will be part of TC+,
   ;;   so proper op will be looked up, depending on input args, 
   ;;   using inherited ops in TC+
   ;; This is assuming Name and TC ... are the same typeclass
   ;; Won't work for, eg (TC1 (List X)) that depends on some other (TC2 X)
   #:with (Xs+ 
           (TC+ ... 
                (~=> TCsub ... 
                     (~TC [generic-op-expected ty-concrete-op-expected] ...)))
           _)
           (infers/tyctx+erase #'([X : #%type] ...) #'(TC ... (Name ty ...)))
   ;; this produces #%app bad stx err, so manually call infer for now
   ;; [([X ≫ X- : #%type] ...) () ⊢ (TC ... (Name ty ...)) ≫
   ;;                                (TC+ ... 
   ;;                                 (~=> TCsub ... 
   ;;                                  (~TC [generic-op-expected ty-concrete-op-expected] ...)))
   ;;                                ⇒ _]
   ;; #:with Xs+ #'(X- ...)
   #:when (TCs-exist? #'(TCsub ...) #:ctx stx)
   ;; simulate as if the declared concrete-op* has TC ... predicates
   ;; TODO: fix this manual deconstruction and assembly
   #:with ((app fa (lam _ ei ty_fn)) ...) #'(ty-concrete-op-expected ...)
   #:with (ty-concrete-op-expected-withTC ...) 
          (stx-map (current-type-eval) #'((app fa (lam Xs+ ei (=> TC+ ... ty_fn))) ...))
   #:fail-unless (set=? (syntax->datum #'(generic-op ...)) 
                        (syntax->datum #'(generic-op-expected ...)))
                 (type-error #:src stx
                  #:msg (format "Type class instance ~a incomplete, missing: ~a"
                          (syntax->datum #'(Name ty ...))
                          (string-join
                           (map symbol->string 
                                (set-subtract 
                                 (syntax->datum #'(generic-op-expected ...)) 
                                 (syntax->datum #'(generic-op ...))))
                           ", ")))
   ;; - sort, using order from define-typeclass
   ;; - insert TC ... if lambda
   #:with ([generic-op-sorted concrete-op-sorted] ...) 
          (stx-map
           (lambda (expected-op) 
             (syntax-parse
                 (stx-findf
                  (lambda (gen+conc) 
                    (equal? (syntax->datum (stx-car gen+conc)) 
                            (syntax->datum expected-op)))
                  #'([generic-op concrete-op] ...))
               [(g c) 
                (syntax-parse #'c
                  ;; add TCs to (unexpanded) lambda
                  [((~and lam (~literal liftedλ)) (args ...) . body) 
                   #'(g (lam (args ... #:where TC ...) . body))]
                  [_ #'(g c)])]))
           #'(generic-op-expected ...))
   ;; ;; for now, dont expand (and typecheck) concrete-op
   ;; #:with ([concrete-op+ ty-concrete-op] ...) (infers+erase #'(concrete-op ...))
   ;; #:when (typechecks? #'(ty-concrete-op ...) #'(ty-concrete-op-expected ...))
   ;; TODO: right now, dont recur to get nested tags
   ;; but may need to do so, ie if an instance needs to define more than one concrete op,
   ;; eg (define-instance (Eq (List Int)) ...)
   #:with (ty_in-tags ...) 
          (stx-map 
           (syntax-parser
             [(~∀ _ (~ext-stlc:→ ty_in ... _))
              (get-type-tags #'(ty_in ...))]
             #;[(~∀ _ (~=> _ ... (~ext-stlc:→ ty_in ... _)))
                (get-type-tags #'(ty_in ...))])
           #'(ty-concrete-op-expected ...))
   #:with (mangled-op ...) (stx-map mangle #'(generic-op ...) #'(ty_in-tags ...))
   ;; need a name for concrete-op because concrete-op and generic-op may be
   ;; mutually recursive, eg (Eq (List X))
   #:with (f ...) (generate-temporaries #'(concrete-op-sorted ...))
  --------
  [≻ (begin-
        (define- f concrete-op-sorted) ...
        (define-syntax- (mangled-op stx) 
          (syntax-parse stx 
            [_:id (assign-type #'f #'ty-concrete-op-expected-withTC)]))
        ...)]])
