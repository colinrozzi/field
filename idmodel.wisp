; idmodel.wisp — identities (field/SPEC-id.md): each name's keys, kept in
; files so the node (store.wisp) can check authors as it admits events. It
; passes field/vectors/id/ (field/vectors/id/run). Feed it each id.* event in
; scope id/<name>, in the node's seen chain order, once, with the keys the
; node's rules list for id/ (the registrars):
;
;   (id-apply dir scope kind text author regs)  text: the canonical text
;
; and ask: id-keys, id-retired, id-may-write (may this author write in id/N
; at all: section 1, "refused"), id-key-ok (does the `id` rule admit an event
; from N by this author at this time: section 3). Under `dir`, per name:
;
;   <dir>/<name>/keys       "<key> <label>" a line: the current keys
;   <dir>/<name>/retired    "<key> <time>" a line: retired, with the retire's time
;   <dir>/<name>/ever       every key the name has had, a line each
(module idmodel
  (provide id-apply id-keys id-retired id-may-write id-key-ok id-from id-start)
  (require list "std/list.wisp")

  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define rest-of (lambda (s i) (substring s i (string-len s))))
  (define has-prefix (lambda (s p)
    (if (< (string-len s) (string-len p)) 0 (if (string=? (substring s 0 (string-len p)) p) 1 0))))
  (define read-or (lambda (p d) (match (fs-read-text p) ((ok t) t) ((err e) d))))
  (define nonempty (lambda (xs) (filter (lambda (x) (< 0 (string-len x))) xs)))
  (define split-on (lambda (s b i acc)
    (let (j (string-index s b i))
      (if (< j 0) (list-push acc (rest-of s i))
        (split-on s b (+ j 1) (list-push acc (substring s i j)))))))
  (define lines (lambda (s) (nonempty (split-on s b-nl 0 (list)))))
  (define words (lambda (s) (nonempty (split-on s b-space 0 (list)))))
  (define in? (lambda (x xs) (= (member x xs string=?) 1)))
  (define code (lambda (s i) (s32 (string-ref s i))))

  ; ^[a-z0-9][a-z0-9._-]{0,63}$
  (define name-from (lambda (s i)
    (if (= i (string-len s)) 1
      (let (c (code s i))
        (if (or (and (<= 97 c) (<= c 122)) (and (<= 48 c) (<= c 57)) (= c 46) (= c 95) (= c 45)) (name-from s (+ i 1)) 0)))))
  (define name? (lambda (s)
    (if (or (= (string-len s) 0) (< 64 (string-len s))) 0
      (let (c (code s 0)) (if (or (and (<= 97 c) (<= c 122)) (and (<= 48 c) (<= c 57))) (name-from s 1) 0)))))
  (define hex-from (lambda (s i)
    (if (= i (string-len s)) 1
      (let (c (code s i)) (if (or (and (<= 48 c) (<= c 57)) (and (<= 97 c) (<= c 102))) (hex-from s (+ i 1)) 0)))))
  (define key? (lambda (s) (if (= (string-len s) 64) (hex-from s 0) 0)))
  ; is decimal a less than decimal b?
  (define num-lt (lambda (a b)
    (if (< (string-len a) (string-len b)) 1
      (if (< (string-len b) (string-len a)) 0
        (if (string=? a b) 0 (lt-from a b 0))))))
  (define lt-from (lambda (a b i)
    (if (= (code a i) (code b i)) (lt-from a b (+ i 1)) (if (< (code a i) (code b i)) 1 0))))

  ; a canonical text's line starting with word, from i -> the rest of the
  ; text after that line (for "body ") or the line's value ("" if none)
  (define line-from (lambda (text word i body)
    (let (j (string-index text b-nl i))
      (if (< j 0) ""
        (let (line (substring text i j))
          (if (= (has-prefix line word) 1) (if (= body 1) (rest-of text (+ j 1)) (rest-of line (string-len word)))
            (if (= (has-prefix line "body ") 1) "" (line-from text word (+ j 1) body))))))))
  (define body-of (lambda (text) (line-from text "body " 0 1)))
  (define time-of (lambda (text) (let (t (line-from text "time " 0 0)) (if (string=? t "") "0" t))))
  ; a body's header lines: up to the first empty line
  (define until-blank (lambda (ls acc)
    (if (null? ls) acc (if (string=? (car ls) "") acc (until-blank (cdr ls) (list-push acc (car ls)))))))
  (define head-of (lambda (body) (until-blank (split-on body b-nl 0 (list)) (list))))
  (define hdr (lambda (ls k)
    (fold (lambda (acc l) (if (string=? acc "") (if (= (has-prefix l (string-append k " ")) 1) (rest-of l (+ 1 (string-len k))) acc) acc)) "" ls)))
  ; a body's `from` (the store calls this with an event's body)
  (define id-from (lambda (body) (hdr (head-of body) "from")))

  (define npath (lambda (dir n f) (string-append dir "/" n "/" f)))
  (define id-start (lambda (dir) (begin (fs-mkdir dir) dir)))
  ; (list (key label) ...) current; (list (key time) ...) retired
  (define id-keys (lambda (dir n) (if (= (name? n) 0) (list) (map (lambda (l) (list (car (words l)) (rest-of l (+ 1 (min-len l))))) (lines (read-or (npath dir n "keys") ""))))))
  (define min-len (lambda (l) (let (j (string-index l b-space 0)) (if (< j 0) (- (string-len l) 1) j))))
  (define id-retired (lambda (dir n) (if (= (name? n) 0) (list) (map words (lines (read-or (npath dir n "retired") ""))))))
  (define current (lambda (dir n) (map car (id-keys dir n))))
  (define ever (lambda (dir n) (if (= (name? n) 0) (list) (lines (read-or (npath dir n "ever") "")))))

  ; may `author` write in id/<n> at all (refused otherwise)?
  (define id-may-write (lambda (dir n author regs)
    (if (= (name? n) 0) 0 (if (or (in? author regs) (in? author (ever dir n))) 1 0))))

  ; does the `id` rule admit an event from n, by author, claiming time t?
  (define id-key-ok (lambda (dir n author t)
    (if (= (name? n) 0) 0
      (if (in? author (current dir n)) 1
        (fold (lambda (acc kt) (if (and (string=? (car kt) author) (= (num-lt t (list-get kt 1)) 1)) 1 acc)) 0 (id-retired dir n))))))

  ; ── applying one event (section 1, 2) ────────────────────────────────
  (define write-keys (lambda (dir n kls)
    (fs-write (npath dir n "keys") (fold (lambda (acc kl) (string-append acc (car kl) " " (list-get kl 1) "\n")) "" kls))))
  (define id-apply (lambda (dir scope kind text author regs)
    (let (n (rest-of scope 3))
      (if (or (= (has-prefix scope "id/") 0) (= (name? n) 0)) ""
        (let (ls (head-of (body-of text)))
          (let (k (hdr ls "key"))
            (let (cur (current dir n))
              (let (by (or (in? author regs) (in? author cur)))
                (if (or (= (key? k) 0) (not by)) ""
                  (begin
                    (fs-mkdir (string-append dir "/" n))
                    (if (string=? kind "id.key")
                      (if (or (in? k cur) (in? k (map car (id-retired dir n)))
                              (and (null? cur) (not (in? author regs))))
                        ""
                        (begin
                          (fs-append (npath dir n "keys") (string-append k " " (hdr ls "label") "\n"))
                          (if (in? k (ever dir n)) 0 (fs-append (npath dir n "ever") (string-append k "\n")))
                          k))
                      (if (string=? kind "id.retire")
                        (if (or (not (in? k cur)) (< (length cur) 2)) ""
                          (begin
                            (write-keys dir n (filter (lambda (kl) (not (string=? (car kl) k))) (id-keys dir n)))
                            (fs-append (npath dir n "retired") (string-append k " " (time-of text) "\n"))
                            k))
                        ""))))))))))))
)
