; client.wisp — use the machine's field store from any session (see
; field/DESIGN.md). Load with (require client "experiment/field/client.wisp").
;
;   (field-post "github-events" "infra/github" "github.pr.merged" "body")
;   (field-post-to ADDR author scope kind body parents links)
;   (field-read ADDR id)        -> (list id sig author scope kind time parents links body)
;                                  or (list "error: ...")
;   (field-after ADDR cursor scope kind)
;       -> (list cursor entries more), entries (id scope kind). scope, kind "" = all.
;          Call again at once when more is 1.
;
; Events are built and signed here, by key name, so the store never holds an
; author's key: it only checks signatures. Each call opens a connection, so a
; session holds nothing between calls.
(module client
  (provide field-post field-post-to field-read field-after field-head FIELD)
  (require list "std/list.wisp")
  (require str "std/str.wisp")

  (define FIELD "127.0.0.1:7800")

  (define b-nl (string-ref "\n" 0))
  (define nonempty (lambda (xs) (filter (lambda (x) (< 0 (string-len x))) xs)))
  (define lines (lambda (s) (nonempty (split s "\n"))))
  (define words (lambda (s) (nonempty (split s " "))))
  (define cat (lambda (xs) (fold (lambda (acc x) (string-append acc x)) "" xs)))

  (define recv-more (lambda (conn buf done? tries)
    (if (done? buf) buf
      (if (= tries 0) buf
        (match (tcp-receive conn 65536)
          ((ok bs) (if (= (length bs) 0) buf
                     (recv-more conn (string-append buf (bytes->string bs)) done? (- tries 1))))
          ((err e) buf))))))

  ; one request -> (list 1 payload) or (list 0 reason)
  (define ask-on (lambda (conn text)
    (begin
      (tcp-send conn text)
      (let (buf (recv-more conn "" (lambda (b) (<= 0 (string-index b b-nl))) 64))
        (let (j (string-index buf b-nl))
          (if (< j 0) (list 0 "no reply from the store")
            (let (head (words (substring buf 0 j)))
              (let (end (+ (+ j 1) (string->number (list-get head 1))))
                (let (all (recv-more conn buf (lambda (b) (<= end (string-len b))) 64))
                  (if (< (string-len all) end) (list 0 "short reply from the store")
                    (list (if (string=? (list-get head 0) "ok") 1 0)
                          (substring all (+ j 1) end))))))))))))

  (define ask (lambda (addr text)
    (match (tcp-connect addr)
      ((err e) (list 0 "cannot reach the store"))
      ((ok conn)
        (let (r (ask-on conn text))
          (begin (tcp-close conn) r))))))

  ; ── the canonical form; store.wisp's encode is the reference ───────────
  (define str-lt-from (lambda (a b i)
    (if (= i (string-len b)) 0
      (if (= i (string-len a)) 1
        (let (x (s32 (string-ref a i)))
          (let (y (s32 (string-ref b i)))
            (if (< x y) 1 (if (< y x) 0 (str-lt-from a b (+ i 1))))))))))
  (define str-lt (lambda (a b) (str-lt-from a b 0)))
  (define sorted-set (lambda (xs)
    (fold (lambda (acc x)
            (if (and (< 0 (length acc)) (string=? x (list-get acc (- (length acc) 1)))) acc
              (list-push acc x)))
          (list) (sort str-lt xs))))

  (define prefixed (lambda (word xs)
    (cat (map (lambda (x) (cat (list word " " x "\n"))) xs))))

  (define encode (lambda (author scope kind time parents links body)
    (cat (list "field 1\nauthor " author "\nscope " scope "\nkind " kind "\ntime " time "\n"
               (prefixed "parent" parents)
               (prefixed "link" links)
               "body " (number->string (string-len body)) "\n"
               body))))

  (define public-key (lambda (name)
    (match (key-public name)
      ((ok k) k)
      ((err e) (match (key-new name) ((ok k) k) ((err x) ""))))))

  ; -> the event's id, or "error: ..."
  (define field-post-to (lambda (addr author scope kind body parents links)
    (let (pub (public-key author))
      (if (string=? pub "") "error: no signing key"
        (let (text (encode pub scope kind (u64->string (now)) (sorted-set parents) (sorted-set links) body))
          (match (sign author (sha256 text))
            ((err e) "error: cannot sign")
            ((ok sig)
              (let (r (ask addr (cat (list "admit " sig " " (number->string (string-len text)) "\n" text))))
                (list-get r 1)))))))))

  (define field-post (lambda (author scope kind body)
    (field-post-to FIELD author scope kind body (list) (list))))

  (define dash (lambda (s) (if (string=? s "") "-" s)))

  (define field-head (lambda (addr)
    (let (r (ask addr "head\n"))
      (if (= (list-get r 0) 1) (list-get r 1) ""))))

  (define field-after (lambda (addr cursor scope kind)
    (let (r (ask addr (cat (list "follow " (dash cursor) " " (dash scope) " " (dash kind) "\n"))))
      (if (= (list-get r 0) 0) (list cursor (list) 0)
        (let (ls (lines (list-get r 1)))
          (let (head (words (list-get ls 0)))
            (list (if (string=? (list-get head 0) "-") "" (list-get head 0))
                  (map words (drop-first ls))
                  (string->number (list-get head 1)))))))))

  (define drop-from (lambda (xs i out)
    (if (>= i (length xs)) out (drop-from xs (+ i 1) (list-push out (list-get xs i))))))
  (define drop-first (lambda (xs) (drop-from xs 1 (list))))

  ; ── reading an event back ──────────────────────────────────────────────
  (define take-lines (lambda (text i word out)
    (let (j (string-index text b-nl i))
      (let (p (string-append word " "))
        (if (and (<= 0 j) (starts-with (substring text i j) p))
          (take-lines text (+ j 1) word (list-push out (substring text (+ i (string-len p)) j)))
          (list out i))))))
  (define one-line (lambda (text i)
    (let (j (string-index text b-nl i))
      (list (substring text (+ 1 (string-index text (string-ref " " 0) i)) j) (+ j 1)))))

  (define field-read (lambda (addr id)
    (let (r (ask addr (cat (list "get " id "\n"))))
      (if (= (list-get r 0) 0) (list (string-append "error: " (list-get r 1)))
        (let (t (list-get r 1))
          (let (sig (one-line t 0))
            (let (magic (one-line t (list-get sig 1)))
              (let (author (one-line t (list-get magic 1)))
                (let (scope (one-line t (list-get author 1)))
                  (let (kind (one-line t (list-get scope 1)))
                    (let (time (one-line t (list-get kind 1)))
                      (let (ps (take-lines t (list-get time 1) "parent" (list)))
                        (let (ls (take-lines t (list-get ps 1) "link" (list)))
                          (let (b (one-line t (list-get ls 1)))
                            (list id (list-get sig 0) (list-get author 0) (list-get scope 0)
                                  (list-get kind 0) (list-get time 0) (list-get ps 0) (list-get ls 0)
                                  (substring t (list-get b 1) (string-len t)))))))))))))))))
)
