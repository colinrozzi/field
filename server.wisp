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
;   blob <sha256>                      -> the blob's bytes (SPEC-node 7.1):
;                                         anyone who can reach this store and
;                                         knows the hash can read it
;   has-blob <sha256>                  -> "1" if this store has the blob, else "0"
;   scope <keys|-> <after|-> <kind|->  -> "<cursor> <more> <at|->\n" then one
;                                         "<seq> <id> <scope> <kind>\n" per seen
;                                         entry under any of keys (up to 8, comma
;                                         separated: a scope, or a prefix ending
;                                         in /; - for all), from the scope index
;                                         (store.wisp, 0159), not the seen chain;
;                                         at: when more is 0, the seen event the
;                                         read ends at, to go on with pull
;   scope-pull <keys|-> <after|-> <kind|->  -> the same head, then records as
;                                         pull's ("<id> <scope> <kind> <len>\n"
;                                         and the file), up to PULL-PAGE: a
;                                         snapshot of a few scopes (live.wisp)
;   put-blob <sha256> <len>\n<bytes>   -> the sha256, once the blob is kept: only
;                                         bytes that hash to the name, at most
;                                         MAX-BLOB, while the disk has MIN-FREE
;                                         left (ticket 0137: how a blob reaches
;                                         a store its writer can't write to)
;   watch                              -> the head now; then, unasked, one more
;                                         "ok" reply holding the new head each
;                                         time this store sees a new event
; A reply is "ok <len>\n<payload>" or "err <len>\n<reason>". Connections stay
; open for more requests. A watch is a hint, like field-subscribe: the watcher
; still follows from its own cursor, so a lost one costs nothing. Bytes so far wait in field/conn/<cid>, as a request can
; arrive in pieces.
(module server
  (provide field-connection field-data field-closed field-serve field-tick)
  (require store "experiment/field/store.wisp")

  (define MAX-REQUEST 20000)
  ; 2 MB: a put costs the daemon some 270x its size in memory today (each byte a
  ; boxed value across the host boundary, 2026-11-17), so 10 MB took server3's
  ; node to GB; raise it again once wisp fixes that
  (define MAX-BLOB 2097152)
  (define MIN-FREE 1024)          ; MiB: put-blob refuses with less than 1 GB free
  (define PULL-PAGE 64)
  (define SCOPE-PAGE 256)
  ; Scopes under this prefix stay on this machine: no request sends them, nor
  ; names them (follow leaves their entries out, get says no such event).
  (define PRIVATE "private/")

  (define find-byte (lambda (s b i) (string-index s b i)))
  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define b-comma (string-ref "," 0))

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

  (define do-scope (lambda (w)
    (if (< (length w) 3) (err-reply "scope wants <prefix> <after> <kind>")
      (let (keys (if (string=? (list-get w 1) "-") (list "") (split-from (list-get w 1) b-comma 0 (list))))
       (if (or (null? keys) (< 8 (length keys))) (err-reply "scope takes 1 to 8 keys")
        (let (f (field-scope keys (dash (list-get w 2)) (if (< (length w) 4) "" (dash (list-get w 3))) SCOPE-PAGE))
        (ok-reply (string-append (orz (list-get f 0)) " " (num->str (list-get f 2)) " " (orz (list-get f 3)) "\n"
                                 (scope-lines (list-get f 1) "")))))))))
  (define do-scope-pull (lambda (w)
    (if (< (length w) 3) (err-reply "scope-pull wants <prefix> <after> <kind>")
      (let (keys (if (string=? (list-get w 1) "-") (list "") (split-from (list-get w 1) b-comma 0 (list))))
       (if (or (null? keys) (< 8 (length keys))) (err-reply "scope-pull takes 1 to 8 keys")
        (let (f (field-scope keys (dash (list-get w 2)) (if (< (length w) 4) "" (dash (list-get w 3))) PULL-PAGE))
          (ok-reply (string-append (orz (list-get f 0)) " " (num->str (list-get f 2)) " " (orz (list-get f 3)) "\n"
                                   (scope-records (list-get f 1) "")))))))))
  ; scope entries (seq id scope kind) as pull records, leaving out private/ and
  ; any event this store can't read back
  (define scope-records (lambda (es out)
    (if (null? es) out
      (let (e (car es))
        (scope-records (cdr es)
          (if (has-prefix (list-get e 2) PRIVATE) out
            (let (f (field-file (list-get e 1)))
              (if (string=? f "") out
                (string-append out (list-get e 1) " " (list-get e 2) " " (list-get e 3) " "
                               (num->str (string-len f)) "\n" f)))))))))
  (define scope-lines (lambda (es out)
    (if (null? es) out
      (let (e (car es))
        (scope-lines (cdr es)
          (if (has-prefix (list-get e 2) PRIVATE) out
            (string-append out (num->str (list-get e 0)) " " (list-get e 1) " " (list-get e 2) " " (list-get e 3) "\n")))))))

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

  ; ── blobs put by request (0137) ──────────────────────────────────────
  ; MiB free on the disk the daemon runs from (its working directory, on
  ; the same disk as the fs root on both nodes), by df; -1 if unknown.
  ; In MiB because wisp numbers are 32-bit
  (define last-line (lambda (ls) (if (null? (cdr ls)) (car ls) (last-line (cdr ls)))))
  (define trim-left (lambda (s i) (if (and (< i (string-len s)) (= (s32 (string-ref s i)) 32)) (trim-left s (+ i 1)) (substring s i (string-len s)))))
  (define disk-free (lambda ()
    (match (process-run "df" (list "-B1048576" "--output=avail" "."))
      ((ok o)
        (match o
          ((run-output st out errb tr)
            (let (ls (split-from (bytes->string out) b-nl 0 (list)))
              (if (< (length ls) 2) -1 (str->num (trim-left (last-line ls) 0)))))))
      ((err e) -1))))
  (define do-put-blob (lambda (w data)
    (let (h (list-get w 1))
      (if (not-hash? h) (err-reply "put-blob wants <sha256> <len>")
        (if (not (string=? (sha256 data) h)) (err-reply "the bytes don't hash to the name")
          (if (= (field-blob-exists h) 1) (ok-reply h)
            (if (< (disk-free) MIN-FREE) (err-reply "too little disk free")
              (let (r (field-blob-put data))
                (if (string=? r h) (ok-reply h) (err-reply r))))))))))
  (define not-hash? (lambda (h) (if (= (string-len h) 64) 0 1)))
  (define not (lambda (b) (if b 0 1)))
  ; the most bytes a request starting buf may need
  (define limit-for (lambda (buf)
    (if (= (has-prefix buf "put-blob ") 1) (+ MAX-BLOB 200) MAX-REQUEST)))

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
                (if (string=? verb "put-blob")
                  (let (n (if (< (length w) 3) -1 (str->num (list-get w 2))))
                    (if (or (< n 0) (< MAX-BLOB n))
                      (begin (tcp-send cid (err-reply (if (< n 0) "put-blob wants <sha256> <len>" "the blob is too large")))
                             (if (< n 0) (drain store cid (rest)) (begin (tcp-close cid) "")))
                      (if (< (string-len buf) (+ (+ j 1) n)) buf
                        (begin
                          (tcp-send cid (do-put-blob w (substring buf (+ j 1) (+ (+ j 1) n))))
                          (drain store cid (substring buf (+ (+ j 1) n) (string-len buf)))))))
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
                        (if (string=? verb "scope") (do-scope w)
                        (if (string=? verb "scope-pull") (do-scope-pull w)
                        (if (string=? verb "pull") (do-pull w)
                          (if (string=? verb "get") (do-get w)
                          (if (string=? verb "blob")
                            (if (< (length w) 2) (err-reply "blob wants <sha256>")
                              (match (field-blob-get (list-get w 1)) ((ok b) (ok-reply b)) ((err e) (err-reply e))))
                            (if (string=? verb "has-blob")
                              (if (< (length w) 2) (err-reply "has-blob wants <sha256>") (ok-reply (num->str (field-blob-exists (list-get w 1)))))
                            (if (string=? verb "watch")
                              (begin (fs-append WATCHERS (string-append cid "\n"))
                                     (ok-reply (field-seen-head)))
                              (err-reply "unknown request")))))))))))
                    (drain store cid (rest)))))))))))))

  (define field-connection (lambda (cid)
    (begin (tcp-activate cid) (tcp-set-active cid "active") "connected")))

  ; Each connection's unfinished request is kept in its conn file between
  ; events, and SAVED holds the length last written, so a buffer that isn't
  ; what was saved (a failed or short write, a read that fails) is caught. Then
  ; the request can never complete: say so and close, so the client retries from
  ; its cursor instead of waiting for a reply that can't come (the 11-20 stall:
  ; a put-blob's buffer stuck at 96 KiB on server3, node-peer wedged; ilse).
  (define SAVED (hash-map))
  (define saved-len (lambda (cid) (match (map-get SAVED cid) ((some n) n) ((none) 0))))
  ; GREW: when each unfinished request last grew (seconds). One that hasn't
  ; for IDLE-S is closed the same way, so a request whose bytes never reach this
  ; handler (an event lost on the way, which SAVED can't see) doesn't hold its
  ; client either (lux, 11-20). field-tick checks every 30 s.
  (define IDLE-S 120)
  (define GREW (hash-map))
  (define now-s (lambda () (s32 (/ (now) 1000u64))))
  ; SAVED -1 marks a connection closed that way: events already queued for it
  ; are dropped, not taken as the start of a new request; on-close forgets it
  (define not-saved (lambda (cid why)
    (begin (tcp-send cid (err-reply (string-append "request not saved: " why)))
           (tcp-close cid) (fs-delete (conn-path cid)) (map-set! SAVED cid -1) (map-delete! GREW cid)
           (string-append "not saved: " why))))
  ; the saved part of cid's request, or (err why) if it isn't what was saved
  (define saved-buf (lambda (cid)
    (let (want (saved-len cid))
      (match (fs-read-text (conn-path cid))
        ((ok t) (if (= (string-len t) want) (ok t)
                  (err (string-append "the buffer is " (num->str (string-len t)) " bytes, not " (num->str want)))))
        ((err x) (if (= want 0) (ok "") (err x)))))))

  (define field-data (lambda (store e)
    (let (cid (car e))
      (if (= (saved-len cid) -1) "dropped: closed, request not saved"
      (match (saved-buf cid)
        ((err why) (not-saved cid why))
        ((ok old)
          (let (left (drain store cid (string-append old (bytes->string (car (cdr e))))))
            (if (< (limit-for left) (string-len left))
              (begin (tcp-send cid (err-reply "request too large")) (tcp-close cid)
                     (fs-delete (conn-path cid)) (map-delete! SAVED cid) (map-delete! GREW cid) "too large")
              (if (string=? left "")
                (begin (fs-delete (conn-path cid)) (map-delete! SAVED cid) (map-delete! GREW cid) "data")
                (match (fs-write (conn-path cid) left)
                  ((ok x) (begin (map-set! SAVED cid (string-len left)) (map-set! GREW cid (now-s)) "data"))
                  ((err why) (not-saved cid why))))))))))))

  (define field-closed (lambda (e)
    (begin (fs-delete (conn-path (car e))) (map-delete! SAVED (car e)) (map-delete! GREW (car e)) (unwatch (car e)) "closed")))

  ; (field-tick name), from the serving file's on-tick: close every request
  ; that hasn't grown for IDLE-S
  (define field-tick (lambda (name)
    (if (string=? name "field-idle") (sweep-idle (map-keys GREW) (now-s)) "other")))
  (define sweep-idle (lambda (ks t)
    (if (null? ks) "swept"
      (begin
        (match (map-get GREW (car ks))
          ((some g) (if (< IDLE-S (- t g)) (not-saved (car ks) (string-append "no bytes for " (num->str (- t g)) " s")) 0))
          ((none) 0))
        (sweep-idle (cdr ks) t)))))

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
      (set-interval "field-idle" 30000)
      (tcp-listen addr))))
)
