; peer.wisp — one store following another (see field/DESIGN.md). Runs in its own
; session, so blocking on the network holds up nothing but this follower.
;
; Each pull: ask the remote store for the page after our cursor, admit the
; events into the local store, then move the cursor. Admission is a
; no-op for events already held, so a crash repeats work and loses nothing, and
; events that came from the other side stop after one hop.
;
; Pulling: (peer-pull ...) asks for "pull <cursor>", which brings up to a page
; of seen events with the events themselves inline (no get per event), admits
; the ones this machine wants, and pulls again at once while there is more, up
; to PULLS a call; "more" tells the caller to call again soon. There is no
; follow + get fallback: only pull leaves private/ scopes out (ticket 0063).
;
; Addresses: "host:port" is plain TCP (loopback, or the SSH tunnel). A gate
; (field/gate.wisp, ticket 0051) is "tls:<server name>:<host:port>:<key>":
; TLS checked against <server name>, then the gate's challenge signed with this
; daemon's key <key>. Either way the result is a connection to a store.
;
; Woken, not polled: (peer-watch name remote) keeps a connection open on which
; the remote store says "new head" each time it sees an event, and the session
; steps on each one (on-data). A slow tick steps too, and re-opens the watch
; when it has closed, so a dropped tunnel only costs latency.
;
;   field/peers/<name>         the cursor: the last remote seen event we finished
;   field/peers/<name>.watch   the open watch connection's id, or nothing
;   field/peers/<name>.blobs   blobs (sha256 lines) an admitted event links that
;                              could not be fetched yet; tried again each pull
;
; Blobs (SPEC-node 7.1): after admitting an event, the blobs it links (link
; blob <sha256> ...) that the local store lacks ("has-blob") are fetched from
; the remote with "blob <sha256>", checked against that name, and handed to
; the local store with "put-blob", which checks again. Both ends are
; reached by request, never this session's own disk, so a pull with the ends
; swapped (the desktop's server3-push) carries blobs too (ticket 0137).
(module peer
  (provide peer-request peer-pull peer-dial peer-state peer-watch peer-watching peer-unwatch)

  (define PULLS 8)   ; pages per peer-pull call

  (define find-byte (lambda (s b i) (string-index s b i)))
  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))

  (define split-from (lambda (s b i acc)
    (let (j (find-byte s b i))
      (let (end (if (< j 0) (string-len s) j))
        (let (acc2 (if (< i end) (list-push acc (substring s i end)) acc))
          (if (< j 0) acc2 (split-from s b (+ j 1) acc2)))))))

  (define num->str (lambda (n)
    (if (< n 10) (substring "0123456789" n (+ n 1))
      (string-append (num->str (/ n 10)) (num->str (- n (* 10 (/ n 10))))))))
  (define digits-from (lambda (s i acc)
    (if (= i (string-len s)) acc
      (digits-from s (+ i 1) (+ (* acc 10) (- (s32 (string-ref s i)) 48))))))

  (define recv-until (lambda (conn buf need tries)
    (if (>= (string-len buf) need) buf
      (if (= tries 0) buf
        (match (tcp-receive conn 65536)
          ((ok bs) (if (= (length bs) 0) buf
                     (recv-until conn (string-append buf (bytes->string bs)) need (- tries 1))))
          ((err e) buf))))))

  ; the reply's header: read until there is a newline
  (define recv-line (lambda (conn buf tries)
    (if (>= (find-byte buf b-nl 0) 0) buf
      (if (= tries 0) buf
        (match (tcp-receive conn 65536)
          ((ok bs) (if (= (length bs) 0) buf
                     (recv-line conn (string-append buf (bytes->string bs)) (- tries 1))))
          ((err e) buf))))))

  ; send one request on an open connection -> (list leftover-ok? payload):
  ; (list 1 payload) for ok, (list 0 reason) otherwise
  (define peer-request (lambda (conn text)
    (begin
      (tcp-send conn text)
      (let (buf (recv-line conn "" 64))
        (let (j (find-byte buf b-nl 0))
          (if (< j 0) (list 0 "no reply")
            (let (head (split-from (substring buf 0 j) b-space 0 (list)))
              (let (n (digits-from (list-get head 1) 0 0))
                (let (all (recv-until conn buf (+ (+ j 1) n) 4096))
                  (if (< (string-len all) (+ (+ j 1) n)) (list 0 "short reply")
                    (list (if (string=? (list-get head 0) "ok") 1 0)
                          (substring all (+ j 1) (+ (+ j 1) n)))))))))))))

  ; an event file ("sig <hex>\n<text>") into the local store -> "" or the error
  (define admit-file (lambda (local file)
    (let (j (find-byte file b-nl 0))
      (let (sig (substring file 4 j))
        (let (text (substring file (+ j 1) (string-len file)))
          (let (a (peer-request local
                    (string-append "admit " sig " " (num->str (string-len text)) "\n" text)))
            (if (= (list-get a 0) 0) (string-append "admit: " (list-get a 1)) "")))))))

  (define cursor-path (lambda (name) (string-append "field/peers/" name)))
  (define peer-state (lambda (name)
    (match (fs-read-text (cursor-path name)) ((ok t) t) ((err e) ""))))

  ; ── the watch ─────────────────────────────────────────────────────────
  (define watch-path (lambda (name) (string-append "field/peers/" name ".watch")))
  (define peer-watching (lambda (name)
    (match (fs-read-text (watch-path name)) ((ok t) t) ((err e) ""))))
  (define peer-unwatch (lambda (name) (begin (fs-write (watch-path name) "") "unwatched")))

  ; open a watch on the remote store unless one is open -> a label. Its replies
  ; arrive as on-data (the only active connection in the session).
  (define peer-watch (lambda (name remote-addr)
    (if (string=? (peer-watching name) "")
      (match (peer-dial remote-addr)
        ((err e) "remote unreachable")
        ((ok c)
          (begin
            (tcp-set-active c "active")
            (tcp-send c "watch\n")
            (fs-write (watch-path name) c)
            "watching")))
      "already watching")))

  ; ── dialing ───────────────────────────────────────────────────────────
  ; "tls:<name>:<host:port>:<key>" -> (list name host:port key), else (list)
  (define tls-parts (lambda (addr)
    (if (= (has-prefix addr "tls:") 0) (list)
      (let (w (split-from (substring addr 4 (string-len addr)) (string-ref ":" 0) 0 (list)))
        (if (= (length w) 4)
          (list (list-get w 0) (string-append (list-get w 1) ":" (list-get w 2)) (list-get w 3))
          (list))))))

  ; the gate's handshake on conn -> "" or what went wrong
  (define gate-hello (lambda (conn name key)
    (match (tcp-tls-client conn name)
      ((err e) "tls failed")
      ((ok x)
        (let (line (begin (tcp-send conn "hello\n") (recv-line conn "" 64)))
          (let (j (find-byte line b-nl 0))
            (if (or (< j 0) (= (has-prefix line "challenge ") 0)) "no challenge"
              (match (sign key (string-append "field-gate " (substring line 10 j)))
                ((err e) "cannot sign")
                ((ok sig)
                  (begin
                    (tcp-send conn (string-append "auth " key " " sig "\n"))
                    (let (ok (recv-line conn "" 64))
                      (if (has-prefix ok "ok\n") "" "refused"))))))))))))

  ; addr (see the top) -> (ok conn) or (err why)
  (define peer-dial (lambda (addr)
    (let (t (tls-parts addr))
      (if (null? t) (tcp-connect addr)
        (match (tcp-connect (list-get t 1))
          ((err e) (err "unreachable"))
          ((ok c)
            (let (h (gate-hello c (list-get t 0) (list-get t 2)))
              (if (string=? h "") (ok c) (begin (tcp-close c) (err h))))))))))

  ; ── pulling ───────────────────────────────────────────────────────────
  (define has-prefix (lambda (s p)
    (if (< (string-len s) (string-len p)) 0 (string=? (substring s 0 (string-len p)) p))))
  ; wants: scope prefixes this machine keeps; an empty list keeps everything
  (define wanted? (lambda (scope wants)
    (if (null? wants) 1
      (if (= (has-prefix scope (car wants)) 1) 1 (wanted? scope (cdr wants))))))

  ; ── blobs ─────────────────────────────────────────────────────────────
  ; the sha256s an event file's "link blob <sha256> ..." lines name (they come
  ; before its body line)
  (define blob-links (lambda (file i acc)
    (let (j (find-byte file b-nl i))
      (if (< j 0) acc
        (let (l (substring file i j))
          (if (= (has-prefix l "body ") 1) acc
            (blob-links file (+ j 1)
              (if (= (has-prefix l "link blob ") 1)
                (let (w (split-from l b-space 0 (list))) (if (< 2 (length w)) (list-push acc (list-get w 2)) acc))
                acc))))))))
  (define blobs-path (lambda (name) (string-append "field/peers/" name ".blobs")))
  ; copy one blob from remote to local unless local has it -> 1 when local
  ; has it after
  (define fetch-blob (lambda (remote local h)
    (let (have (peer-request local (string-append "has-blob " h "\n")))
      (if (and (= (list-get have 0) 1) (string=? (list-get have 1) "1")) 1
        (let (r (peer-request remote (string-append "blob " h "\n")))
          (if (= (list-get r 0) 0) 0
            (let (b (list-get r 1))
              (if (string=? (sha256 b) h)
                (let (p (peer-request local (string-append "put-blob " h " " (num->str (string-len b)) "\n" b)))
                  (if (and (= (list-get p 0) 1) (string=? (list-get p 1) h)) 1 0))
                0))))))))
  ; copy each of hs; -> the ones still missing
  (define fetch-blobs (lambda (remote local hs out)
    (if (null? hs) out
      (fetch-blobs remote local (cdr hs) (if (= (fetch-blob remote local (car hs)) 1) out (list-push out (car hs)))))))
  (define push-all (lambda (xs ys) (if (null? ys) xs (push-all (list-push xs (car ys)) (cdr ys)))))
  (define join-lines (lambda (xs acc) (if (null? xs) acc (join-lines (cdr xs) (string-append acc (car xs) "\n")))))
  ; try the pending ones again, plus hs -> nothing; what is still missing stays pending
  (define settle-blobs (lambda (name remote local hs)
    (let (pend (split-from (match (fs-read-text (blobs-path name)) ((ok t) t) ((err e) "")) b-nl 0 (list)))
      (let (all (push-all pend hs))
        (if (null? all) "none"
          (fs-write (blobs-path name) (join-lines (fetch-blobs remote local all (list)) "")))))))

  ; admit the records of a pull payload p from i -> "" or the error
  (define admit-records (lambda (local p i wants)
    (if (>= i (string-len p)) ""
      (let (j (find-byte p b-nl i))
        (if (< j 0) "bad record"
          (let (w (split-from (substring p i j) b-space 0 (list)))
            (if (< (length w) 4) "bad record"
              (let (end (+ (+ j 1) (digits-from (list-get w 3) 0 0)))
                (if (< (string-len p) end) "short record"
                  (let (r (if (= (wanted? (list-get w 1) wants) 1)
                            (admit-file local (substring p (+ j 1) end)) ""))
                    (if (string=? r "") (admit-records local p end wants) r)))))))))))
  ; the blobs the wanted records of p from i link, added to acc
  (define record-blobs (lambda (p i wants acc)
    (let (j (find-byte p b-nl i))
      (if (< j 0) acc
        (let (w (split-from (substring p i j) b-space 0 (list)))
          (if (< (length w) 4) acc
            (let (end (+ (+ j 1) (digits-from (list-get w 3) 0 0)))
              (if (< (string-len p) end) acc
                (record-blobs p end wants
                  (if (= (wanted? (list-get w 1) wants) 1) (blob-links (substring p (+ j 1) end) 0 acc) acc))))))))))

  (define pull-on (lambda (name remote local wants k)
    (let (after (peer-state name))
      (let (f (peer-request remote (string-append "pull " (if (string=? after "") "-" after) "\n")))
        (if (= (list-get f 0) 0)
          "pull failed"
          (let (p (list-get f 1))
            (let (j (find-byte p b-nl 0))
              (let (head (split-from (substring p 0 j) b-space 0 (list)))
                (let (cursor (list-get head 0))
                  (if (or (string=? cursor "-") (string=? cursor after)) (begin (settle-blobs name remote local (list)) "idle")
                    (if (string=? (admit-records local p (+ j 1) wants) "")
                      (begin
                        (settle-blobs name remote local (record-blobs p (+ j 1) wants (list)))
                        (fs-write-durable (cursor-path name) cursor)
                        (if (string=? (list-get head 1) "1")
                          (if (< 1 k) (pull-on name remote local wants (- k 1)) "more")
                          "copied"))
                      "copy failed")))))))))))

  ; Open both connections and pull until caught up or PULLS pages -> a label:
  ; "more" (call again soon), "copied", "idle", or what failed.
  (define peer-pull (lambda (name remote-addr local-addr wants)
    (match (peer-dial remote-addr)
      ((err e) "remote unreachable")
      ((ok remote)
        (match (peer-dial local-addr)
          ((err e) (begin (tcp-close remote) "local unreachable"))
          ((ok local)
            (let (r (pull-on name remote local wants PULLS))
              (begin (tcp-close remote) (tcp-close local) r))))))))
)
