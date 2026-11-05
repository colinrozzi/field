; gate.wisp — a node's public door (ticket 0051). It listens on a public port
; with TLS, makes each new connection prove which node it is, and then joins it
; to the local store (server.wisp on loopback), passing bytes both ways
; untouched. The store itself stays on loopback and never sees a stranger.
;
; The handshake, after TLS (the client speaks first, so the gate never waits on
; a silent stranger: the TLS upgrade runs in the connection's read loop, active
; mode, with Theater's 10 s handshake deadline):
;   node -> "hello\n"
;   gate -> "challenge <nonce>\n"
;   node -> "auth <name> <sig>\n"   sig = (sign <its key> "field-gate <nonce>")
;   gate -> "ok\n", and from then on it is the store's protocol
; <name> must be a line "<name> <public key hex>" in field/gate-keys; anything
; else gets the connection closed. The nonce is a hash of a signature by this
; node's own key over the time and the connection id, so nobody can guess it.
;
; State is in files, one per connection, under field/gate/:
;   <cid>  "tls"         a client that has not said hello yet
;          "nonce <n>"   a client that has not proved itself yet
;          "up <local>"  a proved client, joined to store connection <local>
;          "down <cid>"  a store connection, joined back to client <cid>
(module gate
  (provide gate-connection gate-data gate-closed gate-serve)
  (require str "std/str.wisp")   ; u64->string

  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define MAX-HELLO 400)
  (define not (lambda (b) (if b 0 1)))

  (define split-from (lambda (s b i acc)
    (let (j (string-index s b i))
      (let (end (if (< j 0) (string-len s) j))
        (let (acc2 (if (< i end) (list-push acc (substring s i end)) acc))
          (if (< j 0) acc2 (split-from s b (+ j 1) acc2)))))))
  (define words (lambda (s) (split-from s b-space 0 (list))))
  (define lines (lambda (s) (split-from s b-nl 0 (list))))
  (define has-prefix (lambda (s p)
    (if (< (string-len s) (string-len p)) 0 (string=? (substring s 0 (string-len p)) p))))
  (define after-prefix (lambda (s p) (substring s (string-len p) (string-len s))))

  (define path (lambda (cid) (string-append "field/gate/" cid)))
  (define state (lambda (cid) (match (fs-read-text (path cid)) ((ok t) t) ((err e) ""))))
  (define forget (lambda (cid) (fs-delete (path cid))))

  ; the public key named `name` in field/gate-keys, or ""
  (define key-of (lambda (name ls)
    (if (null? ls) ""
      (let (w (words (car ls)))
        (if (and (= (length w) 2) (string=? (list-get w 0) name)) (list-get w 1) (key-of name (cdr ls)))))))
  (define known-key (lambda (name)
    (key-of name (lines (match (fs-read-text "field/gate-keys") ((ok t) t) ((err e) ""))))))

  (define nonce-for (lambda (me cid)
    (match (sign me (string-append "field-gate nonce " (string-append (u64->string (now)) cid)))
      ((ok s) (sha256 s))
      ((err e) ""))))

  (define drop (lambda (cid) (begin (forget cid) (tcp-close cid) "refused")))

  ; A new client: queue the TLS upgrade; the challenge follows its hello.
  (define gate-connection (lambda (cid)
    (begin
      (tcp-activate cid)
      (tcp-set-active cid "active")
      (match (tcp-tls-server cid)
        ((err e) (drop cid))
        ((ok x) (begin (fs-write (path cid) "tls") "upgrading"))))))

  (define challenge (lambda (me cid)
    (if (= (tcp-is-tls-now cid) 0) (drop cid)
      (let (n (nonce-for me cid))
        (if (string=? n "") (drop cid)
          (begin
            (fs-write (path cid) (string-append "nonce " n))
            (tcp-send cid (string-append "challenge " n "\n"))
            "challenged"))))))
  (define tcp-is-tls-now (lambda (cid)
    (match (tcp-is-tls cid) ((ok b) (if b 1 0)) ((err e) 0))))

  ; the client's hello line: check it, and on success join it to the store
  (define hello (lambda (cid nonce buf store-addr)
    (let (j (string-index buf b-nl 0))
      (if (< j 0)
        (if (< MAX-HELLO (string-len buf)) (drop cid)
          (begin (fs-write (path cid) (string-append "nonce " nonce "\n" buf)) "waiting"))
        (let (w (words (substring buf 0 j)))
          (let (key (if (= (length w) 3) (known-key (list-get w 1)) ""))
            (if (or (string=? key "") (not (string=? (list-get w 0) "auth"))) (drop cid)
              (if (not (verify key (list-get w 2) (string-append "field-gate " nonce))) (drop cid)
                (match (tcp-connect store-addr)
                  ((err e) (drop cid))
                  ((ok local)
                    (begin
                      (tcp-set-active local "active")
                      (fs-write (path cid) (string-append "up " local))
                      (fs-write (path local) (string-append "down " cid))
                      (tcp-send cid "ok\n")
                      (let (rest (substring buf (+ j 1) (string-len buf)))
                        (if (< 0 (string-len rest)) (tcp-send local rest) 0))
                      "joined")))))))))))

  (define gate-data (lambda (me store-addr e)
    (let (cid (car e))
      (let (bytes (bytes->string (car (cdr e))))
        (let (st (state cid))
          (if (string=? st "tls") (challenge me cid)
          (if (has-prefix st "up ") (begin (tcp-send (after-prefix st "up ") bytes) "up")
            (if (has-prefix st "down ") (begin (tcp-send (after-prefix st "down ") bytes) "down")
              (if (has-prefix st "nonce ")
                ; "nonce <n>" then, if a hello arrived in pieces, "\n<so far>"
                (let (rest (after-prefix st "nonce "))
                  (let (k (string-index rest b-nl 0))
                    (if (< k 0) (hello cid rest bytes store-addr)
                      (hello cid (substring rest 0 k)
                             (string-append (substring rest (+ k 1) (string-len rest)) bytes) store-addr))))
                (drop cid))))))))))

  ; Either end closing closes the other.
  (define gate-closed (lambda (e)
    (let (cid (car e))
      (let (st (state cid))
        (begin
          (forget cid)
          (if (has-prefix st "up ") (let (o (after-prefix st "up ")) (begin (forget o) (tcp-close o))) 0)
          (if (has-prefix st "down ") (let (o (after-prefix st "down ")) (begin (forget o) (tcp-close o))) 0)
          "closed")))))

  (define clear (lambda (es)
    (if (null? es) "cleared"
      (begin (match (car es) ((dir-entry name dir) (fs-delete (path name)))) (clear (cdr es))))))

  (define gate-serve (lambda (addr)
    (begin
      (fs-mkdir "field/gate")
      (match (fs-list "field/gate") ((ok es) (clear es)) ((err e) "none"))
      (tcp-listen addr))))
)
