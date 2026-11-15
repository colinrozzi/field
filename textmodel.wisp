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
; inserting next to any other character splits the node first. A model is
;
;   (list nodes evs eids invalid)
;   nodes  a vector (below) of (list eid k0 len text dead lk rk); node 0 is the
;          root ^. dead: "0"/"1" per character (1 a tombstone); lk, rk: node
;          numbers, each ordered by the first character's id (E, then k).
;   evs    a vector, parallel to eids, of (list len runs): the event's text
;          length and its nodes, by k0
;   eids   the applied events' ids, in the order applied
;   invalid  the ignored events' ids
(module textmodel
  (provide text-new text-apply text-string text-ids text-cursor text-invalid
           text-edit text-ops text-diff text-escape text-unescape cp-len cp-sub num->str)
  (require list "std/list.wisp")
  (require str "std/str.wisp")

  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define b-bs (string-ref "\\" 0))
  (define b-n (string-ref "n" 0))
  (define b-colon (string-ref ":" 0))
  (define rest-of (lambda (s i) (substring s i (string-len s))))
  (define min (lambda (a b) (if (< a b) a b)))
  (define max (lambda (a b) (if (< a b) b a)))
  (define mod (lambda (a b) (- a (* b (/ a b)))))
  (define num->str (lambda (n)
    (if (< n 10) (substring "0123456789" n (+ n 1)) (digits-of n ""))))
  (define digits-of (lambda (n acc)
    (if (= n 0) acc (digits-of (/ n 10) (string-append (substring "0123456789" (mod n 10) (+ (mod n 10) 1)) acc)))))

  ; ── code points ───────────────────────────────────────────────────────
  (define cp-width (lambda (b)
    (let (n (s32 b)) (if (< n 128) 1 (if (< n 224) 2 (if (< n 240) 3 4))))))
  (define cp-byte-from (lambda (s k i)
    (if (or (= k 0) (>= i (string-len s))) i
      (cp-byte-from s (- k 1) (+ i (cp-width (string-ref s i)))))))
  ; the byte index of code point k in s
  (define cp-byte (lambda (s k) (cp-byte-from s k 0)))
  (define cp-len-from (lambda (s i n)
    (if (>= i (string-len s)) n (cp-len-from s (+ i (cp-width (string-ref s i))) (+ n 1)))))
  (define cp-len (lambda (s) (cp-len-from s 0 0)))
  ; code points a..b of s
  (define cp-sub (lambda (s a b)
    (let (i (cp-byte s a)) (substring s i (+ i (cp-byte (rest-of s i) (- b a)))))))

  ; ── strings ───────────────────────────────────────────────────────────
  ; join a list of strings by pairs, so each byte is copied log n times
  (define pairs-from (lambda (xs i out)
    (if (>= i (length xs)) out
      (if (= (+ i 1) (length xs)) (list-push out (list-get xs i))
        (pairs-from xs (+ i 2) (list-push out (string-append (list-get xs i) (list-get xs (+ i 1)))))))))
  (define join-all (lambda (xs)
    (if (null? xs) "" (if (= (length xs) 1) (car xs) (join-all (pairs-from xs 0 (list)))))))
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

  ; ── vectors ───────────────────────────────────────────────────────────
  ; A list with O(log n) get and set until Wisp has its own (ticket 0121): a
  ; tree of lists, 32 wide. (list depth size root); a leaf is a list of items.
  (define W 32)
  (define pow32 (list 1 32 1024 32768 1048576 33554432))
  (define vec-new (lambda () (list 1 0 (list))))
  (define vec-size (lambda (v) (list-get v 1)))
  (define slot (lambda (i lvl) (mod (/ i (list-get pow32 lvl)) W)))
  (define vec-get-from (lambda (node i lvl)
    (if (= lvl 0) (list-get node (slot i 0)) (vec-get-from (list-get node (slot i lvl)) i (- lvl 1)))))
  (define vec-get (lambda (v i) (vec-get-from (list-get v 2) i (- (list-get v 0) 1))))
  (define replace-from (lambda (xs j x i out)
    (if (= i (length xs)) out
      (replace-from xs j x (+ i 1) (list-push out (if (= i j) x (list-get xs i)))))))
  ; xs with item j x (j = its length: x appended)
  (define put (lambda (xs j x) (if (= j (length xs)) (list-push xs x) (replace-from xs j x 0 (list)))))
  ; depth is at most 6, so this recursion is shallow
  (define vec-put (lambda (node i lvl x)
    (if (= lvl 0) (put node (slot i 0) x)
      (let (j (slot i lvl))
        (put node j (vec-put (if (< j (length node)) (list-get node j) (list)) i (- lvl 1) x))))))
  (define vec-set (lambda (v i x)
    (list (list-get v 0) (list-get v 1) (vec-put (list-get v 2) i (- (list-get v 0) 1) x))))
  (define vec-push (lambda (v x)
    (let (g (if (= (list-get v 1) (list-get pow32 (list-get v 0)))
              (list (+ (list-get v 0) 1) (list-get v 1) (list (list-get v 2))) v))
      (list (list-get g 0) (+ (list-get g 1) 1) (vec-put (list-get g 2) (list-get g 1) (- (list-get g 0) 1) x)))))

  ; ── the model ─────────────────────────────────────────────────────────
  (define node (lambda (eid k0 len text dead lk rk) (list eid k0 len text dead lk rk)))
  (define n-eid (lambda (n) (list-get n 0)))
  (define n-k0 (lambda (n) (list-get n 1)))
  (define n-len (lambda (n) (list-get n 2)))
  (define n-text (lambda (n) (list-get n 3)))
  (define n-dead (lambda (n) (list-get n 4)))
  (define n-lk (lambda (n) (list-get n 5)))
  (define n-rk (lambda (n) (list-get n 6)))

  (define text-new (lambda ()
    (list (vec-push (vec-new) (node "^" 0 0 "" "" (list) (list))) (vec-new) (list) (list))))
  (define m-nodes (lambda (m) (list-get m 0)))
  (define m-evs (lambda (m) (list-get m 1)))
  (define m-eids (lambda (m) (list-get m 2)))
  (define text-invalid (lambda (m) (list-get m 3)))

  (define index-from (lambda (xs x i)
    (if (= i (length xs)) -1 (if (string=? (list-get xs i) x) i (index-from xs x (+ i 1))))))
  ; the event's number in evs, or -1 if it isn't applied
  (define ev-index (lambda (m eid) (index-from (m-eids m) eid 0)))
  (define ev-len (lambda (m ei) (list-get (vec-get (m-evs m) ei) 0)))

  ; node a's first character before node b's, by id
  (define before? (lambda (nodes a b)
    (let (x (vec-get nodes a))
      (let (y (vec-get nodes b))
        (let (c (str-cmp (n-eid x) (n-eid y)))
          (if (= c 0) (< (n-k0 x) (n-k0 y)) (< c 0)))))))
  ; kids with node x in its place
  (define insert-kid-from (lambda (nodes kids x i out done)
    (if (= i (length kids)) (if done out (list-push out x))
      (if (and (not done) (before? nodes x (list-get kids i)))
        (insert-kid-from nodes kids x (+ i 1) (list-push (list-push out x) (list-get kids i)) 1)
        (insert-kid-from nodes kids x (+ i 1) (list-push out (list-get kids i)) done)))))
  (define insert-kid (lambda (nodes kids x) (insert-kid-from nodes kids x 0 (list) (= 0 1))))

  ; the node holding character j of event ei: a binary search of its runs
  (define find-run (lambda (m ei j)
    (let (runs (list-get (vec-get (m-evs m) ei) 1))
      (search-runs (m-nodes m) runs j 0 (- (length runs) 1)))))
  (define search-runs (lambda (nodes runs j lo hi)
    (let (mid (/ (+ lo hi) 2))
      (let (n (vec-get nodes (list-get runs mid)))
        (if (or (>= lo hi) (and (<= (n-k0 n) j) (< j (+ (n-k0 n) (n-len n))))) (list-get runs mid)
          (if (< j (n-k0 n)) (search-runs nodes runs j lo (- mid 1)) (search-runs nodes runs j (+ mid 1) hi)))))))
  ; runs with node b just after node a
  (define runs-after-from (lambda (runs a b i out)
    (if (= i (length runs)) out
      (runs-after-from runs a b (+ i 1)
        (if (= (list-get runs i) a) (list-push (list-push out a) b) (list-push out (list-get runs i)))))))
  (define set-runs (lambda (m ei f)
    (let (ev (vec-get (m-evs m) ei))
      (list (m-nodes m) (vec-set (m-evs m) ei (list (list-get ev 0) (f (list-get ev 1)))) (m-eids m) (text-invalid m)))))
  (define set-nodes (lambda (m nodes) (list nodes (m-evs m) (m-eids m) (text-invalid m))))

  ; split node a so that its character `off` (from its start) begins a new
  ; node b, the right child of a's last character -> (list m b)
  (define split-node (lambda (m a off)
    (let (n (vec-get (m-nodes m) a))
      (let (b (vec-size (m-nodes m)))
        (let (cut (cp-byte (n-text n) off))
          (let (nodes (vec-push (m-nodes m)
                        (node (n-eid n) (+ (n-k0 n) off) (- (n-len n) off) (rest-of (n-text n) cut)
                              (rest-of (n-dead n) off) (list) (n-rk n))))
            (let (nodes (vec-set nodes a (node (n-eid n) (n-k0 n) off (substring (n-text n) 0 cut)
                                               (substring (n-dead n) 0 off) (n-lk n) (list b))))
              (list (set-runs (set-nodes m nodes) (ev-index m (n-eid n)) (lambda (rs) (runs-after-from rs a b 0 (list))))
                    b))))))))

  ; the node and side a new child of character (ei, j) hangs from -> (list m node side);
  ; ei -1 is the root
  (define attach-point (lambda (m ei j side)
    (if (< ei 0) (list m 0 side)
      (let (a (find-run m ei j))
        (let (n (vec-get (m-nodes m) a))
          (let (off (- j (n-k0 n)))
            (if (string=? side "R")
              (if (= off (- (n-len n) 1)) (list m a "R")
                (let (s (split-node m a (+ off 1))) (list (car s) a "R")))
              (if (= off 0) (list m a "L")
                (let (s (split-node m a off)) (list (car s) (list-get s 1) "L"))))))))))

  (define add-kid (lambda (nodes p side x)
    (let (n (vec-get nodes p))
      (vec-set nodes p
        (if (string=? side "L")
          (node (n-eid n) (n-k0 n) (n-len n) (n-text n) (n-dead n) (insert-kid nodes (n-lk n) x) (n-rk n))
          (node (n-eid n) (n-k0 n) (n-len n) (n-text n) (n-dead n) (n-lk n) (insert-kid nodes (n-rk n) x)))))))

  ; insert text (len code points) as characters (eid, k0..), its first the
  ; side child of character (ei, j) of the model -> the model
  (define do-insert (lambda (m me ei j side text len k0)
    (let (at (attach-point m ei j side))
      (let (m (car at))
        (let (x (vec-size (m-nodes m)))
          (let (nodes (vec-push (m-nodes m) (node (list-get (m-eids m) me) k0 len text (repeat "0" len) (list) (list))))
            (set-runs (set-nodes m (add-kid nodes (list-get at 1) (list-get at 2) x)) me
                      (lambda (rs) (list-push rs x)))))))))

  ; mark characters k .. k+cnt-1 of event ei deleted
  (define mark-dead (lambda (dead a b) (string-append (substring dead 0 a) (repeat "1" (- b a)) (rest-of dead b))))
  (define delete-runs (lambda (m runs k end i)
    (if (= i (length runs)) m
      (let (n (vec-get (m-nodes m) (list-get runs i)))
        (let (a (max k (n-k0 n)))
          (let (b (min end (+ (n-k0 n) (n-len n))))
            (delete-runs
              (if (< a b)
                (set-nodes m (vec-set (m-nodes m) (list-get runs i)
                               (node (n-eid n) (n-k0 n) (n-len n) (n-text n)
                                     (mark-dead (n-dead n) (- a (n-k0 n)) (- b (n-k0 n))) (n-lk n) (n-rk n))))
                m)
              runs k end (+ i 1))))))))
  (define do-delete (lambda (m ei k cnt)
    (delete-runs m (list-get (vec-get (m-evs m) ei) 1) k (+ k cnt) 0)))

  ; ── parsing and checking an event ─────────────────────────────────────
  (define hex? (lambda (s i)
    (if (= i (string-len s)) 1
      (let (c (s32 (string-ref s i)))
        (if (or (and (<= 48 c) (<= c 57)) (and (<= 97 c) (<= c 102))) (hex? s (+ i 1)) 0)))))
  ; a decimal without leading zeros -> it, or -1
  (define digits? (lambda (s i)
    (if (= i (string-len s)) 1
      (let (c (s32 (string-ref s i))) (if (and (<= 48 c) (<= c 57)) (digits? s (+ i 1)) 0)))))
  (define decimal (lambda (s)
    (if (or (= (string-len s) 0) (= (digits? s 0) 0) (and (< 1 (string-len s)) (string=? (substring s 0 1) "0"))) -1
      (string->number s))))
  ; "^", "@:k" or "E:k" -> (list "^") (list "@" k) (list "E" eid k), or (list "?")
  (define parse-ref (lambda (s)
    (if (string=? s "^") (list "^")
      (let (c (string-index s b-colon 0))
        (if (< c 0) (list "?")
          (let (k (decimal (rest-of s (+ c 1))))
            (if (< k 0) (list "?")
              (if (string=? (substring s 0 c) "@") (list "@" k)
                (if (and (= c 64) (= (hex? (substring s 0 c) 0) 1)) (list "E" (substring s 0 c) k) (list "?"))))))))))
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
        (let (ei (ev-index m (list-get r 1))) (and (<= 0 ei) (< (list-get r 2) (ev-len m ei))))
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
  ; a ref -> (list ei j): ei -1 for the root, me for this event
  (define resolve (lambda (m me r)
    (if (string=? (car r) "^") (list -1 0)
      (if (string=? (car r) "@") (list me (list-get r 1))
        (list (ev-index m (list-get r 1)) (list-get r 2))))))
  (define apply-ops (lambda (m me ops i count)
    (if (= i (length ops)) m
      (let (op (list-get ops i))
        (let (at (resolve m me (list-get op 1)))
          (if (string=? (car op) "i")
            (apply-ops (do-insert m me (car at) (list-get at 1) (list-get op 2) (list-get op 3) (list-get op 4) count)
                       me ops (+ i 1) (+ count (list-get op 4)))
            (apply-ops (do-delete m (car at) (list-get at 1) (list-get op 2)) me ops (+ i 1) count)))))))

  (define text-apply (lambda (m id body)
    (if (or (<= 0 (ev-index m id)) (= (member id (text-invalid m) string=?) 1)) m
      (let (ls (op-lines body))
        (let (c (if (and (= (length ls) 1) (string=? (car ls) "?")) (list "?") (check-ops m ls 0 0 (list))))
          (if (= (length c) 1)
            (list (m-nodes m) (m-evs m) (m-eids m) (list-push (text-invalid m) id))
            (let (me (length (m-eids m)))
              (apply-ops (list (m-nodes m) (vec-push (m-evs m) (list (list-get c 1) (list))) (list-push (m-eids m) id) (text-invalid m))
                         me (car c) 0 0))))))))

  ; ── walking the tree ──────────────────────────────────────────────────
  ; f over the nodes in text order: (f acc node) -> acc. The stack is a chain
  ; of (list item rest), item a node number n to visit, or -1-n to emit n.
  (define push-all (lambda (st xs i)
    (if (< i 0) st (push-all (list (list-get xs i) st) xs (- i 1)))))
  (define walk-from (lambda (nodes st f acc)
    (if (null? st) acc
      (let (it (car st))
        (if (< it 0)
          (walk-from nodes (list-get st 1) f (f acc (vec-get nodes (- -1 it))))
          (let (n (vec-get nodes it))
            (walk-from nodes
              (push-all (list (- -1 it) (push-all (list-get st 1) (n-rk n) (- (length (n-rk n)) 1)))
                        (n-lk n) (- (length (n-lk n)) 1))
              f acc)))))))
  (define walk (lambda (m f acc) (walk-from (m-nodes m) (list 0 (list)) f acc)))

  ; the live characters of a node, as one string
  (define live-from (lambda (n i bi out)
    (if (= i (n-len n)) (join-all out)
      (let (w (cp-width (string-ref (n-text n) bi)))
        (live-from n (+ i 1) (+ bi w)
          (if (string=? (substring (n-dead n) i (+ i 1)) "0") (list-push out (substring (n-text n) bi (+ bi w))) out))))))
  (define live (lambda (n)
    (if (< (string-index (n-dead n) "1" 0) 0) (n-text n) (live-from n 0 0 (list)))))
  (define text-string (lambda (m)
    (join-all (walk m (lambda (acc n) (if (= (n-len n) 0) acc (list-push acc (live n)))) (list)))))

  (define cid (lambda (n i) (string-append (n-eid n) ":" (num->str (+ (n-k0 n) i)))))
  (define ids-from (lambda (n i out)
    (if (= i (n-len n)) out
      (ids-from n (+ i 1) (if (string=? (substring (n-dead n) i (+ i 1)) "0") (list-push out (cid n i)) out)))))
  (define text-ids (lambda (m) (walk m (lambda (acc n) (ids-from n 0 acc)) (list))))

  ; acc (list count out)
  (define cursor-from (lambda (n i acc)
    (if (= i (n-len n)) acc
      (let (c (if (string=? (substring (n-dead n) i (+ i 1)) "0") (+ (car acc) 1) (car acc)))
        (cursor-from n (+ i 1) (list c (list-push (list-get acc 1) (list (cid n i) c))))))))
  (define text-cursor (lambda (m) (list-get (walk m (lambda (acc n) (cursor-from n 0 acc)) (list 0 (list))) 1)))

  ; ── writing (SPEC-text 4) ─────────────────────────────────────────────
  ; every character in text order, tombstones too: (list id dead has-right)
  (define chars-from (lambda (n i out)
    (if (= i (n-len n)) out
      (chars-from n (+ i 1)
        (list-push out (list (n-eid n) (+ (n-k0 n) i) (string=? (substring (n-dead n) i (+ i 1)) "1")
                             (or (< i (- (n-len n) 1)) (not (null? (n-rk n))))))))))
  (define all-chars (lambda (m) (walk m (lambda (acc n) (chars-from n 0 acc)) (list))))
  (define ch-id (lambda (c) (string-append (list-get c 0) ":" (num->str (list-get c 1)))))

  ; scan: s (list vis L-index del-out), L-index the walk index of the visible
  ; character before pos (-1: the root); del-out the visible characters in
  ; pos..pos+del-1
  (define scan (lambda (cs i pos del vis li out)
    (if (= i (length cs)) (list li out)
      (let (c (list-get cs i))
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
  (define root-has-right (lambda (m) (not (null? (n-rk (vec-get (m-nodes m) 0))))))
  (define text-edit (lambda (m pos del ins)
    (let (cs (all-chars m))
      (let (s (scan cs 0 pos del 0 -1 (list)))
        (let (ds (d-lines (list-get s 1) 0 (list) (list) 0))
          (if (string=? ins "") ds
            (let (li (car s))
              (let (has-right (if (< li 0) (root-has-right m) (list-get (list-get cs li) 3)))
                (let (lref (if (< li 0) "^" (ch-id (list-get cs li))))
                  (list-push ds
                    (if has-right
                      (string-append "i " (ch-id (list-get cs (+ li 1))) " L " (text-escape ins))
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
