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
; keeps going.
(define pull-in (lambda ()
  (let (r (peer-pull IN GATE LOCAL WANTS))
    (begin (if (string=? r "more") (set-interval "catchup-in" 50) (clear-interval "catchup-in")) r))))
(define pull-out (lambda ()
  (let (r (peer-pull OUT LOCAL GATE SENDS))
    (begin (if (string=? r "more") (set-interval "catchup-out" 50) (clear-interval "catchup-out")) r))))
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
  (if (string=? name "catchup-in") (pull-in)
    (if (string=? name "catchup-out") (pull-out)
      (begin (peer-watch IN GATE) (peer-watch OUT LOCAL) (pull-in) (pull-out))))))
(peer-watch IN GATE)
(peer-watch OUT LOCAL)
(set-interval "follow" 60000)
