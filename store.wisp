; store.wisp — a field store: one per machine, in its own session (see
; field/DESIGN.md). This is the core: events on disk, admission, the seen
; chain, following. server.wisp puts it on TCP, peer.wisp follows other stores.
;
; An author is an ed25519 public key. Keys live in the daemon ([keys] dir in its
; config); sessions sign by key name and never see a seed.
;
; All state is in files under field/, none in memory:
;   field/events/ab/cdef...    "sig <hex>\n" then the canonical text
;   field/seen-head            the id of this store's newest seen event
;   field/seen-first           the id of its first
;   field/seen-next/<id>       the seen event after <id>; a chain only links
;                              backwards, and follow has to walk forwards in
;                              pages (one evaluation is 1M steps, ~25 appends)
;   field/unseen/<id>          admitted but not yet in the seen chain; a crash
;                              leaves these, and field-start records them
;   field/subs                 subscribers: "<actor> <scope> <kind prefix>" lines
;   field/node                 this node's name (its key's name)
;   field/ids/<name>/...       identities (field/SPEC-id.md, idmodel.wisp), kept as
;                              id.* events are admitted
(module store
  (provide field-start field-append field-admit field-get field-exists field-file
           field-follow field-follow-n field-seen-head field-subscribe
           event-id event-author event-scope event-kind event-time
           event-parents event-links event-body event-sig bad? bad-reason)
  (require list "std/list.wisp")
  (require str "std/str.wisp")
  (require idmodel "experiment/field/idmodel.wisp")

  (define MAX-BODY 16384)
  (define FOLLOW-PAGE 16)   ; seen events per field-follow

  ; ── strings ───────────────────────────────────────────────────────────
  (define b-nl (string-ref "\n" 0))
  (define b-space (string-ref " " 0))
  (define b-slash (string-ref "/" 0))

  (define find-byte (lambda (s b i) (string-index s b i)))

  (define cat (lambda (xs)
    (fold (lambda (acc x) (string-append acc x)) "" xs)))

  ; split, dropping empty pieces
  (define nonempty (lambda (xs)
    (filter (lambda (x) (< 0 (string-len x))) xs)))
  (define lines (lambda (s) (nonempty (split s "\n"))))
  (define words (lambda (s) (nonempty (split s " "))))

  (define digits-from (lambda (s i acc)
    (if (= i (string-len s)) acc
      (digits-from s (+ i 1) (+ (* acc 10) (- (s32 (string-ref s i)) 48))))))
  (define str->num (lambda (s) (digits-from s 0 0)))

  (define all-digits-from (lambda (s i)
    (if (= i (string-len s)) 1
      (let (d (- (s32 (string-ref s i)) 48))
        (if (< d 0) 0 (if (< 9 d) 0 (all-digits-from s (+ i 1))))))))
  (define all-digits (lambda (s)
    (if (= (string-len s) 0) 0 (all-digits-from s 0))))

  ; an id: 64 lowercase hex characters. Ids become file paths, so nothing else
  ; may reach one.
  (define hex-from (lambda (s i)
    (if (= i (string-len s)) 1
      (let (c (s32 (string-ref s i)))
        (if (or (and (< 47 c) (< c 58)) (and (< 96 c) (< c 103))) (hex-from s (+ i 1)) 0)))))
  (define is-id (lambda (s) (if (= (string-len s) 64) (hex-from s 0) 0)))

  ; byte order: is a before b?
  (define str-lt-from (lambda (a b i)
    (if (= i (string-len b)) 0
      (if (= i (string-len a)) 1
        (let (x (s32 (string-ref a i)))
          (let (y (s32 (string-ref b i)))
            (if (< x y) 1 (if (< y x) 0 (str-lt-from a b (+ i 1))))))))))
  (define str-lt (lambda (a b) (str-lt-from a b 0)))

  (define insert-sorted (lambda (x xs)
    (if (null? xs) (list x)
      (if (str-lt x (car xs)) (cons x xs)
        (if (string=? x (car xs)) xs   ; a set: drop duplicates
          (cons (car xs) (insert-sorted x (cdr xs))))))))
  (define sort-set (lambda (xs)
    (fold (lambda (acc x) (insert-sorted x acc)) (list) xs)))

  ; ── keys ──────────────────────────────────────────────────────────────
  (define sha-of (lambda (text) (sha256 text)))
  ; a name's public key, created the first time; "" if the daemon has no keys
  (define author-of (lambda (name)
    (match (key-public name)
      ((ok k) k)
      ((err e) (match (key-new name) ((ok k) k) ((err x) ""))))))
  (define sign-by (lambda (name id)
    (match (sign name id) ((ok s) s) ((err e) ""))))
  (define sig-ok (lambda (author sig id) (if (verify author sig id) 1 0)))

  ; ── files ─────────────────────────────────────────────────────────────
  (define read-or (lambda (path dflt)
    (match (fs-read-text path) ((ok t) t) ((err e) dflt))))
  (define exists (lambda (path)
    (match (fs-exists path) ((ok v) (if v 1 0)) ((err e) 0))))

  (define event-dir (lambda (id) (string-append "field/events/" (substring id 0 2))))
  (define event-path (lambda (id)
    (cat (list (event-dir id) "/" (substring id 2 (string-len id))))))

  (define field-exists (lambda (id)
    (if (= (is-id id) 1) (exists (event-path id)) 0)))

  (define store-file (lambda (id sig text)
    (begin
      (fs-mkdir (event-dir id))
      (fs-write-durable (event-path id) (cat (list "sig " sig "\n" text))))))

  ; ── the canonical encoding ────────────────────────────────────────────
  (define prefix-lines (lambda (word xs)
    (cat (map (lambda (x) (cat (list word " " x "\n"))) xs))))

  ; parents and links must already be sorted sets
  (define encode (lambda (author scope kind time parents links body)
    (cat (list "field 1\n"
               "author " author "\n"
               "scope " scope "\n"
               "kind " kind "\n"
               "time " time "\n"
               (prefix-lines "parent" parents)
               (prefix-lines "link" links)
               "body " (number->string (string-len body)) "\n"
               body))))

  ; An event is (list id sig author scope kind time parents links body).
  (define mk-event (lambda (id sig author scope kind time parents links body)
    (list id sig author scope kind time parents links body)))
  (define nth (lambda (xs n) (list-get xs n)))
  (define event-id (lambda (e) (nth e 0)))
  (define event-sig (lambda (e) (nth e 1)))
  (define event-author (lambda (e) (nth e 2)))
  (define event-scope (lambda (e) (nth e 3)))
  (define event-kind (lambda (e) (nth e 4)))
  (define event-time (lambda (e) (nth e 5)))
  (define event-parents (lambda (e) (nth e 6)))
  (define event-links (lambda (e) (nth e 7)))
  (define event-body (lambda (e) (nth e 8)))

  ; the text after "word " on the line at i, and where the next line starts;
  ; (list "" -1) if the line isn't that word
  (define field-line (lambda (text word i)
    (let (p (string-append word " "))
      (if (= (find-byte text b-nl i) -1) (list "" -1)
        (let (j (find-byte text b-nl i))
          (if (starts-with (substring text i j) p)
            (list (substring text (+ i (string-len p)) j) (+ j 1))
            (list "" -1)))))))

  ; every consecutive line starting with word -> (list values next-i)
  (define repeated (lambda (text word i acc)
    (let (r (field-line text word i))
      (if (= (car (cdr r)) -1) (list (reverse acc) i)
        (repeated text word (car (cdr r)) (cons (car r) acc))))))

  ; A failure is a one-element list holding the reason; an event has nine.
  (define bad (lambda (why) (list (string-append "error: " why))))
  (define bad? (lambda (e) (null? (cdr e))))
  (define bad-reason (lambda (e) (car e)))

  ; canonical text -> an event, or a failure. Encoding what we parsed must
  ; give back the same text, so one event has exactly one form.
  (define parse (lambda (id sig text)
    (let (a (field-line text "field" 0))
      (if (not (string=? (car a) "1")) (bad "not a field 1 event")
      (let (b (field-line text "author" (car (cdr a))))
      (let (c (if (< (car (cdr b)) 0) b (field-line text "scope" (car (cdr b)))))
      (let (d (if (< (car (cdr c)) 0) c (field-line text "kind" (car (cdr c)))))
      (let (e (if (< (car (cdr d)) 0) d (field-line text "time" (car (cdr d)))))
      (if (< (car (cdr e)) 0) (bad "missing header line")
      (if (= (all-digits (car e)) 0) (bad "bad time")
      (let (ps (repeated text "parent" (car (cdr e)) (list)))
      (let (ls (repeated text "link" (car (cdr ps)) (list)))
      (let (f (field-line text "body" (car (cdr ls))))
      (if (< (car (cdr f)) 0) (bad "missing body line")
      (if (= (all-digits (car f)) 0) (bad "bad body length")
      (if (< MAX-BODY (str->num (car f))) (bad "body too long")
      (if (not (= (+ (car (cdr f)) (str->num (car f))) (string-len text))) (bad "wrong body length")
      (let (body (substring text (car (cdr f)) (string-len text)))
      (if (not (string=? text (encode (car b) (car c) (car d) (car e) (sort-set (car ps)) (sort-set (car ls)) body)))
        (bad "not canonical")
        (mk-event id sig (car b) (car c) (car d) (car e) (car ps) (car ls) body))))))))))))))))))))

  (define split-file (lambda (id file)
    (let (j (find-byte file b-nl 0))
      (parse id (substring file 4 j) (substring file (+ j 1) (string-len file))))))

  ; the stored form: "sig <hex>\n" then the canonical text, or "" if absent
  (define field-file (lambda (id)
    (if (= (field-exists id) 0) "" (read-or (event-path id) ""))))

  (define field-get (lambda (id)
    (if (= (field-exists id) 0) (bad "no such event")
      (match (fs-read-text (event-path id))
        ((ok t) (split-file id t))
        ((err e) (bad "cannot read event"))))))

  (define field-seen-head (lambda () (read-or "field/seen-head" "")))

  ; ── the seen chain ────────────────────────────────────────────────────
  (define seen-line (lambda (id)
    (let (e (field-get id))
      (if (bad? e) ""
        (cat (list id " " (event-scope e) " " (event-kind e) "\n"))))))

  ; Record ids in one seen event. Seen events are never themselves recorded:
  ; a seen can't cause another seen.
  (define record-seen (lambda (store ids)
    (let (head (field-seen-head))
      (let (body (cat (map seen-line ids)))
        (let (author (author-of store))
          (let (scope (string-append "field/seen/" store))
            (let (time (u64->string (now)))
              (let (parents (if (string=? head "") (list) (list head)))
                (let (text (encode author scope "field.seen" time parents (list) body))
                  (let (id (sha-of text))
                    (begin
                      (store-file id (sign-by store id) text)
                      (fs-write-durable
                        (if (string=? head "") "field/seen-first" (string-append "field/seen-next/" head))
                        id)
                      (fs-write-durable "field/seen-head" id)
                      (map (lambda (x) (fs-delete (string-append "field/unseen/" x))) ids)
                      (notify-subs id)
                      id)))))))))))

  ; ── admission ─────────────────────────────────────────────────────────
  ; Who may write where: field/rules (the file `rules` next to this one),
  ; lines of "<scope prefix> <who>". The lines with the longest prefix
  ; matching the scope decide; any of them admitting the event admits it. A
  ; scope no rule matches is closed; with no file, all are open. <who> is
  ;   <author key> or *
  ;   id                  the author is a key of the body's `from` (SPEC-id 3)
  ;   <key> before <ms>   that key, for events whose time is before ms
  ; In id/<name> (SPEC-id 1) the matching lines' keys are the registrars, and
  ; a registrar or any key the name has had may write; idmodel ignores what
  ; it may not do.
  (define IDS "field/ids")
  (define rule-matches (lambda (scope)
    (filter (lambda (r) (and (or (= (length r) 2) (and (= (length r) 4) (string=? (nth r 2) "before")))
                             (starts-with scope (nth r 0))))
            (map words (lines (read-or "field/rules" ""))))))
  (define best-rules (lambda (scope)
    (let (ms (rule-matches scope))
      (let (best (fold (lambda (n r) (if (< n (string-len (nth r 0))) (string-len (nth r 0)) n)) -1 ms))
        (filter (lambda (r) (= (string-len (nth r 0)) best)) ms)))))
  (define registrars (lambda (scope) (map (lambda (r) (nth r 1)) (filter (lambda (r) (= (length r) 2)) (best-rules scope)))))
  (define id-scope? (lambda (scope) (starts-with scope "id/")))
  (define admits (lambda (r e)
    (let (who (nth r 1))
      (if (= (length r) 4)
        (and (string=? who (event-author e)) (< (str->num (event-time e)) (str->num (nth r 3))))
        (or (string=? who (event-author e)) (string=? who "*")
            (and (string=? who "id")
                 (= (id-key-ok IDS (id-from (event-body e)) (event-author e) (event-time e)) 1)))))))
  (define may-write (lambda (e)
    (if (string=? (read-or "field/rules" "") "") 1
      (let (rs (best-rules (event-scope e)))
        (if (null? rs) 0
          (if (= (id-scope? (event-scope e)) 1)
            (id-may-write IDS (substring (event-scope e) 3 (string-len (event-scope e))) (event-author e) (registrars (event-scope e)))
            (if (null? (filter (lambda (r) (admits r e)) rs)) 0 1)))))))

  (define missing-parents (lambda (ps)
    (if (null? ps) (list)
      (if (= (field-exists (car ps)) 1) (missing-parents (cdr ps))
        (cons (car ps) (missing-parents (cdr ps)))))))

  ; A complete event from anywhere: its text and signature -> its id, or
  ; "error: ...". Admitting one we already hold is a no-op, so duplicates cost
  ; nothing.
  (define field-admit (lambda (store sig text)
    (let (id (sha-of text))
      (if (string=? id "") "error: hash failed"
      (if (= (field-exists id) 1) id
      (let (e (parse id sig text))
        (if (bad? e) (bad-reason e)
        (if (= (sig-ok (event-author e) sig id) 0) "error: bad signature"
        (if (= (may-write e) 0) "error: author may not write to this scope"
        (let (missing (missing-parents (event-parents e)))
          (if (not (null? missing)) (string-append "error: missing parent " (car missing))
            (begin
              (fs-write-durable (string-append "field/unseen/" id) "")
              (store-file id sig text)
              (if (and (= (id-scope? (event-scope e)) 1) (= (starts-with (event-kind e) "id.") 1))
                (id-apply IDS (event-scope e) (event-kind e) text (event-author e) (registrars (event-scope e)))
                "")
              (record-seen store (list id))
              id))))))))))))

  ; -> the new event's id, or "error: ..."
  (define field-append (lambda (store author scope kind body parents links)
    (let (a (author-of author))
      (if (string=? a "") "error: no signing key"
      (let (text (encode a scope kind (u64->string (now)) (sort-set parents) (sort-set links) body))
        (let (id (sha-of text))
          (field-admit store (sign-by author id) text)))))))

  ; ── following ─────────────────────────────────────────────────────────
  (define seen-entries (lambda (e)
    (map words (lines (event-body e)))))

  ; the seen event after `after` ("" = the first), or ""
  (define seen-after (lambda (after)
    (if (string=? after "") (read-or "field/seen-first" "")
      (if (= (is-id after) 1) (read-or (string-append "field/seen-next/" after) "") ""))))

  (define want-line (lambda (w scope prefix)
    (if (or (string=? scope "") (string=? (nth w 1) scope))
      (starts-with (nth w 2) prefix)
      0)))
  (define entries-of (lambda (es scope prefix acc)
    (fold (lambda (acc e)
            (append acc (filter (lambda (w) (= (want-line w scope prefix) 1)) (seen-entries e))))
          acc es)))

  ; up to n seen events after `after`, oldest first -> (list cursor events more)
  (define walk (lambda (after n acc)
    (let (next (seen-after after))
      (if (string=? next "") (list after (reverse acc) 0)
        (if (= n 0) (list after (reverse acc) 1)
          (let (e (field-get next))
            (if (bad? e) (list after (reverse acc) 0)
              (walk next (- n 1) (cons e acc)))))))))

  ; What this store admitted after seen event `after` ("" = from the start),
  ; oldest first: one page, as (list cursor entries more). Entries are
  ; (id scope kind); scope "" = all. Pass cursor as `after` next time, and call
  ; again at once when more is 1.
  (define field-follow (lambda (after scope prefix) (field-follow-n after scope prefix FOLLOW-PAGE)))
  ; the same, up to n seen events
  (define field-follow-n (lambda (after scope prefix n)
    (let (w (walk after n (list)))
      (list (car w)
            (entries-of (car (cdr w)) scope prefix (list))
            (car (cdr (cdr w)))))))

  ; ── subscribers ───────────────────────────────────────────────────────
  (define field-subscribe (lambda (actor scope prefix)
    (fs-append "field/subs" (cat (list actor " " scope " " prefix "\n")))))

  ; A notice is a hint: a subscriber reads after its own cursor, so a failed
  ; send costs nothing.
  (define notify-subs (lambda (seen-id)
    (map (lambda (line)
           (msg-send (car (words line)) (string-append "field: seen " seen-id)))
         (lines (read-or "field/subs" "")))))

  ; ── start ─────────────────────────────────────────────────────────────
  (define dir-names (lambda (path)
    (match (fs-list path)
      ((ok es) (map (lambda (e) (match e ((dir-entry name dir) name))) es))
      ((err e) (list)))))

  (define field-start (lambda (store)
    (begin
      (map fs-mkdir (list "field" "field/events" "field/seen-next" "field/unseen" IDS))
      (fs-write "field/node" store)  ; this node's name, which is its key's: node-chat signs id.* with it
      ; a crash after admitting but before recording: record them now
      (let (unseen (dir-names "field/unseen"))
        (if (null? unseen) (field-seen-head) (record-seen store unseen))))))
)
