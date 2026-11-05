; This machine's field store, as a boot-list service: the daemon restarts it if
; it dies, and events are in files, so nothing is lost.
(require server "experiment/field/server.wisp")
(define STORE "desktop")
(event-buffer 64)
(define on-connection (lambda (cid) (field-connection cid)))
(define on-data (lambda (e) (field-data STORE e)))
(define on-close (lambda (e) (field-closed e)))
(field-serve STORE "127.0.0.1:7800")
