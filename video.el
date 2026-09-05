;;; video.el --- Canvas-based video playback for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 0WD0

;; Author: 0WD0 <me@0wd0.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))
;; Keywords: multimedia, video, extensions

;; This file is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.

;;; Commentary:

;; video.el presents decoded image and video frames through Emacs Canvas
;; viewports.  It provides a dedicated `video-mode' buffer and lazy inline
;; video occurrences.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'image-mode)
(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))
(require 'image)
(require 'subr-x)
(require 'url-util)

(defgroup video nil
  "Canvas-based video playback."
  :group 'multimedia)

(defcustom video-default-fit 'contain
  "Initial viewport fit used by dedicated video windows."
  :type '(choice (const contain)
          (const cover)
          (const width)
          (const height)
          (const actual))
  :group 'video)

(defcustom video-image-default-fit 'shrink
  "Initial and reset viewport fit used by dedicated image windows.
The default `shrink' fits large images without enlarging small ones.
An explicit `contain' fit may enlarge an image to fill the viewport."
  :type '(choice (const shrink)
          (const contain)
          (const cover)
          (const width)
          (const height)
          (const actual))
  :group 'video)

(defcustom video-pause-when-hidden t
  "Whether playback pauses when none of a player's targets are visible."
  :type 'boolean
  :group 'video)

(defcustom video-network-cache-size (* 64 1024 1024)
  "Maximum bytes retained for progressive network video downloads.

Buffered time ranges drive live mouse-seek previews.  GStreamer keeps this
temporary ring buffer only for formats supporting progressive download.  A
value of zero disables progressive download caching."
  :type 'natnum
  :group 'video)

(defcustom video-pan-frame-interval (/ 1.0 60.0)
  "Minimum seconds between wheel and middle-button pan updates."
  :type 'number
  :group 'video)

(defcustom video-mouse-seek-seconds-per-pixel 0.05
  "Seconds sought per horizontal pixel while dragging mouse button 1.

At the default value, dragging 100 pixels seeks five seconds."
  :type 'number
  :group 'video)

(defcustom video-seek-step 5.0
  "Number of seconds used by short seek commands."
  :type 'number
  :group 'video)

(defcustom video-long-seek-step 30.0
  "Number of seconds used by long seek commands."
  :type 'number
  :group 'video)

(defcustom video-volume-step 0.05
  "Amount added or removed by volume commands."
  :type 'number
  :group 'video)

(defcustom video-controls-hide-delay 1.5
  "Seconds before transport controls fade while playback continues."
  :type 'number
  :group 'video)

(defcustom video-zoom-factor 1.25
  "Multiplier used by viewport zoom commands."
  :type 'number
  :group 'video)

(defcustom video-pan-step 64.0
  "Pixels moved by dedicated viewport pan commands."
  :type 'number
  :group 'video)

(defcustom video-other-frame-parameters
  '((no-special-glyphs . t)
    (minibuffer . nil)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (tab-bar-lines . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (left-fringe . 0)
    (right-fringe . 0)
    (internal-border-width . 0)
    (right-divider-width . 0)
    (bottom-divider-width . 0)
    (unsplittable . t))
  "Frame parameters used by `video-open-other-frame'.

The viewer adds its own internal frame marker after these parameters."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'video)

(defcustom video-display-buffer-function #'video-display-buffer-same-window
  "Function used by `video-display-buffer' to display a media buffer.

The function receives one buffer and must return a live window."
  :type '(choice
          (const :tag "Selected window" video-display-buffer-same-window)
          (const :tag "Other window" video-display-buffer-other-window)
          (const :tag "Presentation frame" video-display-buffer-other-frame)
          (function :tag "Custom function"))
  :group 'video)

