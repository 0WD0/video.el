;;; video.el --- Canvas-based video playback for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 0WD0

;; Author: 0WD0 <wd.1105848296@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))
;; Keywords: multimedia, video, extensions

;; This file is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.

;;; Commentary:

;; video.el presents GStreamer video frames through Emacs Canvas images.  It
;; provides a dedicated `video-mode' buffer and lazy inline video occurrences.

;;; Code:

(require 'cl-lib)
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

(defcustom video-pause-when-hidden t
  "Whether playback pauses when none of a player's targets are visible."
  :type 'boolean
  :group 'video)

(defcustom video-pan-frame-interval (/ 1.0 60.0)
  "Minimum seconds between middle-button pan updates."
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

(defcustom video-zoom-factor 1.25
  "Multiplier used by viewport zoom commands."
  :type 'number
  :group 'video)

(defvar video-player-state-change-hook nil
  "Hook run with one PLAYER argument after playback state changes.")

(defvar video-player-error-hook nil
  "Hook run with PLAYER and error message after playback fails.")

(defconst video--library-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(defvar video--players nil
  "Live `video-player' objects.")

(defvar-local video--buffer-player nil)
(defvar-local video--inline-objects nil)
(defvar-local video--host-hooks-installed nil)

(cl-defstruct (video-player (:constructor video--make-player))
  "One GStreamer playback session."
  source
  handle
  process
  (desired-state 'paused)
  (state 'stopped)
  (position 0.0)
  duration
  (buffering 100)
  (width 0)
  (height 0)
  (volume 1.0)
  muted
  (rate 1.0)
  error
  targets
  dispatch-timer
  suspended
  closed)

(cl-defstruct (video-target (:constructor video--make-target))
  "One Canvas viewport backed by a native render target."
  player
  handle
  canvas
  width
  height
  (fit 'contain)
  (zoom 1.0)
  (center-x 0.5)
  (center-y 0.5)
  last-sequence
  window
  overlay
  inline
  closed)

(cl-defstruct (video-inline (:constructor video--make-inline))
  "One lazy video occurrence embedded in a normal buffer."
  source
  poster
  overlay
  buffer
  width
  height
  fit
  muted
  player
  target
  active
  closed)

(declare-function video-native-create "video-module" (uri process))
(declare-function video-native-close "video-module" (player))
(declare-function video-native-play "video-module" (player))
(declare-function video-native-pause "video-module" (player))
(declare-function video-native-stop "video-module" (player))
(declare-function video-native-seek "video-module" (player seconds))
(declare-function video-native-set-volume "video-module" (player volume))
(declare-function video-native-set-muted "video-module" (player muted))
(declare-function video-native-set-rate "video-module" (player rate))
(declare-function video-native-poll "video-module" (player))
(declare-function video-native-target-create
                  "video-module" (player width height fit zoom center-x center-y))
(declare-function video-native-target-close "video-module" (target))
(declare-function video-native-target-set-view
                  "video-module" (target width height fit zoom center-x center-y))
(declare-function video-native-target-copy
                  "video-module" (target canvas canvas-width canvas-height x y))
(declare-function read--potential-mouse-event "mouse" ())

(defun video--load-native-module ()
  "Load the native video module or signal a useful error."
  (unless (featurep 'video-module)
    (let ((module (expand-file-name
                   (concat "video-module" module-file-suffix)
                   video--library-directory)))
      (unless (file-readable-p module)
        (error "Video.el native module is missing; run `eask run script build-native'"))
      (module-load module))))

(video--load-native-module)

(defun video--normalize-source (source)
  "Return SOURCE as an absolute URI accepted by GStreamer."
  (unless (and (stringp source) (not (string-empty-p source)))
    (error "Video source must be a non-empty string"))
  (cond
   ((string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" source) source)
   ((file-name-absolute-p source)
    (url-encode-url (concat "file://" (expand-file-name source))))
   ((file-exists-p source)
    (url-encode-url (concat "file://" (expand-file-name source))))
   (t (error "Video source is neither a URI nor a readable file: %s" source))))

(defun video--event-sentinel (_process _event)
  "Ignore pipe PROCESS EVENT notifications."
  nil)

(defun video--event-filter (process _output)
  "Schedule a dispatch for the player associated with PROCESS."
  (when-let* ((player (process-get process 'video-player))
              ((not (video-player-closed player)))
              ((not (timerp (video-player-dispatch-timer player)))))
    (setf (video-player-dispatch-timer player)
          (run-at-time 0 nil #'video--dispatch player))))

(cl-defun video-player-create (source &key (volume 1.0) muted (rate 1.0))
  "Create and return a video player for SOURCE.

VOLUME is between zero and one.  MUTED controls initial audio output and RATE
is the positive playback rate.  The player starts paused."
  (unless (display-graphic-p)
    (error "Video.el requires a graphical Emacs display"))
  (unless (image-type-available-p 'canvas)
    (error "This Emacs build does not provide Canvas images"))
  (let* ((uri (video--normalize-source source))
         (process (make-pipe-process
                   :name (generate-new-buffer-name " video-events")
                   :buffer nil
                   :coding 'no-conversion
                   :noquery t
                   :filter #'video--event-filter
                   :sentinel #'video--event-sentinel))
         (player (video--make-player
                  :source uri :process process
                  :volume (max 0.0 (min 1.0 (float volume)))
                  :muted (and muted t)
                  :rate (max 0.01 (float rate)))))
    (process-put process 'video-player player)
    (condition-case error-data
        (setf (video-player-handle player)
              (video-native-create uri process))
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

(defun video-player-play (player)
  "Play PLAYER, respecting target visibility policy."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (setf (video-player-desired-state player) 'playing)
  (video--reconcile-player-visibility player)
  player)

(defun video-player-pause (player)
  "Pause PLAYER."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (setf (video-player-desired-state player) 'paused
        (video-player-suspended player) nil)
  (video-native-pause (video-player-handle player))
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
        (video-player-suspended player) nil)
  (video-native-stop (video-player-handle player))
  player)

(defun video-player-seek (player seconds)
  "Seek PLAYER to absolute position SECONDS."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (let ((limit (video-player-duration player)))
    (video-native-seek
     (video-player-handle player)
     (max 0.0 (if (numberp limit) (min (float seconds) limit) (float seconds)))))
  player)

(defun video-player-seek-relative (player delta)
  "Seek PLAYER by DELTA seconds."
  (video-player-seek player (+ (or (video-player-position player) 0.0) delta)))

(defun video-player-set-volume (player volume)
  "Set PLAYER audio VOLUME between zero and one."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (setf (video-player-volume player)
        (max 0.0 (min 1.0 (float volume))))
  (video-native-set-volume (video-player-handle player)
                           (video-player-volume player))
  player)

(defun video-player-set-muted (player muted)
  "Set PLAYER audio MUTED state."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (setf (video-player-muted player) (and muted t))
  (video-native-set-muted (video-player-handle player)
                          (video-player-muted player))
  player)

(defun video-player-close (player)
  "Close PLAYER and every render target it owns.

This operation is idempotent."
  (when (and (video-player-p player) (not (video-player-closed player)))
    (setf (video-player-closed player) t)
    (when-let* ((timer (video-player-dispatch-timer player))
                ((timerp timer)))
      (cancel-timer timer))
    (setf (video-player-dispatch-timer player) nil)
    (dolist (target (copy-sequence (video-player-targets player)))
      (video-target-close target))
    (when (video-player-handle player)
      (ignore-errors (video-native-close (video-player-handle player))))
    (setf (video-player-handle player) nil)
    (when-let* ((process (video-player-process player))
                ((process-live-p process)))
      (delete-process process))
    (setf (video-player-process player) nil)
    (setq video--players (delq player video--players)))
  nil)

(defun video--make-canvas (width height)
  "Return a unique Canvas image of WIDTH by HEIGHT pixels."
  `(image :type canvas
          :id ,(gensym "video-canvas-")
          :data-width ,width
          :data-height ,height
          :scale 1.0
          :ascent center))

(defun video--fit-name (fit)
  "Return native string name for FIT."
  (pcase fit
    ((or 'contain 'cover 'width 'height 'actual) (symbol-name fit))
    (_ "contain")))

(cl-defun video-target-create
    (player width height &key (fit video-default-fit) (zoom 1.0)
            (center-x 0.5) (center-y 0.5))
  "Create a Canvas target for PLAYER with WIDTH and HEIGHT.

FIT controls aspect treatment.  ZOOM scales relative to that fit, and CENTER-X
and CENTER-Y are normalized source coordinates."
  (unless (video-player-live-p player)
    (error "Video player is closed"))
  (unless (and (integerp width) (> width 0)
               (integerp height) (> height 0))
    (error "Video target dimensions must be positive integers"))
  (let* ((canvas (video--make-canvas width height))
         (handle (video-native-target-create
                  (video-player-handle player) width height
                  (video--fit-name fit) (float zoom)
                  (float center-x) (float center-y)))
         (target (video--make-target
                  :player player :handle handle :canvas canvas
                  :width width :height height :fit fit :zoom (float zoom)
                  :center-x (float center-x) :center-y (float center-y))))
    (push target (video-player-targets player))
    target))

(defun video-target-set-view
    (target width height fit zoom center-x center-y)
  "Set TARGET viewport to WIDTH, HEIGHT, FIT, ZOOM, CENTER-X and CENTER-Y."
  (when (video-target-closed target)
    (error "Video target is closed"))
  (setq width (max 1 (round width))
        height (max 1 (round height))
        zoom (max 0.01 (float zoom))
        center-x (max 0.0 (min 1.0 (float center-x)))
        center-y (max 0.0 (min 1.0 (float center-y))))
  (setf (video-target-width target) width
        (video-target-height target) height
        (video-target-fit target) fit
        (video-target-zoom target) zoom
        (video-target-center-x target) center-x
        (video-target-center-y target) center-y
        (video-target-last-sequence target) nil)
  (plist-put (cdr (video-target-canvas target)) :data-width width)
  (plist-put (cdr (video-target-canvas target)) :data-height height)
  (video-native-target-set-view
   (video-target-handle target) width height (video--fit-name fit)
   zoom center-x center-y)
  target)

(defun video-target-close (target)
  "Close TARGET without closing its player."
  (when (and (video-target-p target) (not (video-target-closed target)))
    (setf (video-target-closed target) t)
    (let ((player (video-target-player target)))
      (setf (video-player-targets player)
            (delq target (video-player-targets player))))
    (when (video-target-handle target)
      (ignore-errors (video-native-target-close (video-target-handle target))))
    (setf (video-target-handle target) nil)
    (when-let* ((overlay (video-target-overlay target))
                ((overlayp overlay)))
      (delete-overlay overlay))
    (when-let* ((window (video-target-window target))
                ((windowp window))
                ((eq (window-parameter window 'video-target) target)))
      (video--cancel-pan window)
      (set-window-parameter window 'video-target nil)))
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
           (eq (window-parameter window 'video-target) target))))
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
          (setf (video-player-suspended player) nil))
        (video-native-play (video-player-handle player)))
       ((not (video-player-suspended player))
        (setf (video-player-suspended player) t)
        (video-native-pause (video-player-handle player)))))))

(defun video--present-target (target)
  "Copy the newest native frame for TARGET into its Canvas."
  (when (and (not (video-target-closed target))
             (video--target-visible-p target))
    (when-let* ((sequence
                 (video-native-target-copy
                  (video-target-handle target)
                  (video-target-canvas target)
                  (video-target-width target)
                  (video-target-height target)
                  0 0))
                ((integerp sequence))
                ((not (equal sequence (video-target-last-sequence target)))))
      (setf (video-target-last-sequence target) sequence)
      (canvas-refresh (video-target-canvas target))
      (when-let* ((inline (video-target-inline target))
                  ((not (video-inline-active inline))))
        (setf (video-inline-active inline) t)
        (when (overlayp (video-inline-overlay inline))
          (overlay-put (video-inline-overlay inline)
                       'display (video-target-canvas target)))))))

(defun video--dispatch (player)
  "Drain native state and present dirty targets for PLAYER."
  (when (video-player-p player)
    (setf (video-player-dispatch-timer player) nil)
    (when (video-player-live-p player)
      (condition-case error-data
          (let* ((old-state (video-player-state player))
                 (old-error (video-player-error player))
                 (state (video-native-poll (video-player-handle player))))
            (setf (video-player-state player) (or (plist-get state :state) 'stopped)
                  (video-player-position player) (or (plist-get state :position) 0.0)
                  (video-player-duration player) (plist-get state :duration)
                  (video-player-buffering player) (or (plist-get state :buffering) 100)
                  (video-player-width player) (or (plist-get state :width) 0)
                  (video-player-height player) (or (plist-get state :height) 0)
                  (video-player-error player) (plist-get state :error))
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
  "Return playback position text for the current video buffer."
  (if (video-player-live-p video--buffer-player)
      (format " %s / %s"
              (video--format-time (video-player-position video--buffer-player))
              (video--format-time (video-player-duration video--buffer-player)))
    ""))

(defun video--window-target-valid-p (window)
  "Return non-nil when WINDOW owns a target for its current video buffer."
  (let ((target (and (window-live-p window)
                     (window-parameter window 'video-target))))
    (and (video-target-p target)
         (not (video-target-closed target))
         (eq (video-target-window target) window)
         (overlayp (video-target-overlay target))
         (eq (overlay-buffer (video-target-overlay target))
             (window-buffer window)))))

(defun video--window-pixel-size (window)
  "Return positive body pixel dimensions for WINDOW."
  (cons (max 1 (window-body-width window t))
        (max 1 (window-body-height window t))))

(defun video--create-window-target (window)
  "Create and attach a render target for WINDOW."
  (with-current-buffer (window-buffer window)
    (when (and (derived-mode-p 'video-mode)
               (video-player-live-p video--buffer-player))
      (let* ((source-target
              (cl-find-if #'video--target-visible-p
                          (video-player-targets video--buffer-player)))
             (size (video--window-pixel-size window))
             (fit (or (and source-target (video-target-fit source-target))
                      video-default-fit))
             (zoom (or (and source-target (video-target-zoom source-target)) 1.0))
             (center-x (or (and source-target
                                (video-target-center-x source-target)) 0.5))
             (center-y (or (and source-target
                                (video-target-center-y source-target)) 0.5))
             (target (video-target-create
                      video--buffer-player (car size) (cdr size)
                      :fit fit :zoom zoom :center-x center-x :center-y center-y))
             (overlay (make-overlay (point-min) (point-max) nil nil nil)))
        (overlay-put overlay 'window window)
        (overlay-put overlay 'display (video-target-canvas target))
        (overlay-put overlay 'video-target target)
        (setf (video-target-window target) window
              (video-target-overlay target) overlay)
        (set-window-parameter window 'video-target target)
        target))))

(defun video--close-stale-window-targets ()
  "Close dedicated targets whose windows no longer display their buffers."
  (dolist (player video--players)
    (dolist (target (copy-sequence (video-player-targets player)))
      (when-let* ((window (video-target-window target)))
        (unless (and (window-live-p window)
                     (eq (window-buffer window)
                         (and (overlayp (video-target-overlay target))
                              (overlay-buffer (video-target-overlay target)))))
          (video-target-close target))))))

(defun video--manage-window-targets (&rest _ignored)
  "Create and remove dedicated targets for the current video buffer."
  (when (derived-mode-p 'video-mode)
    (video--close-stale-window-targets)
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (unless (video--window-target-valid-p window)
        (video--create-window-target window)))
    (when (video-player-live-p video--buffer-player)
      (video--reconcile-player-visibility video--buffer-player))))

(defun video--resize-window-targets (&optional _frame)
  "Resize dedicated targets to their current window bodies."
  (when (derived-mode-p 'video-mode)
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (when (video--window-target-valid-p window)
        (let* ((target (window-parameter window 'video-target))
               (size (video--window-pixel-size window)))
          (unless (and (= (car size) (video-target-width target))
                       (= (cdr size) (video-target-height target)))
            (video-target-set-view
             target (car size) (cdr size)
             (video-target-fit target) (video-target-zoom target)
             (video-target-center-x target) (video-target-center-y target))))))))

(defun video--current-target ()
  "Return the selected window's valid dedicated target."
  (unless (video--window-target-valid-p (selected-window))
    (video--manage-window-targets))
  (or (window-parameter (selected-window) 'video-target)
      (user-error "Current window has no video viewport")))

(defun video--sync-target (target)
  "Send TARGET semantic viewport state to the native renderer."
  (video-target-set-view
   target (video-target-width target) (video-target-height target)
   (video-target-fit target) (video-target-zoom target)
   (video-target-center-x target) (video-target-center-y target)))

(defun video-toggle ()
  "Toggle playback in the current dedicated video buffer."
  (interactive)
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

(defun video-toggle-muted ()
  "Toggle mute for the current player."
  (interactive)
  (video-player-set-muted
   video--buffer-player
   (not (video-player-muted video--buffer-player))))

(defun video-zoom-in ()
  "Enlarge the selected video viewport."
  (interactive)
  (let ((target (video--current-target)))
    (setf (video-target-zoom target)
          (* (video-target-zoom target) video-zoom-factor))
    (video--sync-target target)))

(defun video-zoom-out ()
  "Shrink the selected video viewport."
  (interactive)
  (let ((target (video--current-target)))
    (setf (video-target-zoom target)
          (max 0.01 (/ (video-target-zoom target) video-zoom-factor)))
    (video--sync-target target)))

(defun video-reset-view ()
  "Reset the selected viewport to its default fit and center."
  (interactive)
  (let ((target (video--current-target)))
    (setf (video-target-fit target) video-default-fit
          (video-target-zoom target) 1.0
          (video-target-center-x target) 0.5
          (video-target-center-y target) 0.5)
    (video--sync-target target)))

(defun video-fit-width ()
  "Fit the selected viewport to video width."
  (interactive)
  (let ((target (video--current-target)))
    (setf (video-target-fit target) 'width
          (video-target-zoom target) 1.0)
    (video--sync-target target)))

(defun video-fit-height ()
  "Fit the selected viewport to video height."
  (interactive)
  (let ((target (video--current-target)))
    (setf (video-target-fit target) 'height
          (video-target-zoom target) 1.0)
    (video--sync-target target)))

(defun video--fit-scale (target)
  "Return TARGET's effective source-to-canvas scale."
  (let* ((player (video-target-player target))
         (source-width (video-player-width player))
         (source-height (video-player-height player))
         (target-width (video-target-width target))
         (target-height (video-target-height target)))
    (when (and (> source-width 0) (> source-height 0))
      (* (video-target-zoom target)
         (pcase (video-target-fit target)
           ('cover (max (/ (float target-width) source-width)
                        (/ (float target-height) source-height)))
           ('width (/ (float target-width) source-width))
           ('height (/ (float target-height) source-height))
           ('actual 1.0)
           (_ (min (/ (float target-width) source-width)
                   (/ (float target-height) source-height))))))))

(defun video--apply-pan (target delta-x delta-y)
  "Move TARGET content by pointer DELTA-X and DELTA-Y pixels."
  (when-let* ((scale (video--fit-scale target))
              ((> scale 0)))
    (let* ((player (video-target-player target))
           (source-width (video-player-width player))
           (source-height (video-player-height player)))
      (setf (video-target-center-x target)
            (max 0.0 (min 1.0
                          (- (video-target-center-x target)
                             (/ delta-x scale source-width))))
            (video-target-center-y target)
            (max 0.0 (min 1.0
                          (- (video-target-center-y target)
                             (/ delta-y scale source-height)))))
      (video--sync-target target))))

(defun video--clear-pan-queue (window)
  "Clear queued middle-button movement for WINDOW."
  (dolist (parameter '(video-pan-timer video-pan-token video-pan-delta
                                      video-pan-target video-pan-buffer))
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
    (let ((delta (window-parameter window 'video-pan-delta))
          (target (window-parameter window 'video-pan-target))
          (buffer (window-parameter window 'video-pan-buffer)))
      (video--clear-pan-queue window)
      (when (and (consp delta)
                 (video-target-p target)
                 (not (video-target-closed target))
                 (eq buffer (window-buffer window))
                 (eq target (window-parameter window 'video-target)))
        (video--apply-pan target (car delta) (cdr delta))))))

(defun video--queue-pan (window delta-x delta-y)
  "Queue pointer DELTA-X and DELTA-Y for WINDOW."
  (if (<= video-pan-frame-interval 0)
      (when (video--window-target-valid-p window)
        (video--apply-pan (window-parameter window 'video-target)
                          delta-x delta-y))
    (when (video--window-target-valid-p window)
      (let* ((pending (window-parameter window 'video-pan-delta))
             (combined (cons (+ (if (consp pending) (car pending) 0.0) delta-x)
                             (+ (if (consp pending) (cdr pending) 0.0) delta-y)))
             (timer (window-parameter window 'video-pan-timer)))
        (set-window-parameter window 'video-pan-delta combined)
        (unless (timerp timer)
          (let ((token (list (window-parameter window 'video-target))))
            (set-window-parameter window 'video-pan-token token)
            (set-window-parameter window 'video-pan-target
                                  (window-parameter window 'video-target))
            (set-window-parameter window 'video-pan-buffer (window-buffer window))
            (set-window-parameter
             window 'video-pan-timer
             (run-at-time video-pan-frame-interval nil
                          #'video--flush-pan window token))))))))

(defun video--event-window (event &optional end)
  "Return the live window named by mouse EVENT.

Use EVENT's end position when END is non-nil."
  (condition-case nil
      (let ((window (posn-window (if end (event-end event) (event-start event)))))
        (when (framep window)
          (setq window (frame-selected-window window)))
        (and (window-live-p window) window))
    (error nil)))

(defun video--event-canvas-position (event &optional start)
  "Return EVENT's Canvas-local position, using its start when START is non-nil."
  (condition-case nil
      (when-let* ((position (if start (event-start event) (event-end event)))
                  (coordinates (or (posn-object-x-y position) (posn-x-y position)))
                  ((numberp (car coordinates)))
                  ((numberp (cdr coordinates))))
        (cons (float (car coordinates)) (float (cdr coordinates))))
    (error nil)))

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

(defun video--close-buffer-player ()
  "Close the dedicated player owned by the current buffer."
  (when (video-player-p video--buffer-player)
    (video-player-close video--buffer-player)
    (setq video--buffer-player nil)))

(defvar-keymap video-mode-map
  :doc "Keymap for `video-mode'."
  "SPC" #'video-toggle
  "<left>" #'video-seek-backward
  "<right>" #'video-seek-forward
  "S-<left>" (lambda () (interactive) (video-seek-backward t))
  "S-<right>" (lambda () (interactive) (video-seek-forward t))
  "<up>" #'video-volume-up
  "<down>" #'video-volume-down
  "m" #'video-toggle-muted
  "+" #'video-zoom-in
  "=" #'video-zoom-in
  "-" #'video-zoom-out
  "0" #'video-reset-view
  "W" #'video-fit-width
  "H" #'video-fit-height
  "<down-mouse-2>" #'video-mouse-pan
  "q" #'quit-window
  "Q" #'kill-current-buffer)

;;;###autoload
(define-derived-mode video-mode special-mode "Video"
  "Major mode for Canvas-based video playback."
  :group 'video
  (setq-local buffer-read-only t
              cursor-type nil
              truncate-lines t
              mode-line-position '((:eval (video--mode-line-position))))
  (add-hook 'kill-buffer-hook #'video--close-buffer-player nil t)
  (add-hook 'window-configuration-change-hook
            #'video--manage-window-targets nil t)
  (add-hook 'window-size-change-functions
            #'video--resize-window-targets nil t)
  (add-hook 'window-buffer-change-functions
            #'video--close-stale-window-targets nil t))

;;;###autoload
(defun video-open (source)
  "Open SOURCE in a dedicated `video-mode' buffer and begin playback."
  (interactive "fVideo file or URI: ")
  (let* ((name (if (string-match-p "://" source)
                   source
                 (file-name-nondirectory source)))
         (buffer (generate-new-buffer (format "*Video: %s*" name))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (insert " "))
      (video-mode)
      (setq video--buffer-player (video-player-create source)))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (video--manage-window-targets)
      (video-player-play video--buffer-player))
    buffer))

(defun video-inline-visible-p (inline)
  "Return non-nil when INLINE's display position is visible."
  (when-let* ((overlay (video-inline-overlay inline))
              ((overlayp overlay))
              (buffer (overlay-buffer overlay))
              (position (overlay-start overlay)))
    (cl-some (lambda (window)
               (pos-visible-in-window-p position window t))
             (get-buffer-window-list buffer nil t))))

(defun video--inline-after-change (&rest _ignored)
  "Close inline players whose display overlays were deleted."
  (dolist (inline (copy-sequence video--inline-objects))
    (unless (and (overlayp (video-inline-overlay inline))
                 (overlay-buffer (video-inline-overlay inline)))
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
    (if-let* ((player (video-inline-player inline)))
        (video-player-toggle player)
      (video-inline-play inline))))

(defvar-keymap video-inline-map
  :doc "Keymap installed on inline video occurrences."
  "RET" #'video-inline-toggle
  "SPC" #'video-inline-toggle
  "<mouse-1>" #'video-inline-toggle)

(cl-defun video-inline-insert
    (source poster width height &key (fit 'contain) (muted t))
  "Insert a lazy inline video occurrence for SOURCE.

POSTER is an image display descriptor or display value.  WIDTH and HEIGHT are
fixed Canvas dimensions.  FIT controls aspect treatment and MUTED controls the
initial audio policy.  Return the new `video-inline' object."
  (unless (and (integerp width) (> width 0)
               (integerp height) (> height 0))
    (error "Inline video dimensions must be positive integers"))
  (video--install-host-hooks)
  (let* ((start (point))
         (_ (insert " "))
         (overlay (make-overlay start (point) nil nil t))
         (inline (video--make-inline
                  :source source :poster poster :overlay overlay
                  :buffer (current-buffer)
                  :width width :height height :fit fit :muted muted)))
    (overlay-put overlay 'display (or poster "[Video]"))
    (overlay-put overlay 'keymap video-inline-map)
    (overlay-put overlay 'mouse-face 'highlight)
    (overlay-put overlay 'help-echo "mouse-1/RET: play or pause video")
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'video-inline inline)
    (push inline video--inline-objects)
    inline))

(defun video-inline-play (inline)
  "Create INLINE's lazy player if needed, then start playback."
  (when (video-inline-closed inline)
    (error "Inline video is closed"))
  (unless (video-player-p (video-inline-player inline))
    (let* ((player (video-player-create
                    (video-inline-source inline)
                    :muted (video-inline-muted inline)))
           (target (video-target-create
                    player (video-inline-width inline) (video-inline-height inline)
                    :fit (video-inline-fit inline))))
      (setf (video-inline-player inline) player
            (video-inline-target inline) target
            (video-target-inline target) inline)))
  (video-player-play (video-inline-player inline))
  inline)

(defun video-inline-close (inline)
  "Close INLINE and restore its poster when the occurrence still exists."
  (when (and (video-inline-p inline) (not (video-inline-closed inline)))
    (setf (video-inline-closed inline) t)
    (when-let* ((player (video-inline-player inline)))
      (video-player-close player))
    (when-let* ((overlay (video-inline-overlay inline))
                ((overlayp overlay))
                ((overlay-buffer overlay)))
      (overlay-put overlay 'display (or (video-inline-poster inline) "[Video]")))
    (when-let* ((buffer (video-inline-buffer inline))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (setq video--inline-objects (delq inline video--inline-objects))))
    (setf (video-inline-player inline) nil
          (video-inline-target inline) nil))
  nil)

(defun video--close-all-players ()
  "Close all live players before Emacs exits."
  (dolist (player (copy-sequence video--players))
    (video-player-close player)))

(add-hook 'kill-emacs-hook #'video--close-all-players)

(provide 'video)
;;; video.el ends here
