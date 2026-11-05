; server.wisp — a field store on TCP (see field/DESIGN.md). Only ever serves:
; nothing here blocks, so two stores can't deadlock waiting on each other.
; Following another store is peer.wisp's job, in its own session.
;
; A request is a line, plus a body for admit:
;   head                               -> the newest seen event's id ("" if none)
;   follow <after|-> <scope|-> <kind|-> -> "<cursor|-> <more>\n" then one
;                                         "<id> <scope> <kind>\n" per entry
;   get <id>                           -> "sig <hex>\n" then the canonical text
;   pull <after|->                     -> "<cursor|-> <more>\n" then, for each
;                                         event in up to PULL-PAGE seen events
;                                         that this store shares, "<id> <scope>
;                                         <kind> <len>\n" and its file (as get);
;                                         the cursor moves past unshared ones
;   admit <sig> <len>\n<text>          -> the event's id
;   watch                              -> the head now; then, unasked, one more
;                                         "ok" reply holding the new head each
;                                         time this store sees a new event
; A reply is "ok <len>\n<payload>" or "err <len>\n<reason>". Connections stay
; open for more requests. A watch is a hint, like field-subscribe: the watcher
; still follows from its own cursor, so a lost one costs nothing. Bytes so far wait in field/conn/<cid>, as a request can
; arrive in pieces.
(module server
  (provide field-connection field-data field-closed field-serve)
  (require store "experiment/field/store.wisp")

  (define MAX-REQUEST 20000)
  (define PULL-PAGE 64)
  ; Scopes under this prefix stay on this machine: no request sends them, nor
  ; names them (follow leaves their entries out, get says no such event).
  (define PRIVATE "private/")

  (define find-byte (lambda (s b i) (string-index s b i)))
  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))

  (define split-from (lambda (s b i acc)
    (let (j (find-byte s b i))
      (let (end (if (< j 0) (string-len s) j))
        (let (acc2 (if (< i end) (list-push acc (substring s i end)) acc))
          (if (< j 0) acc2 (split-from s b (+ j 1) acc2)))))))
  (define words (lambda (s) (split-from s b-space 0 (list))))

  (define num->str (lambda (n)
    (if (< n 10) (substring "0123456789" n (+ n 1))
      (string-append (num->str (/ n 10)) (num->str (- n (* 10 (/ n 10))))))))
  (define digits-from (lambda (s i acc)
    (if (= i (string-len s)) acc
      (let (d (- (s32 (string-ref s i)) 48))
        (if (< d 0) -1 (if (< 9 d) -1 (digits-from s (+ i 1) (+ (* acc 10) d))))))))
  (define str->num (lambda (s)
    (if (= (string-len s) 0) -1 (digits-from s 0 0))))

  (define has-prefix (lambda (s p)
    (if (< (string-len s) (string-len p)) 0 (string=? (substring s 0 (string-len p)) p))))

  (define conn-path (lambda (cid) (string-append "field/conn/" cid)))

  (define reply (lambda (word payload)
    (string-append word " " (num->str (string-len payload)) "\n" payload)))
  (define ok-reply (lambda (payload) (reply "ok" payload)))
  (define err-reply (lambda (why) (reply "err" why)))

  (define dash (lambda (s) (if (string=? s "-") "" s)))
  (define orz (lambda (s) (if (string=? s "") "-" s)))

  (define entry-lines (lambda (es i out)
    (if (>= i (length es)) out
      (let (e (list-get es i))
        (entry-lines es (+ i 1)
          (if (has-prefix (list-get e 1) PRIVATE) out
            (string-append out (list-get e 0) " " (list-get e 1) " " (list-get e 2) "\n")))))))

  (define do-follow (lambda (w)
    (if (< (length w) 4) (err-reply "follow wants <after> <scope> <kind>")
      (let (f (field-follow (dash (list-get w 1)) (dash (list-get w 2)) (dash (list-get w 3))))
        (ok-reply (string-append (orz (list-get f 0)) " " (num->str (list-get f 2)) "\n"
                                 (entry-lines (list-get f 1) 0 "")))))))

  (define do-get (lambda (w)
    (if (< (length w) 2) (err-reply "get wants <id>")
      (let (e (field-get (list-get w 1)))
        (if (bad? e) (err-reply "no such event")
          (if (has-prefix (event-scope e) PRIVATE) (err-reply "no such event")
            (let (t (field-file (list-get w 1)))
              (if (string=? t "") (err-reply "no such event") (ok-reply t)))))))))

  ; the pull records for entries es from i, skipping what isn't shared
  (define pull-records (lambda (es i out)
    (if (>= i (length es)) out
      (let (e (list-get es i))
        (pull-records es (+ i 1)
          (if (has-prefix (list-get e 1) PRIVATE) out
            (let (f (field-file (list-get e 0)))
              (if (string=? f "") out
                (string-append out (list-get e 0) " " (list-get e 1) " " (list-get e 2) " "
                               (num->str (string-len f)) "\n" f)))))))))

  (define do-pull (lambda (w)
    (if (< (length w) 2) (err-reply "pull wants <after>")
      (let (f (field-follow-n (dash (list-get w 1)) "" "" PULL-PAGE))
        (ok-reply (string-append (orz (list-get f 0)) " " (num->str (list-get f 2)) "\n"
                                 (pull-records (list-get f 1) 0 "")))))))

  ; ── watchers: connections told about each new event ──────────────────
  (define WATCHERS "field/watchers")
  (define watchers (lambda ()
    (split-from (match (fs-read-text WATCHERS) ((ok t) t) ((err e) "")) b-nl 0 (list))))
  ; the watcher lines without cid, as file text
  (define others (lambda (xs cid acc)
    (if (null? xs) acc
      (others (cdr xs) cid (if (string=? (car xs) cid) acc (string-append acc (string-append (car xs) "\n")))))))
  (define unwatch (lambda (cid) (fs-write WATCHERS (others (watchers) cid ""))))
  (define tell-each (lambda (ws msg)
    (if (null? ws) "told" (begin (tcp-send (car ws) msg) (tell-each (cdr ws) msg)))))
  (define tell-watchers (lambda (head) (tell-each (watchers) (ok-reply head))))

  (define do-admit (lambda (store w text)
    (let (before (field-seen-head))
      (let (r (field-admit store (list-get w 1) text))
        (if (= (string-len r) 64)
          (let (after (field-seen-head))
            (begin
              (if (string=? after before) "known" (tell-watchers after))
              (ok-reply r)))
          (err-reply r))))))

  ; Handle every complete request in buf -> what's left. A request that can
  ; never complete closes the connection.
  (define drain (lambda (store cid buf)
    (let (j (find-byte buf b-nl 0))
      (if (< j 0) buf
        (let (w (words (substring buf 0 j)))
          (let (rest (lambda () (substring buf (+ j 1) (string-len buf))))
            (if (null? w) (drain store cid (rest))
              (let (verb (list-get w 0))
                (if (string=? verb "admit")
                  (let (n (if (< (length w) 3) -1 (str->num (list-get w 2))))
                    (if (< n 0)
                      (begin (tcp-send cid (err-reply "admit wants <sig> <len>"))
                             (drain store cid (rest)))
                      (if (< (string-len buf) (+ (+ j 1) n)) buf
                        (begin
                          (tcp-send cid (do-admit store w (substring buf (+ j 1) (+ (+ j 1) n))))
                          (drain store cid (substring buf (+ (+ j 1) n) (string-len buf)))))))
                  (begin
                    (tcp-send cid
                      (if (string=? verb "head") (ok-reply (field-seen-head))
                        (if (string=? verb "follow") (do-follow w)
                        (if (string=? verb "pull") (do-pull w)
                          (if (string=? verb "get") (do-get w)
                            (if (string=? verb "watch")
                              (begin (fs-append WATCHERS (string-append cid "\n"))
                                     (ok-reply (field-seen-head)))
                              (err-reply "unknown request")))))))
                    (drain store cid (rest))))))))))))

  (define field-connection (lambda (cid)
    (begin (tcp-activate cid) (tcp-set-active cid "active") "connected")))

  (define field-data (lambda (store e)
    (let (cid (car e))
      (let (buf (string-append
                  (match (fs-read-text (conn-path cid)) ((ok t) t) ((err x) ""))
                  (bytes->string (car (cdr e)))))
        (if (< MAX-REQUEST (string-len buf))
          (begin (tcp-send cid (err-reply "request too large")) (tcp-close cid)
                 (fs-delete (conn-path cid)) "too large")
          (let (left (drain store cid buf))
            (begin
              (if (string=? left "") (fs-delete (conn-path cid)) (fs-write (conn-path cid) left))
              "data")))))))

  (define field-closed (lambda (e)
    (begin (fs-delete (conn-path (car e))) (unwatch (car e)) "closed")))

  (define clear-conns (lambda (es i)
    (if (>= i (length es)) "cleared"
      (begin
        (match (list-get es i)
          ((dir-entry name dir) (fs-delete (conn-path name))))
        (clear-conns es (+ i 1))))))

  ; (field-serve store listen-addr): recover, then listen.
  (define field-serve (lambda (store addr)
    (begin
      (field-start store)
      (fs-mkdir "field/conn")
      (match (fs-list "field/conn") ((ok es) (clear-conns es 0)) ((err e) "none"))
      (fs-write WATCHERS "")
      (tcp-listen addr))))
)
