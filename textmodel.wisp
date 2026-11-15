; textmodel.wisp — the live-document text model (doc/live-docs; field/SPEC-text.md):
; Fugue on doc.ops events. Pure: no files, no network; docs.wisp keeps the
; models and talks to the store. Checked by field/vectors/text/run.
;
;   (text-new)                     an empty model
;   (text-apply m id body)         -> m with doc.ops event `id` applied (body: its text)
;   (text-string m)                -> the document's text
;   (text-ops m old new)           -> the op lines that turn text `old` (m's) into `new`
;   (text-save m) / (text-load s)  a model to text and back (docs.wisp's files)
;
; A doc.ops body is header lines ("from NAME"), a blank line, then one op per
; line (SPEC-text.md):
;
;   i <P> <L|R> <text>       insert <text>: its first character the L or R child
;                            of character P, each next one the right child of the last
;   d <E:k> <n>              delete E:k .. E:k+n-1, all from event E
;
; A character id is E:k: event E's k-th inserted character, counting code points
; across all of E's inserts in line order. @:k is this same event's, and ^ the
; document's start (the root). Text escapes \n and \\ only.

; Every walk is a tail loop: a document can be many thousand runs, and each
; non-tail level counts against the evaluator's nesting limit.
;
; The model is a list of runs in document order, each
;   (list id parent side text dead)
; id "E:k" (its first character), parent a character id or "-", side "L"/"R",
; text the run's characters, dead a string of "0"/"1" the same length
; (1: deleted, kept as a tombstone).
(module textmodel
  (provide text-new text-apply text-string text-ops text-save text-load
           text-parse text-escape text-unescape text-diff)
  (require list "std/list.wisp")
  (require str "std/str.wisp")

  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define b-bs (string-ref "\\" 0))
  (define b-n (string-ref "n" 0))
  (define rest-of (lambda (s i) (substring s i (string-len s))))
  (define min (lambda (a b) (if (< a b) a b)))

  ; ── escapes ───────────────────────────────────────────────────────────
  (define escape-from (lambda (s i out)
    (if (= i (string-len s)) out
      (let (c (substring s i (+ i 1)))
        (escape-from s (+ i 1)
          (string-append out (if (string=? c "\n") "\\n" (if (string=? c "\\") "\\\\" c))))))))
  (define text-escape (lambda (s) (escape-from s 0 "")))
  (define unescape-from (lambda (s i out)
    (if (>= i (string-len s)) out
      (if (and (= (string-ref s i) b-bs) (< (+ i 1) (string-len s)))
        (unescape-from s (+ i 2)
          (string-append out (if (= (string-ref s (+ i 1)) b-n) "\n" (substring s (+ i 1) (+ i 2)))))
        (unescape-from s (+ i 1) (string-append out (substring s i (+ i 1))))))))
  (define text-unescape (lambda (s) (unescape-from s 0 "")))

  ; ── parsing a body ────────────────────────────────────────────────────
  (define split-on (lambda (s b i acc)
    (let (j (string-index s b i))
      (if (< j 0) (list-push acc (rest-of s i))
        (split-on s b (+ j 1) (list-push acc (substring s i j)))))))
  ; one op line -> (list "i" ref side text) / (list "d" ref n) / (list "?" line)
  (define parse-op (lambda (line)
    (let (a (string-index line b-space 0))
      (let (b (if (< a 0) -1 (string-index line b-space (+ a 1))))
        (if (< b 0) (list "?" line)
          (let (op (substring line 0 a))
            (let (ref (substring line (+ a 1) b))
              (if (string=? op "d")
                (list "d" ref (string->number (rest-of line (+ b 1))))
                (if (and (string=? op "i") (= (string-index line b-space (+ b 1)) (+ b 2))
                         (< (+ b 3) (string-len line)))
                  (list "i" ref (substring line (+ b 1) (+ b 2)) (text-unescape (rest-of line (+ b 3))))
                  (list "?" line))))))))))
  ; the header lines before the first blank line -> (list headers rest-index)
  (define headers-from (lambda (body i acc)
    (let (j (string-index body b-nl i))
      (if (< j 0) (list (list-push acc (rest-of body i)) (string-len body))
        (if (= j i) (list acc (+ j 1))
          (headers-from body (+ j 1) (list-push acc (substring body i j))))))))
  (define header (lambda (hs name)
    (fold (lambda (v h) (if (and (string=? v "") (starts-with h (string-append name " ")))
                          (rest-of h (+ (string-len name) 1)) v))
          "" hs)))
  ; a body -> (list from ops)
  (define text-parse (lambda (body)
    (let (h (headers-from body 0 (list)))
      (list (header (car h) "from")
            (map parse-op (filter (lambda (x) (< 0 (string-len x)))
                                  (split-on (rest-of body (list-get h 1)) b-nl 0 (list))))))))

  ; ── the model ─────────────────────────────────────────────────────────
  (define text-new (lambda () (list)))

  (define live-from (lambda (t dead i out)
    (if (= i (string-len t)) out
      (live-from t dead (+ i 1)
        (if (string=? (substring dead i (+ i 1)) "0") (string-append out (substring t i (+ i 1))) out)))))
  (define text-string (lambda (m)
    (fold (lambda (acc r) (live-from (list-get r 3) (list-get r 4) 0 acc)) "" m)))

  ; TODO(0122): placement and deletion follow ada's SPEC-text.md (siblings by
  ; id, splitting a run when a ref falls inside it, @n refs).
  (define text-apply (lambda (m id body) m))

  ; ── writing by diff ───────────────────────────────────────────────────
  ; the common prefix and suffix of a and b -> (list start del ins):
  ; delete `del` characters at `start` of a, insert `ins` there
  (define prefix-len (lambda (a b i n)
    (if (or (= i n) (not (= (string-ref a i) (string-ref b i)))) i (prefix-len a b (+ i 1) n))))
  (define suffix-len (lambda (a b i n)
    (if (or (= i n) (not (= (string-ref a (- (string-len a) (+ i 1))) (string-ref b (- (string-len b) (+ i 1))))))
      i (suffix-len a b (+ i 1) n))))
  (define text-diff (lambda (a b)
    (let (p (prefix-len a b 0 (min (string-len a) (string-len b))))
      (let (s (suffix-len a b 0 (- (min (string-len a) (string-len b)) p)))
        (list p (- (string-len a) (+ p s)) (substring b p (- (string-len b) s)))))))

  ; TODO(0122): the diff as op lines, with the character ids at its ends.
  (define text-ops (lambda (m old new) (list)))

  ; ── saving ────────────────────────────────────────────────────────────
  ; one run per line: id parent side dead escaped-text
  (define text-save (lambda (m)
    (fold (lambda (acc r)
            (string-append acc (list-get r 0) " " (list-get r 1) " " (list-get r 2) " "
                           (list-get r 4) " " (text-escape (list-get r 3)) "\n"))
          "" m)))
  (define load-run (lambda (line)
    (let (w (split-on line b-space 0 (list)))
      (list (list-get w 0) (list-get w 1) (list-get w 2)
            (text-unescape (rest-of line (+ 4 (fold (lambda (n x) (+ n (string-len x))) 0 (list (list-get w 0) (list-get w 1) (list-get w 2) (list-get w 3))))))
            (list-get w 3)))))
  (define text-load (lambda (s)
    (map load-run (filter (lambda (x) (< 0 (string-len x))) (split-on s b-nl 0 (list))))))
)
