; feed.wisp — turn what the environment already reports into field events.
; Runs in its own session (a boot-list service), posting through client.wisp, so a
; stopped feed loses new events and nothing else.
;
;   github-events messages -> scope github/REPO, kind github.KIND.ACTION
;   agent-hook lines       -> scope agents/NAME, kind agent.STATE; "NAME STATE [@ID] DETAIL", parented
;                             on ID (what the agent works on) else its previous status event (0212)
;   lib/field-watch lines      -> scope ops/NAME, kind ops.STATE
;
; Each connects to FEED-LISTEN and writes one "NAME STATE DETAIL\n" line;
; lib/field-watch's start with "ops ".
; Handlers return fixed labels: event text may not be valid UTF-8, and a
; handler's result goes back to the host.
(module feed
  (provide feed-message feed-connection feed-data FEED-LISTEN)
  (require client "experiment/field/client.wisp")
  (require list "std/list.wisp")
  (require str "std/str.wisp")

  (define FEED-LISTEN "127.0.0.1:7802")
  (define b-space (string-ref " " 0))
  (define b-nl (string-ref "\n" 0))

  (define github-kind? (lambda (k)
    (member k (list "pr" "review" "comment" "ci") string=?)))

  ; github-events: KIND REPO REF ACTION ACTOR URL TEXT
  (define feed-message (lambda (text)
    (if (not (starts-with text "github-events: ")) "ignored"
      (let (body (substring text 15 (string-len text)))
        (let (w (split body " "))
          (if (or (< (length w) 7) (not (github-kind? (list-get w 0)))) "ignored"
            (begin
              (field-post "github-events"
                (string-append "github/" (list-get w 1))
                (string-append "github." (string-append (list-get w 0) (string-append "." (list-get w 3))))
                body)
              "posted")))))))

  (define feed-connection (lambda (cid)
    (begin (tcp-activate cid) (tcp-set-active cid "active") "connected")))

  ; One short write per connection, so one packet holds the whole line.
  (define post-line (lambda (author scope-prefix kind-prefix line)
    (let (i (string-index line b-space))
      (let (j (if (< i 0) -1 (string-index line b-space (+ i 1))))
        (if (< j 0) "ignored"
          (begin
            (field-post author
              (string-append scope-prefix (substring line 0 i))
              (string-append kind-prefix (substring line (+ i 1) j))
              (substring line (+ j 1) (string-len line)))
            "posted"))))))

  ; an agent's newest status event, by name: its next one's parent when the hook names no work (0212)
  (define LAST (hash-map))
  (define hex64? (lambda (t i)
    (if (>= i (string-len t)) (if (= (string-len t) 64) 1 0)
      (let (c (string-ref t i)) (if (or (and (<= 48 c) (<= c 57)) (and (<= 97 c) (<= c 102))) (hex64? t (+ i 1)) 0)))))
  (define post-agent (lambda (line)
    (let (i (string-index line b-space))
      (let (j (if (< i 0) -1 (string-index line b-space (+ i 1))))
        (if (< j 0) "ignored"
          (let (name (substring line 0 i))
            (let (rest (substring line (+ j 1) (string-len line)))
              (let (k (string-index rest b-space))
                (let (work (if (and (starts-with rest "@") (= k 65) (= (hex64? (substring rest 1 65) 0) 1)) (substring rest 1 65) ""))
                  (let (detail (if (string=? work "") rest (substring rest 66 (string-len rest))))
                    (let (prev (match (map-get LAST name) ((some v) v) ((none) "")))
                      (let (scope (string-append "agents/" name))
                        (let (kind (string-append "agent." (substring line (+ i 1) j)))
                          ; the work it names first; if the store lacks it, its previous status; then none
                          (let (r (agent-post scope kind detail (if (string=? work "") prev work)))
                            (let (r2 (if (or (= (string-len r) 64) (string=? work "")) r (agent-post scope kind detail prev)))
                              (let (r3 (if (or (= (string-len r2) 64) (string=? prev "")) r2 (agent-post scope kind detail "")))
                                (if (= (string-len r3) 64) (begin (map-set! LAST name r3) "posted") "ignored")))))))))))))))))
  (define agent-post (lambda (scope kind body parent)
    (field-post-to FIELD "agents" scope kind body (if (string=? parent "") (list) (list parent)) (list))))

  (define post-any (lambda (line)
    (if (starts-with line "ops ")
      (post-line "ops" "ops/" "ops." (substring line 4 (string-len line)))
      (post-agent line))))

  (define feed-data (lambda (e)
    (let (text (bytes->string (car (cdr e))))
      (let (j (string-index text b-nl))
        (begin
          (tcp-close (car e))
          (if (< j 0) "ignored" (post-any (substring text 0 j))))))))
)
