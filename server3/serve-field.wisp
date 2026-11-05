; server3's field store, as a boot-list service. Reached from the laptop only
; through the ssh tunnel (field/tunnel); listens on loopback.
(require server "experiment/field/server.wisp")
(define STORE "server3")
(event-buffer 64)
(define on-connection (lambda (cid) (field-connection cid)))
(define on-data (lambda (e) (field-data STORE e)))
(define on-close (lambda (e) (field-closed e)))
(field-serve STORE "127.0.0.1:7800")
