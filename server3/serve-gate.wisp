; server3's public door to its field store (field/gate.wisp, ticket 0051):
; TLS on :7443 with the new.colinrozzi.com certificate ([tcp.server_tls] in the
; daemon's config), then a signed challenge, then the store on loopback.
; Nodes allowed in are the lines of field/gate-keys: "<name> <public key hex>".
(require gate "experiment/field/gate.wisp")
(event-buffer 64)
(define ME "server3")
(define STORE "127.0.0.1:7800")
(define on-connection (lambda (cid) (gate-connection cid)))
(define on-data (lambda (e) (gate-data ME STORE e)))
(define on-close (lambda (e) (gate-closed e)))
(gate-serve "0.0.0.0:7443")
