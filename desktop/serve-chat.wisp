; Chat posting (field/chat.wisp), as a boot-list service on :7804.
(require chat "experiment/field/chat.wisp")
(event-buffer 64)
(define on-connection (lambda (cid) (chat-connection cid)))
(define on-data (lambda (e) (chat-data e)))
(define on-close (lambda (e) (chat-closed e)))
(chat-serve "127.0.0.1:7804")
