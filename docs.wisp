; docs.wisp — the live-document service (doc/live-docs): it follows the store's
; doc.ops events, keeps each document's text model (textmodel.wisp) in files,
; and answers on DOCS-LISTEN. lib/chat doc-read and doc-write are the client.
;
;   read <len>\n<D>                      -> "ok <len>\n<text>"
;   apply <len>\n<D>\n<from>\n<op lines>  -> "ok <len>\n<id>": sign and post one burst
;   write <len>\n<D>\n<from>\n<text>      -> "ok <len>\n<id>", or "ok 0\n" if nothing changed:
;                                           the ops that turn D's text into <text>
;   errors: "err <len>\n<why>"
;
; A burst is posted as kind doc.ops in scope doc/<D>, signed with id.<from>
; (refused if this daemon has no such key, as in chat.wisp), its parents the
; newest doc.ops events of D this service holds. Before answering, the
; service reads up to the store's head, so a read after a write sees it.
;
; The models live in this session (Wisp maps, so a restart replays every
; doc.ops event from the store; snapshots are a later ticket, SPEC-text 5):
;   STATE    (vector cursor models tips store): the seen event followed up to, maps
;            from D to its model (textmodel.wisp) and to its tips (doc.ops ids no
;            later one names as a parent), and the store's address
;   field/docs/conn/<cid>    bytes of a request still arriving
(module docs
  (provide docs-connection docs-data docs-closed docs-serve docs-catch-up docs-read DOCS-LISTEN)
  (require client "experiment/field/client.wisp")
  (require textmodel "experiment/field/textmodel.wisp")
  (require list "std/list.wisp")
  (require str "std/str.wisp")

  (define DOCS-LISTEN "127.0.0.1:7803")
  (define MAX-REQUEST 600000)
  (define MAX-BODY 16384)   ; what the node takes (SPEC-node 2.1)
  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define rest-of (lambda (s i) (substring s i (string-len s))))
  (define read-or (lambda (p d) (match (fs-read-text p) ((ok t) t) ((err e) d))))
  (define nonempty (lambda (xs) (filter (lambda (x) (< 0 (string-len x))) xs)))
  (define lines (lambda (s) (nonempty (split s "\n"))))
  (define join-lines (lambda (xs) (fold (lambda (acc x) (string-append acc x "\n")) "" xs)))
  (define in? (lambda (x xs) (= (member x xs string=?) 1)))

  (define reply (lambda (word payload)
    (string-append word " " (num->str (string-len payload)) "\n" payload)))

  ; a document name: one path segment
  (define name-ok? (lambda (d)
    (and (< 0 (string-len d)) (< (string-index d b-space 0) 0)
         (< (string-index d (string-ref "/" 0) 0) 0) (not (string=? d ".")) (not (string=? d "..")))))
  (define STATE (vector "" (hash-map) (hash-map) FIELD))
  (define store (lambda () (vector-ref STATE 3)))
  (define got (lambda (o d) (match o ((some v) v) ((none) d))))

  ; ── following the store ───────────────────────────────────────────────
  (define model-of (lambda (d)
    (let (ms (vector-ref STATE 1))
      (if (= (map-has? ms d) 1) (got (map-get ms d) 0) (map-set! ms d (text-new))))))
  (define tips-of (lambda (d) (got (map-get (vector-ref STATE 2) d) (list))))

  ; one doc.ops event into its document's model and tips
  (define take-event (lambda (id)
    (let (e (field-read (store) id))
      (if (< (length e) 9) 0
        (let (scope (list-get e 3))
          (if (not (starts-with scope "doc/")) 0
            (let (d (rest-of scope 4))
              (if (not (name-ok? d)) 0
                (begin
                  (text-apply (model-of d) id (list-get e 8))
                  (map-set! (vector-ref STATE 2) d
                    (list-push (filter (lambda (t) (not (in? t (list-get e 6)))) (tips-of d)) id))
                  1)))))))))

  ; follow from the cursor to the store's head, a page at a time
  (define docs-catch-up (lambda ()
    (let (r (field-after (store) (vector-ref STATE 0) "" "doc.ops"))
      (begin
        (map (lambda (en) (take-event (list-get en 0))) (list-get r 1))
        (vector-set! STATE 0 (list-get r 0))
        (if (= (list-get r 2) 1) (docs-catch-up) "caught up")))))

  (define docs-read (lambda (d) (begin (docs-catch-up) (text-string (model-of d)))))

  ; ── posting ───────────────────────────────────────────────────────────
  (define signer (lambda (from)
    (match (key-public (string-append "id." from)) ((ok p) (string-append "id." from)) ((err e) ""))))

  ; Catch up first, so the parents are the heads the store has, and every
  ; event the ops name is one of their ancestors (SPEC-text 3). A burst that
  ; is invalid against D's text is refused rather than posted and ignored.
  (define post-ops (lambda (d from ops)
    (let (body (begin (docs-catch-up) (string-append "from " from "\n\n" ops)))
      (if (string=? (signer from) "") (reply "err" (string-append "no key for from " from " on this daemon (lib/chat ME id-new NAME)"))
        (if (< MAX-BODY (string-len body)) (reply "err" "burst over 16384 bytes")
        (if (= (text-valid? (model-of d) body) 0) (reply "err" "invalid burst: a malformed line, or a reference to text this document doesn't have (SPEC-text 3)")
          (let (r (field-post-to (store) (signer from) (string-append "doc/" d) "doc.ops" body (tips-of d) (list)))
            (if (= (string-len r) 64) (begin (docs-catch-up) (reply "ok" r)) (reply "err" r)))))))))

  ; TODO: a diff over 16 KB goes as several bursts, each made on the last.
  (define do-write (lambda (d from text)
    (let (m (begin (docs-catch-up) (model-of d)))
      (let (ops (text-ops m text))
        (if (null? ops) (reply "ok" "") (post-ops d from (join-lines ops)))))))

  ; ── requests ──────────────────────────────────────────────────────────
  ; "<D>" or "<D>\n<from>\n<rest>" -> (list D from rest), from/rest "" if absent
  (define fields3 (lambda (p)
    (let (i (string-index p b-nl 0))
      (if (< i 0) (list p "" "")
        (let (j (string-index p b-nl (+ i 1)))
          (if (< j 0) (list (substring p 0 i) (rest-of p (+ i 1)) "")
            (list (substring p 0 i) (substring p (+ i 1) j) (rest-of p (+ j 1)))))))))

  (define handle (lambda (verb p)
    (let (f (fields3 p))
      (if (not (name-ok? (list-get f 0))) (reply "err" "bad document name")
        (if (string=? verb "read") (reply "ok" (docs-read (list-get f 0)))
          (if (string=? (list-get f 1) "") (reply "err" (string-append verb " wants <D>\\n<from>\\n..."))
            (if (string=? verb "apply") (post-ops (list-get f 0) (list-get f 1) (list-get f 2))
              (do-write (list-get f 0) (list-get f 1) (list-get f 2)))))))))

  (define verb-of (lambda (buf)
    (let (i (string-index buf b-space 0))
      (if (< i 0) "" (let (v (substring buf 0 i)) (if (in? v (list "read" "apply" "write")) v ""))))))

  ; handle every complete request in buf -> what's left
  (define drain (lambda (cid buf)
    (let (j (string-index buf b-nl 0))
      (if (< j 0) buf
        (let (v (verb-of buf))
          (if (string=? v "") (begin (tcp-send cid (reply "err" "unknown request")) "")
            (let (n (string->number (substring buf (+ (string-len v) 1) j)))
              (if (< (string-len buf) (+ (+ j 1) n)) buf
                (begin
                  (tcp-send cid (handle v (substring buf (+ j 1) (+ (+ j 1) n))))
                  (drain cid (rest-of buf (+ (+ j 1) n))))))))))))

  (define conn-path (lambda (cid) (string-append "field/docs/conn/" cid)))
  (define docs-connection (lambda (cid)
    (begin (tcp-activate cid) (tcp-set-active cid "active") "connected")))
  (define docs-data (lambda (e)
    (let (cid (car e))
      (let (buf (string-append (read-or (conn-path cid) "") (bytes->string (car (cdr e)))))
        (if (< MAX-REQUEST (string-len buf))
          (begin (tcp-send cid (reply "err" "request too large")) (tcp-close cid) (fs-delete (conn-path cid)) "too large")
          (let (left (drain cid buf))
            (begin
              (if (string=? left "") (fs-delete (conn-path cid)) (fs-write (conn-path cid) left))
              "data")))))))
  (define docs-closed (lambda (e) (begin (fs-delete (conn-path (car e))) "closed")))

  ; listen on addr; the store at store-addr (client.wisp's FIELD on this machine)
  (define docs-serve (lambda (addr store-addr)
    (begin
      (vector-set! STATE 3 store-addr)
      (map fs-mkdir (list "field/docs" "field/docs/conn"))
      (tcp-listen addr))))
)
