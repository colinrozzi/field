; feed.wisp — turn what the environment already reports into field events.
; Runs in its own session (a boot-list service), posting through client.wisp, so a
; stopped feed loses new events and nothing else.
;
;   github-events messages -> scope github/REPO, kind github.KIND.ACTION
;   agent-hook lines       -> scope agents/NAME, kind agent.STATE; "NAME STATE [@ID] DETAIL". Its first
;                             parent is the agent's previous status event, so they chain; ID (what the agent
;                             works on) is a second parent only when it differs from the previous one's (0212)
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
  ; the newest event in scope sc from the store, reading its pages to the end (at most n), or "":
  ; an agent's previous status after a restart, when LAST has forgotten it (tova, 15:59)
  (define newest-in (lambda (sc cursor last n)
    (if (= n 0) last
      (let (r (field-scope-after FIELD cursor sc "agent."))
        (let (es (list-get r 1))
          (let (l2 (if (= (length es) 0) last (list-get (list-get es (- (length es) 1)) 1)))
            (if (= (list-get r 2) 1) (newest-in sc (list-get r 0) l2 (- n 1)) l2)))))))
  ; the work each agent's newest status named, so the same work isn't a parent again (colin, 13:43)
  (define WORK (hash-map))
  (define hex64? (lambda (t i)
    (if (>= i (string-len t)) (if (= (string-len t) 64) 1 0)
      (let (c (string-ref t i)) (if (or (and (<= 48 c) (<= c 57)) (and (<= 97 c) (<= c 102))) (hex64? t (+ i 1)) 0)))))
  (define post-agent (lambda (line)
    (let (i (string-index line b-space))
      (let (j (if (< i 0) -1 (string-index line b-space (+ i 1))))
        (if (< j 0) "ignored"
          (if (or (= (name-ok? (substring line 0 i) 0) 0) (not (state-ok? (substring line (+ i 1) j)))) "ignored"
          (let (name (substring line 0 i))
            (let (rest (substring line (+ j 1) (string-len line)))
              (let (k (string-index rest b-space))
                (let (work (if (and (starts-with rest "@") (= k 65) (= (hex64? (substring rest 1 65) 0) 1)) (substring rest 1 65) ""))
                  (let (detail (if (string=? work "") rest (substring rest 66 (string-len rest))))
                    (let (prev (match (map-get LAST name) ((some v) v) ((none) (newest-in (string-append "agents/" name) "" "" 100))))
                      (let (scope (string-append "agents/" name))
                        (let (kind (string-append "agent." (substring line (+ i 1) j)))
                          ; the previous status first (a chain), plus the work when it's new; if the store
                          ; lacks the work, the previous status alone; then none
                          (let (was (match (map-get WORK name) ((some v) v) ((none) "")))
                            (let (new-work (if (or (string=? work "") (string=? work was)) "" work))
                              (let (r (agent-post scope kind detail prev new-work))
                                (let (r2 (if (or (= (string-len r) 64) (string=? new-work "")) r (agent-post scope kind detail prev "")))
                                  (let (r3 (if (or (= (string-len r2) 64) (string=? prev "")) r2 (agent-post scope kind detail "" "")))
                                    (if (= (string-len r3) 64)
                                      (begin (map-set! LAST name r3) (if (string=? work "") "" (map-set! WORK name work)) "posted")
                                      "ignored"))))))))))))))))))))
  ; any local process can write a line to the feed (lux): a plain name and a known state only
  (define name-ok? (lambda (t i)
    (if (>= i (string-len t)) (if (and (< 0 (string-len t)) (<= (string-len t) 64)) 1 0)
      (let (c (string-ref t i))
        (if (or (and (<= 97 c) (<= c 122)) (or (and (<= 48 c) (<= c 57)) (and (< 0 i) (or (= c 45) (or (= c 46) (= c 95))))))
          (name-ok? t (+ i 1)) 0)))))
  (define state-ok? (lambda (s) (member s (list "working" "idle" "waiting" "exited") string=?)))
  ; the parents: the previous status and the work, whichever are set
  (define agent-post (lambda (scope kind body prev work)
    (field-post-to FIELD "agents" scope kind body
      (if (string=? prev "") (if (string=? work "") (list) (list work)) (if (string=? work "") (list prev) (list prev work))) (list))))

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
