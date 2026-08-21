#lang racket/base

;; domain/s3/server.rkt — the S3 protocol front door (slice 52).
;;
;; A second door onto the same authorization, never a second authorization system
;; (DOC-1). A SigV4 request resolves to a principal and from that point every read
;; and write goes through `can?` with a resource hash, so the org gate, visibility,
;; owner-ok, grants and token scopes all apply exactly as they do to the console.
;;
;; A bucket IS a team (DOC-2), addressed path-style: `/<team-slug>/<key>`. That makes
;; a cross-team key unrepresentable rather than merely refused. CreateBucket and
;; DeleteBucket answer NotImplemented, because teams are created through the team API.
;;
;; What is NOT here, and answers 501 rather than pretending: bucket policies, ACL
;; sub-resources, lifecycle, replication, website, CORS config, tagging. Silently
;; accepting a bucket policy would let an operator believe an access rule is in force
;; when it is not — the worst failure this subsystem could have (DOC-13).
;;
;; Runs on web-kit/http1, not the servlet: this is the door that has to answer
;; `Expect: 100-continue` and stream a 2 GB body.

(require db-kit/portable racket/string racket/list racket/port racket/match
         web-kit/http1
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../repo/repo.rkt"
         "../repo/blobs.rkt"
         "../authz/sha2.rkt"
         "sigv4.rkt"
         "creds.rkt")

(provide make-s3-handler s3-region xml-escape)

(define (s3-region) (or (getenv "TELEMACHUS_S3_REGION") "us-east-1"))
(define MAX-KEYS-DEFAULT 1000)

