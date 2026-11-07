; docmodel.wisp — the document model of field/SPEC-doc.md, section 2, kept in
; files beside chatmodel.wisp's (same dir). It passes field/vectors/doc/
; (field/vectors/doc/run). Feed each chat event to chat-add, then to doc-add:
;
;   (doc-add dir id scope kind text)   text: the canonical text (no sig line)
;
; and ask: doc-list, doc-sections, doc-edit, doc-history, doc-comments,
; doc-resolved. Under `dir`:
;
;   <dir>/e/<id>                    an edit: "<time> <b> <sec> <from>\n<parents>\n<after>\n<title>\n<text>"
;   <dir>/d/<b>/secs                section names, in arrival order
;   <dir>/d/<b>/s/<sec>/history|heads   edit ids, one per line
;   <dir>/d/<b>/s/<sec>/first       "<time> <id>" of its earliest edit; place: that edit's after
;   <dir>/d/<b>/c/<sec>             comment ids, in arrival order
;   <dir>/r/<root>                  "yes" or "no"; rt/<root> is "<time> <id>" of that reply
(module docmodel
  (provide doc-add doc-list doc-sections doc-edit doc-history doc-comments doc-resolved doc-start)
  (require list "std/list.wisp")
  (require chatmodel "experiment/field/chatmodel.wisp")

  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define rest-of (lambda (s i) (substring s i (string-len s))))
  (define read-or (lambda (p d) (match (fs-read-text p) ((ok t) t) ((err e) d))))
  (define fs-exists-1 (lambda (p) (match (fs-exists p) ((ok v) (if v 1 0)) ((err e) 0))))
  (define nonempty (lambda (xs) (filter (lambda (x) (< 0 (string-len x))) xs)))
  (define split-on (lambda (s b i acc)
    (let (j (string-index s b i))
      (if (< j 0) (list-push acc (rest-of s i))
        (split-on s b (+ j 1) (list-push acc (substring s i j)))))))
  (define lines (lambda (s) (nonempty (split-on s b-nl 0 (list)))))
  (define words (lambda (s) (nonempty (split-on s b-space 0 (list)))))
  (define join-lines (lambda (xs) (fold (lambda (acc x) (string-append acc x "\n")) "" xs)))
  (define join-words (lambda (xs) (fold (lambda (acc x) (if (string=? acc "") x (string-append acc " " x))) "" xs)))
  (define in? (lambda (x xs) (= (member x xs string=?) 1)))
  (define set-of (lambda (p) (lines (read-or p ""))))
  (define add-to (lambda (p x) (if (in? x (set-of p)) 0 (fs-append p (string-append x "\n")))))
  (define move-tips (lambda (p par id)
    (fs-write p (join-lines (list-push (filter (lambda (y) (if (in? y par) (= 0 1) (= 0 0))) (set-of p)) id)))))
  (define dir-names (lambda (p)
    (match (fs-list p)
      ((ok es) (map (lambda (e) (match e ((dir-entry name d) name))) es))
      ((err e) (list)))))

  (define epath (lambda (dir id) (string-append dir "/e/" id)))
  (define dpath (lambda (dir b) (string-append dir "/d/" b)))
  (define spath (lambda (dir b s f) (string-append dir "/d/" b "/s/" s "/" f)))
  (define cpath (lambda (dir b s) (string-append dir "/d/" b "/c/" s)))

  (define doc-start (lambda (dir)
    (begin (chat-start dir)
           (fs-mkdir (string-append dir "/e")) (fs-mkdir (string-append dir "/d"))
           (fs-mkdir (string-append dir "/r")) (fs-mkdir (string-append dir "/rt")) dir)))
  (define doc-dir (lambda (dir b)
    (begin (fs-mkdir (dpath dir b)) (fs-mkdir (string-append (dpath dir b) "/s"))
           (fs-mkdir (string-append (dpath dir b) "/c")) b)))

  ; ── adding one event (2) ──────────────────────────────────────────────
  (define doc-add (lambda (dir id scope kind text)
    (if (not (string=? scope "chat/main")) ""
      (let (c (chat-canon text))
        (let (h (chat-headers (list-get c 2)))
          (let (hdr (lambda (k) (chat-hdr (list-get h 0) k)))
            (if (string=? kind "chat.edit") (add-edit dir id c hdr (list-get h 1))
              (if (string=? kind "chat.msg") (add-msg dir id c hdr) ""))))))))

  (define add-edit (lambda (dir id c hdr text)
    (let (b (hdr "in"))
      (let (s (hdr "sec"))
        (if (or (= (chat-name? b) 0) (= (chat-name? s) 0) (= (fs-exists-1 (epath dir id)) 1)) ""
          (let (who (if (string=? (hdr "from") "") "?" (hdr "from")))
            (let (t (list-get c 0))
              (begin
                (fs-write (epath dir id)
                  (string-append t " " b " " s " " who "\n" (join-words (list-get c 1)) "\n"
                                 (hdr "after") "\n" (hdr "title") "\n" text))
                (doc-dir dir b)
                (fs-mkdir (string-append (dpath dir b) "/s/" s))
                (add-to (string-append (dpath dir b) "/secs") s)
                (fs-append (spath dir b s "history") (string-append id "\n"))
                (move-tips (spath dir b s "heads") (list-get c 1) id)
                (let (first (read-or (spath dir b s "first") ""))
                  (if (or (string=? first "") (= (chat-newer t id first) 0))
                    (begin (fs-write (spath dir b s "first") (string-append t " " id))
                           (fs-write (spath dir b s "place") (hdr "after")))
                    0))
                id))))))))

  ; a comment (a post with sec) or a resolve (a reply with resolve yes|no)
  (define add-msg (lambda (dir id c hdr)
    (let (m (chat-msg dir id))
      (if (null? m) ""
        (let (b (list-get m 0))
          (let (re (list-get m 2))
            (if (string=? re "")
              (let (s (hdr "sec"))
                (if (= (chat-name? s) 0) ""
                  (begin (doc-dir dir b) (fs-append (cpath dir b s) (string-append id "\n")) id)))
              (let (v (hdr "resolve"))
                (if (or (string=? v "yes") (string=? v "no"))
                  (let (t (list-get c 0))
                    (if (= (chat-newer t id (read-or (string-append dir "/rt/" re) "")) 1)
                      (begin (fs-write (string-append dir "/r/" re) v)
                             (fs-write (string-append dir "/rt/" re) (string-append t " " id))
                             id)
                      ""))
                  "")))))))))

  ; ── asking (3) ────────────────────────────────────────────────────────
  ; (list b sec from time title after parents text), or (list)
  (define doc-edit (lambda (dir id)
    (match (fs-read-text (epath dir id))
      ((err e) (list))
      ((ok t)
        (let (l (split-on t b-nl 0 (list)))
          (let (w (words (list-get l 0)))
            (list (list-get w 1) (list-get w 2) (list-get w 3) (list-get w 0) (list-get l 3) (list-get l 2)
                  (words (list-get l 1))
                  ; the text: everything after the fourth LF
                  (rest-of t (+ 1 (string-index t b-nl (+ 1 (string-index t b-nl (+ 1 (string-index t b-nl (+ 1 (string-index t b-nl 0))))))))))))))))

  ; edit id -> "<time> <id>", for ordering
  (define stamp (lambda (dir id) (string-append (list-get (doc-edit dir id) 3) " " id)))
  ; is stamp a newer than stamp b?
  (define stamp-gt (lambda (a b)
    (let (w (words a)) (if (string=? a b) (= 0 1) (= (chat-newer (list-get w 0) (list-get w 1) b) 1)))))

  ; (list (title status) ...) for each document, by branch: (list b title status)
  (define doc-list (lambda (dir)
    (filter (lambda (d) (< 0 (string-len (list-get d 1))))
      (map (lambda (b)
             (let (st (read-or (string-append dir "/b/" b "/state/doc-status") ""))
               (list b (read-or (string-append dir "/b/" b "/state/doc") "") (if (string=? st "") "draft" st))))
           (sort chat-str-lt (dir-names (string-append dir "/b")))))))

  ; a section's heads, newest first
  (define heads (lambda (dir b s)
    (sort (lambda (x y) (stamp-gt (stamp dir x) (stamp dir y))) (set-of (spath dir b s "heads")))))
  (define removed (lambda (dir hs)
    (if (= (length hs) 1)
      (let (e (doc-edit dir (car hs))) (and (string=? (list-get e 4) "") (string=? (list-get e 7) "")))
      (= 0 1))))

  ; the sections in order (3, "Order"): (list (sec heads removed) ...)
  (define doc-sections (lambda (dir b)
    (let (secs (set-of (string-append (dpath dir b) "/secs")))
      (let (parent (lambda (s)
                     (let (p (read-or (spath dir b s "place") ""))
                       (if (string=? p "") "" (if (and (in? p secs) (not (string=? p s))) p "-")))))
        (let (children (lambda (p)
                         (sort (lambda (x y) (stamp-gt (read-or (spath dir b x "first") "") (read-or (spath dir b y "first") "")))
                               (filter (lambda (s) (string=? (parent s) p)) secs))))
          (let (walk (lambda (self p acc)
                       (fold (lambda (a s) (self self s (list-push a s))) acc (children p))))
            (let (reached (walk walk "" (list)))
              (map (lambda (s) (let (hs (heads dir b s)) (list s hs (removed dir hs))))
                   (append reached (sort chat-str-lt (filter (lambda (s) (not (in? s reached))) secs)))))))))))

  (define doc-history (lambda (dir b s) (set-of (spath dir b s "history"))))
  (define doc-comments (lambda (dir b s) (set-of (cpath dir b s))))
  (define doc-resolved (lambda (dir root) (read-or (string-append dir "/r/" root) "")))
)
