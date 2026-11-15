; Live documents (field/docs.wisp), as a boot-list service on :7803.
(require docs "experiment/field/docs.wisp")
(event-buffer 64)
(step-limit 20000000)
(define on-connection (lambda (cid) (docs-connection cid)))
(define on-data (lambda (e) (docs-data e)))
(define on-close (lambda (e) (docs-closed e)))
(docs-serve DOCS-LISTEN "127.0.0.1:7800")