;; ---- XML ------------------------------------------------------------------------
;; S3 is XML, not JSON. A tiny writer rather than a dependency: the shapes are fixed
;; and there are nine of them.
(define (xml-escape s)
  (regexp-replaces (format "~a" s)
                   '((#rx"&" "\\&amp;") (#rx"<" "\\&lt;") (#rx">" "\\&gt;")
                     (#rx"\"" "\\&quot;"))))

(define (el name . body)
  (string-append "<" name ">" (apply string-append (map (lambda (x) (format "~a" x)) body)) "</" name ">"))

(define (xml-doc body)
  (string-append "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" body))

(define (xml-res code body #:headers [h '()])
  (http-res* code (cons (cons #"Content-Type" #"application/xml") h)
             (string->bytes/utf-8 (xml-doc body))))

;; ---- errors ----------------------------------------------------------------------
;; S3's own vocabulary, so a client reports something its users can search for.
(define (s3-error code http-code #:message [msg ""] #:resource [res ""])
  (xml-res http-code
           (el "Error"
               (el "Code" (xml-escape code))
               (el "Message" (xml-escape (if (string=? msg "") code msg)))
               (el "Resource" (xml-escape res))
               (el "RequestId" (new-id)))))

(define (access-denied [msg "Access Denied"]) (s3-error "AccessDenied" 403 #:message msg))
(define (no-such-key k) (s3-error "NoSuchKey" 404 #:message "The specified key does not exist." #:resource k))
(define (no-such-bucket b) (s3-error "NoSuchBucket" 404 #:message "The specified bucket does not exist." #:resource b))
(define (not-implemented what) (s3-error "NotImplemented" 501
  #:message (format "~a is not supported by this server." what)))

;; ---- request shape ----------------------------------------------------------------
;; path-style: "" -> service, "/bucket" -> bucket, "/bucket/a/b" -> object "a/b".
(define (split-path path)
  (define segs (filter (lambda (s) (not (string=? s ""))) (string-split path "/")))
  (cond
    [(null? segs) (values #f #f)]
    [(null? (cdr segs)) (values (car segs) #f)]
    [else (values (car segs) (percent-decode-path (string-join (cdr segs) "/")))]))

;; The key is decoded HERE and nowhere earlier: SigV4 signed the encoded form, so
;; decoding before verification would break the signature (DOC-17).
(define (percent-decode-path s)
  (define out (open-output-bytes))
  (let loop ([i 0])
    (cond
      [(>= i (string-length s)) (void)]
      [(and (char=? (string-ref s i) #\%) (< (+ i 2) (string-length s))
            (string->number (substring s (add1 i) (+ i 3)) 16))
       => (lambda (b) (write-byte b out) (loop (+ i 3)))]
      [else (write-char (string-ref s i) out) (loop (add1 i))]))
  (bytes->string/utf-8 (get-output-bytes out) #\?))

(define (has-q? req name) (and (req-query req name) #t))

;; ---- authentication -----------------------------------------------------------------
;; Returns a principal, or an http-res explaining the refusal. The failure symbols map
;; to S3's own codes so a client can tell "your clock is wrong" from "wrong key".
(define (authenticate conn req)
  (define authz (req-header req "authorization"))
  (define header-auth (parse-authorization authz))
  ;; A presigned URL carries everything in the query string and no Authorization
  ;; header, which is the whole point: a browser can follow it.
  (define query-auth (and (not header-auth) (presign-parse (http-req-query req))))
  (define auth (or header-auth query-auth))
  (define payload-hash (or (req-header req "x-amz-content-sha256") UNSIGNED-PAYLOAD))
  (cond
    [(not auth)
     (s3-error "AccessDenied" 403
               #:message "This server requires AWS Signature Version 4, in an Authorization header or a presigned query.")]
    [else
     (define-values (secret row) (s3-cred-resolve conn (sigv4-auth-access-key auth)))
     (define verdict
       (if query-auth
           (presign-verify auth
                           #:method (http-req-method req)
                           #:path (http-req-path req)
                           #:query (http-req-query req)
                           #:headers (http-req-headers req)
                           #:secret secret)
           (sigv4-verify auth
                         #:method (http-req-method req)
                         #:path (http-req-path req)
                         #:query (http-req-query req)
                         #:headers (http-req-headers req)
                         #:payload-hash payload-hash
                         #:secret secret)))
     (case verdict
       [(#t) (s3-cred-principal conn row)]
       [(expired) (s3-error "AccessDenied" 403
                            #:message "This presigned URL has expired. Ask for a new link.")]
       [(skewed) (s3-error "RequestTimeTooSkewed" 403
                           #:message "The difference between the request time and the server's time is too large.")]
       [(unknown-date) (s3-error "AccessDenied" 403 #:message "Missing or malformed X-Amz-Date.")]
       [(streaming-unsupported)
        (not-implemented "STREAMING-* payload signing (send a plain body or UNSIGNED-PAYLOAD)")]
       [else (s3-error "SignatureDoesNotMatch" 403
                       #:message "The request signature we calculated does not match the signature you provided.")])]))

;; ---- buckets ↔ teams -------------------------------------------------------------------
;; A bucket name resolves to a team the caller can actually reach; the org gate has
;; already decided which those are, because a team in another org is not visible here
;; at all.
(define (bucket->team conn p bucket)
  (define oid (principal-org-id p))
  (define tid (query-maybe-value conn
    (if oid
        "SELECT id FROM teams WHERE slug = ? AND org_id = ?"
        "SELECT id FROM teams WHERE slug = ?")
    bucket oid))
  (and (string? tid) tid))

(define (team-slug conn team-id)
  (define v (query-maybe-value conn "SELECT slug FROM teams WHERE id = ?" team-id))
  (if (string? v) v "team"))

;; The caller's own team is the only bucket they may address. Reaching a sibling team
;; is a team-boundary question `can?` already answers, and answering it here as
;; NoSuchBucket rather than AccessDenied keeps the existence of other teams private.
(define (resolve-bucket conn p bucket)
  (define tid (bucket->team conn p bucket))
  (cond [(and tid (equal? tid (principal-team-id p))) tid]
        [else #f]))

;; ---- timestamps ---------------------------------------------------------------------------
;; S3 clients PARSE LastModified, so a malformed one is not cosmetic — botocore
;; raises and the whole listing fails. The two dialects hand us different shapes for
;; the same TEXT column:
;;
;;   SQLite    "2026-08-21 04:16:09"
;;   Postgres  "2026-08-21 10:12:10.225696-07"      fractional seconds AND an offset
;;
;; Take the date and the seconds, drop everything after them, and stamp Z. Anything
;; unrecognised passes through rather than being mangled into a plausible-looking
;; wrong answer.
(define (iso8601 s)
  (define t (format "~a" s))
  (define m (regexp-match #px"^([0-9]{4}-[0-9]{2}-[0-9]{2})[ T]([0-9]{2}:[0-9]{2}:[0-9]{2})" t))
  (if m (string-append (cadr m) "T" (caddr m) ".000Z") t))

(define (etag-of digest) (string-append "\"" (format "~a" digest) "\""))

;; ---- operations -------------------------------------------------------------------------
(define (op-list-buckets conn p)
  (define slug (team-slug conn (principal-team-id p)))
  (xml-res 200
    (el "ListAllMyBucketsResult"
        (el "Owner" (el "ID" (xml-escape (principal-user-id p)))
                    (el "DisplayName" (xml-escape slug)))
        (el "Buckets" (el "Bucket" (el "Name" (xml-escape slug))
                                   (el "CreationDate" "1970-01-01T00:00:00.000Z"))))))

;; ListObjectsV2. `delimiter` rolls keys sharing a prefix up into CommonPrefixes, which
;; is what makes `aws s3 ls` show folders.
(define (op-list-objects conn p bucket req)
  ;; Query values arrive STILL ENCODED, because that is what SigV4 signed. Decoding
  ;; is this layer's job and has to happen for every one of them — the AWS CLI sends
  ;; `delimiter=%2F`, and comparing that raw against a single character silently
  ;; disables folder grouping while still returning a plausible-looking listing.
  (define prefix (percent-decode-path (or (req-query req "prefix") "")))
  (define delimiter (percent-decode-path (or (req-query req "delimiter") "")))
  (define max-keys (min (or (string->number (or (req-query req "max-keys") "")) MAX-KEYS-DEFAULT)
                        MAX-KEYS-DEFAULT))
  (define start (or (string->number (or (req-query req "continuation-token") "")) 0))
  (define dprefix prefix)
  ;; ask for one more than we will return, so `IsTruncated` is a fact rather than a guess
  (define all (repo-list conn p #:prefix dprefix #:limit (add1 max-keys) #:offset start))
  (define page (if (> (length all) max-keys) (take all max-keys) all))
  (define truncated? (> (length all) max-keys))

  (define-values (keys common)
    (if (string=? delimiter "")
        (values page '())
        (for/fold ([ks '()] [cs '()] #:result (values (reverse ks) (reverse (remove-duplicates cs))))
                  ([o (in-list page)])
          (define k (hash-ref o 'key))
          (define rest (substring k (min (string-length k) (string-length dprefix))))
          (define i (for/first ([c (in-string rest)] [n (in-naturals)]
                                #:when (string=? (string c) delimiter)) n))
          (if i
              (values ks (cons (string-append dprefix (substring rest 0 (add1 i))) cs))
              (values (cons o ks) cs)))))

  (xml-res 200
    (el "ListBucketResult"
        (el "Name" (xml-escape bucket))
        (el "Prefix" (xml-escape dprefix))
        (el "KeyCount" (+ (length keys) (length common)))
        (el "MaxKeys" max-keys)
        (if (string=? delimiter "") "" (el "Delimiter" (xml-escape delimiter)))
        (el "IsTruncated" (if truncated? "true" "false"))
        (if truncated? (el "NextContinuationToken" (+ start max-keys)) "")
        (apply string-append
               (for/list ([o (in-list keys)])
                 (el "Contents"
                     (el "Key" (xml-escape (hash-ref o 'key)))
                     (el "LastModified" (iso8601 (hash-ref o 'updated_at)))
                     (el "ETag" (xml-escape (etag-of (hash-ref o 'digest))))
                     (el "Size" (hash-ref o 'size))
                     (el "StorageClass" "STANDARD"))))
        (apply string-append
               (for/list ([c (in-list common)])
                 (el "CommonPrefixes" (el "Prefix" (xml-escape c))))))))

(define (object-headers o)
  (list (cons #"ETag" (string->bytes/utf-8 (etag-of (hash-ref o 'digest))))
        (cons #"Last-Modified" (string->bytes/utf-8 (format "~a" (hash-ref o 'updated_at))))
        (cons #"x-amz-meta-visibility" (string->bytes/utf-8 (hash-ref o 'visibility)))
        ;; active content is never inline, whichever door it left by (DOC-10)
        (cons #"X-Content-Type-Options" #"nosniff")
        (cons #"Content-Disposition" #"attachment")))

;; "bytes=0-8388607" / "bytes=100-" / "bytes=-500" -> (values start end-inclusive) or #f.
;; Multi-range requests are legal HTTP and no S3 client sends them, so they are
;; ignored rather than half-implemented.
(define (parse-range v size)
  (define m (and v (regexp-match #px"^bytes=([0-9]*)-([0-9]*)$" (string-trim v))))
  (and m
       (let ([a (cadr m)] [b (caddr m)])
         (cond
           [(and (string=? a "") (string=? b "")) #f]
           [(string=? a "")                                    ; suffix: the last N bytes
            (let ([n (string->number b)])
              (and n (> n 0) (cons (max 0 (- size n)) (sub1 size))))]
           [else
            (let* ([start (string->number a)]
                   [end (if (string=? b "") (sub1 size) (min (string->number b) (sub1 size)))])
              (and start (<= start end) (< start size) (cons start end)))]))))

;; Seek if the store's port can, skip if it cannot. A future backend may hand back a
;; socket rather than a file, and a ranged read must still be correct there — just
;; slower.
(define (seek-to! in pos)
  (with-handlers ([exn:fail? (lambda (_)
                               (let loop ([left pos])
                                 (when (> left 0)
                                   (define got (read-bytes (min left 262144) in))
                                   (unless (eof-object? got)
                                     (loop (- left (bytes-length got)))))))])
    (file-position in pos)))

;; `aws s3 cp` downloads a large object with PARALLEL RANGED GETs. Ignoring Range and
;; returning the whole object for each of them produces a corrupt file that the client
;; reports as a success — which is exactly what happened before this existed.
(define (op-get-object conn p bucket key head? [range-header #f] [version-id #f])
  (define o (repo-get conn p key #:by-key (principal-team-id p)))
  (cond
    [(not o) (no-such-key key)]
    [else
     (define-values (obj in) (repo-open conn p (hash-ref o 'id) #:version version-id))
     (cond
       [(not in) (no-such-key key)]
       [else
        (define size (hash-ref obj 'size))
        (define base (cons (cons #"Content-Type"
                                 (string->bytes/utf-8 (hash-ref obj 'content_type)))
                           (cons (cons #"Accept-Ranges" #"bytes") (object-headers obj))))
        (define r (and range-header (parse-range range-header size)))
        (cond
          [head? (close-input-port in)
                 (http-res* 200 base (lambda (out) (void)) #:content-length size)]
          [(and range-header (not r) (regexp-match? #px"^bytes=" (string-trim range-header)))
           (close-input-port in)
           (s3-error "InvalidRange" 416
                     #:message (format "The requested range is not satisfiable for a ~a byte object." size))]
          [r
           (define start (car r))
           (define len (add1 (- (cdr r) start)))
           (http-res* 206
                      (cons (cons #"Content-Range"
                                  (string->bytes/utf-8 (format "bytes ~a-~a/~a" start (cdr r) size)))
                            base)
                      (lambda (out)
                        (dynamic-wind
                          void
                          (lambda ()
                            (seek-to! in start)
                            (let loop ([left len])
                              (when (> left 0)
                                (define chunk (read-bytes (min left 262144) in))
                                (unless (eof-object? chunk)
                                  (write-bytes chunk out)
                                  (loop (- left (bytes-length chunk)))))))
                          (lambda () (close-input-port in))))
                      #:content-length len)]
          [else
           (http-res* 200 base
                      (lambda (out)
                        (dynamic-wind void
                                      (lambda () (copy-port in out))
                                      (lambda () (close-input-port in))))
                      #:content-length size)])])]))

;; PutObject. The body is the request port, so nothing is buffered, and the 100-continue
;; fires on the first read inside repo-put! — after `can?` has already been consulted.
(define (op-put-object conn p bucket key req)
  (define ct (or (req-header req "content-type") "application/octet-stream"))
  (define vis (acl->visibility req))
  (cond
    [(eq? vis 'refused)
     (s3-error "InvalidArgument" 400
               #:message "Public ACLs are not supported: this instance has no anonymous read.")]
    [else
     (define o (repo-put! conn p #:key key #:port (http-req-body req)
                          #:content-type ct
                          #:filename (car (reverse (string-split key "/")))
                          #:visibility vis))
     (http-res* 200 (list (cons #"ETag" (string->bytes/utf-8 (etag-of (hash-ref o 'digest))))) #"")]))

;; DOC-4: the creator sets visibility, in S3's own vocabulary. `public-*` is refused
;; loudly rather than silently downgraded — letting someone believe a link is public
;; when it is not is the worse failure.
(define (acl->visibility req)
  (define meta (req-header req "x-amz-meta-visibility"))
  (define acl (req-header req "x-amz-acl"))
  (cond
    [(and meta (member meta VISIBILITIES)) meta]
    [(not acl) #f]                                     ; leave it to the repository default
    [(string=? acl "private") "private"]
    [(member acl '("authenticated-read" "bucket-owner-read" "bucket-owner-full-control")) "team"]
    [(member acl '("public-read" "public-read-write" "aws-exec-read")) 'refused]
    [else #f]))

(define (op-delete-object conn p bucket key)
  (define o (repo-get conn p key #:by-key (principal-team-id p)))
  ;; S3 deletes are idempotent: removing something that is not there is a 204.
  (when o (repo-delete! conn p (hash-ref o 'id)))
  (http-res* 204 '() #""))

;; POST /<bucket>?delete — what `aws s3 sync --delete` and `rclone` use.
(define (op-delete-objects conn p bucket req)
  (define body (port->string (http-req-body req)))
  (define keys (for/list ([m (in-list (regexp-match* #px"<Key>(.*?)</Key>" body #:match-select cadr))])
                 (unescape-xml m)))
  (define results
    (for/list ([k (in-list keys)])
      (with-handlers ([exn:fail? (lambda (e)
                                   (el "Error" (el "Key" (xml-escape k))
                                       (el "Code" "AccessDenied")
                                       (el "Message" (xml-escape (exn-message e)))))])
        (define o (repo-get conn p k #:by-key (principal-team-id p)))
        (when o (repo-delete! conn p (hash-ref o 'id)))
        (el "Deleted" (el "Key" (xml-escape k))))))
  (xml-res 200 (el "DeleteResult" (apply string-append results))))

(define (unescape-xml s)
  (regexp-replaces s '((#rx"&lt;" "<") (#rx"&gt;" ">") (#rx"&quot;" "\"") (#rx"&amp;" "\\&"))))

;; CopyObject — `PUT /<bucket>/<dst>` with `x-amz-copy-source: /<bucket>/<src>`.
;; Content addressing makes this genuinely metadata-only: the destination version
;; points at the source's digest and no bytes move. The source is read through
;; `repo-open`, so copying something you may not read is refused for the ordinary
;; reason rather than a special one.
(define (op-copy-object conn p bucket key source)
  ;; "/bucket/key" or "bucket/key", optionally "?versionId=..."
  (define clean (percent-decode-path (car (string-split (string-append source "?") "?"))))
  (define trimmed (if (string-prefix? clean "/") (substring clean 1) clean))
  (define segs (string-split trimmed "/"))
  (cond
    [(< (length segs) 2)
     (s3-error "InvalidArgument" 400 #:message "x-amz-copy-source must be /bucket/key.")]
    [(not (equal? (car segs) bucket))
     ;; a bucket is a team, so a cross-bucket copy is a cross-team move — which the
     ;; console can do with a grant, and an S3 client cannot express safely
     (s3-error "InvalidArgument" 400 #:message "Cross-bucket copy is not supported.")]
    [else
     (define src-key (string-join (cdr segs) "/"))
     (define-values (src in) (repo-open conn p (or (let ([o (repo-get conn p src-key
                                                                     #:by-key (principal-team-id p))])
                                                     (and o (hash-ref o 'id)))
                                                  "-")))
     (cond
       [(not in) (no-such-key src-key)]
       [(equal? src-key key)
        (close-input-port in)
        (s3-error "InvalidRequest" 400
                  #:message "The source and destination are the same; nothing to copy.")]
       [else
        (define o (dynamic-wind
                    void
                    (lambda ()
                      (repo-put! conn p #:key key #:port in
                                 #:content-type (hash-ref src 'content_type)
                                 #:filename (car (reverse (string-split key "/")))))
                    (lambda () (close-input-port in))))
        (xml-res 200 (el "CopyObjectResult"
                         (el "ETag" (xml-escape (etag-of (hash-ref o 'digest))))
                         (el "LastModified" (iso8601 (hash-ref o 'updated_at)))))])]))

;; ListObjectVersions — `GET /<bucket>?versions`. Every version of every key that the
;; caller may read, newest first per key, with the current one flagged.
(define (op-list-versions conn p bucket req)
  (define prefix (percent-decode-path (or (req-query req "prefix") "")))
  (define objs (repo-list conn p #:prefix prefix #:limit 1000))
  (xml-res 200
    (el "ListVersionsResult"
        (el "Name" (xml-escape bucket))
        (el "Prefix" (xml-escape prefix))
        (el "IsTruncated" "false")
        (apply string-append
               (for*/list ([o (in-list objs)]
                           [v (in-list (or (repo-versions conn p (hash-ref o 'id)) (list)))])
                 (el "Version"
                     (el "Key" (xml-escape (hash-ref o 'key)))
                     (el "VersionId" (xml-escape (hash-ref v 'id)))
                     (el "IsLatest" (if (hash-ref v 'current) "true" "false"))
                     (el "LastModified" (iso8601 (hash-ref v 'created_at)))
                     (el "ETag" (xml-escape (etag-of (hash-ref v 'digest))))
                     (el "Size" (hash-ref v 'size))
                     (el "StorageClass" "STANDARD")))))))

;; ---- multipart ------------------------------------------------------------------------
;; Not optional: aws-cli switches to multipart above 8 MiB, so `aws s3 cp` of any real
;; document lands here. Parts arrive concurrently and out of order, so each is stored
;; as its own content-addressed blob and the object is assembled at Complete.
(define (op-create-multipart conn p bucket key req)
  (require-perm conn p "files:write")
  (define vis (acl->visibility req))
  (cond
    [(eq? vis 'refused)
     (s3-error "InvalidArgument" 400 #:message "Public ACLs are not supported.")]
    [else
     (define uid (new-id))
     (query-exec conn
       (string-append "INSERT INTO repo_uploads (id, org_id, team_id, user_id, key, content_type, visibility) "
                      "VALUES (?, ?, ?, ?, ?, ?, ?)")
       uid (or (team-org conn (principal-team-id p)) (principal-org-id p))
       (principal-team-id p) (principal-user-id p) key
       (or (req-header req "content-type") "application/octet-stream")
       (or vis sql-null))
     (xml-res 200 (el "InitiateMultipartUploadResult"
                      (el "Bucket" (xml-escape bucket))
                      (el "Key" (xml-escape key))
                      (el "UploadId" uid)))]))

(define (upload-row conn p upload-id)
  (define r (query-maybe-row conn
    (string-append "SELECT id, org_id, team_id, user_id, key, content_type, visibility "
                   "FROM repo_uploads WHERE id = ? AND team_id = ?")
    upload-id (principal-team-id p)))
  (and r (hasheq 'id (vector-ref r 0) 'org_id (vector-ref r 1) 'team_id (vector-ref r 2)
                 'user_id (vector-ref r 3) 'key (vector-ref r 4)
                 'content_type (vector-ref r 5)
                 'visibility (let ([v (vector-ref r 6)]) (and (not (sql-null? v)) v)))))


;; A part is a blob in its own right, staged exactly like a whole object. A retried
;; part with identical bytes therefore costs nothing, and the UNIQUE(upload_id,
;; part_number) index means a retry replaces rather than duplicates.
(define (op-upload-part conn p req upload-id part-number)
  (require-perm conn p "files:write")
  (define up (upload-row conn p upload-id))
  (cond
    [(not up) (s3-error "NoSuchUpload" 404 #:message "The specified upload does not exist.")]
    [(not part-number) (s3-error "InvalidArgument" 400 #:message "partNumber is required.")]
    [else
     (define-values (digest size) (blob-stage! (hash-ref up 'org_id) (http-req-body req)))
     (query-exec conn
       (string-append "INSERT INTO repo_upload_parts (id, upload_id, part_number, digest, size) "
                      "VALUES (?, ?, ?, ?, ?) "
                      "ON CONFLICT(upload_id, part_number) DO UPDATE SET "
                      "digest = excluded.digest, size = excluded.size")
       (new-id) upload-id part-number digest size)
     (http-res* 200 (list (cons #"ETag" (string->bytes/utf-8 (etag-of digest)))) #"")]))

;; Complete assembles the parts IN THE ORDER THE CLIENT NAMES, not the order they
;; arrived — they arrive concurrently and out of order. `input-port-append` chains the
;; part blobs into one stream, so the finished object is written by the same
;; `repo-put!` an ordinary upload uses: same versioning, same quota, same audit entry.
(define (op-complete-multipart conn p req upload-id)
  (define up (upload-row conn p upload-id))
  (cond
    [(not up) (s3-error "NoSuchUpload" 404 #:message "The specified upload does not exist.")]
    [else
     (define body (port->string (http-req-body req)))
     (define wanted (map string->number
                         (regexp-match* #px"<PartNumber>\\s*([0-9]+)\\s*</PartNumber>"
                                        body #:match-select cadr)))
     (define have
       (for/hash ([r (in-list (query-rows conn
              "SELECT part_number, digest FROM repo_upload_parts WHERE upload_id = ?" upload-id))])
         (values (vector-ref r 0) (vector-ref r 1))))
     (define order (if (null? wanted) (sort (hash-keys have) <) wanted))
     (define missing (filter (lambda (n) (not (hash-ref have n #f))) order))
     (cond
       [(null? order) (s3-error "InvalidRequest" 400 #:message "No parts were uploaded.")]
       [(pair? missing)
        (s3-error "InvalidPart" 400
                  #:message (format "Part ~a was never uploaded." (car missing)))]
       [else
        (define org (hash-ref up 'org_id))
        (define ports (for/list ([n (in-list order)]) (blob-get org (hash-ref have n))))
        (cond
          [(memf not ports)
           (for ([q (in-list ports)]) (when q (close-input-port q)))
           (s3-error "InvalidPart" 400 #:message "A part's data is missing from the store.")]
          [else
           (define joined (apply input-port-append #t ports))
           (define o (repo-put! conn p #:key (hash-ref up 'key) #:port joined
                                #:content-type (hash-ref up 'content_type)
                                #:filename (car (reverse (string-split (hash-ref up 'key) "/")))
                                #:visibility (hash-ref up 'visibility)))
           (drop-upload! conn up)
           (xml-res 200 (el "CompleteMultipartUploadResult"
                            (el "Location" (xml-escape (hash-ref up 'key)))
                            (el "Bucket" (xml-escape (team-slug conn (hash-ref up 'team_id))))
                            (el "Key" (xml-escape (hash-ref up 'key)))
                            (el "ETag" (xml-escape (etag-of (hash-ref o 'digest))))))])])]))

(define (op-abort-multipart conn p upload-id)
  (define up (upload-row conn p upload-id))
  (cond
    [(not up) (s3-error "NoSuchUpload" 404 #:message "The specified upload does not exist.")]
    [else (drop-upload! conn up) (http-res* 204 (list) #"")]))

;; Parts are blobs, so dropping an upload must not delete bytes something else still
;; points at — another in-flight upload with an identical part, or a finished object.
;; Same org-scoped refcount as repo-delete!, for the same reason (DOC-6).
(define (drop-upload! conn up)
  (define org (hash-ref up 'org_id))
  (define parts (query-rows conn "SELECT digest FROM repo_upload_parts WHERE upload_id = ?"
                            (hash-ref up 'id)))
  (query-exec conn "DELETE FROM repo_upload_parts WHERE upload_id = ?" (hash-ref up 'id))
  (query-exec conn "DELETE FROM repo_uploads WHERE id = ?" (hash-ref up 'id))
  (for ([r (in-list parts)])
    (define d (vector-ref r 0))
    (define still-a-part (query-value conn
      "SELECT COUNT(*) FROM repo_upload_parts WHERE digest = ?" d))
    (define still-a-version (query-value conn
      (string-append "SELECT COUNT(*) FROM repo_versions v JOIN repo_objects o ON o.id = v.object_id "
                     "WHERE v.digest = ? AND o.org_id = ?") d org))
    (when (and (zero? still-a-part) (zero? still-a-version)) (blob-delete! org d))))

;; ---- routing ---------------------------------------------------------------------
;; Sub-resources we do not implement are matched FIRST and answered NotImplemented, so
;; a `?acl` never falls through to being treated as an ordinary object write (DOC-13).
(define REFUSED-SUBRESOURCES
  '("acl" "policy" "lifecycle" "replication" "website" "cors" "tagging" "logging"
    "versioning" "notification" "encryption" "requestPayment" "accelerate"
    "analytics" "inventory" "metrics" "object-lock" "legal-hold" "retention" "torrent"
    "publicAccessBlock" "intelligent-tiering" "ownershipControls" "restore" "select"))

(define (refused-subresource req)
  (for/first ([q (in-list (http-req-query req))]
              #:when (member (car q) REFUSED-SUBRESOURCES))
    (car q)))

(define (make-s3-handler conn)
  (lambda (req)
    (with-handlers ([exn:fail:forbidden? (lambda (e) (access-denied (exn-message e)))]
                    [exn:fail:user? (lambda (e) (s3-error "InvalidRequest" 400 #:message (exn-message e)))]
                    [exn:fail? (lambda (e) (s3-error "InternalError" 500 #:message (exn-message e)))])
      (define method (string-upcase (http-req-method req)))
      (define who (authenticate conn req))
      (cond
        [(http-res? who) who]                                  ; the refusal itself
        [(refused-subresource req) => (lambda (q) (not-implemented (string-append "?" q)))]
        [else (dispatch conn who req method)]))))

(define (dispatch conn p req method)
  (define-values (bucket key) (split-path (http-req-path req)))
  (define (q name) (req-query req name))
  (cond
    ;; ---- service ----
    [(not bucket)
     (if (string=? method "GET") (op-list-buckets conn p) (not-implemented method))]

    ;; ---- bucket ----
    [(not key)
     (define team (resolve-bucket conn p bucket))
     (cond
       [(not team) (no-such-bucket bucket)]
       [(and (string=? method "GET") (q "location"))
        (xml-res 200 (el "LocationConstraint" (xml-escape (s3-region))))]
       [(string=? method "HEAD") (http-res* 200 '() #"")]
       [(and (string=? method "POST") (has-q? req "delete")) (op-delete-objects conn p bucket req)]
       [(and (string=? method "GET") (has-q? req "versions")) (op-list-versions conn p bucket req)]
       [(string=? method "GET") (op-list-objects conn p bucket req)]
       ;; teams are created through the team API, not by an S3 client (DOC-2)
       [(member method '("PUT" "DELETE"))
        (not-implemented (string-append method " Bucket — a bucket is a team"))]
       [else (not-implemented method)])]

    ;; ---- object ----
    [else
     (define team (resolve-bucket conn p bucket))
     (cond
       [(not team) (no-such-bucket bucket)]
       [(q "uploadId")
        => (lambda (uid)
             (cond
               [(string=? method "PUT")
                (op-upload-part conn p req uid (string->number (or (q "partNumber") "")))]
               [(string=? method "POST") (op-complete-multipart conn p req uid)]
               [(string=? method "DELETE") (op-abort-multipart conn p uid)]
               [else (not-implemented method)]))]
       [(and (string=? method "POST") (has-q? req "uploads"))
        (op-create-multipart conn p bucket key req)]
       [(req-header req "x-amz-copy-source")
        => (lambda (src) (op-copy-object conn p bucket key src))]
       [(string=? method "PUT") (op-put-object conn p bucket key req)]
       [(string=? method "GET")
        (op-get-object conn p bucket key #f (req-header req "range")
                       (let ([v (q "versionId")]) (and v (percent-decode-path v))))]
       [(string=? method "HEAD") (op-get-object conn p bucket key #t)]
       [(string=? method "DELETE") (op-delete-object conn p bucket key)]
       [else (not-implemented method)])]))
