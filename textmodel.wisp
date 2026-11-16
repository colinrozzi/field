; textmodel.wisp — live text on the field (field/SPEC-text.md): Fugue on doc.ops
; events. Pure: no files, no network; docs.wisp keeps the models and talks to
; the store. It passes field/vectors/text/ (field/vectors/text/run).
;
;   (text-new)                      an empty model
;   (text-apply m id body)          -> m with doc.ops event `id` applied (body: its text)
;   (text-string m)                 -> the text
;   (text-ids m)                    -> the visible characters' ids, "E:k", in order
;   (text-cursor m)                 -> (list id offset) for every character, deleted ones
;                                      too: the offset just after it (SPEC-text 4)
;   (text-invalid m)                -> the ids of the events it ignored
;   (text-valid? m body)            -> 1 if a body is a valid event for m now, else 0
;   (text-copy m)                   -> an independent copy (text-apply changes m)
;   (text-edit m pos del ins)       -> the op lines that delete `del` characters at
;                                      visible offset `pos` and insert `ins` there (SPEC-text 4)
;   (text-ops m new)                -> the op lines that turn m's text into `new`
;
; Characters are code points; Wisp strings are UTF-8 bytes, so offsets go
; through cp-byte. Every walk is a loop (a tail call, or an explicit stack):
; the tree can be thousands of characters deep (vectors/text/12-big).
;
; The tree is kept as runs: a node is characters k0 .. k0+len-1 of one event,
; each the right child of the one before (SPEC-text 3). Only its first
; character has left children (lk) and only its last right children (rk);
; inserting next to any other character splits the node first. A model
; changes in place (Wisp vectors and maps, wisp #128); text-copy makes an
; independent one. It is
;
;   (list nodes evs inv invlist)
;   nodes   a vector of nodes, each (vector eid k0 len text dead lk rk); node 0 is
;           the root ^. dead: "0"/"1" per character (1 a tombstone); lk, rk: lists
;           of node numbers, each ordered by the first character's id (E, then k)
;   evs     a map from each applied event's id to (vector len owner): its text's
;           length, and owner[k] the node holding character k
;   inv     a map of the ignored events' ids; invlist the same, in order
(module textmodel
  (provide text-new text-apply text-valid? text-string text-ids text-cursor text-invalid
           text-copy text-edit text-ops text-diff text-escape text-unescape cp-len cp-sub num->str)
  (require list "std/list.wisp")
  (require str "std/str.wisp")

  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define b-bs (string-ref "\\" 0))
  (define b-n (string-ref "n" 0))
  (define b-colon (string-ref ":" 0))
  (define b-zero (string-ref "0" 0))
  (define b-minus (string-ref "-" 0))
  (define rest-of (lambda (s i) (substring s i (string-len s))))
  (define min (lambda (a b) (if (< a b) a b)))
  (define max (lambda (a b) (if (< a b) b a)))
  (define mod (lambda (a b) (- a (* b (/ a b)))))
  (define num->str (lambda (n)
    (if (< n 10) (substring "0123456789" n (+ n 1)) (digits-of n ""))))
  (define digits-of (lambda (n acc)
    (if (= n 0) acc (digits-of (/ n 10) (string-append (substring "0123456789" (mod n 10) (+ (mod n 10) 1)) acc)))))

  ; ── code points ───────────────────────────────────────────────────────
  ; Characters are Unicode code points; Wisp strings are UTF-8 bytes. The
  ; utf8- builtins (wisp #129) count and cut by code point.
  (define cp-len (lambda (s) (utf8-length s)))
  (define cp-byte (lambda (s k) (utf8-offset s k)))
  (define cp-sub (lambda (s a b) (utf8-substring s a b)))
  ; the bytes of the code point that starts with byte b
  (define cp-width (lambda (b)
    (let (n (s32 b)) (if (< n 128) 1 (if (< n 224) 2 (if (< n 240) 3 4))))))

  ; ── strings ───────────────────────────────────────────────────────────
  ; join a list of strings by pairs, so each byte is copied log n times
  ; (joinv v) for a vector of strings, (join-all xs) for a list
  (define pairs-from (lambda (v i out)
    (if (>= i (vector-length v)) out
      (begin
        (vector-push! out (if (= (+ i 1) (vector-length v)) (vector-ref v i)
                            (string-append (vector-ref v i) (vector-ref v (+ i 1)))))
        (pairs-from v (+ i 2) out)))))
  (define joinv (lambda (v)
    (if (= (vector-length v) 0) "" (if (= (vector-length v) 1) (vector-ref v 0) (joinv (pairs-from v 0 (vector)))))))
  (define join-all (lambda (xs) (joinv (list->vector xs))))
  (define repeat-from (lambda (s n out) (if (= n 0) (join-all out) (repeat-from s (- n 1) (list-push out s)))))
  (define repeat (lambda (s n) (repeat-from s n (list))))
  ; -1, 0 or 1, by bytes
  (define cmp-from (lambda (a b i)
    (if (= i (string-len a)) (if (= i (string-len b)) 0 -1)
      (if (= i (string-len b)) 1
        (let (x (s32 (string-ref a i)))
          (let (y (s32 (string-ref b i)))
            (if (< x y) -1 (if (< y x) 1 (cmp-from a b (+ i 1))))))))))
  (define str-cmp (lambda (a b) (cmp-from a b 0)))

  ; ── escapes ───────────────────────────────────────────────────────────
  (define escape-from (lambda (s i out)
    (let (j (string-index s b-bs i))
      (let (k (string-index s b-nl i))
        (let (e (if (< j 0) k (if (< k 0) j (min j k))))
          (if (< e 0) (join-all (list-push out (rest-of s i)))
            (escape-from s (+ e 1)
              (list-push (list-push out (substring s i e)) (if (= e j) "\\\\" "\\n")))))))))
  (define text-escape (lambda (s) (escape-from s 0 (list))))
  ; -> the text, or "" with a bad escape (an empty text is invalid anyway)
  (define unescape-from (lambda (s i out)
    (let (j (string-index s b-bs i))
      (if (< j 0) (join-all (list-push out (rest-of s i)))
        (if (>= (+ j 1) (string-len s)) ""
          (let (c (string-ref s (+ j 1)))
            (if (or (= c b-n) (= c b-bs))
              (unescape-from s (+ j 2) (list-push (list-push out (substring s i j)) (if (= c b-n) "\n" "\\")))
              "")))))))
  (define text-unescape (lambda (s) (unescape-from s 0 (list))))

  ; ── the model ─────────────────────────────────────────────────────────
  ; options from map-get
  (define got (lambda (o) (match o ((some v) v) ((none) 0))))
  (define node (lambda (eid k0 len text dead lk rk) (vector eid k0 len text dead lk rk)))
  (define n-eid (lambda (n) (vector-ref n 0)))
  (define n-k0 (lambda (n) (vector-ref n 1)))
  (define n-len (lambda (n) (vector-ref n 2)))
  (define n-text (lambda (n) (vector-ref n 3)))
  (define n-dead (lambda (n) (vector-ref n 4)))
  ; character i of n is deleted; a node's dead is "" while none of it is
  (define dead? (lambda (n i) (and (< 0 (string-len (n-dead n))) (string=? (substring (n-dead n) i (+ i 1)) "1"))))
  (define n-lk (lambda (n) (vector-ref n 5)))
  (define n-rk (lambda (n) (vector-ref n 6)))

  (define text-new (lambda ()
    (list (vector (node "^" 0 0 "" "" (list) (list))) (hash-map) (hash-map) (vector))))
  (define m-nodes (lambda (m) (list-get m 0)))
  (define m-evs (lambda (m) (list-get m 1)))
  (define m-inv (lambda (m) (list-get m 2)))
  (define text-invalid (lambda (m) (vector->list (list-get m 3))))
  (define nget (lambda (m i) (vector-ref (m-nodes m) i)))
  ; an applied event: (vector len owner), owner[k] the node holding E:k; or 0
  (define ev-of (lambda (m eid) (if (= (map-has? (m-evs m) eid) 1) (got (map-get (m-evs m) eid)) 0)))

  ; a copy that shares nothing with m (the model changes in place)
  (define copy-nodes (lambda (v i out)
    (if (= i (vector-length v)) out (begin (vector-push! out (vector-copy (vector-ref v i))) (copy-nodes v (+ i 1) out)))))
  (define copy-evs (lambda (ps out)
    (if (null? ps) out
      (let (e (list-get (car ps) 1))
        (begin (map-set! out (car (car ps)) (vector (vector-ref e 0) (vector-copy (vector-ref e 1))))
               (copy-evs (cdr ps) out))))))
  (define text-copy (lambda (m)
    (list (copy-nodes (m-nodes m) 0 (vector)) (copy-evs (map->list (m-evs m)) (hash-map))
          (map-copy (m-inv m)) (vector-copy (list-get m 3)))))

  ; node a's first character before node b's, by id
  (define before? (lambda (m a b)
    (let (x (nget m a))
      (let (y (nget m b))
        (let (c (str-cmp (n-eid x) (n-eid y)))
          (if (= c 0) (< (n-k0 x) (n-k0 y)) (< c 0)))))))
  ; kids with node x in its place
  (define insert-kid-from (lambda (m kids x i out done)
    (if (= i (length kids)) (if done out (list-push out x))
      (if (and (not done) (before? m x (list-get kids i)))
        (insert-kid-from m kids x (+ i 1) (list-push (list-push out x) (list-get kids i)) 1)
        (insert-kid-from m kids x (+ i 1) (list-push out (list-get kids i)) done)))))
  (define insert-kid (lambda (m kids x) (insert-kid-from m kids x 0 (list) (= 0 1))))

  ; owner[a..b) = x
  (define own (lambda (owner a b x) (if (>= a b) x (begin (vector-set! owner a x) (own owner (+ a 1) b x)))))

  ; split node a so that its character `off` (from its start) begins a new
  ; node, the right child of a's last character -> that node
  (define split-node (lambda (m a off)
    (let (n (nget m a))
      (let (b (vector-length (m-nodes m)))
        (let (cut (cp-byte (n-text n) off))
          (begin
            (vector-push! (m-nodes m)
              (node (n-eid n) (+ (n-k0 n) off) (- (n-len n) off) (rest-of (n-text n) cut)
                    (if (string=? (n-dead n) "") "" (rest-of (n-dead n) off)) (list) (n-rk n)))
            (own (vector-ref (ev-of m (n-eid n)) 1) (+ (n-k0 n) off) (+ (n-k0 n) (n-len n)) b)
            (vector-set! n 2 off)
            (vector-set! n 3 (substring (n-text n) 0 cut))
            (vector-set! n 4 (if (string=? (n-dead n) "") "" (substring (n-dead n) 0 off)))
            (vector-set! n 6 (list b))
            b))))))

  ; where a new side child of character (eid, j) hangs -> (list node side)
  (define attach-point (lambda (m eid j side)
    (if (string=? eid "^") (list 0 side)
      (let (a (vector-ref (vector-ref (ev-of m eid) 1) j))
        (let (n (nget m a))
          (let (off (- j (n-k0 n)))
            (if (string=? side "R")
              (if (= off (- (n-len n) 1)) (list a "R") (begin (split-node m a (+ off 1)) (list a "R")))
              (if (= off 0) (list a "L") (list (split-node m a off) "L")))))))))

  ; insert text (len code points) as characters me:k0.., its first the side
  ; child of character (eid, j)
  (define do-insert (lambda (m me eid j side text len k0)
    (let (at (attach-point m eid j side))
      (let (x (vector-length (m-nodes m)))
        (let (p (nget m (car at)))
          (begin
            (vector-push! (m-nodes m) (node me k0 len text "" (list) (list)))
            (own (vector-ref (ev-of m me) 1) k0 (+ k0 len) x)
            (if (string=? (list-get at 1) "L") (vector-set! p 5 (insert-kid m (n-lk p) x))
              (vector-set! p 6 (insert-kid m (n-rk p) x)))
            m))))))

  ; mark characters k .. end-1 of event eid deleted, node by node
  (define mark-dead (lambda (dead a b) (string-append (substring dead 0 a) (repeat "1" (- b a)) (rest-of dead b))))
  (define do-delete (lambda (m eid k end)
    (if (>= k end) m
      (let (n (nget m (vector-ref (vector-ref (ev-of m eid) 1) k)))
        (let (b (min end (+ (n-k0 n) (n-len n))))
          (begin
            (vector-set! n 4 (mark-dead (if (string=? (n-dead n) "") (repeat "0" (n-len n)) (n-dead n)) (- k (n-k0 n)) (- b (n-k0 n))))
            (do-delete m eid b end)))))))

  ; ── parsing and checking an event ─────────────────────────────────────
  ; a decimal without leading zeros or sign -> it, or -1
  (define decimal (lambda (s)
    (if (or (= (string-len s) 0) (= (string-ref s 0) b-minus) (and (< 1 (string-len s)) (= (string-ref s 0) b-zero))) -1
      (match (string->s32 s) ((some n) n) ((none) -1)))))
  ; "^", "@:k" or "E:k" -> (list "^") (list "@" k) (list "E" eid k), or (list "?")
  (define parse-ref (lambda (s)
    (if (string=? s "^") (list "^")
      (let (c (string-index s b-colon 0))
        (if (< c 0) (list "?")
          (let (k (decimal (rest-of s (+ c 1))))
            (if (< k 0) (list "?")
              (if (string=? (substring s 0 c) "@") (list "@" k)
                (if (and (= c 64) (= (hex? (substring s 0 c)) 1)) (list "E" (substring s 0 c) k) (list "?"))))))))))
  ; one op line -> (list "i" ref side text) / (list "d" ref n) / (list "?")
  (define parse-op (lambda (line)
    (let (b (if (< (string-len line) 3) -1 (string-index line b-space 2)))
      (if (or (< b 0) (not (= (string-index line b-space 0) 1))) (list "?")
        (let (op (substring line 0 1))
          (let (ref (parse-ref (substring line 2 b)))
            (if (string=? op "d")
              (let (n (decimal (rest-of line (+ b 1))))
                (if (< n 1) (list "?") (list "d" ref n)))
              (if (and (string=? op "i") (< (+ b 3) (string-len line)) (= (string-index line b-space (+ b 1)) (+ b 2))
                       (or (string=? (substring line (+ b 1) (+ b 2)) "L") (string=? (substring line (+ b 1) (+ b 2)) "R")))
                (list "i" ref (substring line (+ b 1) (+ b 2)) (text-unescape (rest-of line (+ b 3))))
                (list "?")))))))))
  ; the op lines of a body (after its first empty line), or (list "?") with none
  (define op-lines (lambda (body)
    (let (j (if (starts-with body "\n") 0 (find-blank body 0)))
      (if (< j 0) (list "?")
        (filter (lambda (x) (< 0 (string-len x))) (split (rest-of body (+ j 1)) "\n"))))))
  (define find-blank (lambda (s i)
    (let (j (string-index s b-nl i))
      (if (< j 0) -1 (if (and (< (+ j 1) (string-len s)) (= (string-ref s (+ j 1)) b-nl)) (+ j 1) (find-blank s (+ j 1)))))))

  ; ref r names a character the model (or this event's first `count`) has -> 1/0
  (define ref-ok? (lambda (m r count)
    (if (string=? (car r) "@") (< (list-get r 1) count)
      (if (string=? (car r) "E")
        (and (= (map-has? (m-evs m) (list-get r 1)) 1) (< (list-get r 2) (vector-ref (ev-of m (list-get r 1)) 0)))
        (= 0 1)))))
  ; the ops, checked -> (list ops count) with each op's text measured, or (list "?")
  (define check-ops (lambda (m ls i count out)
    (if (= i (length ls)) (list out count)
      (let (op (parse-op (list-get ls i)))
        (if (string=? (car op) "i")
          (let (r (list-get op 1))
            (if (or (string=? (list-get op 3) "") (not (or (string=? (car r) "^") (ref-ok? m r count)))) (list "?")
              (let (n (cp-len (list-get op 3)))
                (check-ops m ls (+ i 1) (+ count n) (list-push out (list-push op n))))))
          (if (string=? (car op) "d")
            (let (r (list-get op 1))
              (if (and (ref-ok? m r count)
                       (ref-ok? m (if (string=? (car r) "@") (list "@" (+ (list-get r 1) (- (list-get op 2) 1)))
                                    (list "E" (list-get r 1) (+ (list-get r 2) (- (list-get op 2) 1)))) count))
                (check-ops m ls (+ i 1) count (list-push out op))
                (list "?")))
            (list "?")))))))

  ; ── applying an event ─────────────────────────────────────────────────
  ; a ref -> (list eid j): "^" for the root, me for this event
  (define resolve (lambda (me r)
    (if (string=? (car r) "^") (list "^" 0)
      (if (string=? (car r) "@") (list me (list-get r 1)) (list (list-get r 1) (list-get r 2))))))
  (define apply-ops (lambda (m me ops i count)
    (if (= i (length ops)) m
      (let (op (list-get ops i))
        (let (at (resolve me (list-get op 1)))
          (if (string=? (car op) "i")
            (apply-ops (do-insert m me (car at) (list-get at 1) (list-get op 2) (list-get op 3) (list-get op 4) count)
                       me ops (+ i 1) (+ count (list-get op 4)))
            (apply-ops (do-delete m (car at) (list-get at 1) (+ (list-get at 1) (list-get op 2))) me ops (+ i 1) count)))))))

  ; 1 if a body is valid against m as it stands (SPEC-text 3), else 0; m is unchanged
  (define text-valid? (lambda (m body)
    (let (ls (op-lines body))
      (if (and (= (length ls) 1) (string=? (car ls) "?")) 0
        (if (= (length (check-ops m ls 0 0 (list))) 1) 0 1)))))

  ; Changes m in place and returns it.
  (define text-apply (lambda (m id body)
    (if (or (= (map-has? (m-evs m) id) 1) (= (map-has? (m-inv m) id) 1)) m
      (let (ls (op-lines body))
        (let (c (if (and (= (length ls) 1) (string=? (car ls) "?")) (list "?") (check-ops m ls 0 0 (list))))
          (if (= (length c) 1)
            (begin (map-set! (m-inv m) id 1) (vector-push! (list-get m 3) id) m)
            (begin
              (map-set! (m-evs m) id (vector (list-get c 1) (make-vector (list-get c 1) 0)))
              (apply-ops m id (car c) 0 0))))))))

  ; ── walking the tree ──────────────────────────────────────────────────
  ; f over the nodes in text order: (f acc node) -> acc. The stack holds node
  ; numbers n to visit and -1-n to emit n.
  (define push-all (lambda (st xs i)
    (if (< i 0) st (begin (vector-push! st (list-get xs i)) (push-all st xs (- i 1))))))
  (define walk-from (lambda (m st f acc)
    (if (= (vector-length st) 0) acc
      (let (it (vector-pop! st))
        (if (< it 0) (walk-from m st f (f acc (nget m (- -1 it))))
          (let (n (nget m it))
            (begin
              (push-all st (n-rk n) (- (length (n-rk n)) 1))
              (vector-push! st (- -1 it))
              (push-all st (n-lk n) (- (length (n-lk n)) 1))
              (walk-from m st f acc))))))))
  (define walk (lambda (m f acc) (walk-from m (vector 0) f acc)))

  ; the live characters of a node, as one string
  (define live-from (lambda (n i bi out)
    (if (= i (n-len n)) (join-all out)
      (let (w (cp-width (string-ref (n-text n) bi)))
        (live-from n (+ i 1) (+ bi w)
          (if (dead? n i) out (list-push out (substring (n-text n) bi (+ bi w)))))))))
  (define live (lambda (n)
    (if (< (string-index (n-dead n) "1" 0) 0) (n-text n) (live-from n 0 0 (list)))))
  (define text-string (lambda (m)
    (joinv (walk m (lambda (acc n) (begin (if (= (n-len n) 0) 0 (vector-push! acc (live n))) acc)) (vector)))))

  (define cid (lambda (n i) (string-append (n-eid n) ":" (num->str (+ (n-k0 n) i)))))
  (define ids-from (lambda (n i out)
    (if (= i (n-len n)) out
      (begin (if (dead? n i) 0 (vector-push! out (cid n i))) (ids-from n (+ i 1) out)))))
  (define text-ids (lambda (m) (vector->list (walk m (lambda (acc n) (ids-from n 0 acc)) (vector)))))

  ; acc (vector count out)
  (define cursor-from (lambda (n i acc)
    (if (= i (n-len n)) acc
      (begin
        (if (dead? n i) 0 (vector-set! acc 0 (+ (vector-ref acc 0) 1)))
        (vector-push! (vector-ref acc 1) (list (cid n i) (vector-ref acc 0)))
        (cursor-from n (+ i 1) acc)))))
  (define text-cursor (lambda (m)
    (vector->list (vector-ref (walk m (lambda (acc n) (cursor-from n 0 acc)) (vector 0 (vector))) 1))))

  ; ── writing (SPEC-text 4) ─────────────────────────────────────────────
  ; every character in text order, tombstones too, a vector of
  ; (list eid k dead has-right)
  (define chars-from (lambda (n i out)
    (if (= i (n-len n)) out
      (begin
        (vector-push! out (list (n-eid n) (+ (n-k0 n) i) (dead? n i) (or (< i (- (n-len n) 1)) (not (null? (n-rk n))))))
        (chars-from n (+ i 1) out)))))
  (define all-chars (lambda (m) (walk m (lambda (acc n) (chars-from n 0 acc)) (vector))))
  (define ch-id (lambda (c) (string-append (list-get c 0) ":" (num->str (list-get c 1)))))

  ; scan: s (list vis L-index del-out), L-index the walk index of the visible
  ; character before pos (-1: the root); del-out the visible characters in
  ; pos..pos+del-1
  (define scan (lambda (cs i pos del vis li out)
    (if (= i (vector-length cs)) (list li out)
      (let (c (vector-ref cs i))
        (if (list-get c 2) (scan cs (+ i 1) pos del vis li out)
          (scan cs (+ i 1) pos del (+ vis 1)
                (if (= vis (- pos 1)) i li)
                (if (and (<= pos vis) (< vis (+ pos del))) (list-push out c) out)))))))
  ; the deleted characters as d lines: stretches of one event, consecutive k
  (define d-lines (lambda (ds i out start cnt)
    (if (= i (length ds))
      (if (= cnt 0) out (list-push out (string-append "d " (ch-id start) " " (num->str cnt))))
      (let (c (list-get ds i))
        (if (and (< 0 cnt) (string=? (list-get c 0) (list-get start 0)) (= (list-get c 1) (+ (list-get start 1) cnt)))
          (d-lines ds (+ i 1) out start (+ cnt 1))
          (d-lines ds (+ i 1) (if (= cnt 0) out (list-push out (string-append "d " (ch-id start) " " (num->str cnt)))) c 1))))))
  (define root-has-right (lambda (m) (not (null? (n-rk (nget m 0))))))
  (define text-edit (lambda (m pos del ins)
    (let (cs (all-chars m))
      (let (s (scan cs 0 pos del 0 -1 (list)))
        (let (ds (d-lines (list-get s 1) 0 (list) (list) 0))
          (if (string=? ins "") ds
            (let (li (car s))
              (let (has-right (if (< li 0) (root-has-right m) (list-get (vector-ref cs li) 3)))
                (let (lref (if (< li 0) "^" (ch-id (vector-ref cs li))))
                  (list-push ds
                    (if has-right
                      (string-append "i " (ch-id (vector-ref cs (+ li 1))) " L " (text-escape ins))
                      (string-append "i " lref " R " (text-escape ins)))))))))))))

  ; ── writing by diff ───────────────────────────────────────────────────
  (define prefix-len (lambda (a b i n)
    (if (or (= i n) (not (= (string-ref a i) (string-ref b i)))) i (prefix-len a b (+ i 1) n))))
  (define suffix-len (lambda (a b i n)
    (if (or (= i n) (not (= (string-ref a (- (string-len a) (+ i 1))) (string-ref b (- (string-len b) (+ i 1))))))
      i (suffix-len a b (+ i 1) n))))
  (define cont? (lambda (s i)
    (and (< i (string-len s)) (let (n (s32 (string-ref s i))) (and (<= 128 n) (< n 192))))))
  (define snap-down (lambda (s i) (if (cont? s i) (snap-down s (- i 1)) i)))
  (define snap-suffix (lambda (s n) (if (cont? s (- (string-len s) n)) (snap-suffix s (- n 1)) n)))
  ; a's common prefix and suffix with b, in bytes on code point boundaries ->
  ; (list start del ins): delete del bytes at start of a, insert ins there
  (define text-diff (lambda (a b)
    (let (p (snap-down a (prefix-len a b 0 (min (string-len a) (string-len b)))))
      (let (s (snap-suffix a (suffix-len a b 0 (- (min (string-len a) (string-len b)) p))))
        (list p (- (string-len a) (+ p s)) (substring b p (- (string-len b) s)))))))
  (define text-ops (lambda (m new)
    (let (old (text-string m))
      (let (d (text-diff old new))
        (if (and (= (list-get d 1) 0) (string=? (list-get d 2) "")) (list)
          (text-edit m (cp-len (substring old 0 (car d)))
                     (cp-len (substring old (car d) (+ (car d) (list-get d 1)))) (list-get d 2)))))))
)
