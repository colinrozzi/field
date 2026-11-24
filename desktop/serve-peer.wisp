; This machine and server3's store, both directions, through server3's gate
; (field/gate.wisp: TLS to new.colinrozzi.com:7443, then a challenge signed
; with this daemon's "desktop" key). server3 can't reach us, so this session
; does both: "server3" pulls server3's events into our store, and
; "server3-push" pulls our events into server3's store (peer-pull with the two
; ends swapped). Ticket 0051; before it, an SSH tunnel and a peer on each side.
(require peer "experiment/field/peer.wisp")
(event-buffer 64)
(fs-mkdir "field/peers")
(define LOCAL "127.0.0.1:7800")
(define GATE "tls:new.colinrozzi.com:new.colinrozzi.com:7443:desktop")
(define IN "server3")
(define OUT "server3-push")
; scope prefixes we keep of what server3 shares, and that we send it; (list) = all
(define WANTS (list))
(define SENDS (list))
; Each direction pulls until caught up; while there is more, its catchup timer
; keeps going. While a blob it admitted an event for couldn't be copied, its
; blobs timer pulls again every 3 s, for a while after the pending list last
; changed (peer-blobs-fast?), so a deploy's bundle doesn't wait for the next
; event or the minute tick (11-24: pages v41 waited 2 minutes for its bundle;
; the reason is in .blobs-why), and a link to a blob nobody has costs nothing.
(define pending? (lambda (name) (peer-blobs-fast? name)))
(define pull-in (lambda ()
  (let (r (peer-pull IN GATE LOCAL WANTS))
    (begin (if (string=? r "more") (set-interval "catchup-in" 50) (clear-interval "catchup-in"))
           (if (= (pending? IN) 1) (set-interval "blobs-in" 3000) (clear-interval "blobs-in")) r))))
(define pull-out (lambda ()
  (let (r (peer-pull OUT LOCAL GATE SENDS))
    (begin (if (string=? r "more") (set-interval "catchup-out" 50) (clear-interval "catchup-out"))
           (if (= (pending? OUT) 1) (set-interval "blobs-out" 3000) (clear-interval "blobs-out")) r))))
; Woken by watches: on server3's store (something new there) and on ours.
(peer-unwatch IN)
(peer-unwatch OUT)
(define on-data (lambda (e)
  (if (string=? (car e) (peer-watching IN)) (pull-in)
    (if (string=? (car e) (peer-watching OUT)) (pull-out) "other"))))
(define on-close (lambda (e)
  (if (string=? (car e) (peer-watching IN)) (peer-unwatch IN)
    (if (string=? (car e) (peer-watching OUT)) (peer-unwatch OUT) "other"))))
; the minute tick is the backstop, and re-opens a watch that closed
(define on-tick (lambda (name)
  (if (or (string=? name "catchup-in") (string=? name "blobs-in")) (pull-in)
    (if (or (string=? name "catchup-out") (string=? name "blobs-out")) (pull-out)
      (begin (peer-watch IN GATE) (peer-watch OUT LOCAL) (pull-in) (pull-out))))))
(peer-watch IN GATE)
(peer-watch OUT LOCAL)
(set-interval "follow" 60000)
; A receive that hears nothing for 20 s gives up (wisp #139), so a
; half-open connection can't hold this session (it held it 5 h on 2026-11-17):
; the pull says it failed and the next tick tries again from the cursor. Only
; on a daemon that has the verb (its tcp help names it). 20 s, not 2 minutes
; (2026-11-24): theater's send doesn't flush, so the tail of a big put-blob
; through the TLS gate can sit unsent until the connection closes, and the
; node's reply then only comes after this timeout; the retry finds the blob
; there. Until theater flushes, this bound is the wait. The timeout is the
; whole daemon's (theater keeps it on state every actor shares), and nothing on
; the desktop waits on a pull read anywhere near 20 s (the hub's one-line
; replies, the supervisor's checks, the field clients).
(define has-text (lambda (s p i)
  (if (< (string-len s) (+ i (string-len p))) 0
    (if (string=? (substring s i (+ i (string-len p))) p) 1 (has-text s p (+ i 1))))))
(if (= (has-text (help "tcp") "tcp-set-read-timeout" 0) 1) (tcp-set-read-timeout 20000) "no read timeout on this daemon")