(defcustom video-pre-display-buffer-hook nil
  "Hook run in a media buffer before `video-display-buffer' displays it."
  :type 'hook
  :group 'video)

(defcustom video-post-display-buffer-hook nil
  "Hook run in a media buffer after `video-display-buffer' displays it."
  :type 'hook
  :group 'video)

(defcustom video-bury-buffer-function #'quit-window
  "Function called by `video-quit' when no embedding application handles quit."
  :type '(choice
          (const :tag "Quit window" quit-window)
          (const :tag "Kill buffer" kill-current-buffer)
          (function :tag "Custom function"))
  :group 'video)

(defvar video-display-buffer-noselect nil
  "When non-nil, `video-display-buffer' does not select its display window.")

(defvar video-player-state-change-hook nil
  "Hook run with one PLAYER argument after playback state changes.")

(defvar video-player-error-hook nil
  "Hook run with PLAYER and error message after playback fails.")

(defconst video--library-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(defconst video--cache-poll-delay 0.1
  "Seconds between bounded cache-completion retry polls.")

(defconst video--cache-poll-limit 20
  "Maximum cache-completion retry polls after a native event burst.")

(defvar video--players nil
  "Live `video-player' objects.")

(defvar video--sessions nil
  "Live `video-session' objects.")

(defvar-local video--buffer-player nil)
(defvar-local video--buffer-owns-player nil
  "Non-nil when the current media buffer must close its player.")
(defvar-local video--buffer-session nil)
(defvar-local video--buffer-session-lease nil)
(defvar-local video--inline-objects nil)
(defvar-local video--host-hooks-installed nil)

(defvar-local video-next-function nil
  "Function called by `video-next' in a dedicated media buffer.")

(defvar-local video-previous-function nil
  "Function called by `video-previous' in a dedicated media buffer.")

(defvar-local video-quit-function nil
  "Function called by `video-quit' in a dedicated media buffer.")

(cl-defstruct (video--view (:constructor video--make-view))
  "Semantic viewport state owned by one window."
  buffer
  scale
  (x 0.0)
  (y 0.0))

(cl-defstruct (video-player (:constructor video--make-player))
  "One GStreamer playback session."
  source
  (kind 'video)
  animated-p
  animation-loop-count
  (animation-loop-policy 'file)
  (animation-iterations 0)
  animation-ended
  handle
  process
  (desired-state 'paused)
  (state 'stopped)
  (position 0.0)
  duration
  seekable
  stream-live
  live-hint
  (buffering 100)
  (width 0)
  (height 0)
  (volume 1.0)
  muted
  (rate 1.0)
  error
  request-headers
  cache-file
  cache-complete-function
  cache-error
  cache-poll-timer
  (cache-poll-remaining 0)
  buffered-time-ranges
  (buffered-range-vector [])
  (buffered-ranges-updated-at 0.0)
  session
  targets
  dispatch-timer
  buffering-timer
  suspended
  controls-timer
  closed)

(cl-defstruct (video-session (:constructor video--make-session))
  "One player and all presentation leases sharing its exact state."
  player
  presentations
  auto-close
  armed
  closed)

(cl-defstruct (video--session-lease (:constructor video--make-session-lease))
  "One inline or dedicated presentation retaining a `video-session'."
  session
  owner
  close-function
  closed)

(cl-defstruct (video-target (:constructor video--make-target))
  "One Canvas viewport backed by a native render target."
  player
  handle
  canvas
  width
  height
  canvas-width
  canvas-height
  (destination-x 0)
  (destination-y 0)
  canvas-follows-target
  (fit 'contain)
  scale
  (x 0.0)
  (y 0.0)
  last-sequence
  presented-frame
  window
  overlay
  inline
  (controls-until 0.0)
  closed)

(cl-defstruct (video-inline (:constructor video--make-inline))
  "One lazy video occurrence embedded in a normal buffer."
  source
  live
  request-headers
  poster
  overlay
  buffer
  width
  height
  fit
  muted
  canvas
  canvas-width
  canvas-height
  (destination-x 0)
  (destination-y 0)
  visible-function
  alive-function
  activate-function
  player
  session
  session-lease
  owns-player
  close-function
  target
  active
  closed)

(declare-function video-native-create
                  "video-module"
                  (uri process cache-size cache-template request-headers))
(declare-function video-native-close "video-module" (player))
(declare-function video-native-play "video-module" (player))
(declare-function video-native-pause "video-module" (player))
(declare-function video-native-stop "video-module" (player))
(declare-function video-native-seek "video-module" (player seconds))
(declare-function video-native-buffered-ranges "video-module" (player))
(declare-function video-native-set-volume "video-module" (player volume))
(declare-function video-native-set-muted "video-module" (player muted))
(declare-function video-native-set-rate "video-module" (player rate))
(declare-function video-native-poll "video-module" (player))
(declare-function video-native-target-create
                  "video-module" (player width height fit scale x y))
(declare-function video-native-target-close "video-module" (target))
(declare-function video-native-target-set-view
                  "video-module" (target width height fit scale x y))
(declare-function video-native-canvas-draw-uri
                  "video-module"
                  (canvas canvas-width canvas-height uri x y width height fit))
(declare-function video-native-target-copy
                  "video-module" (target canvas canvas-width canvas-height x y))
(declare-function video-native-control-layout
                  "video-module" (x y width height))
(declare-function video-native-canvas-draw-controls
                  "video-module"
                  (canvas canvas-width canvas-height x y width height
                          playing position duration muted opacity waiting
                          buffering has-frame seekable buffered-ranges))
(declare-function read--potential-mouse-event "mouse" ())
(defvar pixel-scroll-precision-coalesce-scroll-events)
(defvar pixel-scroll-precision-coalesce-maximum)

(defun video--load-native-module ()
  "Load the native video module or signal a useful error."
  (unless (featurep 'video-module)
    (let ((module (expand-file-name
                   (concat "video-module" module-file-suffix)
                   video--library-directory)))
      (unless (file-readable-p module)
        (error "Video.el native module is missing; run `make module'"))
      (module-load module))))

(video--load-native-module)

(defun video--normalize-source (source)
  "Return SOURCE as an absolute URI accepted by GStreamer."
  (unless (and (stringp source) (not (string-empty-p source)))
    (error "Video source must be a non-empty string"))
  (cond
   ((string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" source) source)
   ((or (file-name-absolute-p source) (file-exists-p source))
    (url-encode-url (concat "file://" (expand-file-name source))))
   (t (error "Video source is neither a URI nor a readable file: %s" source))))

(defconst video--http-header-name-regexp
  "\\`[!#$%&'*+.^_`|~0-9A-Za-z-]+\\'"
  "Regexp matching one valid HTTP field name.")

(defun video--normalize-request-headers (headers)
  "Validate HEADERS and return an alternating name/value vector.

HEADERS is nil or an alist of string field names and values.  Duplicate field
names are rejected case-insensitively.  The returned vector is safe to pass to
the native module."
  (unless (listp headers)
    (error "Video request headers must be an alist"))
  (let ((seen (make-hash-table :test #'equal))
        values)
    (dolist (header headers)
      (unless (and (consp header)
                   (stringp (car header))
                   (string-match-p video--http-header-name-regexp (car header))
                   (stringp (cdr header))
                   (not (string-match-p "[\0\r\n]" (cdr header))))
        (error "Invalid video request header"))
      (let ((name (downcase (car header))))
        (when (gethash name seen)
          (error "Duplicate video request header: %s" (car header)))
        (puthash name t seen))
      (push (car header) values)
      (push (cdr header) values))
    (vconcat (nreverse values))))

(defun video--network-uri-p (uri)
  "Return non-nil when URI is not a local file URI."
  (and (stringp uri) (not (string-prefix-p "file:" uri t))))

(defun video--cache-pending-p (player)
  "Return non-nil when PLAYER may still produce a persistent cache."
  (and (video-player-live-p player)
       (video-player-cache-file player)
       (not (video-player-cache-error player))
       (not (file-regular-p (video-player-cache-file player)))))

(defun video--cancel-cache-poll (player)
  "Cancel PLAYER's pending cache-completion retry."
  (when-let* ((timer (video-player-cache-poll-timer player))
              ((timerp timer)))
    (cancel-timer timer))
  (setf (video-player-cache-poll-timer player) nil
        (video-player-cache-poll-remaining player) 0))

(defun video--schedule-cache-poll (player)
  "Schedule PLAYER's next bounded cache-completion retry."
  (when (and (video--cache-pending-p player)
             (> (video-player-cache-poll-remaining player) 0)
             (not (timerp (video-player-cache-poll-timer player))))
    (setf (video-player-cache-poll-timer player)
          (run-at-time video--cache-poll-delay nil
                       #'video--run-cache-poll player))))

(defun video--run-cache-poll (player)
  "Retry native cache-completion detection for PLAYER once."
  (when (video-player-p player)
    (setf (video-player-cache-poll-timer player) nil)
    (if (not (video--cache-pending-p player))
        (video--cancel-cache-poll player)
      (cl-decf (video-player-cache-poll-remaining player))
      (video--dispatch player)
      (video--schedule-cache-poll player))))

(defun video--arm-cache-poll (player)
  "Start a bounded cache-completion retry burst for PLAYER."
  (when (video--cache-pending-p player)
    (setf (video-player-cache-poll-remaining player)
          video--cache-poll-limit)
    (video--schedule-cache-poll player)))

(defun video--commit-network-cache (player location)
  "Atomically promote PLAYER's complete temporary cache at LOCATION."
  (when-let* ((target (video-player-cache-file player))
              ((file-regular-p location)))
    (condition-case error-data
        (progn
          (unless (file-regular-p target)
            (condition-case rename-error
                (rename-file location target)
              (file-already-exists
               (unless (file-regular-p target)
                 (signal (car rename-error) (cdr rename-error))))))
          (video--cancel-cache-poll player)
          (setf (video-player-cache-error player) nil)
          (when-let* ((callback (video-player-cache-complete-function player)))
            (setf (video-player-cache-complete-function player) nil)
            (funcall callback player target))
          target)
      (error
       (setf (video-player-cache-error player)
             (error-message-string error-data))
       (video--cancel-cache-poll player)
       (display-warning
        'video
        (format "Could not retain completed video cache: %s"
                (video-player-cache-error player))
        :warning)
       nil))))

(defun video--event-filter (process output)
  "Schedule dispatch for PROCESS, retrying cache detection after event OUTPUT."
  (when-let* ((player (process-get process 'video-player))
              ((not (video-player-closed player))))
    (when (string-match-p "e" output)
      (video--arm-cache-poll player))
    (unless (timerp (video-player-dispatch-timer player))
      (setf (video-player-dispatch-timer player)
            (run-at-time 0 nil #'video--dispatch player)))))

(defcustom video-animation-loop-policy 'file
  "How animated images repeat.
`file' honors GIF loop metadata: absent means once, zero means forever,
and a positive count is the number of repetitions after the first pass.
`forever' repeats without limit; `once' disables repetition.
The value is captured when a player is created.  Remote image animation
is discovered from native duration information, not the filename; its
loop metadata is unavailable, so `file' plays it once."
  :type '(choice (const file) (const forever) (const once))
  :group 'video)

(defun video--gif-metadata (file)
  "Read GIF frame and loop metadata from local FILE, or return nil.
Only complete GIF streams are accepted.  Read in bounded chunks and skip
compressed image data without decoding it.  Loop counts follow the
NETSCAPE2.0 and ANIMEXTS1.0 application extensions."
  (when (and file (not (file-remote-p file)) (file-readable-p file)
             (file-regular-p file))
    (condition-case nil
        (let ((size (file-attribute-size (file-attributes file)))
              (offset 0) (cache-start 0) (frames 0) loops)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (catch 'video--invalid-gif
              (cl-labels
                  ((bytes (count)
                     (when (> (+ offset count) size)
                       (throw 'video--invalid-gif nil))
                     (unless (and (>= offset cache-start)
                                  (<= (+ offset count)
                                      (+ cache-start (buffer-size))))
                       (erase-buffer)
                       (setq cache-start offset)
                       (insert-file-contents-literally
                        file nil offset (min size (+ offset (max count 65536)))))
                     (when (> (+ (- offset cache-start) count) (buffer-size))
                       (throw 'video--invalid-gif nil))
                     (let ((start (1+ (- offset cache-start))))
                       (setq offset (+ offset count))
                       (buffer-substring-no-properties start (+ start count))))
                   (byte () (aref (bytes 1) 0))
                   (skip (count)
                     (setq offset (+ offset count))
                     (when (> offset size) (throw 'video--invalid-gif nil)))
                   (blocks ()
                     (let ((count (byte)))
                       (while (> count 0)
                         (skip count)
                         (setq count (byte)))))
                   (word (data index)
                     (+ (aref data index) (ash (aref data (1+ index)) 8))))
                (unless (member (bytes 6) '("GIF87a" "GIF89a"))
                  (throw 'video--invalid-gif nil))
                (let ((screen (bytes 7)))
                  (when (or (zerop (word screen 0)) (zerop (word screen 2)))
                    (throw 'video--invalid-gif nil))
                  (when (/= 0 (logand (aref screen 4) #x80))
                    (skip (* 3 (ash 1 (1+ (logand (aref screen 4) 7)))))))
                (let (done)
                  (while (not done)
                    (pcase (byte)
                      (#x3b (setq done t))
                      (#x2c
                       (let ((descriptor (bytes 9)))
                         (when (or (zerop (word descriptor 4))
                                   (zerop (word descriptor 6)))
                           (throw 'video--invalid-gif nil))
                         (when (/= 0 (logand (aref descriptor 8) #x80))
                           (skip (* 3 (ash 1 (1+ (logand (aref descriptor 8) 7)))))))
                       (byte) ; LZW minimum code size.
                       (blocks)
                       (cl-incf frames))
                      (#x21
                       (pcase (byte)
                         (#xff
                          (let* ((length (byte))
                                 (application (bytes length)))
                            (if (and (= length 11)
                                     (member application '("NETSCAPE2.0" "ANIMEXTS1.0")))
                                (let ((count (byte)))
                                  (while (> count 0)
                                    (let ((data (bytes count)))
                                      (when (and (= count 3) (= (aref data 0) 1))
                                        (setq loops (word data 1))))
                                    (setq count (byte))))
                              (blocks))))
                         (_ (blocks))))
                      (_ (throw 'video--invalid-gif nil)))))
                (when (> frames 0)
                  (list :frames frames :loop-count loops))))))
      (file-error nil))))

(defun video--animation-repeat-p (player)
  "Whether PLAYER may begin another animation iteration."
  (pcase (video-player-animation-loop-policy player)
    ('forever t)
    ('file
     (let ((count (video-player-animation-loop-count player)))
       (and (integerp count)
            (or (zerop count)
                (<= (video-player-animation-iterations player) count)))))
    (_ nil)))

(defun video--restart-animation (player)
  "Rewind PLAYER without resetting its animation repeat budget."
  (if (video-player-seekable player)
      (video-native-seek (video-player-handle player) 0.0)
    (video-native-stop (video-player-handle player)))
  (setf (video-player-position player) 0.0
        (video-player-animation-ended player) nil
        (video-player-suspended player) t))

(defun video--animation-eos (player)
  "Handle animated PLAYER's EOS and return non-nil if repeating.
Count each completed iteration once, including an EOS observed while
paused.  Repetition is owned by the player, never by a render target."
  (when (video-player-animated-p player)
    (unless (video-player-animation-ended player)
      (cl-incf (video-player-animation-iterations player))
      (setf (video-player-animation-ended player) t))
    (when (and (eq (video-player-desired-state player) 'playing)
               (video--animation-repeat-p player))
      (video--restart-animation player)
      t)))

(cl-defun video-player-create
    (source &key (kind 'video) (volume 1.0) muted (rate 1.0) live
            cache-file cache-complete-function request-headers
            (animation-loop-policy video-animation-loop-policy))
  "Create and return a media player for SOURCE.

KIND is `video' or `image'.  VOLUME is between zero and one.  MUTED controls
initial audio output and RATE is the positive playback rate.  LIVE forces
live-stream semantics when protocol discovery cannot identify a live source.
For a network video, CACHE-FILE names an optional persistent destination
promoted only after GStreamer's sparse progressive cache becomes complete.
CACHE-COMPLETE-FUNCTION is then called with the player and local file.
REQUEST-HEADERS is an alist of HTTP field names and values applied to every
HTTP resource created for SOURCE.  ANIMATION-LOOP-POLICY overrides
`video-animation-loop-policy' for this player.
GIF capability is independent of KIND.  Local GIF
metadata is read before playback; remote image animation is discovered
from native duration, with no file loop metadata.  The player starts paused."
  (unless (display-graphic-p)
    (error "Video.el requires a graphical Emacs display"))
  (unless (image-type-available-p 'canvas)
    (error "This Emacs build does not provide Canvas images"))
  (unless (memq kind '(video image))
    (error "Unsupported media kind: %S" kind))
  (unless (memq animation-loop-policy '(file forever once))
    (error "Unsupported animation loop policy: %S" animation-loop-policy))
  (when (and live (not (eq kind 'video)))
    (error "Only video sources can be marked live"))
  (when (and cache-complete-function
             (not (functionp cache-complete-function)))
    (error "Video cache completion callback is not callable"))
  (let* ((uri (video--normalize-source source))
         (animation (and (eq kind 'image)
                         (video--gif-metadata (video--local-source-file source))))
         (request-headers (video--normalize-request-headers request-headers))
         (cache-file
          (when cache-file
            (unless (and (eq kind 'video) (video--network-uri-p uri))
              (error "Persistent video cache requires a network video source"))
            (unless (and (stringp cache-file)
                         (not (string-empty-p cache-file)))
              (error "Video cache file must be a non-empty filename"))
            (when (zerop video-network-cache-size)
              (error "Persistent video cache requires progressive caching"))
            (expand-file-name cache-file)))
         (cache-template
          (when cache-file
            (make-directory (file-name-directory cache-file) t)
            (concat cache-file ".part-XXXXXX")))
         (process (make-pipe-process
                   :name (generate-new-buffer-name " video-events")
                   :buffer nil
                   :coding 'no-conversion
                   :noquery t
                   :filter #'video--event-filter
                   :sentinel #'ignore))
         (player (video--make-player
                  :source uri :kind kind :process process
                  :animated-p (and animation (> (plist-get animation :frames) 1))
                  :animation-loop-count (plist-get animation :loop-count)
                  :animation-loop-policy animation-loop-policy
                  :volume (max 0.0 (min 1.0 (float volume)))
                  :muted (and muted t)
                  :rate (max 0.01 (float rate))
                  :stream-live (and live t)
                  :live-hint (and live t)
                  :request-headers request-headers
                  :cache-file cache-file
                  :cache-complete-function cache-complete-function)))
    (process-put process 'video-player player)
    (condition-case error-data
        (setf (video-player-handle player)
              (video-native-create
               uri process (if (eq kind 'video) video-network-cache-size 0)
               cache-template request-headers))
      (error
       (delete-process process)
       (signal (car error-data) (cdr error-data))))
    (video-native-set-volume (video-player-handle player)
                             (video-player-volume player))
    (video-native-set-muted (video-player-handle player)
                            (video-player-muted player))
    (video-native-set-rate (video-player-handle player)
                           (video-player-rate player))
    (push player video--players)
    (video--dispatch player)
    player))

(defun video-player-live-p (player)
  "Return non-nil when PLAYER owns a live native session."
  (and (video-player-p player)
       (not (video-player-closed player))
       (video-player-handle player)))

(cl-defun video-session-create
    (source &key (kind 'video) (volume 1.0) muted (rate 1.0) live
            cache-file cache-complete-function request-headers (auto-close t))
  "Create a reusable presentation session for SOURCE.

KIND, VOLUME, MUTED, RATE, LIVE, CACHE-FILE, CACHE-COMPLETE-FUNCTION, and
REQUEST-HEADERS are forwarded to `video-player-create'.  When AUTO-CLOSE is
non-nil, closing the last presentation closes the session after it has
presented at least once.  The player starts paused."
  (let* ((player
          (video-player-create
           source :kind kind :volume volume :muted muted :rate rate :live live
           :cache-file cache-file
           :cache-complete-function cache-complete-function
           :request-headers request-headers))
         (session
          (video--make-session
           :player player :auto-close (and auto-close t))))
    (setf (video-player-session player) session)
    (push session video--sessions)
    session))

(defun video-session-live-p (session)
  "Return non-nil when SESSION owns a live player."
  (and (video-session-p session)
       (not (video-session-closed session))
       (video-player-live-p (video-session-player session))))

(defun video-session-presentation-count (session)
  "Return the number of live presentations retaining SESSION."
  (if (video-session-p session)
      (length (video-session-presentations session))
    0))

(defun video--session-acquire (session owner close-function)
  "Retain SESSION for presentation OWNER closed by CLOSE-FUNCTION."
  (unless (video-session-live-p session)
    (error "Cannot present a closed video session"))
  (unless (functionp close-function)
    (error "Video session presentation close function is not callable"))
  (let ((lease
         (video--make-session-lease
          :session session :owner owner :close-function close-function)))
    (setf (video-session-armed session) t)
    (push lease (video-session-presentations session))
    lease))

(defun video--session-release (lease)
  "Release one presentation LEASE and auto-close its session if empty."
  (when (and (video--session-lease-p lease)
             (not (video--session-lease-closed lease)))
    (setf (video--session-lease-closed lease) t)
    (let ((session (video--session-lease-session lease)))
      (setf (video--session-lease-owner lease) nil
            (video--session-lease-close-function lease) nil)
      (when (video-session-p session)
        (setf (video-session-presentations session)
              (delq lease (video-session-presentations session)))
        (when (and (video-session-auto-close session)
                   (video-session-armed session)
                   (null (video-session-presentations session))
                   (not (video-session-closed session)))
          (video-session-close session)))))
  nil)

(defun video-player-play (player)
  "Play PLAYER, respecting target visibility policy."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (if (video-player-animated-p player)
      (when (video-player-animation-ended player)
        (unless (video--animation-repeat-p player)
          (setf (video-player-animation-iterations player) 0))
        (video--restart-animation player))
    (when-let* (((video-player-seekable player))
              (duration (video-player-duration player))
              (position (video-player-position player))
              ((>= position (max 0.0 (- duration 0.05)))))
    (video-native-seek (video-player-handle player) 0.0)
    (setf (video-player-position player) 0.0)))
  (setf (video-player-error player) nil
        (video-player-desired-state player) 'playing
        (video-player-suspended player) t)
  (video--reconcile-player-visibility player)
  (video--show-player-controls player)
  (video--update-player-buffering-animation player)
  player)

(defun video-player-pause (player)
  "Pause PLAYER."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (setf (video-player-desired-state player) 'paused
        (video-player-suspended player) nil)
  (video-native-pause (video-player-handle player))
  (video--show-player-controls player)
  (video--update-player-buffering-animation player)
  player)

(defun video-player-toggle (player)
  "Toggle PLAYER between playing and paused."
  (if (eq (video-player-desired-state player) 'playing)
      (video-player-pause player)
    (video-player-play player)))

(defun video-player-stop (player)
  "Stop PLAYER and reset its desired state."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (setf (video-player-desired-state player) 'stopped
        (video-player-suspended player) nil
        (video-player-animation-iterations player) 0
        (video-player-animation-ended player) nil)
  (video-native-stop (video-player-handle player))
  (video--show-player-controls player)
  (video--update-player-buffering-animation player)
  player)

(defun video-player-seek (player seconds)
  "Seek PLAYER to absolute position SECONDS."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (unless (video-player-seekable player)
    (user-error "Current media is not seekable"))
  (let* ((limit (video-player-duration player))
         (position
          (max 0.0
               (if (numberp limit)
                   (min (float seconds) limit)
                 (float seconds)))))
    (setf (video-player-position player) position)
    (video-native-seek (video-player-handle player) position))
  (video--show-player-controls player)
  (force-mode-line-update t)
  player)

(defun video-player-seek-relative (player delta)
  "Seek PLAYER by DELTA seconds."
  (video-player-seek player (+ (or (video-player-position player) 0.0) delta)))

(defun video--store-player-buffered-ranges (player ranges)
  "Store native RANGES and normalized transport ranges on PLAYER."
  (let ((duration (video-player-duration player))
        normalized)
    (when (and (numberp duration) (> duration 0.0))
      (dolist (range ranges)
        (when (and (consp range)
                   (numberp (car range))
                   (numberp (cdr range))
                   (< (car range) (cdr range)))
          (push (/ (float (car range)) duration) normalized)
          (push (/ (float (cdr range)) duration) normalized))))
    (setf (video-player-buffered-time-ranges player) ranges
          (video-player-buffered-range-vector player) (vconcat (nreverse normalized))
          (video-player-buffered-ranges-updated-at player) (float-time))
    ranges))

(defun video-player-buffered-ranges (player)
  "Return locally available time ranges for PLAYER.

Each range is a cons cell of start and end seconds.  Return nil when the
native pipeline cannot report buffering ranges."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (video--store-player-buffered-ranges
   player (video-native-buffered-ranges (video-player-handle player))))

(defun video--player-buffered-range-vector (player)
  "Return PLAYER buffered ranges normalized for transport drawing."
  (when (and (video--network-uri-p (video-player-source player))
             (> (- (float-time)
                   (video-player-buffered-ranges-updated-at player))
                0.25))
    (video-player-buffered-ranges player))
  (video-player-buffered-range-vector player))

(defun video-player-set-volume (player volume)
  "Set PLAYER audio VOLUME between zero and one."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (setf (video-player-volume player)
        (max 0.0 (min 1.0 (float volume))))
  (video-native-set-volume (video-player-handle player)
                           (video-player-volume player))
  (video--show-player-controls player)
  player)

(defun video-player-set-muted (player muted)
  "Set PLAYER audio MUTED state."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (setf (video-player-muted player) (and muted t))
  (video-native-set-muted (video-player-handle player)
                          (video-player-muted player))
  (video--show-player-controls player)
  player)

(defun video-session-close (session)
  "Close SESSION, every presentation retaining it, and its player.

This operation is idempotent."
  (when (and (video-session-p session)
             (not (video-session-closed session)))
    (setf (video-session-closed session) t)
    (setq video--sessions (delq session video--sessions))
    (let ((presentations (video-session-presentations session))
          (player (video-session-player session)))
      (setf (video-session-presentations session) nil)
      (dolist (lease presentations)
        (unless (video--session-lease-closed lease)
          (setf (video--session-lease-closed lease) t)
          (let ((owner (video--session-lease-owner lease))
                (close-function
                 (video--session-lease-close-function lease)))
            (setf (video--session-lease-owner lease) nil
                  (video--session-lease-close-function lease) nil)
            (condition-case error-data
                (funcall close-function owner)
              (error
               (message "Video session presentation close failed: %s"
                        (error-message-string error-data)))))))
      (when (video-player-p player)
        (setf (video-player-session player) nil)
        (video-player-close player))))
  nil)

(defun video-player-close (player)
  "Close PLAYER and every render target it owns.

This operation is idempotent."
  (when-let* ((session (and (video-player-p player)
                            (video-player-session player)))
              ((not (video-session-closed session))))
    (video-session-close session))
  (when (and (video-player-p player) (not (video-player-closed player)))
    (setf (video-player-closed player) t)
    (when-let* ((timer (video-player-dispatch-timer player))
                ((timerp timer)))
      (cancel-timer timer))
    (setf (video-player-dispatch-timer player) nil)
    (video--cancel-cache-poll player)
    (when-let* ((timer (video-player-controls-timer player))
                ((timerp timer)))
      (cancel-timer timer))
    (setf (video-player-controls-timer player) nil)
    (when-let* ((timer (video-player-buffering-timer player))
                ((timerp timer)))
      (cancel-timer timer))
    (setf (video-player-buffering-timer player) nil)
    (dolist (target (copy-sequence (video-player-targets player)))
      (video-target-close target))
    (when (video-player-handle player)
      (condition-case error-data
          (video-native-close (video-player-handle player))
        (error
         (message "Video player close failed: %s"
                  (error-message-string error-data)))))
    (setf (video-player-handle player) nil)
    (when-let* ((process (video-player-process player))
                ((process-live-p process)))
      (delete-process process))
    (setf (video-player-process player) nil)
    (setq video--players (delq player video--players)))
  nil)

(defun video-canvas-create (width height)
  "Return a unique Canvas image of WIDTH by HEIGHT pixels."
  (list 'image
        :type 'canvas
        :id (gensym "video-canvas-")
        :data-width width
        :data-height height
        :scale 1.0
        :ascent 'center))

(defun video-canvas-draw-uri
    (canvas canvas-width canvas-height source x y width height &optional fit)
  "Draw one frame from SOURCE into CANVAS.

CANVAS-WIDTH and CANVAS-HEIGHT describe the complete Canvas.  X, Y, WIDTH, and
HEIGHT describe the destination rectangle and may be clipped at its edges.
FIT defaults to `contain'.  Return non-nil when a frame was drawn.  This
function does not call `canvas-refresh', so scene hosts can batch several
regions before one refresh."
  (video-native-canvas-draw-uri
   canvas canvas-width canvas-height (video--normalize-source source)
   (round x) (round y) (round width) (round height)
   (video--fit-name (or fit 'contain))))

(defun video--fit-name (fit)
  "Return native string name for FIT."
  (pcase fit
    ((or 'contain 'shrink 'cover 'width 'height 'actual) (symbol-name fit))
    (_ "contain")))

(cl-defun video-target-create
    (player width height &key (fit video-default-fit) scale
            (x 0.0) (y 0.0)
            canvas canvas-width canvas-height
            (destination-x 0) (destination-y 0))
  "Create a viewport render target for PLAYER with WIDTH and HEIGHT.

SCALE is the absolute source-pixel to display-pixel ratio.  X and Y locate the
viewport in the resulting virtual media plane.  When SCALE is nil, FIT chooses
an automatic scale; this mode is intended for fixed inline targets.  CANVAS may
supply a larger host-owned scene.  CANVAS-WIDTH, CANVAS-HEIGHT, DESTINATION-X,
and DESTINATION-Y place this target inside that scene."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (unless (and (integerp width) (> width 0)
               (integerp height) (> height 0))
    (error "Video target dimensions must be positive integers"))
  (setq scale (and scale
                   (max 0.0001 (min 65536.0 (float scale))))
        x (float x)
        y (float y))
  (let* ((follows-target (null canvas))
         (canvas (or canvas (video-canvas-create width height)))
         (canvas-width (or canvas-width width))
         (canvas-height (or canvas-height height))
         (handle (video-native-target-create
                  (video-player-handle player) width height
                  (video--fit-name fit) (float (or scale 0.0)) x y))
         (target (video--make-target
                  :player player :handle handle :canvas canvas
                  :width width :height height
                  :canvas-width canvas-width :canvas-height canvas-height
                  :destination-x (round destination-x)
                  :destination-y (round destination-y)
                  :canvas-follows-target follows-target
                  :fit fit :scale scale :x x :y y
                  :controls-until (+ (float-time)
                                     video-controls-hide-delay))))
    (push target (video-player-targets player))
    target))

(defun video-target-set-view
    (target width height scale x y &optional fit)
  "Set TARGET's WIDTH by HEIGHT viewport to absolute SCALE and origin X,Y.

When SCALE is nil, use automatic FIT instead."
  (when (video-target-closed target)
    (error "Video target is closed"))
  (setq width (max 1 (round width))
        height (max 1 (round height))
        scale (and scale
                   (max 0.0001 (min 65536.0 (float scale))))
        x (float x)
        y (float y)
        fit (or fit (video-target-fit target)))
  (setf (video-target-width target) width
        (video-target-height target) height
        (video-target-fit target) fit
        (video-target-scale target) scale
        (video-target-x target) x
        (video-target-y target) y
        (video-target-last-sequence target) nil)
  (when (video-target-canvas-follows-target target)
    (setf (video-target-canvas-width target) width
          (video-target-canvas-height target) height)
    (plist-put (cdr (video-target-canvas target)) :data-width width)
    (plist-put (cdr (video-target-canvas target)) :data-height height))
  (video-native-target-set-view
   (video-target-handle target) width height (video--fit-name fit)
   (float (or scale 0.0)) x y)
  target)

(defun video-target-close (target)
  "Close TARGET without closing its player."
  (when (and (video-target-p target) (not (video-target-closed target)))
    (setf (video-target-closed target) t)
    (let ((player (video-target-player target)))
      (setf (video-player-targets player)
            (delq target (video-player-targets player))))
    (when (video-target-handle target)
      (condition-case error-data
          (video-native-target-close (video-target-handle target))
        (error
         (message "Video target close failed: %s"
                  (error-message-string error-data)))))
    (setf (video-target-handle target) nil)
    (let ((overlay (video-target-overlay target))
          (window (video-target-window target)))
      (when (and (windowp window)
                 (eq (window-parameter window 'video-overlay) overlay))
        (video--cancel-pan window)
        (set-window-parameter window 'video-overlay nil))
      (when (overlayp overlay)
        (delete-overlay overlay)))
    (setf (video-target-overlay target) nil
          (video-target-window target) nil))
  nil)

(defun video--target-visible-p (target)
  "Return non-nil when TARGET is visible in a live window."
  (cond
   ((video-target-closed target) nil)
   ((video-target-window target)
    (let ((window (video-target-window target))
          (overlay (video-target-overlay target)))
      (and (window-live-p window)
           (overlayp overlay)
           (eq (window-buffer window) (overlay-buffer overlay))
           (eq (window-parameter window 'video-overlay) overlay)
           (eq (overlay-get overlay 'video-target) target))))
   ((video-target-inline target)
    (video-inline-visible-p (video-target-inline target)))
   (t t)))

(defun video--reconcile-player-visibility (player)
  "Apply visibility suspension policy to PLAYER."
  (when (video-player-live-p player)
    (let ((visible (or (null (video-player-targets player))
                       (cl-some #'video--target-visible-p
                                (video-player-targets player)))))
      (cond
       ((not (eq (video-player-desired-state player) 'playing)) nil)
       ((or visible (not video-pause-when-hidden))
        (when (video-player-suspended player)
          (setf (video-player-suspended player) nil)
          (video-native-play (video-player-handle player))))
       ((not (video-player-suspended player))
        (setf (video-player-suspended player) t)
        (video-native-pause (video-player-handle player)))))
    (video--update-player-buffering-animation player)))

(defconst video--control-map-ids
  '(video-control-toggle video-control-mute video-control-seek)
  "Image-map IDs owned by video.el transport controls.")

(defun video--target-control-layout (target)
  "Return native transport rectangles for TARGET."
  (video-native-control-layout
   (video-target-destination-x target)
   (video-target-destination-y target)
   (video-target-width target)
   (video-target-height target)))

(defun video--control-map-entry (rectangle id help)
  "Return one image map entry for RECTANGLE, ID, and HELP."
  (let ((x (aref rectangle 0))
        (y (aref rectangle 1))
        (width (aref rectangle 2))
        (height (aref rectangle 3)))
    (list `(rect . ((,x . ,y) . (,(+ x width) . ,(+ y height))))
          id
          `(:pointer hand :help-echo ,help))))

(defun video--target-control-map (target)
  "Return image map entries for TARGET's transport controls."
  (let* ((player (video-target-player target))
         (layout (video--target-control-layout target))
         (controls
          (list
           (video--control-map-entry
            (aref layout 0) 'video-control-toggle "Play or pause")
           (video--control-map-entry
            (aref layout 1) 'video-control-mute "Toggle mute"))))
    (if (video-player-seekable player)
        (append
         controls
         (list
          (video--control-map-entry
           (aref layout 2) 'video-control-seek "Seek")))
      controls)))

(defun video--install-target-control-map (target)
  "Prepend TARGET transport hot spots to its Canvas image map."
  (let* ((canvas (video-target-canvas target))
         (existing (plist-get (cdr canvas) :map))
         (host-map
          (cl-remove-if
           (lambda (entry)
             (memq (cadr entry) video--control-map-ids))
           existing)))
    (plist-put (cdr canvas) :map
               (append (video--target-control-map target) host-map))))

(defun video--player-transport-p (player)
  "Return non-nil when PLAYER supports playback controls."
  (or (eq (video-player-kind player) 'video)
      (video-player-animated-p player)))

(defun video--player-waiting-p (player)
  "Return non-nil when network PLAYER is waiting for playable data."
  (and (video--player-transport-p player)
       (not (video-player-error player))
       (video--network-uri-p (video-player-source player))
       (eq (video-player-desired-state player) 'playing)
       (not (video-player-suspended player))
       (or (eq (video-player-state player) 'buffering)
           (eq (video-player-state player) 'stopped)
           (< (or (video-player-buffering player) 100) 100))))

(defun video--animate-player-buffering (player)
  "Advance PLAYER's visible buffering indicator."
  (if (and (video-player-live-p player)
           (video--player-waiting-p player))
      (dolist (target (video-player-targets player))
        (setf (video-target-last-sequence target) nil)
        (video--present-target target))
    (when-let* ((timer (video-player-buffering-timer player))
                ((timerp timer)))
      (cancel-timer timer))
    (setf (video-player-buffering-timer player) nil)))

(defun video--update-player-buffering-animation (player)
  "Start or stop PLAYER's visible buffering animation."
  (if (video--player-waiting-p player)
      (unless (timerp (video-player-buffering-timer player))
        (setf (video-player-buffering-timer player)
              (run-at-time 0.1 0.1 #'video--animate-player-buffering player)))
    (when-let* ((timer (video-player-buffering-timer player))
                ((timerp timer)))
      (cancel-timer timer))
    (setf (video-player-buffering-timer player) nil)))

(defun video--target-controls-opacity (target)
  "Return current transport control opacity for TARGET."
  (let ((player (video-target-player target)))
    (if (or (not (eq (video-player-desired-state player) 'playing))
            (> (video-target-controls-until target) (float-time)))
        0.9
      0.0)))

(defun video--draw-target-controls (target)
  "Draw PLAYER transport and network-waiting state over TARGET."
  (let* ((player (video-target-player target))
         (opacity (video--target-controls-opacity target))
         (waiting (video--player-waiting-p player)))
    (when (or waiting (> opacity 0.0))
      (video-native-canvas-draw-controls
       (video-target-canvas target)
       (video-target-canvas-width target)
       (video-target-canvas-height target)
       (video-target-destination-x target)
       (video-target-destination-y target)
       (video-target-width target)
       (video-target-height target)
       (eq (video-player-desired-state player) 'playing)
       (float (or (video-player-position player) 0.0))
       (float (or (video-player-duration player) 0.0))
       (video-player-muted player)
       opacity
       waiting
       (float (or (video-player-buffering player) 100))
       (video-target-presented-frame target)
       (video-player-seekable player)
       (if (> opacity 0.0)
           (video--player-buffered-range-vector player)
         [])))))

(defun video--expire-player-controls (player)
  "Hide transport controls for a still-playing PLAYER."
  (when (video-player-p player)
    (setf (video-player-controls-timer player) nil)
    (when (and (video-player-live-p player)
               (eq (video-player-desired-state player) 'playing))
      (dolist (target (video-player-targets player))
        (setf (video-target-last-sequence target) nil)
        (video--present-target target)))))

(defun video--show-player-controls (player)
  "Show PLAYER transport controls and schedule their fade."
  (when (and (video-player-live-p player)
             (video--player-transport-p player))
    (when-let* ((timer (video-player-controls-timer player))
                ((timerp timer)))
      (cancel-timer timer))
    (let ((until (+ (float-time) (max 0.0 video-controls-hide-delay))))
      (dolist (target (video-player-targets player))
        (setf (video-target-controls-until target) until
              (video-target-last-sequence target) nil)
        (video--present-target target)))
    (setf (video-player-controls-timer player)
          (when (eq (video-player-desired-state player) 'playing)
            (run-at-time (max 0.0 video-controls-hide-delay) nil
                         #'video--expire-player-controls player)))))

(defun video--present-target (target)
  "Copy the newest current-view frame and current overlays into TARGET."
  (when (and (not (video-target-closed target))
             (video--target-visible-p target))
    (let* ((player (video-target-player target))
           (sequence
            (video-native-target-copy
             (video-target-handle target) (video-target-canvas target)
             (video-target-canvas-width target) (video-target-canvas-height target)
             (video-target-destination-x target)
             (video-target-destination-y target)))
           (frame-changed
            (and (integerp sequence)
                 (not (equal sequence (video-target-last-sequence target))))))
      (when (or frame-changed
                (and (video--player-transport-p player)
                     (not (video-target-presented-frame target))))
        (when frame-changed
          (setf (video-target-last-sequence target) sequence
                (video-target-presented-frame target) t)
          (when-let* ((window (video-target-window target))
                      (overlay (video-target-overlay target))
                      ((window-live-p window))
                      ((eq (video--window-overlay window) overlay)))
            (overlay-put overlay 'display (video-target-canvas target))))
        (when (video--player-transport-p player)
          (video--install-target-control-map target)
          (video--draw-target-controls target))
        (canvas-refresh (video-target-canvas target))
        (when-let* ((inline (video-target-inline target))
                    ((video-target-presented-frame target))
                    ((not (video-inline-active inline))))
          (if-let* ((activate (video-inline-activate-function inline)))
              (funcall activate inline (video-target-canvas target))
            (when (overlayp (video-inline-overlay inline))
              (overlay-put (video-inline-overlay inline) 'display
                           (video-target-canvas target))))
          (setf (video-inline-active inline) t))))))

(defun video--dispatch (player)
  "Drain native state and present dirty targets for PLAYER."
  (when (video-player-p player)
    (setf (video-player-dispatch-timer player) nil)
    (when (video-player-live-p player)
      (condition-case error-data
          (let* ((old-state (video-player-state player))
                 (old-buffering (video-player-buffering player))
                 (old-seekable (video-player-seekable player))
                 (old-stream-live (video-player-stream-live player))
                 (old-animated (video-player-animated-p player))
                 (old-error (video-player-error player))
                 (state (video-native-poll (video-player-handle player)))
                 (stream-live
                  (or (video-player-live-hint player)
                      (plist-get state :live)))
                 (seekable
                  (and (not stream-live) (plist-get state :seekable))))
            (setf (video-player-state player) (or (plist-get state :state) 'stopped)
                  (video-player-position player) (or (plist-get state :position) 0.0)
                  (video-player-duration player) (plist-get state :duration)
                  (video-player-seekable player) seekable
                  (video-player-stream-live player) stream-live
                  (video-player-buffering player) (or (plist-get state :buffering) 100)
                  (video-player-width player) (or (plist-get state :width) 0)
                  (video-player-height player) (or (plist-get state :height) 0)
                  (video-player-error player) (plist-get state :error))
            (when (and (eq (video-player-kind player) 'image)
                       (video--network-uri-p (video-player-source player))
                       (numberp (video-player-duration player))
                       (> (video-player-duration player) 0))
              (setf (video-player-animated-p player) t))
            (when-let* ((location (plist-get state :cache-location)))
              (video--commit-network-cache player location))
            (video--initialize-player-window-views player)
            (when (or (video-player-error player)
                      (and (plist-get state :eos)
                           (not (video--animation-eos player))))
              (setf (video-player-desired-state player) 'paused
                    (video-player-suspended player) nil)
              (when-let* ((timer (video-player-controls-timer player))
                          ((timerp timer)))
                (cancel-timer timer))
              (setf (video-player-controls-timer player) nil))
            (when (or (not (eq old-animated (video-player-animated-p player)))
                      (not (eq old-state (video-player-state player)))
                      (not (equal old-buffering
                                  (video-player-buffering player)))
                      (not (eq old-seekable
                               (video-player-seekable player)))
                      (not (eq old-stream-live
                               (video-player-stream-live player)))
                      (not (equal old-error (video-player-error player))))
              (dolist (target (video-player-targets player))
                (setf (video-target-last-sequence target) nil)))
            (video--update-player-buffering-animation player)
            (dolist (target (video-player-targets player))
              (video--present-target target))
            (video--reconcile-player-visibility player)
            (unless (eq old-state (video-player-state player))
              (run-hook-with-args 'video-player-state-change-hook player))

            (when (and (video-player-error player)
                       (not (equal old-error (video-player-error player))))
              (run-hook-with-args 'video-player-error-hook
                                  player (video-player-error player)))
            (force-mode-line-update t))
        (error
         (setf (video-player-error player) (error-message-string error-data)))))))

(defun video--format-time (seconds)
  "Return SECONDS as a compact playback timestamp."
  (if (not (numberp seconds))
      "--:--"
    (let* ((whole (max 0 (floor seconds)))
           (hours (/ whole 3600))
           (minutes (% (/ whole 60) 60))
           (remaining (% whole 60)))
      (if (> hours 0)
          (format "%d:%02d:%02d" hours minutes remaining)
        (format "%02d:%02d" minutes remaining)))))

(defun video--mode-line-position ()
  "Return media state and the displayed window's scale for this buffer."
  (when (video-player-live-p video--buffer-player)
    (concat
     (cond
      ((video-player-error video--buffer-player)
       (propertize " Playback failed"
                   'face 'error 'help-echo
                   (video-player-error video--buffer-player)))
      ((eq (video-player-kind video--buffer-player) 'image)
       (format " %dx%d"
               (video-player-width video--buffer-player)
               (video-player-height video--buffer-player)))
      (t
       (concat
        (when (video--player-waiting-p video--buffer-player)
          (let ((percent (video-player-buffering video--buffer-player)))
            (if (and (numberp percent) (< percent 100))
                (format " Buffering %d%%" percent)
              " Buffering...")))
        (if (video-player-stream-live video--buffer-player)
            " LIVE"
          (format " %s / %s"
                  (video--format-time
                   (video-player-position video--buffer-player))
                  (video--format-time
                   (video-player-duration video--buffer-player)))))))
     ;; Redisplay selects the window whose mode line is being formatted.
     (when-let* (((eq (window-buffer (selected-window)) (current-buffer)))
                 (view (video--window-view))
                 (scale (video--view-scale view)))
       (format " %.6g%%" (* scale 100.0))))))

(defun video--window-view (&optional window)
  "Return the semantic media view owned by WINDOW."
  (setq window (or window (selected-window)))
  (when (window-live-p window)
    (let ((view (window-parameter window 'video-view)))
      (and (video--view-p view)
           (eq (video--view-buffer view) (window-buffer window))
           view))))

(defun video--set-window-view (window view)
  "Make WINDOW own semantic media VIEW."
  (setf (video--view-buffer view) (window-buffer window))
  (set-window-parameter window 'video-view view)
  view)

(defun video--copy-view (view buffer)
  "Return an independent copy of VIEW owned by BUFFER."
  (when view
    (let ((copy (copy-video--view view)))
      (setf (video--view-buffer copy) buffer)
      copy)))

(defun video--window-overlay (&optional window)
  "Return the dedicated media overlay owned by WINDOW."
  (window-parameter (or window (selected-window)) 'video-overlay))

(defun video--window-target (window)
  "Return WINDOW's native media target, or nil."
  (when-let* ((overlay (video--window-overlay window))
              ((overlayp overlay)))
    (overlay-get overlay 'video-target)))

(defun video--window-target-valid-p (window)
  "Return non-nil when WINDOW owns native state for its media buffer."
  (let* ((overlay (and (window-live-p window)
                       (video--window-overlay window)))
         (target (and (overlayp overlay)
                      (overlay-get overlay 'video-target))))
    (and (video-target-p target)
         (not (video-target-closed target))
         (eq (video-target-window target) window)
         (eq (video-target-overlay target) overlay)
         (eq (overlay-get overlay 'window) window)
         (eq (overlay-buffer overlay) (window-buffer window)))))

(defun video--close-window-overlay (overlay &optional clear-view)
  "Close native state associated with OVERLAY.
When CLEAR-VIEW is non-nil, discard the window's semantic viewport.
Retain the last displayed image only while replacing a media presentation."
  (when (overlayp overlay)
    (let ((window (overlay-get overlay 'window))
          (target (overlay-get overlay 'video-target)))
      (when (and (window-live-p window)
                 (eq (video--window-overlay window) overlay))
        (when (and (or (not clear-view)
                       (not (eq (overlay-buffer overlay) (window-buffer window))))
                   (with-current-buffer (window-buffer window)
                     (derived-mode-p 'video-mode)))
          (set-window-parameter window 'video-pending-image
                                (overlay-get overlay 'display)))
        (video--cancel-pan window)
        (set-window-parameter window 'video-overlay nil)
        (when clear-view
          (set-window-parameter window 'video-view nil)))
      (when (video-target-p target)
        (video-target-close target))
      (when (overlay-buffer overlay)
        (delete-overlay overlay)))))

(defun video--window-pixel-size (window)
  "Return positive body pixel dimensions for WINDOW."
  (cons (max 1 (window-body-width window t))
        (max 1 (window-body-height window t))))

(defun video--create-window-target (window)
  "Create and attach independent viewport state for WINDOW."
  (with-current-buffer (window-buffer window)
    (when (and (derived-mode-p 'video-mode)
               (video-player-live-p video--buffer-player))
      (let ((existing (video--window-overlay window)))
        (when (and existing (not (video--window-target-valid-p window)))
          (video--close-window-overlay existing t)))
      (if (video--window-target-valid-p window)
          (video--window-target window)
        (let* ((buffer (current-buffer))
               (source-window
                (cl-find-if
                 (lambda (candidate)
                   (and (not (eq candidate window))
                        (video--window-view candidate)))
                 (get-buffer-window-list buffer nil t)))
               (view (or (video--window-view window)
                         (video--copy-view
                          (and source-window (video--window-view source-window))
                          buffer)
                         (video--make-view :buffer buffer)))
               (size (video--window-pixel-size window))
               (target (video-target-create
                        video--buffer-player (car size) (cdr size)
                        :fit (video--default-fit video--buffer-player)
                        :scale (video--view-scale view)
                        :x (video--view-x view) :y (video--view-y view)))
               (overlay (make-overlay (point-min) (point-max) buffer nil nil)))
          (overlay-put overlay 'window window)
          ;; Keep the outgoing image visible until this target has a frame
          ;; rendered with its final viewport, not an empty Canvas.
          (overlay-put overlay 'display
                       (or (window-parameter window 'video-pending-image)
                           (video-target-canvas target)))
          (set-window-parameter window 'video-pending-image nil)
          (overlay-put overlay 'video-target target)
          (setf (video-target-window target) window
                (video-target-overlay target) overlay)
          (video--set-window-view window view)
          (set-window-parameter window 'video-overlay overlay)
          (set-window-start window (point-min) t)
          (set-window-point window (point-min))
          (set-window-hscroll window 0)
          (set-window-vscroll window 0 t)
          (video--initialize-target-view target)
          target)))))

(defun video--close-stale-window-targets (&optional _window)
  "Close dedicated targets no longer owned by their display windows."
  (dolist (player video--players)
    (dolist (target (copy-sequence (video-player-targets player)))
      (when-let* ((window (video-target-window target))
                  (overlay (video-target-overlay target)))
        (unless (and (window-live-p window)
                     (eq (window-buffer window) (overlay-buffer overlay))
                     (eq (video--window-overlay window) overlay))
          (video--close-window-overlay overlay t))))))

(defun video--resize-window-target (window)
  "Resize WINDOW's dedicated target to its complete text body."
  (when (video--window-target-valid-p window)
    (let* ((target (video--window-target window))
           (size (video--window-pixel-size window)))
      (unless (and (= (car size) (video-target-width target))
                   (= (cdr size) (video-target-height target)))
        (setf (video-target-width target) (car size)
              (video-target-height target) (cdr size))
        (video--sync-target target)
        (video--present-target target)))))

(defun video--manage-window-targets (&rest _ignored)
  "Create and remove per-window targets for the current media buffer."
  (when (derived-mode-p 'video-mode)
    (video--close-stale-window-targets)
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (unless (video--window-target-valid-p window)
        (video--create-window-target window))
      (video--resize-window-target window))
    (when (video-player-live-p video--buffer-player)
      (video--reconcile-player-visibility video--buffer-player))))

(defun video--resize-window-targets (&optional _frame)
  "Resize dedicated targets to their current window bodies."
  (when (derived-mode-p 'video-mode)
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (video--resize-window-target window))))

(defun video--current-target ()
  "Return the selected window's valid dedicated target."
  (unless (video--window-target-valid-p (selected-window))
    (video--manage-window-targets))
  (or (video--window-target (selected-window))
      (user-error "Current window has no media viewport")))

(defun video--sync-target (target)
  "Commit TARGET's absolute viewport and redraw its native renderer."
  (when-let* ((window (video-target-window target))
              (view (video--window-view window)))
    (setf (video--view-scale view) (video-target-scale target)
          (video--view-x view) (video-target-x target)
          (video--view-y view) (video-target-y target)))
  (video-target-set-view
   target (video-target-width target) (video-target-height target)
   (video-target-scale target) (video-target-x target) (video-target-y target)
   (video-target-fit target)))

(defun video--control-event-target (event)
  "Return the dedicated video target receiving mouse EVENT."
  (let ((window (or (video--event-window event) (selected-window))))
    (and (video--window-target-valid-p window)
         (video--window-target window))))

(defun video-control-toggle (event)
  "Toggle dedicated playback from transport control EVENT."
  (interactive "e")
  (when-let* ((target (video--control-event-target event)))
    (video-player-toggle (video-target-player target))))

(defun video-control-mute (event)
  "Toggle dedicated mute state from transport control EVENT."
  (interactive "e")
  (when-let* ((target (video--control-event-target event))
              (player (video-target-player target)))
    (video-player-set-muted player (not (video-player-muted player)))))

(defun video-control-seek (event)
  "Seek dedicated playback using progress-bar EVENT."
  (interactive "e")
  (when-let* ((target (video--control-event-target event)))
    (video--seek-target-from-event target event)))

(defun video-control-show (event)
  "Reveal dedicated transport controls after mouse EVENT."
  (interactive "e")
  (when-let* ((target (video--control-event-target event)))
    (video--show-player-controls (video-target-player target))))

(defun video-toggle ()
  "Toggle playback in the current dedicated video buffer."
  (interactive)
  (unless (video--player-transport-p video--buffer-player)
    (user-error "Current media is a still image"))
  (video-player-toggle video--buffer-player))

(defun video-seek-forward (&optional long)
  "Seek forward; use the long interval when LONG is non-nil."
  (interactive "P")
  (video-player-seek-relative video--buffer-player
                              (if long video-long-seek-step video-seek-step)))

(defun video-seek-backward (&optional long)
  "Seek backward; use the long interval when LONG is non-nil."
  (interactive "P")
  (video-player-seek-relative video--buffer-player
                              (- (if long video-long-seek-step video-seek-step))))

(defun video-seek-long-forward ()
  "Seek forward by `video-long-seek-step'."
  (interactive)
  (video-seek-forward t))

(defun video-seek-long-backward ()
  "Seek backward by `video-long-seek-step'."
  (interactive)
  (video-seek-backward t))

(defun video-volume-up ()
  "Increase current player volume."
  (interactive)
  (video-player-set-volume
   video--buffer-player
   (+ (video-player-volume video--buffer-player) video-volume-step)))

(defun video-volume-down ()
  "Decrease current player volume."
  (interactive)
  (video-player-set-volume
   video--buffer-player
   (- (video-player-volume video--buffer-player) video-volume-step)))

(defun video-pan-left ()
  "Pan the selected media viewport toward its left edge."
  (interactive)
  (video--apply-pan (video--current-target) video-pan-step 0.0))

(defun video-pan-right ()
  "Pan the selected media viewport toward its right edge."
  (interactive)
  (video--apply-pan (video--current-target) (- video-pan-step) 0.0))

(defun video-pan-up ()
  "Pan the selected media viewport toward its top edge."
  (interactive)
  (video--apply-pan (video--current-target) 0.0 video-pan-step))

(defun video-pan-down ()
  "Pan the selected media viewport toward its bottom edge."
  (interactive)
  (video--apply-pan (video--current-target) 0.0 (- video-pan-step)))

(defun video-left ()
  "Seek backward in video, or pan left in a still image."
  (interactive)
  (if (eq (video-player-kind video--buffer-player) 'image)
      (video-pan-left)
    (video-seek-backward)))

(defun video-right ()
  "Seek forward in video, or pan right in a still image."
  (interactive)
  (if (eq (video-player-kind video--buffer-player) 'image)
      (video-pan-right)
    (video-seek-forward)))

(defun video-up ()
  "Raise video volume, or pan up in a still image."
  (interactive)
  (if (eq (video-player-kind video--buffer-player) 'image)
      (video-pan-up)
    (video-volume-up)))

(defun video-down ()
  "Lower video volume, or pan down in a still image."
  (interactive)
  (if (eq (video-player-kind video--buffer-player) 'image)
      (video-pan-down)
    (video-volume-down)))

(defun video--wheel-event-modifiers (event)
  "Return modifiers distinguishing EVENT's wheel input stream."
  (let (modifiers)
    (dolist (modifier (event-modifiers event) (nreverse modifiers))
      (unless (memq modifier '(click double triple))
        (push modifier modifiers)))))

(defun video--wheel-raw-deltas (event)
  "Return raw floating-point (DX . DY) from wheel EVENT, or nil."
  (let ((raw (nth 4 event)))
    (when (and (consp raw)
               (or (numberp (car raw)) (numberp (cdr raw))))
      (cons (if (numberp (car raw)) (float (car raw)) 0.0)
            (if (numberp (cdr raw)) (float (cdr raw)) 0.0)))))

(defun video--wheel-coalescible-event-p (event window modifiers)
  "Return non-nil when EVENT belongs to WINDOW's MODIFIERS input stream."
  (and (consp event)
       (memq (event-basic-type event)
             '(wheel-up wheel-down wheel-left wheel-right))
       (eq (video--event-window event) window)
       (equal (video--wheel-event-modifiers event) modifiers)
       (video--wheel-raw-deltas event)))

(defun video--wheel-coalesced-deltas (event window)
  "Return raw EVENT deltas merged with pending input for WINDOW."
  (when-let* ((raw (video--wheel-raw-deltas event)))
    (let ((delta-x (car raw))
          (delta-y (cdr raw))
          (modifiers (video--wheel-event-modifiers event))
          (enabled
           (if (boundp 'pixel-scroll-precision-coalesce-scroll-events)
               pixel-scroll-precision-coalesce-scroll-events
             t))
          (maximum
           (if (boundp 'pixel-scroll-precision-coalesce-maximum)
               pixel-scroll-precision-coalesce-maximum
             32))
          (count 0)
          next-event)
      (while (and enabled
                  (< count maximum)
                  (setq next-event (read-event nil nil 0)))
        (if (video--wheel-coalescible-event-p
             next-event window modifiers)
            (let ((next (video--wheel-raw-deltas next-event)))
              (setq delta-x (+ delta-x (car next))
                    delta-y (+ delta-y (cdr next))
                    count (1+ count)))
          (push next-event unread-command-events)
          (setq count maximum)))
      (cons delta-x delta-y))))

(defun video--wheel-fallback (event window)
  "Pan WINDOW by one configured step for non-pixel wheel EVENT."
  (let ((amount (* video-pan-step (max 1 (event-click-count event))))
        (basic-type (event-basic-type event))
        (shift (memq 'shift (event-modifiers event))))
    (pcase basic-type
      ('wheel-up
       (if shift
           (video--queue-pan window amount 0.0)
         (video--queue-pan window 0.0 amount)))
      ('wheel-down
       (if shift
           (video--queue-pan window (- amount) 0.0)
         (video--queue-pan window 0.0 (- amount))))
      ('wheel-left (video--queue-pan window (- amount) 0.0))
      ('wheel-right (video--queue-pan window amount 0.0)))))

(defun video-wheel-pan (event)
  "Pan the independent media viewport receiving wheel EVENT."
  (interactive "e")
  (when-let* ((window (video--event-window event))
              ((video--window-target-valid-p window)))
    (if-let* ((raw (video--wheel-coalesced-deltas event window)))
        (let ((basic-type (event-basic-type event)))
          (if (and (memq 'shift (event-modifiers event))
                   (memq basic-type '(wheel-up wheel-down)))
              (video--queue-pan window (cdr raw) 0.0)
            (video--queue-pan window (car raw) (cdr raw))))
      (video--wheel-fallback event window))))

(defun video--wheel-zoom-factor (event)
  "Return an accelerated zoom multiplier for wheel EVENT."
  (+ video-zoom-factor
     (* 0.1 (1- (min 3 (max 1 (event-click-count event)))))))

(defun video-wheel-zoom-in (event)
  "Enlarge media around the pointer in the viewport receiving EVENT."
  (interactive "e")
  (when-let* ((target (video--control-event-target event)))
    (video--zoom-target target (video--wheel-zoom-factor event)
                        (video--event-canvas-position event))))

(defun video-wheel-zoom-out (event)
  "Shrink media around the pointer in the viewport receiving EVENT."
  (interactive "e")
  (when-let* ((target (video--control-event-target event)))
    (video--zoom-target target (/ (video--wheel-zoom-factor event))
                        (video--event-canvas-position event))))

(defun video-next ()
  "Open the application's next media item, or the next local image."
  (interactive)
  (if (functionp video-next-function)
      (funcall video-next-function)
    (video--image-neighbor 1)))

(defun video-previous ()
  "Open the application's previous media item, or the previous local image."
  (interactive)
  (if (functionp video-previous-function)
      (funcall video-previous-function)
    (video--image-neighbor -1)))

(defun video-quit ()
  "Quit through the embedding application or `video-bury-buffer-function'."
  (interactive)
  (if (functionp video-quit-function)
      (funcall video-quit-function)
    (funcall video-bury-buffer-function)))

(defun video-toggle-muted ()
  "Toggle mute for the current player."
  (interactive)
  (video-player-set-muted
   video--buffer-player
   (not (video-player-muted video--buffer-player))))

(defun video--fit-scale (target fit)
  "Return one absolute SCALE fitting TARGET according to FIT."
  (let* ((player (video-target-player target))
         (source-width (video-player-width player))
         (source-height (video-player-height player)))
    (when (and (> source-width 0) (> source-height 0))
      (let ((scale-x (/ (float (video-target-width target)) source-width))
            (scale-y (/ (float (video-target-height target)) source-height)))
        (pcase fit
          ('cover (max scale-x scale-y))
          ('width scale-x)
          ('height scale-y)
          ('actual 1.0)
          ('shrink (min 1.0 scale-x scale-y))
          (_ (min scale-x scale-y)))))))

(defun video--default-fit (player)
  "Return the dedicated viewport default fit policy for PLAYER."
  (if (eq (video-player-kind player) 'image)
      video-image-default-fit
    video-default-fit))

(defun video--fit-target (target fit)
  "Set TARGET to one absolute FIT scale and center its virtual viewport."
  (when-let* ((scale (video--fit-scale target fit)))
    (let* ((player (video-target-player target))
           (virtual-width (* (video-player-width player) scale))
           (virtual-height (* (video-player-height player) scale)))
      (setf (video-target-fit target) fit
            (video-target-scale target) scale
            (video-target-x target)
            (/ (- virtual-width (video-target-width target)) 2.0)
            (video-target-y target)
            (/ (- virtual-height (video-target-height target)) 2.0))
      (video--sync-target target)
      (force-mode-line-update t)
      t)))

(defun video--initialize-target-view (target)
  "Resolve TARGET's initial absolute scale once source geometry is known."
  (when (and (video-target-window target)
             (null (video-target-scale target)))
    (video--fit-target target
                       (video--default-fit (video-target-player target)))))

(defun video--initialize-player-window-views (player)
  "Resolve pending absolute viewport scales for PLAYER's dedicated windows."
  (when (and (> (video-player-width player) 0)
             (> (video-player-height player) 0))
    (dolist (target (video-player-targets player))
      (video--initialize-target-view target))))

(defun video--viewport-anchor (viewport-length scale origin &optional coordinate)
  "Map COORDINATE in a viewport axis to its source coordinate.
VIEWPORT-LENGTH, SCALE and ORIGIN describe the current virtual media axis.
When COORDINATE is nil, use the viewport center.  Origins remain meaningful
when the media is smaller than the viewport, including after panning."
  (/ (+ origin (or coordinate (/ viewport-length 2.0))) scale))

(defun video--scale-target (target scale &optional position)
  "Set TARGET to absolute SCALE around Canvas-local POSITION.
When POSITION is nil, preserve the source pixel at the viewport center."
  (unless (and (numberp scale) (<= 0.0001 scale 65536.0))
    (user-error "Scale must be between 0.01 and 6553600 percent"))
  (video--initialize-target-view target)
  (unless (video-target-scale target)
    (user-error "Media dimensions are not available yet"))
  (when-let* ((window (video-target-window target)))
    (video--cancel-pan window))
  (let* ((old-scale (video-target-scale target))
         (pixel-x (if position
                      (- (car position) (video-target-destination-x target))
                    (/ (video-target-width target) 2.0)))
         (pixel-y (if position
                      (- (cdr position) (video-target-destination-y target))
                    (/ (video-target-height target) 2.0)))
         (anchor-x (video--viewport-anchor
                    (video-target-width target) old-scale
                    (video-target-x target) pixel-x))
         (anchor-y (video--viewport-anchor
                    (video-target-height target) old-scale
                    (video-target-y target) pixel-y)))
    (setf (video-target-scale target) (float scale)
          (video-target-x target) (- (* anchor-x scale) pixel-x)
          (video-target-y target) (- (* anchor-y scale) pixel-y))
    (video--sync-target target)
    (force-mode-line-update t)))

(defun video--zoom-target (target factor &optional position)
  "Multiply TARGET's scale by FACTOR around Canvas-local POSITION.
When POSITION is nil, zoom around the viewport center."
  (video--initialize-target-view target)
  (when-let* ((old-scale (video-target-scale target)))
    (video--scale-target target
                        (max 0.0001
                             (min 65536.0 (* old-scale (float factor))))
                        position)))

(defun video-zoom-in ()
  "Enlarge media in the selected window without enlarging its Canvas."
  (interactive)
  (video--zoom-target (video--current-target) video-zoom-factor))

(defun video-zoom-out ()
  "Shrink media in the selected window without resizing its Canvas."
  (interactive)
  (video--zoom-target (video--current-target) (/ video-zoom-factor)))

(defun video-original-size ()
  "Display media at 100 percent, centered in the selected viewport."
  (interactive)
  (unless (video--fit-target (video--current-target) 'actual)
    (user-error "Media dimensions are not available yet")))

(defun video-set-scale (percent)
  "Display media at PERCENT of its original size in the selected viewport.
Preserve the source pixel at the viewport center."
  (interactive (list (read-number "Scale (percent): " 100)))
  (unless (and (numberp percent) (<= 0.01 percent 6553600.0))
    (user-error "Scale must be between 0.01 and 6553600 percent"))
  (video--scale-target (video--current-target) (/ (float percent) 100.0)))

(defun video-scale-adjust (steps)
  "Adjust media scale by STEPS from an Emacs text-scale command."
  (interactive "p")
  (let* ((steps
          (pcase this-original-command
            ('text-scale-decrease (- steps))
            ('text-scale-adjust
             (pcase (event-basic-type last-command-event)
               ((or ?+ ?=) steps)
               (?- (- steps))
               (?0 0)
               (_ steps)))
            (_ steps)))
         (target (video--current-target)))
    (cond
     ((zerop steps)
      (video--fit-target target
                         (video--default-fit (video-target-player target))))
     ((> steps 0)
      (video--zoom-target target (expt video-zoom-factor steps)))
     (t
      (video--zoom-target target
                          (expt (/ video-zoom-factor) (- steps)))))))

(defun video-reset-view ()
  "Fit and center media in the selected viewport using its default fit policy.
Images use `video-image-default-fit'; videos use `video-default-fit'."
  (interactive)
  (let ((target (video--current-target)))
    (unless (video--fit-target target
                              (video--default-fit (video-target-player target)))
      (user-error "Media dimensions are not available yet"))))

(defun video-fit-width ()
  "Set one absolute scale fitting media to the selected viewport width."
  (interactive)
  (unless (video--fit-target (video--current-target) 'width)
    (user-error "Media dimensions are not available yet")))

(defun video-fit-height ()
  "Set one absolute scale fitting media to the selected viewport height."
  (interactive)
  (unless (video--fit-target (video--current-target) 'height)
    (user-error "Media dimensions are not available yet")))

(defun video--apply-pan (target delta-x delta-y)
  "Move TARGET content by pointer DELTA-X and DELTA-Y display pixels."
  (video--initialize-target-view target)
  (when (and (video-target-scale target)
             (or (not (zerop delta-x)) (not (zerop delta-y))))
    (setf (video-target-x target) (- (video-target-x target) delta-x)
          (video-target-y target) (- (video-target-y target) delta-y))
    (video--sync-target target)))

(defun video--clear-pan-queue (window)
  "Clear queued middle-button movement for WINDOW."
  (dolist (parameter '(video-pan-timer video-pan-token video-pan-delta
                       video-pan-overlay video-pan-buffer))
    (set-window-parameter window parameter nil)))

(defun video--cancel-pan (&optional window)
  "Cancel pending middle-button movement for WINDOW."
  (setq window (or window (selected-window)))
  (when-let* ((timer (and (windowp window)
                          (window-parameter window 'video-pan-timer)))
              ((timerp timer)))
    (cancel-timer timer))
  (when (windowp window)
    (video--clear-pan-queue window)))

(defun video--flush-pan (window token)
  "Commit WINDOW's queued pan movement for TOKEN."
  (when (and (window-live-p window)
             (eq token (window-parameter window 'video-pan-token)))
    (let* ((delta (window-parameter window 'video-pan-delta))
           (overlay (window-parameter window 'video-pan-overlay))
           (target (and (overlayp overlay)
                        (overlay-get overlay 'video-target)))
           (buffer (window-parameter window 'video-pan-buffer)))
      (video--clear-pan-queue window)
      (when (and (consp delta)
                 (video-target-p target)
                 (not (video-target-closed target))
                 (eq buffer (window-buffer window))
                 (eq overlay (video--window-overlay window)))
        (video--apply-pan target (car delta) (cdr delta))))))

(defun video--queue-pan (window delta-x delta-y)
  "Queue pointer DELTA-X and DELTA-Y for WINDOW."
  (if (<= video-pan-frame-interval 0)
      (when (video--window-target-valid-p window)
        (video--apply-pan (video--window-target window) delta-x delta-y))
    (when (video--window-target-valid-p window)
      (let* ((pending (window-parameter window 'video-pan-delta))
             (combined (cons (+ (if (consp pending) (car pending) 0.0) delta-x)
                             (+ (if (consp pending) (cdr pending) 0.0) delta-y)))
             (timer (window-parameter window 'video-pan-timer)))
        (set-window-parameter window 'video-pan-delta combined)
        (unless (timerp timer)
          (let* ((overlay (video--window-overlay window))
                 (token (list overlay)))
            (set-window-parameter window 'video-pan-token token)
            (set-window-parameter window 'video-pan-overlay overlay)
            (set-window-parameter window 'video-pan-buffer (window-buffer window))
            (set-window-parameter
             window 'video-pan-timer
             (run-at-time video-pan-frame-interval nil
                          #'video--flush-pan window token))))))))

(defun video--event-window (event &optional end)
  "Return the live window named by mouse EVENT.

Use EVENT's end position when END is non-nil."
  (let ((window (posn-window (if end (event-end event) (event-start event)))))
    (when (framep window)
      (setq window (frame-selected-window window)))
    (and (window-live-p window) window)))

(defun video--event-canvas-position (event &optional start)
  "Return EVENT's Canvas-local position, using its start when START is non-nil."
  (when-let* ((position (if start (event-start event) (event-end event)))
              (coordinates (or (posn-object-x-y position) (posn-x-y position)))
              ((numberp (car coordinates)))
              ((numberp (cdr coordinates))))
    (cons (float (car coordinates)) (float (cdr coordinates)))))

(defun video--redisplay-pending-player-frame (player)
  "Present any native frame already available for PLAYER without waiting."
  (let* ((process (video-player-process player))
         (notified
          (and (process-live-p process)
               (accept-process-output process 0)))
         (timer (video-player-dispatch-timer player))
         (dispatched nil))
    (when (timerp timer)
      (cancel-timer timer)
      (setf (video-player-dispatch-timer player) nil)
      (video--dispatch player)
      (setq dispatched t))
    (when (or notified dispatched)
      (redisplay t))))

(defun video-mouse-pan (event)
  "Pan a dedicated video viewport by dragging mouse button 2 with EVENT.

A click without movement is replayed as an ordinary `mouse-2' event."
  (interactive "e")
  (let* ((window (video--event-window event))
         (buffer (and window (window-buffer window)))
         (start (video--event-canvas-position event t))
         (last start)
         (moved nil)
         (released nil))
    (if (not (and window start (video--window-target-valid-p window)))
        (push (cons (event-basic-type event) (cdr event)) unread-command-events)
      (select-window window)
      (video--cancel-pan window)
      (track-mouse
        (setq track-mouse 'video-panning)
        (catch 'video-pan-done
          (while t
            (let ((next-event (read--potential-mouse-event)))
              (cond
               ((mouse-movement-p next-event)
                (when (and (eq (video--event-window next-event t) window)
                           (eq (window-buffer window) buffer))
                  (when-let* ((current (video--event-canvas-position next-event)))
                    (let ((delta-x (- (car current) (car last)))
                          (delta-y (- (cdr current) (cdr last))))
                      (unless (and (zerop delta-x) (zerop delta-y))
                        (setq moved t)
                        (video--queue-pan window delta-x delta-y))
                      (setq last current)))))
               ((eq (event-basic-type next-event) 'mouse-2)
                (setq released t)
                (throw 'video-pan-done nil))
               (t
                (push next-event unread-command-events)
                (throw 'video-pan-done nil)))))))
      (when (and released (not moved))
        (push (cons (event-basic-type event) (cdr event))
              unread-command-events)))))

(defun video-mouse-seek (event)
  "Seek a dedicated video by dragging mouse button 1 with EVENT.

Dragging right seeks forward and dragging left seeks backward relative to the
position at button-down.  The native buffering map limits live preroll
previews to locally available positions; an unavailable position is sought
when the gesture ends.  A click without horizontal motion toggles playback."
  (interactive "e")
  (let* ((window (video--event-window event))
         (buffer (and window (window-buffer window)))
         (start (video--event-canvas-position event t))
         (target (and window
                      (video--window-target-valid-p window)
                      (video--window-target window)))
         (player (and target (video-target-player target))))
    (when (and start
               (video--player-transport-p player)
               (video-player-live-p player)
               (video-player-seekable player))
      (let* ((initial-position (float (or (video-player-position player) 0.0)))
             (local-source-p
              (string-prefix-p "file://" (or (video-player-source player) "")))
             (buffered-ranges
              (unless local-source-p
                (video-player-buffered-ranges player)))
             (resume-after-seek
              (and (eq (video-player-desired-state player) 'playing)
                   (not (video-player-suspended player))))
             (moved nil)
             (released nil)
             (pending-position nil)
             (last-request-position nil))
        (select-window window)
        (when resume-after-seek
          (video-native-pause (video-player-handle player)))
        (unwind-protect
            (cl-labels
                ((target-current-p
                   ()
                   (and (eq (window-buffer window) buffer)
                        (video--window-target-valid-p window)
                        (eq (video--window-target window) target)
                        (video-player-live-p player)))
                 (position-previewable-p
                   (position)
                   (or local-source-p
                       (cl-some
                        (lambda (range)
                          (and (consp range)
                               (numberp (car range))
                               (numberp (cdr range))
                               (<= (car range) position (cdr range))))
                        buffered-ranges)))
                 (record-position
                   (next-event)
                   (when (target-current-p)
                     (when-let* ((current
                                  (video--event-canvas-position next-event)))
                       (let ((delta-x (- (car current) (car start))))
                         (when (or moved (not (zerop delta-x)))
                           (setq moved t
                                 pending-position
                                 (+ initial-position
                                    (* delta-x
                                       video-mouse-seek-seconds-per-pixel)))
                           (when (and
                                  (position-previewable-p pending-position)
                                  (not (equal pending-position
                                              last-request-position)))
                             (video-player-seek player pending-position)
                             (setq last-request-position
                                   pending-position))))))))
              (track-mouse
                (setq track-mouse 'video-seeking)
                (catch 'video-seek-done
                  (while t
                    (let ((next-event (read--potential-mouse-event)))
                      (video--redisplay-pending-player-frame player)
                      (cond
                       ((mouse-movement-p next-event)
                        (when (eq (video--event-window next-event t) window)
                          (record-position next-event)))
                       ((eq (event-basic-type next-event) 'mouse-1)
                        (setq released
                              (and (eq (video--event-window next-event t) window)
                                   (target-current-p)))
                        (when released
                          (record-position next-event))
                        (throw 'video-seek-done nil))
                       (t
                        (push next-event unread-command-events)
                        (throw 'video-seek-done nil)))))))
              (when (and moved
                         pending-position
                         (target-current-p)
                         (not (equal pending-position last-request-position)))
                (video-player-seek player pending-position))
              (when (and released (not moved) (target-current-p))
                (video-player-toggle player)))
          (when (and resume-after-seek
                     (video-player-live-p player)
                     (eq (video-player-desired-state player) 'playing)
                     (not (video-player-suspended player)))
            (video-native-play (video-player-handle player))))))))

(defun video--close-buffer-player (&optional clear-view)
  "Detach the current buffer's player and release its presentation lease.

When CLEAR-VIEW is non-nil, also discard every window's semantic viewport.
A low-level player owned directly by the buffer is closed after detachment."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (when-let* ((overlay (video--window-overlay window)))
      (video--close-window-overlay overlay clear-view))
    (when clear-view
      (set-window-parameter window 'video-view nil)))
  (let ((player video--buffer-player)
        (owns-player video--buffer-owns-player)
        (lease video--buffer-session-lease))
    (setq video--buffer-player nil
          video--buffer-owns-player nil
          video--buffer-session nil
          video--buffer-session-lease nil)
    (if lease
        (video--session-release lease)
      (when (and owns-player (video-player-p player))
        (video-player-close player)))))

(defun video--kill-buffer ()
  "Release all window and player state owned by the current buffer."
  (video--close-buffer-player t))

(defvar-keymap video-mode-map
  :doc "Keymap for `video-mode'."
  "<left>" #'video-left
  "<right>" #'video-right
  "<up>" #'video-up
  "<down>" #'video-down
  "S-<left>" #'video-seek-long-backward
  "S-<right>" #'video-seek-long-forward
  "C-b" #'video-pan-left
  "C-f" #'video-pan-right
  "C-p" #'video-pan-up
  "C-n" #'video-pan-down
  "<remap> <backward-char>" #'video-pan-left
  "<remap> <forward-char>" #'video-pan-right
  "<remap> <previous-line>" #'video-pan-up
  "<remap> <next-line>" #'video-pan-down
  "<wheel-up>" #'video-wheel-pan
  "<wheel-down>" #'video-wheel-pan
  "<wheel-left>" #'video-wheel-pan
  "<wheel-right>" #'video-wheel-pan
  "S-<wheel-up>" #'video-wheel-pan
  "S-<wheel-down>" #'video-wheel-pan
  "S-<wheel-left>" #'video-wheel-pan
  "S-<wheel-right>" #'video-wheel-pan
  "C-<wheel-up>" #'video-wheel-zoom-in
  "C-<wheel-down>" #'video-wheel-zoom-out
  "<remap> <text-scale-increase>" #'video-scale-adjust
  "<remap> <text-scale-decrease>" #'video-scale-adjust
  "<remap> <text-scale-adjust>" #'video-scale-adjust
  "m" #'video-toggle-muted
  "RET" #'video-toggle
  "+" #'video-zoom-in
  "=" #'video-zoom-in
  "-" #'video-zoom-out
  "0" #'video-reset-view
  "C-+" #'video-zoom-in
  "C-=" #'video-zoom-in
  "C--" #'video-zoom-out
  "C-0" #'video-reset-view
  "W" #'video-fit-width
  "H" #'video-fit-height
  "n" #'video-next
  "p" #'video-previous
  "<down-mouse-2>" #'video-mouse-pan
  "<down-mouse-1>" #'video-mouse-seek
  "q" #'video-quit
  "Q" #'kill-current-buffer)

(defvar-keymap video--mode-parent-map
  :doc "Empty parent map preventing `special-mode-map' scrolling bindings.")

(set-keymap-parent video-mode-map video--mode-parent-map)

(dolist (id video--control-map-ids)
  (define-key video-mode-map (vector id 'down-mouse-1) #'ignore))
(define-key video-mode-map
            [video-control-toggle mouse-1] #'video-control-toggle)
(define-key video-mode-map
            [video-control-mute mouse-1] #'video-control-mute)
(define-key video-mode-map
            [video-control-seek mouse-1] #'video-control-seek)
(define-key video-mode-map [mouse-movement] #'video-control-show)

;;;###autoload
(define-derived-mode video-mode special-mode "Media"
  "Major mode for reader-style Canvas image and video viewing."
  :group 'video
  (setq-local buffer-read-only t
              cursor-type nil
              truncate-lines t
              left-fringe-width 0
              right-fringe-width 0
              mode-line-position '((:eval (video--mode-line-position))))
  (when (boundp 'pixel-scroll-precision-mode)
    (setq-local pixel-scroll-precision-mode nil))
  (add-hook 'kill-buffer-hook #'video--kill-buffer nil t)
  (add-hook 'change-major-mode-hook #'video--kill-buffer nil t)
  (add-hook 'window-configuration-change-hook
            #'video--manage-window-targets nil t)
  (add-hook 'window-size-change-functions
            #'video--resize-window-targets nil t)
  (add-hook 'window-buffer-change-functions
            #'video--close-stale-window-targets nil t))

(defconst video--image-extension-regexp
  "\\.\\(?:avif\\|bmp\\|gif\\|heic\\|heif\\|jpe?g\\|png\\|svgz?\\|tiff?\\|webp\\)\\(?:[?#].*\\)?\\'"
  "File-name suffixes recognized as still image sources.")

(defun video--source-kind (source)
  "Return `image' or `video' for SOURCE."
  (if (or (and (file-readable-p source)
               (condition-case nil
                   (image-type-from-file-header source)
                 (file-error nil)))
          (string-match-p video--image-extension-regexp (downcase source)))
      'image
    'video))

(defun video--prepare-presentation-buffer (media buffer)
  "Prepare BUFFER to borrow a player or retain a session MEDIA."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'buffer-file-name buffer))
    (user-error "Cannot replace a file buffer with a media presentation"))
  (let* ((session (and (video-session-p media) media))
         (player (if session (video-session-player session) media)))
    (unless (if session (video-session-live-p session)
              (video-player-live-p player))
      (error "Cannot present a closed video %s" (if session "session" "player")))
    (unless (buffer-live-p buffer)
      (setq buffer
            (generate-new-buffer
             (format "*Media: %s*" (video-player-source player)))))
    (with-current-buffer buffer
      (unless (and (derived-mode-p 'video-mode)
                   (eq video--buffer-player player)
                   (eq video--buffer-session session)
                   (if session
                       (and (video--session-lease-p video--buffer-session-lease)
                            (not (video--session-lease-closed
                                  video--buffer-session-lease)))
                     (not video--buffer-owns-player)))
        (video--close-buffer-player)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "\n"))
        (video-mode)
        (setq video--buffer-player player
              video--buffer-owns-player nil
              video--buffer-session session
              video--buffer-session-lease
              (when session
                (video--session-acquire
                 session buffer
                 (lambda (owner)
                   (when (buffer-live-p owner)
                     (kill-buffer owner))))))
        (set-buffer-modified-p nil)))
    buffer))

(defun video--activate-presented-buffer (buffer)
  "Create visible targets for BUFFER without changing playback state."
  (with-current-buffer buffer
    (video--manage-window-targets)
    (video--reconcile-player-visibility video--buffer-player))
  buffer)

(defun video--presentation-frame-parameters ()
  "Return frame parameters for a dedicated media presentation."
  (cons '(video-presentation-frame . t)
        (assq-delete-all
         'video-presentation-frame
         (copy-tree video-other-frame-parameters))))

(defun video--presentation-window (buffer)
  "Return BUFFER's live presentation-frame window, or nil."
  (cl-find-if
   (lambda (window)
     (frame-parameter (window-frame window) 'video-presentation-frame))
   (get-buffer-window-list buffer nil t)))

(defun video--configure-presentation-window (window)
  "Remove text-window chrome from presentation WINDOW."
  (dolist (parameter '(mode-line-format header-line-format tab-line-format))
    (set-window-parameter window parameter 'none))
  (set-window-fringes window 0 0 nil t)
  (set-window-margins window 0 0)
  (set-window-scroll-bars window nil nil nil nil t)
  (set-window-dedicated-p window t)
  (set-window-hscroll window 0)
  (set-window-vscroll window 0 t)
  window)

(defun video-display-buffer-same-window (buffer)
  "Display media BUFFER in the selected window and return that window."
  (display-buffer buffer '(display-buffer-same-window)))

(defun video-display-buffer-other-window (buffer)
  "Display media BUFFER in another window and return that window."
  (display-buffer
   buffer
   '((display-buffer-reuse-window display-buffer-pop-up-window)
     (inhibit-same-window . t))))

(defun video-display-buffer-other-frame (buffer)
  "Display media BUFFER in a reusable presentation frame.

The frame uses `video-other-frame-parameters'."
  (let ((window
         (or (video--presentation-window buffer)
             (display-buffer
              buffer
              `(display-buffer-pop-up-frame
                (pop-up-frame-parameters
                 . ,(video--presentation-frame-parameters)))))))
    (unless (window-live-p window)
      (error "Unable to display media in another frame"))
    (video--configure-presentation-window window)))

(defun video-display-buffer (buffer &optional display-function)
  "Display media BUFFER and return its live window.

Use DISPLAY-FUNCTION when non-nil, otherwise use
`video-display-buffer-function'.  Run `video-pre-display-buffer-hook' before
display and `video-post-display-buffer-hook' afterward.  Unless
`video-display-buffer-noselect' is non-nil, select the returned window and give
its frame input focus."
  (with-current-buffer buffer
    (run-hooks 'video-pre-display-buffer-hook))
  (let ((window
         (funcall (or display-function video-display-buffer-function) buffer)))
    (unless (window-live-p window)
      (error "Video display function did not return a live window"))
    (unless video-display-buffer-noselect
      (let ((old-frame (selected-frame))
            (new-frame (window-frame window)))
        (select-window window)
        (unless (eq old-frame new-frame)
          (select-frame-set-input-focus new-frame))))
    (with-current-buffer buffer
      (run-hooks 'video-post-display-buffer-hook))
    window))

(cl-defun video-session-present (session &key buffer display-function)
  "Present SESSION in a dedicated media buffer without changing player state.

Reuse BUFFER when it is live.  DISPLAY-FUNCTION has the same meaning as in
`video-open'.  The buffer retains SESSION until it changes mode or is killed."
  (cl-check-type session video-session)
  (let ((generated-p (not (buffer-live-p buffer))))
    (setq buffer (video--prepare-presentation-buffer session buffer))
    (condition-case error-data
        (progn
          (video-display-buffer buffer display-function)
          (video--activate-presented-buffer buffer))
      ((error quit)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (eq video--buffer-session session)
             (video--close-buffer-player t)))
         (when generated-p
           (kill-buffer buffer)))
       (signal (car error-data) (cdr error-data))))))

(cl-defun video-open (source &key kind buffer display-function live
                              cache-file cache-complete-function request-headers)
  "Open SOURCE using the configured display policy and return its media buffer.
KIND may be `image' or `video' and is inferred when omitted.  A local
image without BUFFER visits its file in `video-image-mode'.  Otherwise
reuse BUFFER when live, or create a dedicated presentation buffer.
BUFFER must not visit a file: presentation buffers contain display data,
not the source bytes.  DISPLAY-FUNCTION overrides the display policy.
LIVE, CACHE-FILE, CACHE-COMPLETE-FUNCTION, and REQUEST-HEADERS have the
same meanings as in `video-session-create'."
  (interactive (list (read-file-name "Media file: ")))
  (setq kind (or kind (video--source-kind source)))
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'buffer-file-name buffer))
    (user-error "Cannot replace a file buffer with a media presentation"))
  (let ((file (and (eq kind 'image) (not (buffer-live-p buffer))
                   (video--local-source-file source))))
    (if (and file (file-readable-p file)
             (not live) (not cache-file) (not cache-complete-function)
             (not request-headers))
        (let* ((auto-mode-alist
                (cons '(".*" . video-image-mode) auto-mode-alist))
               (viewer (find-file-noselect file)))
          (with-current-buffer viewer
            (unless (derived-mode-p 'video-image-mode)
              (when (buffer-modified-p)
                (user-error "Save or revert image changes before opening the Canvas viewer"))
              (video-image-mode)))
          (video-display-buffer viewer display-function)
          (video--activate-presented-buffer viewer))
      (let ((session (video-session-create
                      source :kind kind :muted (eq kind 'image) :live live
                      :cache-file cache-file
                      :cache-complete-function cache-complete-function
                      :request-headers request-headers))
            opened-p)
        (unwind-protect
            (prog1 (video-session-present session :buffer buffer
                                          :display-function display-function)
              (video-player-play (video-session-player session))
              (setq opened-p t))
          (unless opened-p
            (video-session-close session)))))))

(cl-defun video-present-player (player &key buffer display-function)
  "Present existing PLAYER without creating or taking ownership of it.

Reuse BUFFER when it is live and otherwise create a dedicated `video-mode'
buffer.  DISPLAY-FUNCTION has the same meaning as in `video-open'.  Playback
position, desired state, buffering, audio state, and network cache remain
owned by PLAYER."
  (cl-check-type player video-player)
  (setq buffer (video--prepare-presentation-buffer player buffer))
  (video-display-buffer buffer display-function)
  (video--activate-presented-buffer buffer))

;;;###autoload
(cl-defun video-open-other-window
    (source &key kind buffer live cache-file cache-complete-function
            request-headers)
  "Open SOURCE in another window and return its media buffer.

KIND, BUFFER, LIVE, CACHE-FILE, CACHE-COMPLETE-FUNCTION, and REQUEST-HEADERS
have the same meanings as in `video-open'."
  (interactive (list (read-file-name "Media file: ")))
  (video-open source
              :kind kind
              :buffer buffer
              :live live
              :cache-file cache-file
              :cache-complete-function cache-complete-function
              :request-headers request-headers
              :display-function #'video-display-buffer-other-window))

;;;###autoload
(cl-defun video-open-other-frame
    (source &key kind buffer live cache-file cache-complete-function
            request-headers)
  "Open SOURCE in a chrome-free presentation frame.

KIND, BUFFER, LIVE, CACHE-FILE, CACHE-COMPLETE-FUNCTION, and REQUEST-HEADERS
have the same meanings as in `video-open'."
  (interactive (list (read-file-name "Media file: ")))
  (video-open source
              :kind kind
              :buffer buffer
              :live live
              :cache-file cache-file
              :cache-complete-function cache-complete-function
              :request-headers request-headers
              :display-function #'video-display-buffer-other-frame))

(defun video-inline-live-p (inline)
  "Return non-nil while INLINE still belongs to its host."
  (if-let* ((predicate (video-inline-alive-function inline)))
      (funcall predicate inline)
    (and (overlayp (video-inline-overlay inline))
         (overlay-buffer (video-inline-overlay inline)))))

(defun video-inline-visible-p (inline)
  "Return non-nil when INLINE's display position is visible."
  (if-let* ((predicate (video-inline-visible-function inline)))
      (funcall predicate inline)
    (when-let* ((overlay (video-inline-overlay inline))
                ((overlayp overlay))
                (buffer (overlay-buffer overlay))
                (position (overlay-start overlay)))
      (cl-some (lambda (window)
                 (pos-visible-in-window-p position window t))
               (get-buffer-window-list buffer nil t)))))

(defun video--inline-after-change (&rest _ignored)
  "Close inline players whose host occurrence was deleted."
  (dolist (inline (copy-sequence video--inline-objects))
    (unless (video-inline-live-p inline)
      (video-inline-close inline))))

(defun video--host-visibility-change (&rest _ignored)
  "Reconcile players hosted by the current buffer after a visibility change."
  (when (video-player-p video--buffer-player)
    (video--reconcile-player-visibility video--buffer-player))
  (dolist (inline video--inline-objects)
    (when-let* ((player (video-inline-player inline)))
      (video--reconcile-player-visibility player))))

(defun video--install-host-hooks ()
  "Install buffer-local lifecycle hooks for inline video hosts."
  (unless video--host-hooks-installed
    (setq video--host-hooks-installed t)
    (add-hook 'after-change-functions #'video--inline-after-change nil t)
    (add-hook 'window-scroll-functions #'video--host-visibility-change nil t)
    (add-hook 'window-configuration-change-hook
              #'video--host-visibility-change nil t)
    (add-hook 'kill-buffer-hook #'video--close-inline-objects nil t)))

(defun video--close-inline-objects ()
  "Close every inline video occurrence in the current buffer."
  (dolist (inline (copy-sequence video--inline-objects))
    (video-inline-close inline)))

(defun video--inline-at-event (&optional event)
  "Return the inline occurrence at EVENT or point."
  (let* ((position
          (if event
              (let ((point (posn-point (event-end event))))
                (if (consp point) (car point) point))
            (point)))
         (overlays (and (integer-or-marker-p position)
                        (overlays-at position))))
    (cl-loop for overlay in overlays
             for inline = (overlay-get overlay 'video-inline)
             when (video-inline-p inline) return inline)))

(defun video-inline-toggle (&optional event)
  "Toggle the inline video occurrence at EVENT or point."
  (interactive (list last-input-event))
  (when-let* ((inline (video--inline-at-event event)))
    (video-inline-toggle-occurrence inline)))

(defun video--event-canvas-x (event)
  "Return EVENT x coordinate within its display object."
  (when-let* ((position (event-end event))
              (coordinates (posn-x-y position)))
    (float (car coordinates))))

(defun video--seek-target-from-event (target event)
  "Seek TARGET's player using the progress position in mouse EVENT."
  (when-let* ((player (video-target-player target))
              ((video-player-seekable player))
              (duration (video-player-duration player))
              ((> duration 0))
              (event-x (video--event-canvas-x event)))
    (let* ((seek-rectangle
            (aref (video--target-control-layout target) 2))
           (progress-x (aref seek-rectangle 0))
           (progress-width (max 1 (aref seek-rectangle 2)))
           (ratio (/ (- event-x progress-x)
                     (float progress-width))))
      (video-player-seek
       player (* duration (max 0.0 (min 1.0 ratio)))))))

(defun video-inline-show-controls (inline)
  "Show INLINE transport controls until their next fade."
  (when-let* ((player (video-inline-player inline)))
    (video--show-player-controls player)))

(defun video-inline-bind-controls (inline map)
  "Install Canvas transport commands for INLINE in keymap MAP."
  (define-key
   map [video-control-toggle mouse-1]
   (lambda ()
     (interactive)
     (video-inline-toggle-occurrence inline)))
  (define-key
   map [video-control-mute mouse-1]
   (lambda ()
     (interactive)
     (video-inline-toggle-muted inline)))
  (define-key
   map [video-control-seek mouse-1]
   (lambda (event)
     (interactive "e")
     (when-let* ((target (video-inline-target inline)))
       (video--seek-target-from-event target event))))
  (define-key
   map [mouse-movement]
   (lambda (_event)
     (interactive "e")
     (video-inline-show-controls inline)))
  map)

(defvar-keymap video-inline-map
  :doc "Keymap installed on inline video occurrences."
  "RET" #'video-inline-toggle
  "<mouse-1>" #'video-inline-toggle)

(cl-defun video-inline-create
    (source width height
            &key poster (fit 'contain) (muted t) live buffer player session
            request-headers close-function canvas canvas-width canvas-height
            (destination-x 0) (destination-y 0)
            visible-function alive-function activate-function)
  "Create a lazy inline occurrence for SOURCE without inserting text.

WIDTH and HEIGHT fix the video target.  POSTER is host-owned static display
data.  FIT, MUTED, LIVE, and REQUEST-HEADERS configure a lazily created player.
BUFFER defaults to the current buffer.  PLAYER borrows a low-level player,
while SESSION retains a `video-session'; they are mutually exclusive.  A
session-backed occurrence always reads audio state from the shared player.
CLOSE-FUNCTION is called with the inline object after its target and session
lease are released.  CANVAS may supply a larger scene, with CANVAS-WIDTH,
CANVAS-HEIGHT, DESTINATION-X, and DESTINATION-Y locating the dynamic video
region.  VISIBLE-FUNCTION, ALIVE-FUNCTION, and ACTIVATE-FUNCTION let an
application own placement and replace its static presentation with the Canvas."
  (unless (and (integerp width) (> width 0)
               (integerp height) (> height 0))
    (error "Inline video dimensions must be positive integers"))
  (when (and close-function (not (functionp close-function)))
    (error "Inline video close function is not callable"))
  (when (and player session)
    (error "Inline video cannot borrow both a player and a session"))
  (when session
    (unless (video-session-live-p session)
      (error "Inline video cannot borrow a closed session"))
    (setq player (video-session-player session)))
  (when player
    (unless (video-player-live-p player)
      (error "Inline video cannot borrow a closed player"))
    (setq source (or source (video-player-source player))
          muted (video-player-muted player)
          live (video-player-stream-live player)
          request-headers (video-player-request-headers player)))
  (setq buffer (or buffer (current-buffer)))
  (unless (buffer-live-p buffer)
    (error "Inline video requires a live host buffer"))
  (let ((inline
          (video--make-inline
           :source source :live (and live t) :request-headers request-headers
           :poster poster :buffer buffer
           :width width :height height :fit fit :muted muted
           :canvas canvas :canvas-width canvas-width :canvas-height canvas-height
           :destination-x (round destination-x)
           :destination-y (round destination-y)
           :visible-function visible-function
           :alive-function alive-function
           :activate-function activate-function
           :player player :session session :owns-player (not player)
           :close-function close-function)))
    (with-current-buffer buffer
      (video--install-host-hooks)
      (push inline video--inline-objects))
    (condition-case error-data
        (progn
          (when session
            (setf (video-inline-session-lease inline)
                  (video--session-acquire
                   session inline
                   #'video-inline-close)))
          inline)
      ((error quit)
       (with-current-buffer buffer
         (setq video--inline-objects
               (delq inline video--inline-objects)))
       (signal (car error-data) (cdr error-data))))))

(cl-defun video-session-inline-create
    (session width height
             &key poster (fit 'contain) buffer close-function
             canvas canvas-width canvas-height
             (destination-x 0) (destination-y 0)
             visible-function alive-function activate-function)
  "Create an inline presentation retaining SESSION at WIDTH by HEIGHT.

POSTER, FIT, BUFFER, CLOSE-FUNCTION, CANVAS, CANVAS-WIDTH, CANVAS-HEIGHT,
DESTINATION-X, DESTINATION-Y, VISIBLE-FUNCTION, ALIVE-FUNCTION, and
ACTIVATE-FUNCTION have the same meanings as in `video-inline-create'.
Playback and audio state remain canonical on SESSION's player."
  (video-inline-create
   nil width height :session session :poster poster :fit fit :buffer buffer
   :close-function close-function
   :canvas canvas :canvas-width canvas-width :canvas-height canvas-height
   :destination-x destination-x :destination-y destination-y
   :visible-function visible-function :alive-function alive-function
   :activate-function activate-function))

(cl-defun video-inline-insert
    (source poster width height
            &key (fit 'contain) (muted t) live request-headers)
  "Insert a lazy inline video occurrence for SOURCE.

POSTER is an image display descriptor or display value.  WIDTH and HEIGHT are
fixed Canvas dimensions.  FIT controls aspect treatment; MUTED, LIVE, and
REQUEST-HEADERS are forwarded to the lazy player.  Return the new
`video-inline' object."
  (let* ((start (point))
         (_ (insert " "))
         (overlay (make-overlay start (point) nil nil t))
         (inline (video-inline-create
                  source width height :poster poster :fit fit :muted muted
                  :live live :request-headers request-headers
                  :buffer (current-buffer))))
    (setf (video-inline-overlay inline) overlay)
    (overlay-put overlay 'display (or poster "[Video]"))
    (overlay-put overlay 'keymap video-inline-map)
    (overlay-put overlay 'mouse-face 'highlight)
    (overlay-put overlay 'help-echo "mouse-1/RET: play or pause video")
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'video-inline inline)
    inline))

(defun video-inline-toggle-occurrence (inline)
  "Toggle playback for INLINE."
  (if-let* ((player (video-inline-player inline)))
      (video-player-toggle player)
    (video-inline-play inline)))

(defun video-inline-muted-p (inline)
  "Return INLINE's current canonical mute state."
  (when (video-inline-closed inline)
    (error "Inline video is closed"))
  (if-let* ((player (video-inline-player inline))
            ((video-player-live-p player)))
      (video-player-muted player)
    (video-inline-muted inline)))

(defun video-inline-set-muted (inline muted)
  "Set INLINE audio MUTED state before or during playback."
  (when (video-inline-closed inline)
    (error "Inline video is closed"))
  (setf (video-inline-muted inline) (and muted t))
  (when-let* ((player (video-inline-player inline))
              ((video-player-live-p player)))
    (video-player-set-muted player (video-inline-muted inline)))
  inline)

(defun video-inline-toggle-muted (inline)
  "Toggle INLINE's canonical player audio output."
  (video-inline-set-muted inline (not (video-inline-muted-p inline))))

(defun video-inline-play (inline)
  "Create INLINE's lazy player or target as needed, then start playback."
  (when (video-inline-closed inline)
    (error "Inline video is closed"))
  (unless (video-player-p (video-inline-player inline))
    (setf (video-inline-player inline)
          (video-player-create
           (video-inline-source inline)
           :muted (video-inline-muted inline)
           :live (video-inline-live inline)
           :request-headers (video-inline-request-headers inline))
          (video-inline-owns-player inline) t))
  (let ((player (video-inline-player inline)))
    (unless (video-target-p (video-inline-target inline))
      (let ((target
             (video-target-create
              player (video-inline-width inline) (video-inline-height inline)
              :fit (video-inline-fit inline)
              :canvas (video-inline-canvas inline)
              :canvas-width (video-inline-canvas-width inline)
              :canvas-height (video-inline-canvas-height inline)
              :destination-x (video-inline-destination-x inline)
              :destination-y (video-inline-destination-y inline))))
        (setf (video-inline-target inline) target
              (video-target-inline target) inline)))
    (video-player-play player))
  inline)

(defun video-inline-close (inline)
  "Close INLINE's target and release its player or session ownership.

A lazily created player is closed directly.  A low-level borrowed player
remains live.  A session-backed occurrence releases its presentation lease;
the session decides whether its shared player should close."
  (when (and (video-inline-p inline) (not (video-inline-closed inline)))
    (setf (video-inline-closed inline) t)
    (when-let* ((target (video-inline-target inline)))
      (video-target-close target))
    (when-let* ((player (video-inline-player inline))
                ((video-inline-owns-player inline)))
      (video-player-close player))
    (when-let* ((overlay (video-inline-overlay inline))
                ((overlayp overlay))
                ((overlay-buffer overlay)))
      (overlay-put overlay 'display (or (video-inline-poster inline) "[Video]")))
    (when-let* ((buffer (video-inline-buffer inline))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (setq video--inline-objects (delq inline video--inline-objects))))
    (let ((lease (video-inline-session-lease inline)))
      (setf (video-inline-player inline) nil
            (video-inline-session inline) nil
            (video-inline-session-lease inline) nil
            (video-inline-target inline) nil)
      (when lease
        (video--session-release lease)))
    (when-let* ((close-function (video-inline-close-function inline)))
      (setf (video-inline-close-function inline) nil)
      (funcall close-function inline)))
  nil)

(defun video--close-all-players ()
  "Close all live players before Emacs exits."
  (dolist (player (copy-sequence video--players))
    (video-player-close player)))

(add-hook 'kill-emacs-hook #'video--close-all-players)

(defcustom video-image-file-extensions '("png" "jpg" "jpeg" "gif" "bmp" "webp" "avif" "svg" "tif" "tiff")
  "Local image extensions claimed by `video-image-auto-mode'.
Formats still require the corresponding GStreamer decoder.  Remote files
and displays without Canvas support continue to use `image-mode'."
  :type '(repeat string)
  :group 'video)

(defvar video--image-auto-mode-entry nil
  "Exact entry installed by `video-image-auto-mode'.")

(defvar-local video--image-directory-order nil
  "Image filenames in the originating Dired buffer's display order.")

(defun video--image-file-p (file)
  "Return non-nil if FILE is a readable, supported local image filename."
  (and (stringp file) (not (file-remote-p file))
       (member (downcase (or (file-name-extension file) ""))
               video-image-file-extensions)
       (file-regular-p file) (file-readable-p file)))

(defun video--local-source-file (source)
  "Return a local filename for SOURCE, or nil for nonlocal URIs."
  (let ((file
         (cond
          ((string-match "\\`file://\\(?:localhost\\)?\\(/[^?#]*\\)\\(?:[?#].*\\)?\\'" source)
           (decode-coding-string
            (url-unhex-string (match-string 1 source))
            (or file-name-coding-system default-file-name-coding-system 'utf-8)))
          ((string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" source) nil)
          (t (expand-file-name source)))))
    (and file (not (file-remote-p file)) file)))

(defun video--image-dired-order (file)
  "Return FILE's directory images in the selected Dired window's order."
  (let ((origin (window-buffer (selected-window))) files)
    (when (buffer-live-p origin)
      (with-current-buffer origin
        (when (derived-mode-p 'dired-mode)
          (save-excursion
            (goto-char (point-min))
            (while (not (eobp))
              (when-let* ((name (dired-get-filename nil t))
                          ((equal (file-name-directory name)
                                  (file-name-directory file)))
                          ((video--image-file-p name)))
                (push name files))
              (forward-line 1))))))
    (setq files (nreverse files))
    (when (member file files) files)))

(defun video--file-load ()
  "Replace the current file's player without changing its buffer contents."
  (unless (and buffer-file-name (not (file-remote-p buffer-file-name))
               (file-regular-p buffer-file-name) (file-readable-p buffer-file-name))
    (user-error "Canvas media viewing requires a readable local file"))
  (when (buffer-modified-p)
    (user-error "Save or revert file changes before opening the Canvas viewer"))
  (video--close-buffer-player)
  (let* ((imagep (derived-mode-p 'video-image-mode))
         (player (video-player-create buffer-file-name
                                      :kind (if imagep 'image 'video)
                                      :muted imagep)))
    (setq video--buffer-player player video--buffer-owns-player t)
    (condition-case err
        (progn
          (video--manage-window-targets)
          (video-player-play player))
      (error
       (video--close-buffer-player)
       (signal (car err) (cdr err))))))

(defun video--file-after-revert ()
  "Restore Canvas media presentation after rereading the file."
  (when (derived-mode-p 'video-image-mode 'video-file-mode)
    (video--file-load)))

(defun video--file-initialize ()
  "Initialize file-backed media presentation in the current buffer."
  (add-hook 'before-revert-hook #'video--close-buffer-player nil t)
  (add-hook 'after-revert-hook #'video--file-after-revert nil t)
  (video--file-load))

;;;###autoload
(define-derived-mode video-file-mode video-mode "Video/Canvas"
  "View a local video file through an independent Canvas per window.
The buffer retains its original file contents.  Reverting reloads the
video; changing major mode releases its player and display overlays.
Remote files and displays without Canvas support are not supported."
  (unless (and (display-graphic-p) (image-type-available-p 'canvas))
    (user-error "Canvas video viewing requires a graphical Canvas display"))
  (video--file-initialize))

;;;###autoload
(define-derived-mode video-image-mode video-mode "Image/Canvas"
  "View a local image file through an independent Canvas per window.
The buffer retains its original file contents.  Reverting reloads the
image; changing major mode releases its player and display overlays."
  (video--file-initialize)
  (setq-local video--image-directory-order
              (video--image-dired-order buffer-file-name)))

(defun video--image-file-mode ()
  "Choose Canvas for local image files, otherwise use native `image-mode'."
  (if (and buffer-file-name (not (file-remote-p buffer-file-name))
           (display-graphic-p) (image-type-available-p 'canvas))
      (video-image-mode)
    (image-mode)))

;;;###autoload
(defun video--file-mode ()
  "Choose an image or video major mode for the current file.
Local media files use Canvas.  Images on remote filesystems or displays
without Canvas support use native `image-mode'; videos signal an error.
This can also replace a text mode in a previously visited media buffer."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a media file"))
  (cond
   ((file-remote-p buffer-file-name)
    (if (string-match-p video--image-extension-regexp (downcase buffer-file-name))
        (image-mode)
      (user-error "Canvas video viewing requires a local file")))
   ((eq (video--source-kind buffer-file-name) 'image)
    (video--image-file-mode))
   (t (video-file-mode))))

;;;###autoload
(define-minor-mode video-image-auto-mode
  "Use Canvas when visiting supported local image files.
This global switch affects future mode selection, not existing buffers.
Disabling it removes only the entry installed by this package."
  :global t :group 'video
  (when video--image-auto-mode-entry
    (setq auto-mode-alist (delq video--image-auto-mode-entry auto-mode-alist)
          video--image-auto-mode-entry nil))
  (when video-image-auto-mode
    (setq video--image-auto-mode-entry
          (cons (concat "\\." (regexp-opt video-image-file-extensions t) "\\'")
                #'video--image-file-mode))
    (push video--image-auto-mode-entry auto-mode-alist)))

(defun video-image-native ()
  "View this file with native `image-mode', retaining the original bytes."
  (interactive)
  (unless (and buffer-file-name (derived-mode-p 'video-image-mode))
    (user-error "Current buffer is not a Canvas image file"))
  ;; `image-mode' suspends rather than kills the previous mode.  Explicitly
  ;; leave Canvas first so its player and window overlays cannot survive.
  (fundamental-mode)
  (image-mode))

(defun video--image-neighbor (step)
  "Visit the image STEP places away, respecting the originating Dired order."
  (let* ((file (or buffer-file-name
                   (and (video-player-p video--buffer-player)
                        (video--local-source-file
                         (video-player-source video--buffer-player)))))
         (directory (and file (file-name-directory file))))
    (unless (and directory (video--image-file-p file))
      (user-error "Current media has no local image directory"))
    (let* ((files (seq-filter #'video--image-file-p
                              (or video--image-directory-order
                                  (directory-files directory t nil t))))
           (files (if video--image-directory-order files
                    (sort files #'string-lessp)))
           (index (cl-position file files :test #'equal)))
      (unless (and index (> (length files) 1))
        (user-error "No other image in this directory"))
      (let* ((origin (current-buffer))
             (order video--image-directory-order)
             (buffer (video-open (nth (mod (+ index step) (length files)) files))))
        (with-current-buffer buffer
          (setq video--image-directory-order order))
        ;; Keep a file viewed in another window, but do not accumulate hidden
        ;; decoders while browsing an ordinary single-window image directory.
        (when (and (buffer-live-p origin)
                   (buffer-local-value 'buffer-file-name origin)
                   (not (buffer-modified-p origin))
                   (not (get-buffer-window origin t)))
          (kill-buffer origin))))))

(define-key video-mode-map (kbd "1") #'video-original-size)
(define-key video-mode-map (kbd "s") #'video-set-scale)
(define-key video-image-mode-map (kbd "C-c C-c") #'video-image-native)

(provide 'video)
;;; video.el ends here
