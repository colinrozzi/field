; groupmodel.wisp — the groups of field/SPEC-group.md, kept in files so a
; long-running reader can add one event at a time. mailmodel.wisp keeps one
; (so push.wisp has groups too); it passes field/vectors/group/
; (field/vectors/group/run). Feed it each event in scope group/<g>, in the
; node's seen chain order, once:
;
;   (group-add dir id scope kind text)  text: the canonical text (no sig line)
;
; and ask: group-direct, group-members (effective, through nesting),
; group-open?. Under `dir`, for each group g:
;
;   <dir>/<g>/m       its direct members, "<who> <role>" a line (who: a name or group/<h>)
;   <dir>/<g>/open    "yes" or "no"
;   <dir>/<g>/ever    exists once the group has had a member
(module groupmodel
  (provide group-add group-direct group-members group-open? group-start)
  (require list "std/list.wisp")
  (require chatmodel "experiment/field/chatmodel.wisp")

  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define rest-of (lambda (s i) (substring s i (string-len s))))
  (define has-prefix (lambda (s p)
    (if (< (string-len s) (string-len p)) 0 (if (string=? (substring s 0 (string-len p)) p) 1 0))))
  (define read-or (lambda (p d) (match (fs-read-text p) ((ok t) t) ((err e) d))))
  (define fs-exists-1 (lambda (p) (match (fs-exists p) ((ok v) (if v 1 0)) ((err e) 0))))
  (define nonempty (lambda (xs) (filter (lambda (x) (< 0 (string-len x))) xs)))
  (define split-on (lambda (s b i acc)
    (let (j (string-index s b i))
      (if (< j 0) (list-push acc (rest-of s i))
        (split-on s b (+ j 1) (list-push acc (substring s i j)))))))
  (define lines (lambda (s) (nonempty (split-on s b-nl 0 (list)))))
  (define words (lambda (s) (nonempty (split-on s b-space 0 (list)))))
  (define in? (lambda (x xs) (= (member x xs string=?) 1)))

  (define rank (lambda (r) (if (string=? r "admin") 3 (if (string=? r "write") 2 (if (string=? r "read") 1 0)))))
  (define lower (lambda (a b) (if (< (rank a) (rank b)) a b)))
  ; an association list of (key value): its value for k, or ""
  (define get (lambda (al k) (fold (lambda (acc kv) (if (string=? (car kv) k) (list-get kv 1) acc)) "" al)))
  (define put (lambda (al k v)
    (if (string=? (get al k) "") (list-push al (list k v))
      (map (lambda (kv) (if (string=? (car kv) k) (list k v) kv)) al))))
  (define drop (lambda (al k) (filter (lambda (kv) (not (string=? (car kv) k))) al)))

  (define gpath (lambda (dir g f) (string-append dir "/" g "/" f)))
  (define group-start (lambda (dir) (begin (fs-mkdir dir) dir)))
  (define exists? (lambda (dir g) (if (= (chat-name? g) 0) 0 (fs-exists-1 (gpath dir g "ever")))))

  ; (list (who role) ...), in the order they were added
  (define group-direct (lambda (dir g)
    (if (= (chat-name? g) 0) (list)
      (map (lambda (l) (words l)) (lines (read-or (gpath dir g "m") ""))))))
  (define group-open? (lambda (dir g) (if (string=? (read-or (gpath dir g "open") "") "yes") 1 0)))

  ; effective members (3): (list (name role) ...); path: the groups on the way here
  (define members-on (lambda (dir g path)
    (if (or (in? g path) (= (exists? dir g) 0)) (list)
      (fold (lambda (acc wr)
              (fold (lambda (a nr) (if (< (rank (get a (car nr))) (rank (list-get nr 1))) (put a (car nr) (list-get nr 1)) a))
                    acc
                    (if (= (has-prefix (car wr) "group/") 1)
                      (map (lambda (nr) (list (car nr) (lower (list-get wr 1) (list-get nr 1))))
                           (members-on dir (rest-of (car wr) 6) (cons g path)))
                      (list wr))))
            (list) (group-direct dir g)))))
  (define group-members (lambda (dir g) (members-on dir g (list))))
  (define has-admin (lambda (al) (fold (lambda (acc nr) (if (string=? (list-get nr 1) "admin") 1 acc)) 0 al)))

  (define write-direct (lambda (dir g al)
    (fs-write (gpath dir g "m") (fold (lambda (acc wr) (string-append acc (car wr) " " (list-get wr 1) "\n")) "" al))))

  ; ── adding one event (2) ──────────────────────────────────────────────
  (define who-ok (lambda (w) (if (= (chat-name? w) 1) 1 (if (= (has-prefix w "group/") 1) (chat-name? (rest-of w 6)) 0))))
  (define group-add (lambda (dir id scope kind text)
    (let (g (rest-of scope 6))
      (let (h (list-get (chat-headers (list-get (chat-canon text) 2)) 0))
        (let (who (chat-hdr h "who"))
          (let (from (chat-hdr h "from"))
            (let (role (if (string=? (chat-hdr h "role") "") "write" (chat-hdr h "role")))
              (let (op (chat-hdr h "open"))
                (if (or (= (has-prefix scope "group/") 0) (= (chat-name? g) 0)
                        (not (or (string=? kind "group.add") (string=? kind "group.remove") (string=? kind "group.open")))
                        (and (not (string=? kind "group.open")) (= (who-ok who) 0))
                        (and (string=? kind "group.add") (= (rank role) 0))
                        (and (string=? kind "group.open") (not (or (string=? op "yes") (string=? op "no")))))
                  ""
                  (begin
                    (fs-mkdir (string-append dir "/" g))
                    (apply-event dir g kind who from role op)))))))))))

  (define apply-event (lambda (dir g kind who from role op)
    (let (first (if (= (exists? dir g) 0) 1 0))
      (if (and (= first 1) (= (chat-name? from) 0)) ""
        (let (start (if (= first 1) (list (list from "admin")) (group-direct dir g)))
          (if (and (= first 0)
                   (not (string=? (get (group-members dir g) from) "admin"))
                   (not (and (= (group-open? dir g) 1) (string=? who from)
                             (or (string=? kind "group.remove") (<= (rank role) 2)))))
            ""
            (let (next (if (string=? kind "group.add") (put start who role)
                         (if (string=? kind "group.remove") (drop start who) start)))
              (begin
                (write-direct dir g next)
                (fs-write (gpath dir g "ever") "1")
                (if (= (has-admin (group-members dir g)) 0)
                  (begin (write-direct dir g start) "")
                  (begin (if (string=? kind "group.open") (fs-write (gpath dir g "open") op) 0) g))))))))))
)
