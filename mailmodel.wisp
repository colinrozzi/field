; mailmodel.wisp — the mailbox of field/SPEC-mailbox.md, kept in files so a
; long-running reader (site/push.wisp) can add one event at a time. It
; passes field/vectors/mail/ (field/vectors/mail/run). Feed it every event in
; the node's seen chain order, once, from every scope; it keeps the chat
; model (chatmodel.wisp) in <dir>/chat itself:
;
;   (mail-add dir id scope kind text)  text: the canonical text (no sig line)
;                                      -> the names it is addressed to, or (list)
;
; and ask: mail-box, mail-unread, mail-mark; mail-to gives a text's `to`
; names (push.wisp pushes only chat.msg or an explicit to). Under `dir`:
;
;   <dir>/n                 events received so far (positions count from 1)
;   <dir>/p/<id>            that event's position
;   <dir>/box/<name>        ids addressed to name, one per line, in arrival order
;   <dir>/mark/<name>       "<pos> <id>": the newest mail.read's upto (3)
;   <dir>/pend/<id>         names whose mail.read names id, not yet received
(module mailmodel
  (provide mail-add mail-box mail-unread mail-mark mail-to mail-start)
  (require list "std/list.wisp")
  (require chatmodel "experiment/field/chatmodel.wisp")

  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define b-at (string-ref "@" 0))
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
  (define set-of (lambda (p) (lines (read-or p ""))))
  ; xs then the ys not already in it
  (define union (lambda (xs ys) (fold (lambda (acc y) (if (in? y acc) acc (list-push acc y))) xs ys)))

  (define range-list (lambda (i n acc) (if (>= i n) acc (range-list (+ i 1) n (list-push acc i)))))
  (define str->num (lambda (s) (fold (lambda (acc i) (+ (* acc 10) (- (code s i) 48))) 0 (range-list 0 (string-len s) (list)))))
  (define num->str (lambda (n)
    (if (< n 10) (substring "0123456789" n (+ n 1))
      (string-append (num->str (/ n 10)) (num->str (- n (* 10 (/ n 10))))))))

  (define chat-dir (lambda (dir) (string-append dir "/chat")))
  (define ppath (lambda (dir id) (string-append dir "/p/" id)))
  (define pos-of (lambda (dir id) (let (s (read-or (ppath dir id) "")) (if (string=? s "") 0 (str->num s)))))

  (define mail-start (lambda (dir)
    (begin (fs-mkdir dir) (chat-start (chat-dir dir))
           (fs-mkdir (string-append dir "/p")) (fs-mkdir (string-append dir "/box"))
           (fs-mkdir (string-append dir "/mark")) (fs-mkdir (string-append dir "/pend")) dir)))

  ; ── addressing (1, 2) ─────────────────────────────────────────────────
  ; a body's `to` names
  (define mail-to (lambda (body)
    (filter (lambda (w) (= (chat-name? w) 1))
      (words (chat-hdr (list-get (chat-headers body) 0) "to")))))

  ; the names text @-mentions: every name-shaped prefix after an @ that
  ; chat-mentions? accepts (so "@ada." gives ada)
  (define code (lambda (s i) (s32 (string-ref s i))))
  (define name-char (lambda (c) (or (and (<= 97 c) (<= c 122)) (and (<= 48 c) (<= c 57)) (= c 46) (= c 95) (= c 45))))
  (define name-run (lambda (s i) (if (< i (string-len s)) (if (name-char (code s i)) (name-run s (+ i 1)) i) i)))
  (define prefixes (lambda (s n acc) (if (< (string-len s) n) acc (prefixes s (+ n 1) (list-push acc (substring s 0 n))))))
  (define mentions-from (lambda (text i acc)
    (let (j (string-index text b-at i))
      (if (< j 0) acc
        (let (run (substring text (+ j 1) (name-run text (+ j 1))))
          (mentions-from text (+ j 1)
            (union acc (filter (lambda (n) (and (= (chat-name? n) 1) (= (chat-mentions? text n) 1)))
                               (prefixes (if (< 64 (string-len run)) (substring run 0 64) run) 1 (list))))))))))

  ; chat's rule (2): a chat.msg the chat model added
  (define chat-rule (lambda (dir id)
    (let (m (chat-msg (chat-dir dir) id))
      (if (null? m) (list)
        (let (br (chat-branch (chat-dir dir) (list-get m 0)))
          (let (th (if (string=? (list-get m 2) "") (list) (chat-thread (chat-dir dir) (list-get m 2))))
            (union (union (if (null? br) (list) (list-get br 2)) (if (null? th) (list) (list-get th 2)))
                   (mentions-from (list-get m 3) 0 (list)))))))))

  ; ── the read mark (3) ─────────────────────────────────────────────────
  (define advance (lambda (dir name id)
    (let (p (pos-of dir id))
      (let (cur (words (read-or (string-append dir "/mark/" name) "0 -")))
        (if (< (str->num (list-get cur 0)) p)
          (fs-write (string-append dir "/mark/" name) (string-append (num->str p) " " id))
          0)))))
  (define add-read (lambda (dir scope body)
    (let (name (rest-of scope 5))
      (let (h (list-get (chat-headers body) 0))
        (let (upto (chat-hdr h "upto"))
          (if (or (= (chat-name? name) 0) (not (string=? (chat-hdr h "from") name)) (not (= (string-len upto) 64))) 0
            (if (< 0 (pos-of dir upto)) (advance dir name upto)
              (fs-append (string-append dir "/pend/" upto) (string-append name "\n")))))))))

  ; ── adding one event ──────────────────────────────────────────────────
  (define mail-add (lambda (dir id scope kind text)
    (if (or (= (has-prefix scope "field/") 1) (< 0 (pos-of dir id))) (list)
      (let (n (+ 1 (str->num (read-or (string-append dir "/n") "0"))))
        (begin
          (fs-write (string-append dir "/n") (num->str n))
          (fs-write (ppath dir id) (num->str n))
          (let (added (if (= (has-prefix scope "chat/") 1) (chat-add (chat-dir dir) id scope kind text) ""))
            (begin
              (map (lambda (name) (advance dir name id)) (set-of (string-append dir "/pend/" id)))
              (let (body (list-get (chat-canon text) 2))
                (if (= (has-prefix scope "mail/") 1)
                  (begin (if (string=? kind "mail.read") (add-read dir scope body) 0) (list))
                  (let (from (chat-hdr (list-get (chat-headers body) 0) "from"))
                    (let (names (filter (lambda (x) (not (string=? x from)))
                                  (union (mail-to body)
                                         (if (and (string=? kind "chat.msg") (not (string=? added ""))) (chat-rule dir id) (list)))))
                      (begin
                        (map (lambda (x) (fs-append (string-append dir "/box/" x) (string-append id "\n"))) names)
                        names))))))))))))

  ; ── asking ────────────────────────────────────────────────────────────
  (define mail-box (lambda (dir name) (set-of (string-append dir "/box/" name))))
  ; the mark's id, or "" if none
  (define mail-mark (lambda (dir name)
    (let (w (words (read-or (string-append dir "/mark/" name) "0 -")))
      (if (string=? (list-get w 1) "-") "" (list-get w 1)))))
  ; the ids addressed to name after mark `after` (an id, or "" for the
  ; model's own mark), in arrival order
  (define mail-unread (lambda (dir name after)
    (let (m (pos-of dir (if (string=? after "") (mail-mark dir name) after)))
      (filter (lambda (id) (< m (pos-of dir id))) (mail-box dir name)))))
)
