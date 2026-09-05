;;; video-view.el --- Dedicated windows for Canvas media  -*- lexical-binding: t; -*-

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

;; Dedicated window viewports, interactive controls, display policies, and
;; file-backed media viewing with Dired-aware navigation.

;;; Code:

(require 'video-runtime)
(require 'image-mode)
(require 'seq)

(defvar video--window-overlays nil
  "Dedicated window overlays, including windows awaiting detachment.")

(defun video--target-window (target)
  "Return the dedicated window whose overlay owns TARGET."
  (when-let* ((overlay
               (cl-find-if (lambda (overlay)
                             (eq (overlay-get overlay 'video-target) target))
                           video--window-overlays)))
    (overlay-get overlay 'window)))


(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))

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

(defvar-local video--buffer-player nil)
(defvar-local video--buffer-owns-player nil
  "Non-nil when the current media buffer must close its player.")
(defvar-local video--buffer-session nil)
(defvar-local video--buffer-session-lease nil)
(defvar-local video--directory-order nil
  "Media filenames in the originating Dired buffer's display order.")

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
(declare-function read--potential-mouse-event "mouse" ())
(defvar pixel-scroll-precision-coalesce-scroll-events)
(defvar pixel-scroll-precision-coalesce-maximum)

(defun video--view-visibility-change (&rest _ignored)
  "Reconcile the current dedicated buffer's player after visibility changes."
  (when (video-player-live-p video--buffer-player)
    (video--reconcile-player-visibility video--buffer-player)))

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
               (overlay (make-overlay (point-min) (point-max) buffer nil nil))
               (target (video-target-create
                        video--buffer-player (car size) (cdr size)
                        :fit (video--default-fit video--buffer-player)
                        :scale (video--view-scale view)
                        :x (video--view-x view) :y (video--view-y view)
                        :visible-function
                        (lambda (target)
                          (and (window-live-p window)
                               (eq (window-buffer window) (overlay-buffer overlay))
                               (eq (video--window-overlay window) overlay)
                               (eq (overlay-get overlay 'video-target) target)))
                        :prepare-function
                        (lambda (target)
                          (when (eq (video--window-overlay window) overlay)
                            (video--initialize-target-view target)))
                        :present-function
                        (lambda (target)
                          (when (and (window-live-p window)
                                     (eq (video--window-overlay window) overlay))
                            (overlay-put overlay 'display
                                         (video-target-canvas target))))
                        :close-function
                        (lambda (_target)
                          (when (and (windowp window)
                                     (eq (video--window-overlay window) overlay))
                            (video--cancel-pan window)
                            (set-window-parameter window 'video-overlay nil))
                          (setq video--window-overlays
                                (delq overlay video--window-overlays))
                          (overlay-put overlay 'video-target nil)
                          (delete-overlay overlay)))))
          (overlay-put overlay 'window window)
          ;; Keep the outgoing image visible until this target has a frame
          ;; rendered with its final viewport, not an empty Canvas.
          (overlay-put overlay 'display
                       (or (window-parameter window 'video-pending-image)
                           (video-target-canvas target)))
          (set-window-parameter window 'video-pending-image nil)
          (overlay-put overlay 'video-target target)
          (push overlay video--window-overlays)
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
  (dolist (overlay (copy-sequence video--window-overlays))
    (let ((window (overlay-get overlay 'window)))
      (unless (and (window-live-p window)
                   (eq (window-buffer window) (overlay-buffer overlay))
                   (eq (video--window-overlay window) overlay))
        (video--close-window-overlay overlay t)))))

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
    (video--view-visibility-change)))

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
  (when-let* ((window (video--target-window target))
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

(defun video-toggle-loop ()
  "Toggle repetition for the current player, shared by all presentations."
  (interactive)
  (video-player-toggle-loop video--buffer-player)
  (message "Media loop %s" (if (video-player-loop-p video--buffer-player)
                              "enabled" "disabled")))

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
  "Open the application's next media item, or the next local media file."
  (interactive)
  (if (functionp video-next-function)
      (funcall video-next-function)
    (video--directory-neighbor 1)))

(defun video-previous ()
  "Open the application's previous media item, or the previous local media file."
  (interactive)
  (if (functionp video-previous-function)
      (funcall video-previous-function)
    (video--directory-neighbor -1)))

(defun video-quit ()
  "Return from a presentation frame, then quit through the embedding application."
  (interactive)
  (when (frame-parameter nil 'video-presentation-frame)
    (video-toggle-frame))
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
  (when (and (video--target-window target)
             (null (video-target-scale target)))
    (video--fit-target target
                       (video--default-fit (video-target-player target)))))



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
  (when-let* ((window (video--target-window target)))
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
  "Q" #'kill-current-buffer
  "L" #'video-toggle-loop
  "F" #'video-toggle-frame)

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
  (add-hook 'window-scroll-functions #'video--view-visibility-change nil t)
  (add-hook 'window-configuration-change-hook
            #'video--manage-window-targets nil t)
  (add-hook 'window-size-change-functions
            #'video--resize-window-targets nil t)
  (add-hook 'window-buffer-change-functions
            #'video--close-stale-window-targets nil t)
  (add-hook 'kill-buffer-hook #'video--kill-presentation-frames nil t))

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
        (setq video--directory-order
              (video--dired-order (video-player-source player)))
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

(defun video--frame-return-window (frame)
  "Find a normal window for FRAME without replacing another media view."
  (let* ((buffer (frame-parameter frame 'video-presentation-buffer))
         (origin (frame-parameter frame 'video-return-window))
         (windows
          (cl-loop for candidate in (frame-list)
                   unless (or (eq candidate frame)
                              (frame-parameter candidate 'video-presentation-frame)
                              (not (eq (display-graphic-p candidate)
                                       (display-graphic-p frame))))
                   append (window-list candidate 'no-minibuffer))))
    (or (and (memq origin windows)
             (not (window-dedicated-p origin))
             (or (eq (window-buffer origin) buffer)
                 (not (with-current-buffer (window-buffer origin)
                        (derived-mode-p 'video-mode))))
             origin)
        (cl-find-if (lambda (window) (eq (window-buffer window) buffer)) windows)
        (cl-find-if
         (lambda (window)
           (and (not (window-dedicated-p window))
                (not (with-current-buffer (window-buffer window)
                       (derived-mode-p 'video-mode)))))
         windows))))



(defun video--return-from-frame (frame)
  "Return FRAME's media without copying its viewport into another window.
An existing ordinary view stays untouched.  Otherwise restore the original
window's saved viewport, never the detached frame's viewport."
  (when-let* ((buffer (frame-parameter frame 'video-presentation-buffer))
              ((buffer-live-p buffer))
              (destination (video--frame-return-window frame)))
    (unless (eq (window-buffer destination) buffer)
      (let ((view (frame-parameter frame 'video-return-view)))
        (with-current-buffer buffer
          (set-window-buffer destination buffer)
          (when (and (eq destination (frame-parameter frame 'video-return-window))
                     (video--view-p view)
                     (eq (video--view-buffer view) buffer))
            (when-let* ((overlay (video--window-overlay destination)))
              (video--close-window-overlay overlay t))
            (video--set-window-view destination (video--copy-view view buffer)))
          (video--activate-presented-buffer buffer)))
      (when (eq destination (frame-parameter frame 'video-return-window))
        (set-window-parameter destination 'quit-restore
                              (frame-parameter frame 'video-return-quit-restore))))
    (set-frame-parameter frame 'video-presentation-buffer nil)
    (select-frame-set-input-focus (window-frame destination))
    (select-window destination)
    destination))

(defun video--presentation-frame-deleted (frame)
  "Return media when the window manager closes its presentation FRAME."
  (when (and (frame-parameter frame 'video-presentation-frame)
             (frame-live-p frame))
    (video--return-from-frame frame)))

(defun video--kill-presentation-frames ()
  "Close frames owned by the media buffer being killed."
  (dolist (frame (frame-list))
    (when (eq (frame-parameter frame 'video-presentation-buffer) (current-buffer))
      ;; Do not redisplay a buffer whose kill hooks are already running.
      (set-frame-parameter frame 'video-presentation-buffer nil)
      (delete-frame frame))))

(defun video-toggle-frame ()
  "Move this media view between an ordinary window and a presentation frame.
Share the player and application callbacks, but keep window viewports independent.
Returning restores the ordinary view rather than copying the frame's pan or zoom.
Closing the frame through the window manager also returns to an ordinary view.
Use `video-quit' to leave the viewer and return to its embedding application."
  (interactive)
  (unless (derived-mode-p 'video-mode)
    (user-error "Current buffer is not a media view"))
  (let ((frame (selected-frame))
        (origin (selected-window))
        (buffer (current-buffer)))
    (if (frame-parameter frame 'video-presentation-frame)
        (progn
          (unless (video--return-from-frame frame)
            (user-error "No ordinary window available for this media view"))
          (delete-frame frame))
      (when (window-dedicated-p origin)
        (user-error "Cannot move media out of a dedicated window"))
      (video-display-buffer buffer #'video-display-buffer-other-frame)
      (video--activate-presented-buffer buffer)
      (switch-to-prev-buffer origin 'bury)
      (with-current-buffer buffer
        (video--manage-window-targets)))))

(add-hook 'delete-frame-functions #'video--presentation-frame-deleted)

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
The frame uses `video-other-frame-parameters' and remembers its return window."
  (let* ((origin (selected-window))
         (origin-view (and (eq (window-buffer origin) buffer)
                           (video--copy-view (video--window-view origin) buffer)))
         (current (and (frame-parameter nil 'video-presentation-frame)
                       (frame-selected-window (selected-frame))))
         (window (or current (video--presentation-window buffer)
                     (display-buffer
                      buffer
                      `(display-buffer-pop-up-frame
                        (pop-up-frame-parameters
                         . ,(video--presentation-frame-parameters)))))))
    (unless (window-live-p window)
      (error "Unable to display media in another frame"))
    (let ((frame (window-frame window)))
      (unless (eq (window-frame origin) frame)
        (set-frame-parameter frame 'video-return-window origin)
        (set-frame-parameter frame 'video-return-view origin-view)
        (set-frame-parameter frame 'video-return-quit-restore
                             (window-parameter origin 'quit-restore)))
      (set-window-dedicated-p window nil)
      (set-window-buffer window buffer)
      (set-frame-parameter frame 'video-presentation-buffer buffer))
    (video--configure-presentation-window window)))

(defun video-display-buffer (buffer &optional display-function)
  "Display media BUFFER and return its live window.
Use DISPLAY-FUNCTION when non-nil, otherwise keep an active presentation
frame or use `video-display-buffer-function'.  Run
`video-pre-display-buffer-hook' before display and
`video-post-display-buffer-hook' afterward.  Unless
`video-display-buffer-noselect' is non-nil, select the returned window and give
its frame input focus."
  (with-current-buffer buffer
    (run-hooks 'video-pre-display-buffer-hook))
  (let ((window (funcall (or display-function
                             (and (frame-parameter nil 'video-presentation-frame)
                                  #'video-display-buffer-other-frame)
                             video-display-buffer-function)
                         buffer)))
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
  (setq kind (or kind (video-source-kind source)))
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'buffer-file-name buffer))
    (user-error "Cannot replace a file buffer with a media presentation"))
  (let ((file (and (eq kind 'image) (not (buffer-live-p buffer))
                   (video-source-file source))))
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

(defcustom video-image-file-extensions '("png" "jpg" "jpeg" "gif" "bmp" "webp" "avif" "svg" "tif" "tiff")
  "Local image extensions claimed by `video-image-auto-mode'.
Formats still require the corresponding GStreamer decoder.  Remote files
and displays without Canvas support continue to use `image-mode'."
  :type '(repeat string)
  :group 'video)

(defcustom video-video-file-extensions '("mp4" "mov" "mkv" "webm" "avi" "flv" "m4v")
  "Local video extensions included in directory navigation.
Together with `video-image-file-extensions', these select files for
`video-next' and `video-previous'.  Decoding requires the corresponding
GStreamer plugin; this option does not change file-mode selection."
  :type '(repeat string)
  :group 'video)

(defvar video--image-auto-mode-entry nil
  "Exact entry installed by `video-image-auto-mode'.")

(defun video--media-file-p (file)
  "Return non-nil if FILE is a readable local image or video filename."
  (and (stringp file) (not (file-remote-p file))
       (let ((extension (downcase (or (file-name-extension file) ""))))
         (or (member extension video-image-file-extensions)
             (member extension video-video-file-extensions)))
       (file-regular-p file) (file-readable-p file)))

(defun video--dired-order (source)
  "Return local SOURCE's directory media in the selected Dired window's order."
  (let ((file (and source (video-source-file source)))
        (origin (window-buffer (selected-window)))
        files)
    (when file
      (with-current-buffer origin
        (when (derived-mode-p 'dired-mode)
          (save-excursion
            (goto-char (point-min))
            (while (not (eobp))
              (when-let* ((name (dired-get-filename nil t))
                          ((equal (file-name-directory name)
                                  (file-name-directory file)))
                          ((video--media-file-p name)))
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
  (video--file-load)
  (setq-local video--directory-order (video--dired-order buffer-file-name)))

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
  (video--file-initialize))

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
   ((eq (video-source-kind buffer-file-name) 'image)
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

(defun video--directory-neighbor (step)
  "Visit the media file STEP places away, respecting the originating Dired order."
  (let* ((file (or buffer-file-name
                   (and (video-player-p video--buffer-player)
                        (video-source-file
                         (video-player-source video--buffer-player)))))
         (directory (and file (file-name-directory file))))
    (unless (and directory (video--media-file-p file))
      (user-error "Current media has no local media directory"))
    (let* ((files (seq-filter #'video--media-file-p
                             (or video--directory-order
                                 (directory-files directory t nil t))))
           (files (if video--directory-order files
                    (sort files #'string-lessp)))
           (index (cl-position file files :test #'equal)))
      (unless (and index (> (length files) 1))
        (user-error "No other media in this directory"))
      (let* ((origin (current-buffer))
             (order video--directory-order)
             (buffer (video-open (nth (mod (+ index step) (length files)) files))))
        (with-current-buffer buffer
          (setq video--directory-order order))
        ;; Keep borrowed players and media still displayed in another window.
        ;; Retire hidden file/session presentations instead of leaking decoders.
        (when (and (buffer-live-p origin)
                   (or (buffer-local-value 'buffer-file-name origin)
                       (buffer-local-value 'video--buffer-session-lease origin))
                   (not (buffer-modified-p origin))
                   (not (get-buffer-window origin t)))
          (kill-buffer origin))))))

(define-key video-mode-map (kbd "1") #'video-original-size)
(define-key video-mode-map (kbd "s") #'video-set-scale)
(define-key video-image-mode-map (kbd "C-c C-c") #'video-image-native)

(provide 'video-view)
;;; video-view.el ends here
