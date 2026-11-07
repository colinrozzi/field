; docmodel.wisp — the document model of field/SPEC-doc.md, section 2, kept in
; files beside chatmodel.wisp's (same dir). It passes field/vectors/doc/
; (field/vectors/doc/run). Feed each chat event to chat-add, then to doc-add:
;
;   (doc-add dir id scope kind text)   text: the canonical text (no sig line)
;
; and ask: doc-list, doc-sections, doc-edit, doc-history, doc-comments,
; doc-resolved, and (SPEC-doc 5) doc-links, doc-backlinks, doc-wiki. Under `dir`:
;
;   <dir>/e/<id>                    an edit: "<time> <b> <sec> <from>\n<parents>\n<after>\n<title>\n<text>"
;   <dir>/d/<b>/secs                section names, in arrival order
;   <dir>/d/<b>/s/<sec>/history|heads   edit ids, one per line
;   <dir>/d/<b>/s/<sec>/first       "<time> <id>" of its earliest edit; place: that edit's after
;   <dir>/d/<b>/c/<sec>             comment ids, in arrival order
;   <dir>/r/<root>                  "yes" or "no"; rt/<root> is "<time> <id>" of that reply
;   <dir>/ds/<D>/<key>              a document in scope doc/<D> (field/SPEC-group.md 6): its
;                                   doc.set values; st/<key> is "<time> <id>" of the set
; A document is named by its branch, or doc/<D> for one in its own scope.
(module docmodel
  (provide doc-add doc-list doc-sections doc-edit doc-history doc-comments doc-resolved doc-start
           doc-links doc-backlinks doc-wiki doc-resolve)
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
           (fs-mkdir (string-append dir "/e")) (fs-mkdir (string-append dir "/d")) (fs-mkdir (string-append dir "/d/doc"))
           (fs-mkdir (string-append dir "/ds"))
           (fs-mkdir (string-append dir "/r")) (fs-mkdir (string-append dir "/rt")) dir)))
  (define doc-dir (lambda (dir b)
    (begin (fs-mkdir (dpath dir b)) (fs-mkdir (string-append (dpath dir b) "/s"))
           (fs-mkdir (string-append (dpath dir b) "/c")) b)))

  ; ── adding one event (2) ──────────────────────────────────────────────
  (define has-prefix (lambda (s p)
    (if (< (string-len s) (string-len p)) 0 (if (string=? (substring s 0 (string-len p)) p) 1 0))))
  (define doc-add (lambda (dir id scope kind text)
    (let (c (chat-canon text))
      (let (h (chat-headers (list-get c 2)))
        (let (hdr (lambda (k) (chat-hdr (list-get h 0) k)))
          (if (string=? scope "chat/main")
            (if (string=? kind "chat.edit") (if (= (chat-name? (hdr "in")) 1) (add-edit dir id c hdr (list-get h 1) (hdr "in")) "")
              (if (string=? kind "chat.msg") (add-msg dir id c hdr) ""))
            (if (and (= (has-prefix scope "doc/") 1) (= (chat-name? (rest-of scope 4)) 1))
              (if (string=? kind "doc.edit") (add-edit dir id c hdr (list-get h 1) scope)
                (if (string=? kind "doc.set") (add-set dir id c hdr (rest-of scope 4) (list-get h 1)) ""))
              "")))))))

  ; doc.set: title, status, group, branch or wiki; the newest (time, id) wins
  (define add-set (lambda (dir id c hdr d v)
    (let (k (hdr "key"))
      (if (not (in? k (list "title" "status" "group" "branch" "wiki"))) ""
        (let (st (string-append dir "/ds/" d "/st"))
          (begin
            (fs-mkdir (string-append dir "/ds/" d)) (fs-mkdir st)
            (if (= (chat-newer (list-get c 0) id (read-or (string-append st "/" k) "")) 1)
              (begin (fs-write (string-append dir "/ds/" d "/" k) v)
                     (fs-write (string-append st "/" k) (string-append (list-get c 0) " " id)) id)
              "")))))))

  (define add-edit (lambda (dir id c hdr text b)
    (begin
      (let (s (hdr "sec"))
        (if (or (= (chat-name? s) 0) (= (fs-exists-1 (epath dir id)) 1)) ""
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
                  ; on a document in doc/<D> with a doc header (SPEC-group 6), else on the branch's own
                  (let (key (if (= (chat-name? (hdr "doc")) 1) (string-append "doc/" (hdr "doc")) b))
                    (begin (doc-dir dir key) (fs-append (cpath dir key s) (string-append id "\n")) id))))
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

  ; every document, by name: (list name title status). A branch whose doc
  ; moved (state doc-moved) is listed as its new one only.
  (define doc-list (lambda (dir)
    (sort (lambda (x y) (chat-str-lt (car x) (car y)))
      (filter (lambda (d) (< 0 (string-len (list-get d 1))))
        (append
          (map (lambda (b)
                 (let (st (read-or (string-append dir "/b/" b "/state/doc-status") ""))
                   (list b (if (string=? (read-or (string-append dir "/b/" b "/state/doc-moved") "") "")
                             (read-or (string-append dir "/b/" b "/state/doc") "") "")
                         (if (string=? st "") "draft" st))))
               (dir-names (string-append dir "/b")))
          (map (lambda (d)
                 (let (st (read-or (string-append dir "/ds/" d "/status") ""))
                   (list (string-append "doc/" d) (read-or (string-append dir "/ds/" d "/title") "") (if (string=? st "") "draft" st))))
               (dir-names (string-append dir "/ds"))))))))

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

  ; ── links and the wiki (SPEC-doc 5) ───────────────────────────────────
  (define b-tick (string-ref "`" 0))
  (define b-lb (string-ref "[" 0))
  (define b-rb (string-ref "]" 0))
  (define b-hash (string-ref "#" 0))
  ; a line without its code spans: each from a backtick to the next one on
  ; the line (a backtick with no partner stays)
  (define strip-code (lambda (s i acc)
    (let (a (string-index s b-tick i))
      (if (< a 0) (string-append acc (rest-of s i))
        (let (z (string-index s b-tick (+ a 1)))
          (if (< z 0) (string-append acc (rest-of s i))
            (strip-code s (+ z 1) (string-append acc (substring s i a)))))))))
  ; the index of the next "]]" from i, or -1
  (define find-close (lambda (s i)
    (let (k (string-index s b-rb i))
      (if (or (< k 0) (<= (string-len s) (+ k 1))) -1
        (if (= (string-ref s (+ k 1)) b-rb) k (find-close s (+ k 1)))))))
  ; inner text of [[...]] -> "D S" (S empty for [[D]]), or "" when not a link
  (define link-key (lambda (inner)
    (let (h (string-index inner b-hash 0))
      (if (< h 0) (if (= (chat-name? inner) 1) (string-append inner " ") "")
        (let (d (substring inner 0 h))
          (let (sec (rest-of inner (+ h 1)))
            (if (and (= (chat-name? d) 1) (= (chat-name? sec) 1)) (string-append d " " sec) "")))))))
  (define line-links (lambda (s i acc)
    (let (a (string-index s b-lb i))
      (if (or (< a 0) (<= (string-len s) (+ a 1))) acc
        (if (not (= (string-ref s (+ a 1)) b-lb)) (line-links s (+ a 1) acc)
          (let (z (find-close s (+ a 2)))
            (if (< z 0) acc
              (let (k (link-key (substring s (+ a 2) z)))
                (line-links s (+ z 2) (if (or (string=? k "") (in? k acc)) acc (list-push acc k)))))))))))
  ; the links in a text, outside code blocks and spans, as "D S" keys
  (define text-links (lambda (text)
    (list-get
      (fold (lambda (st line)
              (if (= (has-prefix line "```") 1) (list (list-get st 0) (if (= (list-get st 1) 1) 0 1))
                (if (= (list-get st 1) 1) st
                  (list (line-links (strip-code line 0 "") 0 (list-get st 0)) 0))))
            (list (list) 0) (split-on text b-nl 0 (list)))
      0)))
  ; a document's links: (list (list D S) ...), sorted, from every head of
  ; every section not removed
  (define doc-links (lambda (dir b)
    (map (lambda (k) (let (sp (string-index k b-space 0)) (list (substring k 0 sp) (rest-of k (+ sp 1)))))
      (sort chat-str-lt
        (fold (lambda (acc x)
                (if (list-get x 2) acc
                  (fold (lambda (a h) (fold (lambda (a2 k) (if (in? k a2) a2 (list-push a2 k))) a (text-links (list-get (doc-edit dir h) 7))))
                        acc (list-get x 1))))
              (list) (doc-sections dir b))))))
  ; the document [[name]] resolves to, or ""
  (define doc-resolve (lambda (dir name)
    (if (= (chat-name? name) 0) ""
      (if (not (string=? (read-or (string-append dir "/ds/" name "/title") "") "")) (string-append "doc/" name)
        (let (mv (read-or (string-append dir "/b/" name "/state/doc-moved") ""))
          (if (and (not (string=? mv "")) (not (string=? (read-or (string-append dir "/ds/" mv "/title") "") "")))
            (string-append "doc/" mv)
            (if (string=? (read-or (string-append dir "/b/" name "/state/doc") "") "") "" name)))))))
  ; the other documents with a link resolving to key, sorted by name
  (define doc-backlinks (lambda (dir key)
    (filter (lambda (k)
              (and (not (string=? k key))
                   (< 0 (length (filter (lambda (l) (string=? (doc-resolve dir (list-get l 0)) key)) (doc-links dir k))))))
            (map car (doc-list dir)))))
  ; a doc/<D> document's wiki topic, or ""
  (define doc-wiki (lambda (dir key)
    (if (= (has-prefix key "doc/") 1) (read-or (string-append dir "/ds/" (rest-of key 4) "/wiki") "") "")))

  (define doc-history (lambda (dir b s) (set-of (spath dir b s "history"))))
  (define doc-comments (lambda (dir b s) (set-of (cpath dir b s))))
  (define doc-resolved (lambda (dir root) (read-or (string-append dir "/r/" root) "")))
)
