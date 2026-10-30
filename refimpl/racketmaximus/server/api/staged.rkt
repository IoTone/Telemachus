#lang racket/base

;; server/api/staged.rkt — streamed capture: an upload assembled from chunks
;; (#192 slice 2, decisions STG‑1…6).
;;
;; #192 requirement 3 asks for "an api for streamed notes capture". The protocol
;; it wants has existed since slice 52 and was reachable only through SigV4:
;; `repo_uploads`/`repo_upload_parts` take numbered parts, each as its own
;; content-addressed blob, assembled at Complete through the same `repo-put!` an
;; ordinary upload uses — with the bytes charged on arrival, refunded in one
;; place, and an abandoned upload reaped on the newest part's clock.
;;
;; STG‑1 — SO THIS IS THREE ROUTES AND NO NEW STORAGE. A browser's
;; `MediaRecorder` hands a chunk to `onddataavailable` every timeslice and cannot
;; compose an AWS signature; the S3 listener is also off by default. The table
;; operations moved to `domain/repo/staging.rkt` when they got a second asker,
;; which is the move `release-blob!` already made in that file, and both surfaces
;; now go through them — so the refund, the reap, the retry-replaces rule and the
;; assembly are shared rather than reimplemented here.
;;
;; STG‑3 — IT IS NOT VOICE-SPECIFIC, and the route names say so. The chunking has
;; nothing to do with audio: it is "a thing being recorded or produced while it is
;; uploaded", which is equally a long export, a camera roll or a database dump.
;; Naming it `/api/voice-notes` would have been a second upload API the first time
;; anybody wanted one for something else — the shape #114 avoided by making feed
;; adapters a registry rather than a `cond`. What IS voice-specific is the
;; content type the caller sends, and the trigger that fires on it afterwards.

(provide ep-staged-begin ep-staged-part ep-staged-complete ep-staged-abort
         ep-staged-get)

(require racket/string
         racket/port
         json
         db-kit/portable
         web-server/http
         web-kit
         (only-in "../../config.rkt" max-upload-bytes)
         (only-in "../../domain/authz/authz.rkt" require-perm principal-team-id)
         (only-in "../../domain/repo/repo.rkt" VISIBILITIES)
         (only-in "../../domain/repo/staging.rkt"
                  staging-begin! staging-row staging-put-part! staging-parts
                  staging-complete! staging-drop! STAGING-MAX-PARTS)
         "../kit.rkt")

(define (upload-json up parts)
  (hasheq 'upload_id (hash-ref up 'id)
          'key (hash-ref up 'key)
          'content_type (hash-ref up 'content_type)
          'visibility (or (hash-ref up 'visibility) 'null)
          'parts (for/list ([pt (in-list parts)])
                   (hasheq 'part (hash-ref pt 'part) 'size (hash-ref pt 'size)))
          'bytes (for/sum ([pt (in-list parts)]) (hash-ref pt 'size))
          'max_parts STAGING-MAX-PARTS
          'max_part_bytes (max-upload-bytes)))

;; POST /api/uploads {key, content_type?, visibility?}
(define (ep-staged-begin req)
  (with-auth req (lambda (p)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define key (let ([v (hash-ref b 'key #f)]) (and (string? v) v)))
      (define ct (let ([v (hash-ref b 'content_type #f)])
                   (if (and (string? v) (> (string-length v) 0)) v "application/octet-stream")))
      (define vis (let ([v (hash-ref b 'visibility #f)])
                    (and (string? v) (member v VISIBILITIES) v)))
      (cond
        [(not key) (err "a valid key is required" 400)]
        [else
         ;; The key's own validation is `staging-begin!`'s (STG‑4), so both
         ;; surfaces refuse at Begin rather than at Complete — and this handler's
         ;; `exn:fail:user?` wrapper turns it into the 400. One home.
         (define uid (staging-begin! db-conn p key ct #:visibility vis))
         (define up (staging-row db-conn p uid))
         (json-response (upload-json up '()) #:code 201)])))))

;; GET /api/uploads/:id — what has landed so far, which is what lets a client
;; resume rather than start again: it is the list of part numbers it does NOT
;; have to send twice.
(define (ep-staged-get req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:write")
    (define up (staging-row db-conn p id))
    (if (not up) (err "no such upload" 404)
        (json-response (upload-json up (staging-parts db-conn (hash-ref up 'id))))))))

;; PUT /api/uploads/:id/parts/:n — one chunk, as the raw request body.
;;
;; STG‑5 — THE PART NUMBER IS IN THE PATH, NOT INFERRED. An append-only
;; `POST .../parts` would be simpler and is wrong for the one failure this exists
;; to survive: a chunk whose request fails has to be sent again, and with an
;; implied position a retry either duplicates it or is indistinguishable from the
;; next chunk. Numbered, a retry REPLACES — `UNIQUE(upload_id, part_number)` and
;; the upsert in `staging-put-part!` — so a flaky connection costs one chunk
;; rather than the recording.
(define (ep-staged-part req id n)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:write")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define up (staging-row db-conn p id))
      (define part (string->number (format "~a" n)))
      (cond
        [(not up) (err "no such upload" 404)]
        [(not (exact-positive-integer? part)) (err "a positive part number is required" 400)]
        [else
         ;; `request-post-data/raw` buffers, which is why `max-upload-bytes` caps
         ;; ONE part — and is the whole reason a long recording is chunks rather
         ;; than one body. DOC‑15's listener is the streaming data plane; this
         ;; plane trades a buffer per chunk for a protocol a browser can speak.
         (define raw (or (request-post-data/raw req) #""))
         (define-values (digest size)
           (staging-put-part! db-conn up part (open-input-bytes raw) #:who 'uploads))
         (json-response (hasheq 'upload_id (hash-ref up 'id)
                                'part part
                                'size size
                                'digest digest))])))))

;; POST /api/uploads/:id/complete — assemble, in ASCENDING part order.
;;
;; STG‑6 — THE CLIENT DOES NOT NAME THE ORDER, WHERE THE S3 SURFACE MAKES IT.
;; There it must: parts arrive concurrently from `aws s3 cp`'s parallel workers
;; and only the client knows which byte range each one was. A streamed capture
;; has ONE writer producing chunks in time order, so ascending IS the order and
;; accepting a list would be offering a way to assemble a recording wrong.
(define (ep-staged-complete req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:write")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define up (staging-row db-conn p id))
      (cond
        [(not up) (err "no such upload" 404)]
        [else
         ;; `staging-complete!` writes through `repo-put!`, so the finished object
         ;; is versioned, quota'd, audited and — the part that matters for #192 —
         ;; passes the put hook, which is what makes a completed recording fire a
         ;; trigger exactly as a single-shot PUT would.
         (define o (staging-complete! db-conn p up #f #:who 'uploads))
         (json-response (hasheq 'id (hash-ref o 'id)
                                'key (hash-ref o 'key)
                                'version_id (hash-ref o 'version_id)
                                'size (hash-ref o 'size)
                                'digest (hash-ref o 'digest)
                                'content_type (hash-ref o 'content_type))
                        #:code 201)])))))

;; DELETE /api/uploads/:id — give up, and get the staged bytes back.
(define (ep-staged-abort req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:write")
    (define up (staging-row db-conn p id))
    (if (not up) (err "no such upload" 404)
        (begin (staging-drop! db-conn up)
               (json-response (hasheq 'aborted (hash-ref up 'id))))))))
