#lang racket/base

;; domain/repo/voice.rkt — what counts as a voice note (#192, VOICE‑5…7).
;;
;; Pure of the repository, of the network and of the database, so the rules here
;; are testable with a string. The tool is `voice-tools.rkt`; the wire is
;; `transcribe-exchange` in `executor.rkt`.

(require racket/string racket/list)

(provide AUDIO-TYPES audio-type? audio-extension-for audio-filename-for
         VOICE-MAX-BYTES VOICE-FIELDS)

;; VOICE‑5 — A CLOSED LIST, NOT `audio/*`. A prefix match would claim every
;; format anybody invents, and the transcription endpoint decides what it can
;; decode from the FILENAME extension (`audio-extension-for`) — so a type with no
;; extension this knows would be posted as `.bin` and refused by the far end with
;; a message about the format rather than about the type. A closed list refuses
;; here instead, by name, and extending it is one line plus one extension.
;;
;; `video/*` is deliberately absent. A screen recording with a voice track is a
;; real thing and transcribing it is a different decision — it carries pictures
;; this platform would be discarding silently, and the one format question
;; (which audio stream?) has no answer a closed list can give.
(define AUDIO-TYPES
  (list "audio/mpeg"          ; mp3
        "audio/mp4"           ; m4a, the usual phone recording
        "audio/x-m4a"
        "audio/aac"
        "audio/wav"
        "audio/x-wav"
        "audio/wave"
        "audio/ogg"
        "audio/opus"          ; what a browser's MediaRecorder produces
        "audio/webm"
        "audio/flac"
        "audio/x-flac"))

;; The extension each type is posted under. Several types map to one extension
;; (`audio/wav`, `audio/x-wav` and `audio/wave` are all `.wav`), which is exactly
;; why this is a table rather than "take the bit after the slash".
(define EXTENSIONS
  (hash "audio/mpeg" "mp3"
        "audio/mp4" "m4a"   "audio/x-m4a" "m4a"
        "audio/aac" "aac"
        "audio/wav" "wav"   "audio/x-wav" "wav"  "audio/wave" "wav"
        "audio/ogg" "ogg"   "audio/opus" "opus"
        "audio/webm" "webm"
        "audio/flac" "flac" "audio/x-flac" "flac"))

(define (normalize ct)
  (string-downcase (string-trim (car (string-split (or ct "") ";")))))

(define (audio-type? ct) (and (member (normalize ct) AUDIO-TYPES) #t))

(define (audio-extension-for ct) (hash-ref EXTENSIONS (normalize ct) #f))

;; VOICE‑6 — THE POSTED FILENAME IS DERIVED FROM THE CONTENT TYPE, NOT FROM THE
;; DOCUMENT'S KEY. Two reasons and the second is the one that matters: a key is
;; somebody else's string and it becomes part of a multipart header, where a
;; newline would ADD a header (the injection `fetch` refuses for its own
;; headers); and a key need not carry an extension at all, while every
;; OpenAI-compatible transcription server picks its decoder from one. So the name
;; is `voice-note.<ext>` and the document's identity stays in the row.
(define (audio-filename-for ct)
  (define ext (audio-extension-for ct))
  (if ext (format "voice-note.~a" ext) "voice-note.bin"))

;; A ceiling on what is posted, because the whole recording goes over HTTP to the
;; endpoint in one body. 100 MiB is about 14 hours of 16 kbps opus and about 10
;; minutes of uncompressed 16-bit 44.1 kHz stereo WAV — so the cap bites on the
;; FORMAT rather than on the length, which is worth knowing before concluding a
;; recording was too long. `TMACH_MAX_UPLOAD` (32 MiB by default) bounds what the
;; front door accepts in one PUT, so on a default instance that is the real limit
;; and this one is the backstop for an object assembled by the S3 listener's
;; multipart path.
(define VOICE-MAX-BYTES (* 100 1024 1024))

;; What a transcription writes beyond the text, through `repo-fields-declare!`.
;; LAY‑4 refuses an undefined key, so these are declared before the write — and
;; they are attributes rather than columns for the reason the classifier's three
;; are: no migration, and `?attr=` filters on them for nothing.
(define VOICE-FIELDS
  (list (hasheq 'key "voice_duration" 'label "Duration (s)")
        (hasheq 'key "voice_language" 'label "Spoken language")
        (hasheq 'key "voice_model"    'label "Transcribed by")))
