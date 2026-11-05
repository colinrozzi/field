; serve-field.wisp — start a field store in this session, as a boot-list
; service. Set STORE and LISTEN for the machine.
(require server "experiment/field/server.wisp")
(require store "experiment/field/store.wisp")
(define STORE "desktop")
(define LISTEN "127.0.0.1:7800")
(event-buffer 64)
(define on-connection (lambda (cid) (field-connection cid)))
(define on-data (lambda (e) (field-data STORE e)))
(define on-close (lambda (e) (field-closed e)))
(field-serve STORE LISTEN)
