; chatmodel.wisp — the chat model of field/SPEC-chat.md, section 5, kept in
; files so a long-running reader (site/push.wisp) can add one event at a time.
; It passes field/vectors/chat/ (field/vectors/chat/run). Readers feed it each
; chat event in their node's seen chain order, once:
;
;   (chat-add dir id scope kind text)  text: the canonical text (no sig line)
;                                      -> the id if it added a message, else ""
;
; and ask it what they need: chat-msg, chat-branch, chat-thread, chat-reaches,
; chat-tickets; chat-name? and chat-mentions? are the spec's rules for any
; writer. Everything is under `dir`:
;
;   <dir>/seq                         messages so far
;   <dir>/m/<id>                      "<seq> <time> <branch> <from> <re|->\n<parents>\n<text>"
;   <dir>/b/<name>/members|tips       one per line, in insertion order
;   <dir>/b/<name>/anchor|by|t|last   one value
;   <dir>/b/<name>/state/<key>        the value; st/<key> is "<time> <id>" of its set
;   <dir>/th/<root>/tips|replies|people
;
; Times stay as the event's milliseconds: they order chat.set as seconds would.
(module chatmodel
  (provide chat-add chat-name? chat-mentions? chat-msg chat-branch chat-thread
           chat-reaches chat-tickets chat-start
           chat-canon chat-headers chat-hdr chat-newer chat-str-lt)
  (require list "std/list.wisp")

  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))

  (define has-prefix (lambda (s p)
    (if (< (string-len s) (string-len p)) 0 (if (string=? (substring s 0 (string-len p)) p) 1 0))))
  (define rest-of (lambda (s i) (substring s i (string-len s))))
  (define read-or (lambda (p d) (match (fs-read-text p) ((ok t) t) ((err e) d))))
  (define nonempty (lambda (xs) (filter (lambda (x) (< 0 (string-len x))) xs)))
  (define split-on (lambda (s b i acc)
    (let (j (string-index s b i))
      (if (< j 0) (list-push acc (rest-of s i))
        (split-on s b (+ j 1) (list-push acc (substring s i j)))))))
  (define lines (lambda (s) (nonempty (split-on s b-nl 0 (list)))))
  (define words (lambda (s) (nonempty (split-on s b-space 0 (list)))))
  (define join-lines (lambda (xs) (fold (lambda (acc x) (string-append acc x "\n")) "" xs)))
  (define in? (lambda (x xs) (= (member x xs string=?) 1)))
  (define differ (lambda (a b) (if (string=? a b) (= 0 1) (= 0 0))))
  ; byte order: is a before b?
  (define str-lt-from (lambda (a b i)
    (if (= i (string-len b)) (= 0 1)
      (if (= i (string-len a)) (= 0 0)
        (if (= (code a i) (code b i)) (str-lt-from a b (+ i 1)) (< (code a i) (code b i)))))))
  (define str-lt (lambda (a b) (str-lt-from a b 0)))

  ; ── names and ids ─────────────────────────────────────────────────────
  (define code (lambda (s i) (s32 (string-ref s i))))
  (define lower-or-digit (lambda (c) (or (and (<= 97 c) (<= c 122)) (and (<= 48 c) (<= c 57)))))
  (define word-char (lambda (c) (or (lower-or-digit c) (and (<= 65 c) (<= c 90)) (= c 95))))
  (define name-from (lambda (s i)
    (if (= i (string-len s)) 1
      (let (c (code s i))
        (if (or (lower-or-digit c) (= c 46) (= c 95) (= c 45)) (name-from s (+ i 1)) 0)))))
  ; ^[a-z0-9][a-z0-9._-]{0,63}$
  (define chat-name? (lambda (s)
    (if (= (string-len s) 0) 0
      (if (< 64 (string-len s)) 0
        (if (lower-or-digit (code s 0)) (name-from s 1) 0)))))
  (define hex-from (lambda (s i)
    (if (= i (string-len s)) 1
      (let (c (code s i))
        (if (or (and (<= 48 c) (<= c 57)) (and (<= 97 c) (<= c 102))) (hex-from s (+ i 1)) 0)))))
  ; ids name files here, so only a node's ids are taken
  (define id? (lambda (s) (if (= (string-len s) 64) (hex-from s 0) 0)))

  ; (^|[^A-Za-z0-9_@])@name\b in text, from i
  (define mention-at (lambda (text name j)
    (let (end (+ j (+ 1 (string-len name))))
      (let (before-ok (if (= j 0) 1 (let (c (code text (- j 1))) (if (or (word-char c) (= c 64)) 0 1))))
        (let (last-word (word-char (code name (- (string-len name) 1))))
          (let (after-word (if (= end (string-len text)) 0 (if (word-char (code text end)) 1 0)))
            (if (= before-ok 0) 0 (if last-word (if (= after-word 1) 0 1) after-word))))))))
  (define mentions-from (lambda (text pat name i)
    (let (j (string-index text pat i))
      (if (< j 0) 0
        (if (= (mention-at text name j) 1) 1 (mentions-from text pat name (+ j 1)))))))
  (define chat-mentions? (lambda (text name)
    (if (= (string-len name) 0) 0 (mentions-from text (string-append "@" name) name 0))))

  ; ── reading an event ──────────────────────────────────────────────────
  ; the canonical text -> (list time parents body)
  (define canon-from (lambda (text i time parents)
    (let (j (string-index text b-nl i))
      (if (< j 0) (list time parents "")
        (let (line (substring text i j))
          (if (= (has-prefix line "body ") 1) (list time parents (rest-of text (+ j 1)))
            (canon-from text (+ j 1)
              (if (= (has-prefix line "time ") 1) (rest-of line 5) time)
              (if (= (has-prefix line "parent ") 1) (list-push parents (rest-of line 7)) parents))))))))

  ; the first value of key k in header text head ("" if none)
  (define hdr-in (lambda (ls k i)
    (if (>= i (length ls)) ""
      (let (l (list-get ls i))
        (let (sp (string-index l b-space 0))
          (let (key (if (< sp 0) l (substring l 0 sp)))
            (if (string=? key k) (if (< sp 0) "" (rest-of l (+ sp 1))) (hdr-in ls k (+ i 1)))))))))
  ; body -> (list header-lines text)
  (define headers (lambda (body)
    (let (i (string-index body "\n\n" 0))
      (if (< i 0) (list (split-on body b-nl 0 (list)) "")
        (list (split-on (substring body 0 i) b-nl 0 (list)) (rest-of body (+ i 2)))))))
  (define strip-nl (lambda (s)
    (if (= (string-len s) 0) s (if (= (code s 0) 10) (strip-nl (rest-of s 1)) s))))
  ; a legacy chat/<thread> body -> (list who who-header text)
  (define legacy-who (lambda (ls i)
    (if (>= i (length ls)) ""
      (let (w (split-on (list-get ls i) b-space 0 (list)))
        (if (and (= (length w) 2) (string=? (list-get w 0) "who") (< 0 (string-len (list-get w 1))))
          (list-get w 1) (legacy-who ls (+ i 1)))))))
  (define legacy (lambda (body)
    (let (j (string-index body b-nl 0))
      (let (first (if (< j 0) body (substring body 0 j)))
        (let (rest (if (< j 0) "" (rest-of body (+ j 1))))
          (list (if (= (has-prefix first "from ") 1) (rest-of first 5) "?")
                (legacy-who (split-on rest b-nl 0 (list)) 0)
                (strip-nl rest)))))))

  ; ── the files ─────────────────────────────────────────────────────────
  (define bpath (lambda (dir b f) (string-append dir "/b/" b "/" f)))
  (define tpath (lambda (dir r f) (string-append dir "/th/" r "/" f)))
  (define mpath (lambda (dir id) (string-append dir "/m/" id)))
  (define set-of (lambda (p) (lines (read-or p ""))))
  (define add-to (lambda (p x) (if (in? x (set-of p)) 0 (fs-append p (string-append x "\n")))))
  (define drop-from (lambda (p x) (fs-write p (join-lines (filter (lambda (y) (differ y x)) (set-of p))))))
  ; tips without any of par, plus id
  (define move-tips (lambda (p par id)
    (fs-write p (join-lines (list-push (filter (lambda (y) (if (in? y par) (= 0 1) (= 0 0))) (set-of p)) id)))))

  (define chat-start (lambda (dir)
    (begin (fs-mkdir dir) (fs-mkdir (string-append dir "/m")) (fs-mkdir (string-append dir "/b"))
           (fs-mkdir (string-append dir "/th")) dir)))
  (define branch-dir (lambda (dir b)
    (let (d (string-append dir "/b/" b))
      (begin (fs-mkdir d) (fs-mkdir (string-append d "/state")) (fs-mkdir (string-append d "/st")) d))))

  ; the message record: (list seq time b from re parents text), or (list)
  (define msg-rec (lambda (dir id)
    (if (= (id? id) 0) (list)
      (match (fs-read-text (mpath dir id))
        ((err e) (list))
        ((ok t)
          (let (i (string-index t b-nl 0))
            (let (j (string-index t b-nl (+ i 1)))
              (let (w (split-on (substring t 0 i) b-space 0 (list)))
                (list (list-get w 0) (list-get w 1) (list-get w 2) (list-get w 3)
                      (if (string=? (list-get w 4) "-") "" (list-get w 4))
                      (words (substring t (+ i 1) j)) (rest-of t (+ j 1)))))))))))

  ; ── adding one event (5.3) ────────────────────────────────────────────
  (define chat-add (lambda (dir id scope kind text)
    (if (= (has-prefix scope "chat/") 0) ""
      (if (= (has-prefix kind "chat.") 0) ""
        (if (= (id? id) 0) ""
          (if (= (fs-exists-1 (mpath dir id)) 1) ""
            (let (c (canon-from text 0 "0" (list)))
              (let (s (rest-of scope 5))
                (if (string=? s "main")
                  (let (h (headers (list-get c 2)))
                    (let (ls (list-get h 0))
                      (let (from (hdr-in ls "from" 0))
                        (add-parsed dir id kind c "main" (if (string=? from "") "?" from)
                          (first-of (list (hdr-in ls "in" 0) (hdr-in ls "branch" 0) (hdr-in ls "name" 0) "general"))
                          (lambda (k) (hdr-in ls k 0)) (list-get h 1)))))
                  (let (l (legacy (list-get c 2)))
                    (add-parsed dir id kind c s (list-get l 0) s
                      (lambda (k) (if (string=? k "who") (list-get l 1) "")) (list-get l 2))))))))))))
  (define fs-exists-1 (lambda (p) (match (fs-exists p) ((ok v) (if v 1 0)) ((err e) 0))))
  (define first-of (lambda (xs) (if (< 0 (string-len (car xs))) (car xs) (first-of (cdr xs)))))

  (define add-parsed (lambda (dir id kind c s who b hdr text)
    (if (= (chat-name? b) 0) ""
      (begin
        (branch-dir dir b)
        (if (string=? kind "chat.msg") (add-msg dir id c s who b (hdr "re") text)
          (if (string=? kind "chat.branch") (add-branch dir c who b (hdr "anchor"))
            (if (string=? kind "chat.join") (begin (add-to (bpath dir b "members") (member-of hdr who)) "")
              (if (string=? kind "chat.leave") (begin (drop-from (bpath dir b "members") (member-of hdr who)) "")
                (if (string=? kind "chat.set") (add-set dir id c b (hdr "key") text) "")))))))))
  (define member-of (lambda (hdr who) (let (w (hdr "who")) (if (string=? w "") who w))))

  (define add-msg (lambda (dir id c s who b0 re0 text)
    (let (root (msg-rec dir re0))
      (let (re (if (null? root) "" re0))
        (let (b (if (null? root) b0 (list-get root 2)))
          (let (seq (+ 1 (num-or (read-or (string-append dir "/seq") "0"))))
            (let (par (list-get c 1))
              (begin
                (fs-write (string-append dir "/seq") (num->str seq))
                (fs-write (mpath dir id)
                  (string-append (num->str seq) " " (list-get c 0) " " b " " who " " (if (string=? re "") "-" re) "\n"
                                 (fold (lambda (acc p) (if (string=? acc "") p (string-append acc " " p))) "" par) "\n" text))
                (fs-write (bpath dir b "last") (num->str seq))
                (add-to (bpath dir b "members") who)
                (if (string=? re "")
                  (if (string=? s "main") (move-tips (bpath dir b "tips") par id) 0)
                  (begin
                    (fs-mkdir (string-append dir "/th/" re))
                    (move-tips (tpath dir re "tips") par id)
                    (fs-append (tpath dir re "replies") (string-append id "\n"))
                    (add-to (tpath dir re "people") (list-get root 3))
                    (add-to (tpath dir re "people") who)))
                id))))))))

  (define add-branch (lambda (dir c who b anchor)
    (begin
      (if (null? (msg-rec dir anchor)) 0 (fs-write (bpath dir b "anchor") anchor))
      (fs-write (bpath dir b "by") who)
      (fs-write (bpath dir b "t") (list-get c 0))
      (add-to (bpath dir b "members") who)
      "")))

  ; (t, id) >= (t2, id2): times compare as numbers, ids as strings
  (define num-ge (lambda (a b)
    (if (< (string-len a) (string-len b)) 0 (if (< (string-len b) (string-len a)) 1 (if (str-lt a b) 0 1)))))
  (define newer (lambda (t id st)
    (let (w (words st))
      (if (null? w) 1
        (if (string=? t (list-get w 0)) (if (str-lt id (list-get w 1)) 0 1) (num-ge t (list-get w 0)))))))
  (define add-set (lambda (dir id c b k text)
    (if (= (chat-name? k) 0) ""
      (begin
        (if (= (newer (list-get c 0) id (read-or (bpath dir b (string-append "st/" k)) "")) 1)
          (begin (fs-write (bpath dir b (string-append "state/" k)) text)
                 (fs-write (bpath dir b (string-append "st/" k)) (string-append (list-get c 0) " " id)))
          0)
        ""))))

  ; ── asking ────────────────────────────────────────────────────────────
  ; (list b from re text), or (list)
  (define chat-msg (lambda (dir id)
    (let (m (msg-rec dir id))
      (if (null? m) m (list (list-get m 2) (list-get m 3) (list-get m 4) (list-get m 6))))))

  (define dir-names (lambda (p)
    (match (fs-list p)
      ((ok es) (map (lambda (e) (match e ((dir-entry name d) name))) es))
      ((err e) (list)))))
  (define branch? (lambda (dir b) (if (= (chat-name? b) 0) 0 (fs-exists-1 (string-append dir "/b/" b)))))
  ; (list anchor tips members state), state a list of (key value) by key; or (list)
  (define chat-branch (lambda (dir b)
    (if (= (branch? dir b) 0) (list)
      (list (read-or (bpath dir b "anchor") "") (set-of (bpath dir b "tips")) (set-of (bpath dir b "members"))
            (map (lambda (k) (list k (read-or (bpath dir b (string-append "state/" k)) "")))
                 (sort str-lt (dir-names (string-append dir "/b/" b "/state"))))))))

  ; (list tips replies people), or (list)
  (define chat-thread (lambda (dir root)
    (if (= (fs-exists-1 (string-append dir "/th/" root)) 0) (list)
      (list (set-of (tpath dir root "tips")) (set-of (tpath dir root "replies")) (set-of (tpath dir root "people"))))))

  ; does message id reach name (6, "Reaches")?
  (define chat-reaches (lambda (dir id name)
    (let (m (msg-rec dir id))
      (if (null? m) 0
        (if (string=? (list-get m 3) name) 0
          (if (in? name (set-of (bpath dir (list-get m 2) "members"))) 1
            (if (= 1 (if (string=? (list-get m 4) "") 0 (if (in? name (set-of (tpath dir (list-get m 4) "people"))) 1 0))) 1
              (chat-mentions? (list-get m 6) name))))))))

  ; (list (n branch) ...) sorted by n
  (define chat-tickets (lambda (dir)
    (sort (lambda (a b) (str-lt (car a) (car b)))
      (filter (lambda (t) (< 0 (string-len (car t))))
        (map (lambda (b) (list (read-or (bpath dir b "state/n") "") b)) (dir-names (string-append dir "/b")))))))

  (define num-or (lambda (s) (fold (lambda (acc i) (+ (* acc 10) (- (code s i) 48))) 0 (range-list 0 (string-len s) (list)))))
  (define range-list (lambda (i n acc) (if (>= i n) acc (range-list (+ i 1) n (list-push acc i)))))
  (define num->str (lambda (n)
    (if (< n 10) (substring "0123456789" n (+ n 1))
      (string-append (num->str (/ n 10)) (num->str (- n (* 10 (/ n 10))))))))

  ; for field/docmodel.wisp: the canonical text -> (list time parents body);
  ; body -> (list header-lines text); a header's value; is (t, id) >= st?
  (define chat-canon (lambda (text) (canon-from text 0 "0" (list))))
  (define chat-headers headers)
  (define chat-hdr (lambda (ls k) (hdr-in ls k 0)))
  (define chat-newer newer)
  (define chat-str-lt str-lt)
)
