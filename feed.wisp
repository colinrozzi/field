; feed.wisp — turn what the environment already reports into field events.
; Runs in its own session (a boot-list service), posting through client.wisp, so a
; stopped feed loses new events and nothing else.
;
;   github-events messages -> scope github/REPO, kind github.KIND.ACTION
;   agent-hook lines       -> scope agents/NAME, kind agent.STATE
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

  (define post-any (lambda (line)
    (if (starts-with line "ops ")
      (post-line "ops" "ops/" "ops." (substring line 4 (string-len line)))
      (post-line "agents" "agents/" "agent." line))))

  (define feed-data (lambda (e)
    (let (text (bytes->string (car (cdr e))))
      (let (j (string-index text b-nl))
        (begin
          (tcp-close (car e))
          (if (< j 0) "ignored" (post-any (substring text 0 j))))))))
)
