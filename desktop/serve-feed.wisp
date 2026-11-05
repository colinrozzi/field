; The feed (field/feed.wisp), as a boot-list service. A restart changes its id,
; and github-events may restart too, so it subscribes again on every tick;
; a repeat just replaces the same subscription.
(require feed "experiment/field/feed.wisp")
(event-buffer 64)
(msg-register)
(define on-message (lambda (e) (feed-message (bytes->string (car e)))))
(define on-connection (lambda (cid) (feed-connection cid)))
(define on-data (lambda (e) (feed-data e)))
(define on-close (lambda (e) "closed"))
(define subscribe (lambda ()
  (match (fs-read-text "experiment/run/github-events")
    ((ok id) (begin
      (msg-send (substring id 0 36) (string-append "subscribe " (string-append (self) " all")))
      "subscribed"))
    ((err e) "no github-events"))))
(define on-tick (lambda (name) (subscribe)))
(tcp-listen FEED-LISTEN)
(subscribe)
(set-interval "subscribe" 300000)
