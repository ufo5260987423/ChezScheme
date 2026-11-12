;; verify-select-semantics.ss — exhaustive cross-checker for the
;; branchless-select semantics (isel/fpsel families).
;;
;; Reference: Chez's own predicate value (fop a b), which compiles
;; through the pre-select value path — trusted and independent of the
;; select conversion under test.
;;
;; Subjects: (if (fop x y) THEN ELSE) compiled with cp0 bypassed and
;; opaque arms (recipes S-1+S-2 from
;; docs/kb/04-verification/shape-forcing-recipes.md) so the written
;; arm order survives to np-normalize-context and the select
;; conversion fires on every shape: boolean immediates in both orders
;; (the setcc specialization), integer immediates (asm-*-sel-imms),
;; and uvar arms (asm-*-sel-regs), in tail and effect position.
;;
;; Usage (from a built machine dir, e.g. ta6le):
;;   bin/ta6le/scheme --script ../docs/kb/tools/verify-select-semantics.ss
;;
;; Exit status is non-zero if any case mismatches the reference.

(import (chezscheme))

(define failures 0)
(define total 0)

(define (check who f fop-proc a b t e)
  (define expected (if (fop-proc a b) t e))
  (define got (f a b))
  (set! total (+ total 1))
  (unless (eqv? got expected)
    (set! failures (+ failures 1))
    (fprintf (current-error-port)
      "MISMATCH ~a: (~a ~a ~a) then=~s else=~s => got ~s, expected ~s~n"
      who fop-proc a b t e got expected)))

;; cp0-bypassed compile of a subject whose arms are opaque (recipe S-1):
;; (#%$value (values v)) keeps cp0 from folding or reordering the arm.
(define (compile-subject fop-src arm-srcs effect-context?)
  (parameterize ([optimize-level 3]
                 [run-cp0 (lambda (cp0 x) x)])
    (compile
      (if effect-context?
          `(lambda (x y ,@(if (eq? arm-srcs 'uvar) '(c d) '()))
             (let ([r (if (,fop-src x y) ,@(if (eq? arm-srcs 'uvar)
                                               '(c d)
                                               arm-srcs))])
               r))
          `(lambda (x y ,@(if (eq? arm-srcs 'uvar) '(c d) '()))
             (if (,fop-src x y) ,@(if (eq? arm-srcs 'uvar)
                                      '(c d)
                                      arm-srcs)))))))

(define inputs
  '((1.0 2.0) (2.0 1.0) (2.0 2.0) (-1.0 1.0)
    (+nan.0 2.0) (2.0 +nan.0) (+nan.0 +nan.0)))

(define fops '(fl< fl<= fl> fl>=))

(define (opaque-arm v) `(#%$value (values ,v)))

(for-each
  (lambda (fop)
    (define fop-proc (eval fop (environment '(chezscheme))))
    (define arm-sets
      ;; (arm-sources then-value else-value subject-thunk-args-adjust)
      `(((,(opaque-arm #t) ,(opaque-arm #f)) #t #f)
        ((,(opaque-arm #f) ,(opaque-arm #t)) #f #t)
        ((,(opaque-arm 10) ,(opaque-arm 20)) 10 20)
        ((,(opaque-arm 20) ,(opaque-arm 10)) 20 10)
        ((,(opaque-arm -7) ,(opaque-arm 3)) -7 3)
        (uvar 10 20)))
    (for-each
      (lambda (arm-set)
        (define arm-srcs (car arm-set))
        (define then-v (cadr arm-set))
        (define else-v (caddr arm-set))
        (for-each
          (lambda (effect-context?)
            (define f (compile-subject fop arm-srcs effect-context?))
            (define who
              (format "~a ~a ~a" fop
                      (if (eq? arm-srcs 'uvar) 'uvar
                          (if (boolean? then-v) 'bool 'int))
                      (if effect-context? 'effect 'tail)))
            (for-each
              (lambda (ab)
                (define a (car ab))
                (define b (cadr ab))
                (if (eq? arm-srcs 'uvar)
                    (begin
                      (check who (lambda (a b) (f a b then-v else-v))
                             fop-proc a b then-v else-v)
                      (check (string-append who "-rev")
                             (lambda (a b) (f a b else-v then-v))
                             fop-proc a b else-v then-v))
                    (check who (lambda (a b) (f a b))
                           fop-proc a b then-v else-v)))
              inputs))
          '(#t #f)))
      arm-sets))
  fops)

(printf "verify-select-semantics: ~a cases, ~a failures~n" total failures)
(when (> failures 0)
  (exit 1))
