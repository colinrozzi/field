; chat.wisp — post chat events into this machine's field store (see
; field/CHAT.md). lib/chat is the client; this signs, since keys stay in the
; daemon. Who wrote an event is the body's first line, "from NAME"; it is
; signed with NAME's key id.NAME if this daemon holds one (field/SPEC-id.md),
; else with the "chat" key. Anyone who can reach this port can write as any
; name whose key is here: the trust is this machine's.
;
;   post <len>\n<thread>\n<kind>\n<body>   -> "ok <len>\n<id>" or "err <len>\n<why>"
;   send <len>\n<thread>\n<kind>\n<parent ids, space-separated, or ->\n<body>
;
; kind is chat.msg, chat.join, chat.leave, chat.branch, chat.set or chat.edit, and the event's
; scope is chat/<thread>. Or one of these, and <thread> is the scope itself: mail.read in
; mail/<name> (field/SPEC-mailbox.md); group.add, group.remove, group.open in group/<name>
; (field/SPEC-group.md); doc.set, doc.edit in doc/<name>; id.key, id.retire in id/<name>
; (field/SPEC-id.md), signed with this node's own key (field/node), the registrar.
; An id.key whose body has "key new" makes the name's key id.<name> in this
; daemon (if it has none) and writes that key.
; Bytes so far wait in field/chat-conn/<cid>, as a request can arrive in pieces.
(module chat
  (provide chat-connection chat-data chat-closed chat-serve)
  (require client "experiment/field/client.wisp")
  (require str "std/str.wisp")
  (require list "std/list.wisp")

  (define MAX-REQUEST 20000)
  (define MAX-BODY 16384)   ; what the node takes (SPEC-node 2.1)
  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))

  (define num->str (lambda (n)
    (if (< n 10) (substring "0123456789" n (+ n 1))
      (string-append (num->str (/ n 10)) (num->str (- n (* 10 (/ n 10))))))))
  (define digits-from (lambda (s i acc)
    (if (= i (string-len s)) acc
      (let (d (- (s32 (string-ref s i)) 48))
        (if (< d 0) -1 (if (< 9 d) -1 (digits-from s (+ i 1) (+ (* acc 10) d))))))))
  (define str->num (lambda (s)
    (if (= (string-len s) 0) -1 (digits-from s 0 0))))

  (define conn-path (lambda (cid) (string-append "field/chat-conn/" cid)))
  (define reply (lambda (word payload)
    (string-append word " " (num->str (string-len payload)) "\n" payload)))

  (define kind-ok? (lambda (k)
    (member k (list "chat.msg" "chat.join" "chat.leave" "chat.branch" "chat.set" "chat.edit" "mail.read"
                    "group.add" "group.remove" "group.open" "doc.set" "doc.edit" "id.key" "id.retire") string=?)))

  ; the scope prefix a kind outside chat/ needs ("" for a chat kind)
  (define scope-for (lambda (k)
    (if (string=? k "mail.read") "mail/"
      (if (and (< 6 (string-len k)) (string=? (substring k 0 6) "group.")) "group/"
        (if (and (< 4 (string-len k)) (string=? (substring k 0 4) "doc.")) "doc/"
          (if (and (< 3 (string-len k)) (string=? (substring k 0 3) "id.")) "id/" ""))))))
  ; id.* is signed by the registrar, this node's own key. The rest by the
  ; key of the body's `from`, id.<from>, if this daemon holds it
  ; (field/SPEC-id.md 5), else by "chat" (until rules step C).
  (define signer (lambda (kind body)
    (if (string=? (scope-for kind) "id/") (match (fs-read-text "field/node") ((ok n) n) ((err e) "no-node-name"))
      (let (from (from-of body))
        (if (string=? from "") "chat"
          (match (key-public (string-append "id." from)) ((ok p) (string-append "id." from)) ((err e) "chat")))))))
  ; the body's `from` header: its first line, "from NAME"
  (define from-of (lambda (body)
    (let (j (string-index body b-nl 0))
      (let (line (if (< j 0) body (substring body 0 j)))
        (if (and (< 5 (string-len line)) (string=? (substring line 0 5) "from ")
                 (< (string-index line b-space 5) 0) (< (string-index line (string-ref "/" 0) 0) 0))
          (substring line 5 (string-len line)) "")))))
  ; "key new" in an id.key: the name's own key id.<name>, made here if missing
  (define id-body (lambda (kind thread body)
      (if (or (not (string=? kind "id.key")) (< (string-len thread) 4)) body
        (let (j (find-sub body "\nkey new\n" 0))
          (if (< j 0) body
            (let (name (substring thread 3 (string-len thread)))
              (let (pub (match (key-public (string-append "id." name)) ((ok p) p)
                          ((err e) (match (key-new (string-append "id." name)) ((ok p) p) ((err x) "")))))
                (string-append (substring body 0 j) "\nkey " pub "\n" (substring body (+ j 9) (string-len body))))))))))
  (define find-sub (lambda (s pat i)
    (let (j (string-index s (string-ref pat 0) i))
      (if (< j 0) -1
        (if (< (string-len s) (+ j (string-len pat))) -1
          (if (string=? (substring s j (+ j (string-len pat))) pat) j (find-sub s pat (+ j 1))))))))
  (define in-scope? (lambda (t p)
    (if (<= (string-len t) (string-len p)) 0 (if (string=? (substring t 0 (string-len p)) p) 1 0))))

  (define parent-list (lambda (line)
    (if (string=? line "-") (list)
      (filter (lambda (w) (< 0 (string-len w))) (split line " ")))))

  ; thread\nkind\nbody, or with parents: thread\nkind\nparents\nbody -> the reply
  (define do-post (lambda (p with-parents)
    (let (i (string-index p b-nl))
      (let (j (if (< i 0) -1 (string-index p b-nl (+ i 1))))
        (let (k (if (= with-parents 0) j (if (< j 0) -1 (string-index p b-nl (+ j 1)))))
          (if (< k 0) (reply "err" "post wants <thread>\\n<kind>\\n<body>")
            (let (thread (substring p 0 i))
              (let (kind (substring p (+ i 1) j))
                (if (or (= i 0) (<= 0 (string-index thread b-space))) (reply "err" "bad thread name")
                  (if (not (kind-ok? kind)) (reply "err" "kind is chat.msg, chat.join, chat.leave, chat.branch, chat.set, chat.edit, mail.read, group.add, group.remove, group.open, doc.set or doc.edit")
                  (if (and (not (string=? (scope-for kind) "")) (= (in-scope? thread (scope-for kind)) 0))
                    (reply "err" (string-append kind " goes in " (scope-for kind) "<name>"))
                    (if (< MAX-BODY (- (string-len p) (+ k 1))) (reply "err" "body over 16384 bytes")
                    (let (r (field-post-to FIELD (signer kind (substring p (+ k 1) (string-len p))) (if (string=? (scope-for kind) "") (string-append "chat/" thread) thread) kind
                                        (id-body kind thread (substring p (+ k 1) (string-len p)))
                                        (if (= with-parents 0) (list) (parent-list (substring p (+ j 1) k)))
                                        (list)))
                      (if (= (string-len r) 64) (reply "ok" r) (reply "err" r)))))))))))))))

  ; Handle every complete request in buf -> what's left.
  (define drain (lambda (cid buf)
    (let (j (string-index buf b-nl))
      (if (< j 0) buf
        (if (not (or (starts-with buf "post ") (starts-with buf "send ")))
          (begin (tcp-send cid (reply "err" "unknown request")) "")
          (let (n (str->num (substring buf 5 j)))
            (if (< n 0) (begin (tcp-send cid (reply "err" "post wants <len>")) "")
              (if (< (string-len buf) (+ (+ j 1) n)) buf
                (begin
                  (tcp-send cid (do-post (substring buf (+ j 1) (+ (+ j 1) n)) (if (starts-with buf "send ") 1 0)))
                  (drain cid (substring buf (+ (+ j 1) n) (string-len buf))))))))))))

  (define chat-connection (lambda (cid)
    (begin (tcp-activate cid) (tcp-set-active cid "active") "connected")))

  (define chat-data (lambda (e)
    (let (cid (car e))
      (let (buf (string-append
                  (match (fs-read-text (conn-path cid)) ((ok t) t) ((err x) ""))
                  (bytes->string (car (cdr e)))))
        (if (< MAX-REQUEST (string-len buf))
          (begin (tcp-send cid (reply "err" "request too large")) (tcp-close cid)
                 (fs-delete (conn-path cid)) "too large")
          (let (left (drain cid buf))
            (begin
              (if (string=? left "") (fs-delete (conn-path cid)) (fs-write (conn-path cid) left))
              "data")))))))

  (define chat-closed (lambda (e)
    (begin (fs-delete (conn-path (car e))) "closed")))

  (define chat-serve (lambda (addr)
    (begin
      (fs-mkdir "field/chat-conn")
      (tcp-listen addr))))
)
