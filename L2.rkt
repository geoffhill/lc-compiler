#lang plai

;;; EECS 322 L2->L1 Compiler
;;; Geoff Hill <GeoffreyHill2012@u.northwestern.edu>
;;; Spring 2011

(require (file "preds.rkt"))
(require (file "utils.rkt"))
(require (file "types.rkt"))
(require (file "input.rkt"))
(require (file "output.rkt"))
(require (file "renaming.rkt"))

;;;
;;; GENERAL UTILITY FUNCTIONS
;;;

;; executes a replacement function on every var in an L2stmt
(define-with-contract (replace-stmt-vars stmt r)
  (L2stmt? (L2-s? . -> . L2-s?) . -> . L2stmt?)
  (type-case L2stmt stmt
    [l2s-assign (lhs rhs) (l2s-assign (r lhs) (r rhs))]
    [l2s-memget (lhs base offset) (l2s-memget (r lhs) (r base) offset)]
    [l2s-memset (base offset rhs) (l2s-memset (r base) offset (r rhs))]
    [l2s-aop (lhs op rhs) (l2s-aop (r lhs) op (r rhs))]
    [l2s-sop (lhs op rhs) (l2s-sop (r lhs) op (r rhs))]
    [l2s-cmp (lhs c1 op c2) (l2s-cmp (r lhs) (r c1) op (r c2))]
    [l2s-label (lbl) (l2s-label lbl)]
    [l2s-goto (lbl) (l2s-goto lbl)]
    [l2s-cjump (c1 op c2 lbl1 lbl2) (l2s-cjump (r c1) op (r c2) lbl1 lbl2)]
    [l2s-call (dst) (l2s-call (r dst))]
    [l2s-tcall (dst) (l2s-tcall (r dst))]
    [l2s-return () (l2s-return)]
    [l2s-print (lhs arg1) (l2s-print (r lhs) (r arg1))]
    [l2s-alloc (lhs arg1 arg2) (l2s-alloc (r lhs) (r arg1) (r arg2))]
    [l2s-arrayerr (lhs arg1 arg2) (l2s-arrayerr (r lhs) (r arg1) (r arg2))]))

;;;
;;; REGISTER ALLOCATION TYPES
;;;

