; chat.wisp — post chat events into this machine's field store (see
; field/CHAT.md). lib/chat is the client; this signs, since keys stay in the
; daemon. Every chat event is signed with the "chat" key; who wrote it is the
; body's first line, "from NAME" (over-permissive on purpose, for now).
;
;   post <len>\n<thread>\n<kind>\n<body>   -> "ok <len>\n<id>" or "err <len>\n<why>"
;   send <len>\n<thread>\n<kind>\n<parent ids, space-separated, or ->\n<body>
;
; kind is chat.msg, chat.join, chat.leave, chat.branch or chat.set; the event's scope is chat/<thread>.
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
    (member k (list "chat.msg" "chat.join" "chat.leave" "chat.branch" "chat.set" "chat.edit") string=?)))

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
                  (if (not (kind-ok? kind)) (reply "err" "kind is chat.msg, chat.join, chat.leave, chat.branch, chat.set or chat.edit")
                    (if (< MAX-BODY (- (string-len p) (+ k 1))) (reply "err" "body over 16384 bytes")
                    (let (r (field-post-to FIELD "chat" (string-append "chat/" thread) kind
                                        (substring p (+ k 1) (string-len p))
                                        (if (= with-parents 0) (list) (parent-list (substring p (+ j 1) k)))
                                        (list)))
                      (if (= (string-len r) 64) (reply "ok" r) (reply "err" r))))))))))))))

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
