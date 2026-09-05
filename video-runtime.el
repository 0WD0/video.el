;;; video-runtime.el --- Playback runtime for Canvas media  -*- lexical-binding: t; -*-

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

;; Players, sessions, presentation leases, render targets, and shared Canvas
;; controls.  Hosts supply per-target lifecycle callbacks; native playback and
;; target resources remain owned here.

;;; Code:

(require 'video-source)
(require 'video-module)

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

(defcustom video-controls-hide-delay 1.5
  "Seconds before transport controls fade while playback continues."
  :type 'number
  :group 'video)

(defvar video-player-state-change-hook nil
  "Hook run with one PLAYER argument after playback state changes.")

(defvar video-player-error-hook nil
  "Hook run with PLAYER and error message after playback fails.")

(defconst video--cache-poll-delay 0.1
  "Seconds between bounded cache-completion retry polls.")

(defconst video--cache-poll-limit 20
  "Maximum cache-completion retry polls after a native event burst.")

(defvar video--players nil
  "Live `video-player' objects.")

(defvar video--sessions nil
  "Live `video-session' objects.")

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
  closed
  ;; Append slots: downstream bytecode inlines existing field offsets.
  ;; Explicit looping overrides the initial animation file policy.
  loop-p
  loop-explicit-p)

(cl-defstruct (video-session (:constructor video--make-session))
  "One player and all presentation leases sharing its exact state."
  player
  presentations
  auto-close
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
  visible-function
  prepare-function
  present-function
  close-function
  (controls-until 0.0)
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

(defun video--animation-repeat-p (player)
  "Whether PLAYER may begin another animation iteration."
  (if (video-player-loop-explicit-p player)
      (and (video-player-loop-p player)
           (video-player-seekable player)
           (not (video-player-stream-live player)))
    (pcase (video-player-animation-loop-policy player)
      ('forever t)
      ('file
       (let ((count (video-player-animation-loop-count player)))
         (and (integerp count)
              (or (zerop count)
                  (<= (video-player-animation-iterations player) count)))))
      (_ nil))))

(defun video--restart-player (player)
  "Rewind PLAYER without resetting its animation repeat budget.
Only the original animation policy may restart nonseekable media."
  (if (video-player-seekable player)
      (video-native-seek (video-player-handle player) 0.0)
    (video-native-stop (video-player-handle player)))
  (setf (video-player-position player) 0.0
        (video-player-animation-ended player) nil
        (video-player-suspended player) t))

(defun video--player-eos (player)
  "Handle PLAYER's EOS and return non-nil if repeating.
Count each completed animation iteration once, including an EOS observed
while paused.  Repetition belongs to the player, never a render target."
  (when (and (video-player-animated-p player)
             (not (video-player-animation-ended player)))
    (cl-incf (video-player-animation-iterations player))
    (setf (video-player-animation-ended player) t))
  (when (and (eq (video-player-desired-state player) 'playing)
             (if (video-player-animated-p player)
                 (video--animation-repeat-p player)
               (and (video-player-loop-p player)
                    (video-player-seekable player)
                    (not (video-player-stream-live player)))))
    (video--restart-player player)
    t))

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
  (let* ((uri (video-source-uri source))
         (animation (and (eq kind 'image)
                         (video-source-gif-metadata (video-source-file source))))
         (request-headers (video-source-header-vector request-headers))
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
        (video--restart-player player))
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

(defun video-player-set-loop (player loop)
  "Set PLAYER's explicit LOOP state and return PLAYER.
Non-nil LOOP repeats seekable, non-live video, audio, or animation at EOS.
Nil disables repetition, including an animation's file loop policy.
Until this function is called, animations retain their original policy.
Changing LOOP does not start playback, seek, or interrupt the current pass.
Still images cannot loop.  Enabling looping requires known seekability;
disabling it remains possible if media has become live or nonseekable."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (unless (video--player-transport-p player)
    (user-error "Current media is a still image"))
  (when loop
    (when (video-player-stream-live player)
      (user-error "Live streams cannot loop"))
    (unless (video-player-seekable player)
      (user-error "Current media is not seekable")))
  (setf (video-player-loop-p player) (and loop t)
        (video-player-loop-explicit-p player) t)
  (force-mode-line-update t)
  player)

(defun video-player-toggle-loop (player)
  "Toggle PLAYER's effective repetition policy and return PLAYER.
The first toggle of an animation overrides its original loop policy."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (video-player-set-loop
   player
   (not (if (and (video-player-animated-p player)
                 (not (video-player-loop-explicit-p player)))
            (video--animation-repeat-p player)
          (video-player-loop-p player)))))

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
  "Store native RANGES and transport fractions on PLAYER."
  (let ((duration (video-player-duration player))
        fractions)
    (when (and (numberp duration) (> duration 0.0))
      (dolist (range ranges)
        (when (and (consp range)
                   (numberp (car range))
                   (numberp (cdr range))
                   (< (car range) (cdr range)))
          (push (/ (float (car range)) duration) fractions)
          (push (/ (float (cdr range)) duration) fractions))))
    (setf (video-player-buffered-time-ranges player) ranges
          (video-player-buffered-range-vector player) (vconcat (nreverse fractions))
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
  "Return PLAYER buffered range fractions for transport drawing."
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
   canvas canvas-width canvas-height (video-source-uri source)
   (round x) (round y) (round width) (round height)
   (video--fit-name (or fit 'contain))))

(defun video--fit-name (fit)
  "Return native string name for FIT."
  (pcase fit
    ((or 'contain 'shrink 'cover 'width 'height 'actual) (symbol-name fit))
    (_ "contain")))

(cl-defun video-target-create
    (player width height &key (fit 'contain) scale
            (x 0.0) (y 0.0)
            canvas canvas-width canvas-height
            (destination-x 0) (destination-y 0)
            visible-function prepare-function present-function close-function)
  "Create a viewport render target for PLAYER with WIDTH and HEIGHT.

SCALE is the absolute source-pixel to display-pixel ratio.  X and Y locate the
viewport in the resulting virtual media plane.  When SCALE is nil, FIT chooses
an automatic scale; this mode is intended for fixed inline targets.  CANVAS may
supply a larger host-owned scene.  CANVAS-WIDTH, CANVAS-HEIGHT, DESTINATION-X,
and DESTINATION-Y place this target inside that scene.
Host callbacks receive TARGET.  VISIBLE-FUNCTION decides whether to render;
without it a target is visible.  PREPARE-FUNCTION runs before copying a frame
with current media state.  PRESENT-FUNCTION runs after a valid frame is copied
and its Canvas refreshed.  CLOSE-FUNCTION runs once on close.  The latter
three callbacks do nothing when omitted."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (unless (and (integerp width) (> width 0)
               (integerp height) (> height 0))
    (error "Video target dimensions must be positive integers"))
  (dolist (callback (list visible-function prepare-function
                          present-function close-function))
    (when (and callback (not (functionp callback)))
      (error "Video target callback is not callable")))
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
                  :visible-function visible-function
                  :prepare-function prepare-function
                  :present-function present-function
                  :close-function close-function
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
  "Close TARGET and release its host attachment once.
The target does not own its player.  Host cleanup may release a session lease
or an owned player when the presentation itself closes."
  (when (and (video-target-p target) (not (video-target-closed target)))
    (setf (video-target-closed target) t)
    (let ((player (video-target-player target))
          (close-function (video-target-close-function target)))
      (setf (video-player-targets player)
            (delq target (video-player-targets player))
            (video-target-visible-function target) nil
            (video-target-prepare-function target) nil
            (video-target-present-function target) nil
            (video-target-close-function target) nil)
      (when (video-target-handle target)
        (condition-case error-data
            (video-native-target-close (video-target-handle target))
          (error
           (message "Video target close failed: %s"
                    (error-message-string error-data)))))
      (setf (video-target-handle target) nil)
      (when close-function
        (condition-case error-data
            (funcall close-function target)
          (error
           (message "Video target host close failed: %s"
                    (error-message-string error-data)))))))
  nil)

(defun video--target-visible-p (target)
  "Return non-nil when TARGET is open and its host is visible."
  (and (not (video-target-closed target))
       (if-let* ((visible (video-target-visible-function target)))
           (funcall visible target)
         t)))

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
  (when (video--target-visible-p target)
    (when-let* ((prepare (video-target-prepare-function target)))
      (funcall prepare target))
    (unless (video-target-closed target)
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
                  (video-target-presented-frame target) t))
          (when (video--player-transport-p player)
            (video--install-target-control-map target)
            (video--draw-target-controls target))
          (canvas-refresh (video-target-canvas target))
          (when-let* (((integerp sequence))
                      (present (video-target-present-function target)))
            (funcall present target)))))))

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
            (when (or (video-player-error player)
                      (and (plist-get state :eos)
                           (not (video--player-eos player))))
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

(defun video--close-all-players ()
  "Close all live players before Emacs exits."
  (dolist (player (copy-sequence video--players))
    (video-player-close player)))

(add-hook 'kill-emacs-hook #'video--close-all-players)

(provide 'video-runtime)
;;; video-runtime.el ends here