;; labelmap type
;; immutable hash, maps labels to stmt numbers
;; defines constructor and contract
(define labelmap hash)
(define labelmap?
  (flat-named-contract
   'labelmap?
   (hash/c label? integer? #:immutable #t #:flat? #t)))

;; colormap type
;; immutable hash, maps variables to registers
;; defines constructor and contract
(define (colormap init-set)
  (make-immutable-hash (set-map init-set (λ (x) (cons x x)))))
(define colormap?
  (flat-named-contract
   'colormap?
   (hash/c L2-x? L1-x? #:immutable #t #:flat? #t)))

;; L2reg types for register allocation
;; each type for different stage in the data buildup
(define-type L2reg
  [l2reg-base (stmts (vectorof L2stmt?))
              (lblmap labelmap?)]
  [l2reg-succ (stmts (vectorof L2stmt?))
              (succs (vectorof (setof integer?)))]
  [l2reg-liveness (stmts (vectorof L2stmt?))
                  (ins (vectorof (setof L2-x?)))
                  (outs (vectorof (setof L2-x?)))]
  [l2reg-graph (stmts (vectorof L2stmt?))
               (nodes (setof L2-x?))
               (edges (setof (pairof L2-x?)))]
  [l2reg-color (stmts (vectorof L2stmt?))
               (coloring colormap?)])

;;;
;;; L2REG-BASE GENERATION
;;;

;; creates an L2reg-base
(define-with-contract (build-l2reg-base stmts)
  ((listof L2stmt?) . -> . l2reg-base?)
  (let ([vecstmts (make-vector (length stmts))])
    (let loop ([stmts stmts]
               [index 0]
               [lblmap (labelmap)])
      (if (null? stmts)
          (l2reg-base vecstmts lblmap)
          (let ([stmt (car stmts)])
            (vector-set! vecstmts index stmt)
            (loop (cdr stmts)
                  (+ index 1)
                  (if (l2s-label? stmt)
                      (hash-set lblmap (l2s-label-lbl stmt) index)
                      lblmap)))))))

;;;
;;; L2REG-SUCC GENERATION
;;;

;; creates an L2reg-succ from an L2reg-base
(define-with-contract (build-l2reg-succ l2fn)
  (l2reg-base? . -> . l2reg-succ?)
  (let* ([stmts (l2reg-base-stmts l2fn)]
         [lblmap (l2reg-base-lblmap l2fn)]
         [len (vector-length stmts)]
         [succs (make-vector len)])
    (for ([i (in-range len)])
      (vector-set! succs i (successors (vector-ref stmts i) lblmap i len)))
    (l2reg-succ stmts succs)))

;; gets the set of all successors of an L2stmt
;; within the context of an function
(define-with-contract (successors stmt lblmap line len)
  (L2stmt? labelmap? integer? integer? . -> . (set/c integer?))
  (type-case L2stmt stmt
    [l2s-goto (lbl)
              (set (hash-ref lblmap lbl))]
    [l2s-cjump (c1 op c2 lbl1 lbl2)
               (set (hash-ref lblmap lbl1)
                    (hash-ref lblmap lbl2))]
    [l2s-tcall (dst) (set)]
    [l2s-return () (set)]
    [l2s-arrayerr (lhs arg1 arg2) (set)]
    [else (if (= line (- len 1))
              (set)
              (set (+ line 1)))]))

;;;
;;; L2REG-LIVENESS GENERATION
;;;

;; creates an L2reg-liveness frpm L2reg-succ
(define-with-contract (build-l2reg-liveness l2fn)
  (l2reg-succ? . -> . l2reg-liveness?)
  (let* ([stmts (l2reg-succ-stmts l2fn)]
         [succs (l2reg-succ-succs l2fn)]
         [len (vector-length stmts)])
    (let loop ([ins (vector-map gen stmts)]
               [outs (build-vector len (λ (n) (set)))])
      (let ([new-ins (vector-copy ins)]
            [new-outs (vector-copy outs)])
        (for ([i (in-range len)])
          (vector-set! new-ins i
                       (set-union (vector-ref ins i)
                                  (set-subtract (vector-ref outs i)
                                                (kill (vector-ref stmts i)))))
          (vector-set! new-outs i
                       (setlst-union (set-map (vector-ref succs i)
                                              (λ (s) (vector-ref ins s))))))
        (if (and (equal? ins new-ins) (equal? outs new-outs))
            (l2reg-liveness stmts ins outs)
            (loop new-ins new-outs))))))

;; gets the gen set for an L2stmt
(define-with-contract (gen stmt)
  (L2stmt? . -> . (setof L2-x?))
  (list->set
   (filter L2-x?
           (type-case L2stmt stmt
             [l2s-assign (lhs rhs) `(,rhs)]
             [l2s-memget (lhs base offset) `(,base)]
             [l2s-memset (base offset rhs) `(,base ,rhs)]
             [l2s-aop (lhs op rhs) `(,lhs ,rhs)]
             [l2s-sop (lhs op rhs) `(,lhs ,rhs)]
             [l2s-cmp (lhs c1 op c2) `(,c1 ,c2)]
             [l2s-label (lbl) `()]
             [l2s-goto (lbl) `()]
             [l2s-cjump (c1 op c2 lbl1 lbl2) `(,c1 ,c2)]
             [l2s-call (dst) `(,dst eax ecx edx)]
             [l2s-tcall (dst) `(,dst eax ecx edx edi esi)]
             [l2s-return () `(eax edi esi)]
             [l2s-print (lhs arg1) `(,arg1)]
             [l2s-alloc (lhs arg1 arg2) `(,arg1 ,arg2)]
             [l2s-arrayerr (lhs arg1 arg2) `(,arg1 ,arg2)]))))

;; gets the kill set for an L2stmt
(define-with-contract (kill stmt)
  (L2stmt? . -> . (setof L2-x?))
  (list->set
   (filter L2-x?
           (type-case L2stmt stmt
             [l2s-assign (lhs rhs) `(,lhs)]
             [l2s-memget (lhs base offset) `(,lhs)]
             [l2s-memset (base offset rhs) `()]
             [l2s-aop (lhs op rhs) `(,lhs)]
             [l2s-sop (lhs op rhs) `(,lhs)]
             [l2s-cmp (lhs c1 op c2) `(,lhs)]
             [l2s-label (lbl) `()]
             [l2s-goto (lbl) `()]
             [l2s-cjump (c1 op c2 lbl1 lbl2) `()]
             [l2s-call (dst) `(eax ebx ecx edx)]
             [l2s-tcall (dst) `()]
             [l2s-return () `(eax ecx edx)]
             [l2s-print (lhs arg1) `(,lhs eax ecx edx)]
             [l2s-alloc (lhs arg1 arg2) `(,lhs eax ecx edx)]
             [l2s-arrayerr (lhs arg1 arg2) `(,lhs eax ecx edx)]))))

;;;
;;; L2REG-GRAPH GENERATION
;;;

(define node? L2-x?)
(define node-set? (setof node?))
(define non-empty-node-set? (non-empty-setof node?))
(define edge? (pairof node?))
(define edge-set? (setof (pairof node?)))
(define non-empty-edge-set? (non-empty-setof (pairof node?)))

;; creates an L2reg-graph from L2reg-liveness
(define-with-contract (build-l2reg-graph l2fn)
  (l2reg-liveness? . -> . l2reg-graph?)
  (let ([stmts (l2reg-liveness-stmts l2fn)]
        [nodes (graph-nodes l2fn)]
        [edges (graph-edges l2fn)])
    (l2reg-graph stmts nodes edges)))

;; register sets for graph generation
(define all-regs (set 'eax 'ebx 'ecx 'edx 'edi 'esi 'ebp 'esp))
(define used-regs (set 'eax 'ebx 'ecx 'edx 'edi 'esi))
(define ignored-regs (set 'ebp 'esp))
(define valid-cmp-regs (set 'eax 'ebx 'ecx 'edx))
(define valid-sop-regs (set 'ecx))

;; predicate to see if a set contains no ignored regs
(define-with-contract (no-ignored-regs s)
  (set? . -> . boolean?)
  (set-empty? (set-intersect s ignored-regs)))

;; generates the set of nodes of the graph
(define-with-contract (graph-nodes l2fn)
  (l2reg-liveness? . -> . (setof L2-x?))
  (set-union
   used-regs
   (setlst-union
    (vector->list
     (vector-map (λ (s) (set-subtract s ignored-regs))
                 (vector-map var (l2reg-liveness-stmts l2fn)))))))

;; gets the full variable set for an L2stmt
;; including all the implicitly used variables
;; from gen/kill
(define-with-contract (var stmt)
  (L2stmt? . -> . node-set?)
  (set-union (gen stmt) (kill stmt)))

;; generates the set of edges of the graph
(define-with-contract (graph-edges l2fn)
  (l2reg-liveness? . -> . edge-set?)
  (let* ([stmts (l2reg-liveness-stmts l2fn)]
         [len (vector-length stmts)]
         [ins (l2reg-liveness-ins l2fn)]
         [outs (l2reg-liveness-outs l2fn)])
    (let loop ([i 0]
               [edges (powerset used-regs)])
      (if (= i len)
          edges
          (let* ([stmt (vector-ref stmts i)]
                 [in (vector-ref ins i)]
                 [out (vector-ref outs i)]
                 [toomany-interfering-pairs
                  (set-union
                   ; all var combos of the kill set of every stmt
                   (powerset (set-union out (kill stmt)))
                   ; all var combos of the gen set of first stmt
                   (if (= i 0) (powerset (set-union out (gen stmt))) (set))
                   ; all regs that cannot be arg of a shift for sop stmt
                   (if (and (l2s-sop? stmt) (L2-x? (l2s-sop-rhs stmt)))
                       (pairs (l2s-sop-rhs stmt)
                              (set-subtract used-regs valid-sop-regs))
                       (set))
                   ; all regs that cannot be result of a compare for cmp stmt
                   (if (l2s-cmp? stmt)
                       (pairs (l2s-cmp-lhs stmt)
                              (set-subtract used-regs valid-cmp-regs))
                       (set)))]
                 [interfering-pairs
                  (type-case L2stmt stmt
                    [l2s-assign (lhs rhs) (set-remove toomany-interfering-pairs (set lhs rhs))]
                    [else toomany-interfering-pairs])]
                 [important-pairs (set-filter interfering-pairs no-ignored-regs)])
            (loop (+ i 1) (set-union edges important-pairs)))))))

;;;
;;; L3FN-COLOR GENERATION
;;;

(define L2-spill-prefix 'spill)

;; creates an L2reg-color from L2reg-graph
(define-with-contract (build-l2reg-color l2fn)
  (l2reg-graph? . -> . l2reg-color?)
  (let ([varfn (make-counter L2-spill-prefix)])
    (let loop ([l2fn l2fn]
               [offset 0]
               [spillables (set-subtract (l2reg-graph-nodes l2fn) all-regs)])
      (let* ([stmts (l2reg-graph-stmts l2fn)]
             [nodes (l2reg-graph-nodes l2fn)]
             [edges (l2reg-graph-edges l2fn)]
             [coloring (color nodes edges)])
        (if coloring
            (l2reg-color (fix-stack stmts offset) coloring)
            (if (set-empty? spillables)
                (error 'L2 "no variables left to spill")
                (let-values ([(to-spill to-keep) (choose-spill-vars spillables edges)])
                  (let* ([stmt-lst (vector->list stmts)]
                         [spill-lst (set->list to-spill)]
                         [spilled-fn (spill-multiple stmt-lst spill-lst offset varfn)]
                         [num-spilled (set-count to-spill)]
                         [new-base (build-l2reg-base spilled-fn)]
                         [new-succ (build-l2reg-succ new-base)]
                         [new-liveness (build-l2reg-liveness new-succ)]
                         [new-graph (build-l2reg-graph new-liveness)])
                    (loop new-graph (- offset (* 4 num-spilled)) to-keep)))))))))

;; spills a set of variables
(define-with-contract (spill-multiple stmts name-lst offset varfn)
  ((listof L2stmt?) (listof node?) n4? (-> symbol?) . -> . (listof L2stmt?))
  (if (null? name-lst)
      stmts
      (spill-multiple (spill-one stmts (first name-lst) (- offset 4) varfn)
                      (rest name-lst)
                      (- offset 4)
                      varfn)))

;; spills a single variable
(define-with-contract (spill-one stmts name offset varfn)
  ((listof L2stmt?) node? n4? (-> symbol?) . -> . (listof L2stmt?))
  (if (null? stmts)
      '()
      (append (spill-stmt (first stmts) name offset varfn)
              (spill-one (rest stmts) name offset varfn))))

;; spills a single statement
(define-with-contract (spill-stmt stmt name offset varfn)
  (L2stmt? node? n4? (-> symbol?) . -> . (listof L2stmt?))
  (let* ([in-gen (set-member? (gen stmt) name)]
         [in-kill (set-member? (kill stmt) name)])
    (cond
      ; special case: unneccesary assignment
      [(and (l2s-assign? stmt)
            (equal? (l2s-assign-lhs stmt) name)
            (equal? (l2s-assign-rhs stmt) name))
       '()]
      ; special case: assignment lhs
      [(and (l2s-assign? stmt)
            (equal? (l2s-assign-lhs stmt) name))
       (list (l2s-memset 'ebp offset (l2s-assign-rhs stmt)))]
      ; special case: assignment rhs
      [(and (l2s-assign? stmt)
            (equal? (l2s-assign-rhs stmt) name))
       (list (l2s-memget (l2s-assign-lhs stmt) 'ebp offset))]
      ; general case: gen'd and kill'd
      [(and in-gen in-kill)
       (let ([temp (varfn)])
         (list (l2s-memget temp 'ebp offset)
               (replace-stmt-vars stmt (λ (x) (if (equal? x name) temp x)))
               (l2s-memset 'ebp offset temp)))]
      ; general case: gen'd only
      [in-gen
       (let ([temp (varfn)])
         (list (l2s-memget temp 'ebp offset)
               (replace-stmt-vars stmt (λ (x) (if (equal? x name) temp x)))))]
      ; general case: kill'd only
      [in-kill
       (let ([temp (varfn)])
         (list (replace-stmt-vars stmt (λ (x) (if (equal? x name) temp x)))
               (l2s-memset 'ebp offset temp)))]
      ; general case: not gen'd or kill'd
      [else (list stmt)])))


;; given a spillable set, choose the best set to spill
;; policy decision
;; this implementation spills sqrt(N)-1 for N > 15, otherwise 1
(define-with-contract (choose-spill-vars spillables edges)
  (non-empty-node-set? edge-set? . -> . (values node-set? node-set?))
  (let* ([total (set-count spillables)]
         [taken (if (total . > . 15)
                    (- (integer-sqrt total) 1)
                    1)])
    (split-by-degree spillables edges taken)))


;; add statements to fix stack alignment
;; ensures that labeled functions stay labeled
(define-with-contract (fix-stack stmts offset)
  ((vectorof L2stmt?) nonpositive-n4? . -> . (vectorof L2stmt?))
  (let ([pos-offset (- 0 offset)])
    (if (zero? offset)
        stmts
        (let loop ([i (vector-length stmts)]
                   [accum `()])
          (if (zero? i)
              (list->vector `(,(l2s-aop 'esp '-= pos-offset) ,@accum ,(l2s-aop 'esp '+= pos-offset)))
              (let* ([stmt (vector-ref stmts (- i 1))]
                     [new-stmts (type-case L2stmt stmt
                                  [l2s-tcall (dst) `(,(l2s-aop 'esp '+= pos-offset) ,stmt)]
                                  [l2s-return () `(,(l2s-aop 'esp '+= pos-offset) ,stmt)]
                                  [else `(,stmt)])])
                (loop (- i 1) (append new-stmts accum))))))))

;; create a color mapping from an interference graph
(define-with-contract (color nodes edges)
  (node-set? edge-set? . -> . (or/c colormap? false?))
  (build-colormap (set-subtract nodes used-regs)
                  edges
                  (colormap used-regs)))

(define-with-contract (build-colormap rem-nodes edges colors)
  (node-set? edge-set? colormap? . -> . (or/c colormap? false?))
  (build-colormap-ordered (order-nodes-to-color rem-nodes edges) edges colors))

(define-with-contract (build-colormap-ordered rem-list edges colors)
  ((listof node?) edge-set? colormap? . -> . (or/c colormap? false?))
  (if (null? rem-list)
      colors
      (let* ([possible-edges (pairs (first rem-list) used-regs)]
             [valid-edges (set-subtract possible-edges edges)])
        (and (not (set-empty? valid-edges))
             (let* ([edge (choose-edge valid-edges edges)]
                    [reg (reg-from-edge edge)]
                    [new-edges (interference-union edge edges)])
               (build-colormap-ordered (rest rem-list)
                                       new-edges
                                       (hash-set colors (first rem-list) reg)))))))

;; given a colorable node set, choose the best one to color
;; policy decision
;; this implementation orders by decreasing degree
(define-with-contract (order-nodes-to-color rem-nodes edges)
  (non-empty-node-set? edge-set? . -> . (listof node?))
  (sort-by-degree rem-nodes edges))

;; given a set of valid register associations, choose the best one
;; policy decision
;; arbitrarily selects edge
(define-with-contract (choose-edge valid-edges edges)
  (non-empty-edge-set? edge-set? . -> . edge?)
  (first (set->list valid-edges)))

;; extends edges so that everything that interfered
;; with one member of edge also interferes with other
(define-with-contract (interference-union edge edges)
  (edge? edge-set? . -> . edge-set?)
  (let* ([ns (set->list edge)]
         [n1 (first ns)]
         [n2 (second ns)])
    (set-union edges
               (list->set
                (set-map (set-filter edges (λ (e) (set-member? e n1)))
                         (λ (e) (set n2 (opposite e n1)))))
               (list->set
                (set-map (set-filter edges (λ (e) (set-member? e n2)))
                         (λ (e) (set n1 (opposite e n2))))))))

;; given an edge with one register, get the register
(define-with-contract (reg-from-edge edge)
  (edge? . -> . node?)
  (first (set->list (set-intersect edge all-regs))))

;; given an edge and one of the nodes, get the other node
(define-with-contract (opposite edge node)
  (edge? node? . -> . node?)
  (first (set->list (set-remove edge node))))

;; given a node and an edge set, get the degree of the node
(define-with-contract (degree node edges)
  (node? edge-set? . -> . integer?)
  (set-count (set-filter edges (λ (e) (set-member? e node)))))

;; given a set of nodes and an edge set, sort the nodes by degree
(define-with-contract (sort-by-degree nodes edges)
  (node-set? edge-set? . -> . (listof node?))
  (sort (set->list nodes) > #:key (λ (n) (degree n edges))))

;; splits a set of nodes based on the degree
(define pos-int? exact-positive-integer?)
(define-with-contract (split-by-degree nodes edges count)
  (non-empty-node-set? edge-set? pos-int? . -> . (values node-set? node-set?))
  (let-values ([(a b) (split-at (sort-by-degree nodes edges) count)])
    (values (list->set a) (list->set b))))

;;;
;;; L2 -> L1 COMPILATION
;;;

(define L2-svar-prefix 's)

;; compile an L2prog into an L1prog
(define-with-contract (compile-L2prog prog)
  (L2prog? . -> . L1prog?)
  (let ([renamed-prog (rename-L2prog prog)])
    (type-case L2prog renamed-prog
      [l2prog (main others)
              (l1prog (compile-L2fn main)
                      (map compile-L2fn others))])))

;; compile an L2fn into an L1fn
(define-with-contract (compile-L2fn fn)
  (L2fn? . -> . L1fn?)
  (let* ([stmts (type-case L2fn fn
                  [l2mainfn (stmts) stmts]
                  [l2fn (lbl stmts) stmts])]
         [aliased-stmts (make-alias stmts)]
         [base (build-l2reg-base aliased-stmts)]
         [more (build-l2reg-succ base)]
         [liveness (build-l2reg-liveness more)]
         [graph (build-l2reg-graph liveness)]
         [color (build-l2reg-color graph)]
         [coloring (l2reg-color-coloring color)]
         [new-stmts (map compile-L2stmt
                         (vector->list
                          (vector-map
                           (λ (stmt) (replace-stmt-vars stmt (λ (x) (hash-ref coloring x x))))
                           (l2reg-color-stmts color))))]
         [useful-stmts (filter useful-stmt? new-stmts)])
    (type-case L2fn fn
      [l2mainfn (stmts) (l1mainfn useful-stmts)]
      [l2fn (lbl stmts) (l1fn lbl useful-stmts)])))

(define-with-contract (make-alias stmts)
  ((listof L2stmt?) . -> . (listof L2stmt?))
  (let* ([varfn (make-counter L2-svar-prefix)]
         [edi-var (varfn)]
         [esi-var (varfn)])
    (let loop ([stmts (reverse stmts)]
               [accum '()])
      (if (null? stmts)
          (append `(,(l2s-assign edi-var 'edi)
                    ,(l2s-assign esi-var 'esi))
                  accum
                  `(,(l2s-assign 'edi edi-var)
                    ,(l2s-assign 'esi esi-var)))
          (let* ([stmt (first stmts)]
                 [new-stmts (type-case L2stmt stmt
                              [l2s-tcall (dst) `(,(l2s-assign 'edi edi-var)
                                                 ,(l2s-assign 'esi esi-var)
                                                 ,stmt)]
                              [l2s-return () `(,(l2s-assign 'edi edi-var)
                                               ,(l2s-assign 'esi esi-var)
                                               ,stmt)]
                              [else `(,stmt)])])
            (loop (rest stmts) (append new-stmts accum)))))))

(define-with-contract (useful-stmt? stmt)
  (L1stmt? . -> . boolean?)
  (type-case L1stmt stmt
    [l1s-assign (lhs rhs) (not (equal? lhs rhs))]
    [else #t]))

;; compile an L2stmt into an L1stmt
(define-with-contract (compile-L2stmt stmt)
  (L2stmt? . -> . L1stmt?)
  (type-case L2stmt stmt
    [l2s-assign (lhs rhs) (l1s-assign lhs rhs)]
    [l2s-memget (lhs base offset) (l1s-memget lhs base offset)]
    [l2s-memset (base offset rhs) (l1s-memset base offset rhs)]
    [l2s-aop (lhs op rhs) (l1s-aop lhs op rhs)]
    [l2s-sop (lhs op rhs) (l1s-sop lhs op rhs)]
    [l2s-cmp (lhs c1 op c2) (l1s-cmp lhs c1 op c2)]
    [l2s-label (lbl) (l1s-label lbl)]
    [l2s-goto (lbl) (l1s-goto lbl)]
    [l2s-cjump (c1 op c2 lbl1 lbl2) (l1s-cjump c1 op c2 lbl1 lbl2)]
    [l2s-call (dst) (l1s-call dst)]
    [l2s-tcall (dst) (l1s-tcall dst)]
    [l2s-return () (l1s-return)]
    [l2s-print (lhs arg1) (l1s-print lhs arg1)]
    [l2s-alloc (lhs arg1 arg2) (l1s-alloc lhs arg1 arg2)]
    [l2s-arrayerr (lhs arg1 arg2) (l1s-arrayerr lhs arg1 arg2)]))

