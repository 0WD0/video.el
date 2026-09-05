;;; video-inline.el --- Inline occurrences for Canvas media  -*- lexical-binding: t; -*-

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

;; Lazy inline occurrences and their host lifecycle, including poster-to-frame
;; activation and explicit player or session ownership.

;;; Code:

(require 'video-runtime)
(defvar-local video--inline-objects nil)
(defvar-local video--inline-hooks-installed nil)

(declare-function video-session-present "video-view"
                  (session &rest args))
(declare-function video-present-player "video-view"
                  (player &rest args))
(declare-function video-display-buffer-other-frame "video-view" (buffer))

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
  closed
  presentation-buffer)

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

(defun video--inline-visibility-change (&rest _ignored)
  "Reconcile inline players in the current buffer after visibility changes."
  (dolist (inline video--inline-objects)
    (when-let* ((player (video-inline-player inline)))
      (video--reconcile-player-visibility player))))

(defun video--install-inline-hooks ()
  "Install buffer-local lifecycle hooks for inline video hosts."
  (unless video--inline-hooks-installed
    (setq video--inline-hooks-installed t)
    (add-hook 'after-change-functions #'video--inline-after-change nil t)
    (add-hook 'window-scroll-functions #'video--inline-visibility-change nil t)
    (add-hook 'window-configuration-change-hook
              #'video--inline-visibility-change nil t)
    (add-hook 'change-major-mode-hook #'video--close-inline-objects nil t)
    (add-hook 'kill-buffer-hook #'video--close-inline-objects nil t)))

(defun video--close-inline-objects ()
  "Close every inline video occurrence in the current buffer."
  (dolist (inline (copy-sequence video--inline-objects))
    (video-inline-close inline)))

(defun video--inline-at-event (&optional event)
  "Return the live inline occurrence at mouse EVENT or point.
Keyboard events resolve at point.  Mouse events use their own window's
buffer, which need not be the selected buffer."
  (let* ((mouse (mouse-event-p event))
         (window (and mouse (video--event-window event t)))
         (buffer (if mouse
                     (and window (window-buffer window))
                   (current-buffer)))
         (position (if mouse
                       (posn-point (event-end event))
                     (point))))
    (when (consp position)
      (setq position (car position)))
    (unless (and (buffer-live-p buffer)
                 (integer-or-marker-p position))
      (user-error "No inline video at this event"))
    (let ((inline
            (with-current-buffer buffer
              (cl-loop for overlay in (overlays-at position)
                       for occurrence = (overlay-get overlay 'video-inline)
                       when (video-inline-p occurrence) return occurrence))))
      (unless inline
        (user-error "No inline video at this position"))
      (when (or (video-inline-closed inline)
                (not (video-inline-live-p inline))
                (and (video-inline-player inline)
                     (not (video-player-live-p (video-inline-player inline)))))
        (user-error "Inline video is closed"))
      inline)))

(defun video-inline-toggle (&optional event)
  "Toggle the inline video occurrence at EVENT or point."
  (interactive (list last-input-event))
  (video-inline-toggle-occurrence (video--inline-at-event event)))

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
  "<return>" #'video-inline-toggle
  "L" #'video-inline-loop
  "m" #'video-inline-mute
  "F" #'video-inline-frame
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
      (video--install-inline-hooks)
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
         (overlay (make-overlay start (point) nil t nil))
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
  "Prepare INLINE's target and toggle its player's playback."
  (video-inline-prepare inline)
  (video-player-toggle (video-inline-player inline)))

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

(defun video-inline-loop (&optional event)
  "Toggle repetition for the inline video at EVENT or point."
  (interactive (list last-input-event))
  (let ((inline (video-inline-toggle-loop (video--inline-at-event event))))
    (message "Media loop %s"
             (if (video-player-loop-p (video-inline-player inline))
                 "enabled" "disabled"))))

(defun video-inline-mute (&optional event)
  "Toggle audio output for the inline video at EVENT or point."
  (interactive (list last-input-event))
  (video-inline-toggle-muted (video--inline-at-event event)))

(defun video-inline-frame (&optional event)
  "Present the inline video at EVENT or point in an independent frame."
  (interactive (list last-input-event))
  (video-inline-present (video--inline-at-event event)))

(defun video-inline-toggle-loop (inline)
  "Toggle repetition for INLINE without starting or initializing playback.
The player must already be initialized.  Its runtime capability policy
controls whether repetition can be enabled or disabled."
  (when (video-inline-closed inline)
    (user-error "Inline video is closed"))
  (let ((player (video-inline-player inline)))
    (unless player
      (user-error "Initialize the inline video before changing loop state"))
    (unless (video-player-live-p player)
      (user-error "Inline video player is closed"))
    (video-player-toggle-loop player))
  inline)

(defun video-inline-prepare (inline)
  "Create INLINE's lazy player and target without changing playback state.
Internally created players belong to a session retained by INLINE, so a
separate presentation can outlive the inline occurrence."
  (when (video-inline-closed inline)
    (user-error "Inline video is closed"))
  (unless (video-inline-player inline)
    (let* ((session
            (video-session-create
             (video-inline-source inline)
             :muted (video-inline-muted inline)
             :live (video-inline-live inline)
             :request-headers (video-inline-request-headers inline)))
           (lease
            (condition-case error-data
                (video--session-acquire session inline #'video-inline-close)
              ((error quit)
               (video-session-close session)
               (signal (car error-data) (cdr error-data))))))
      (setf (video-inline-player inline) (video-session-player session)
            (video-inline-session inline) session
            (video-inline-session-lease inline) lease
            (video-inline-owns-player inline) nil)))
  (let ((player (video-inline-player inline)))
    (unless (video-player-live-p player)
      (user-error "Inline video player is closed"))
    (unless (video-target-p (video-inline-target inline))
      (let ((target
             (video-target-create
              player (video-inline-width inline) (video-inline-height inline)
              :fit (video-inline-fit inline)
              :canvas (video-inline-canvas inline)
              :canvas-width (video-inline-canvas-width inline)
              :canvas-height (video-inline-canvas-height inline)
              :destination-x (video-inline-destination-x inline)
              :destination-y (video-inline-destination-y inline)
              :visible-function
              (lambda (_target)
                (and (not (video-inline-closed inline))
                     (video-inline-visible-p inline)))
              :present-function
              (lambda (target)
                (unless (video-inline-active inline)
                  (setf (video-inline-active inline) t)
                  (if-let* ((activate (video-inline-activate-function inline)))
                      (funcall activate inline (video-target-canvas target))
                    (when (overlayp (video-inline-overlay inline))
                      (overlay-put (video-inline-overlay inline) 'display
                                   (video-target-canvas target))))))
              :close-function
              (lambda (_target)
                (video-inline-close inline)))))
        (setf (video-inline-target inline) target))))
  inline)

(defun video-inline-present (inline &optional display-function)
  "Present INLINE separately without changing its player's playback state.
Initialize a lazy player and inline target without autoplay.  Reuse INLINE's
live presentation buffer while it still presents the same player and session.
DISPLAY-FUNCTION defaults to an independent presentation frame.  Return the
presentation buffer, retaining a session or borrowing an explicit player."
  (require 'video-view)
  (video-inline-prepare inline)
  (let* ((player (video-inline-player inline))
         (session (video-inline-session inline))
         (buffer (video-inline-presentation-buffer inline))
         (buffer (and (buffer-live-p buffer)
                      (eq (buffer-local-value 'video--buffer-player buffer)
                          player)
                      (eq (buffer-local-value 'video--buffer-session buffer)
                          session)
                      buffer))
         (display-function (or display-function
                               #'video-display-buffer-other-frame)))
    (setf (video-inline-presentation-buffer inline)
          (if session
              (video-session-present session :buffer buffer
                                     :display-function display-function)
            (video-present-player player :buffer buffer
                                  :display-function display-function)))))

(defun video-inline-play (inline)
  "Create INLINE's lazy player or target as needed, then start playback."
  (video-inline-prepare inline)
  (video-player-play (video-inline-player inline))
  inline)

(defun video-inline-close (inline)
  "Close INLINE's target and release its player or session ownership.

A low-level borrowed player remains live.  A session-backed occurrence,
including a lazily initialized one, releases its presentation lease; the
session keeps its player alive while another presentation retains it."
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
            (video-inline-target inline) nil
            (video-inline-active inline) nil
            (video-inline-visible-function inline) nil
            (video-inline-alive-function inline) nil
            (video-inline-activate-function inline) nil
            (video-inline-presentation-buffer inline) nil)
      (when lease
        (video--session-release lease)))
    (when-let* ((close-function (video-inline-close-function inline)))
      (setf (video-inline-close-function inline) nil)
      (funcall close-function inline)))
  nil)

(provide 'video-inline)
;;; video-inline.el ends here
