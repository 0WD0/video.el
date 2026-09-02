;;; video-test.el --- Tests for video.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 0WD0
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'video)

(defconst video-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the video.el tests.")

(defun video-test--fixture ()
  "Return the absolute test video fixture name."
  (expand-file-name "fixtures/test.webm" video-test--directory))

(ert-deftest video-normalize-source-converts-local-file-to-uri ()
  (let ((uri (video--normalize-source (video-test--fixture))))
    (should (string-prefix-p "file:///" uri))
    (should (string-suffix-p "test.webm" uri))))

(ert-deftest video-normalize-source-retains-network-uri ()
  (should (equal (video--normalize-source "https://example.test/video.mp4")
                 "https://example.test/video.mp4")))

(ert-deftest video-canvas-descriptors-own-their-property-lists ()
  (let ((first (video-canvas-create 320 180))
        (second (video-canvas-create 180 320)))
    (plist-put (cdr first) :height 180)
    (plist-put (cdr first) :map 'first-map)
    (should (= (plist-get (cdr first) :height) 180))
    (should (eq (plist-get (cdr first) :map) 'first-map))
    (should-not (plist-member (cdr second) :height))
    (should-not (plist-member (cdr second) :map))))

(ert-deftest video-player-audio-setters-cache-authoritative-values ()
  (let ((player (video--make-player :handle 'native))
        volume-call
        mute-call)
    (cl-letf (((symbol-function 'video-native-set-volume)
               (lambda (&rest args) (setq volume-call args)))
              ((symbol-function 'video-native-set-muted)
               (lambda (&rest args) (setq mute-call args))))
      (video-player-set-volume player 2.0)
      (video-player-set-muted player t))
    (should (= (video-player-volume player) 1.0))
    (should (video-player-muted player))
    (should (equal volume-call '(native 1.0)))
    (should (equal mute-call '(native t)))))

(ert-deftest video-inline-mute-control-updates-lazy-and-active-state ()
  (let* ((player (video--make-player :handle 'native))
         (inline (video--make-inline :muted t :player player))
         mute-call)
    (cl-letf (((symbol-function 'video-native-set-muted)
               (lambda (&rest arguments)
                 (setq mute-call arguments))))
      (video-inline-toggle-muted inline))
    (should-not (video-inline-muted inline))
    (should-not (video-player-muted player))
    (should (equal mute-call '(native nil)))
    (setf (video-inline-player inline) nil)
    (video-inline-set-muted inline t)
    (should (video-inline-muted inline))))

(ert-deftest video-player-restarts-from-zero-after-end-of-stream ()
  (let ((player (video--make-player
                 :handle 'native :position 10.0 :duration 10.0))
        seek-call)
    (cl-letf (((symbol-function 'video-native-seek)
               (lambda (&rest arguments)
                 (setq seek-call arguments)))
              ((symbol-function 'video--reconcile-player-visibility) #'ignore)
              ((symbol-function 'video--show-player-controls) #'ignore))
      (video-player-play player))
    (should (equal seek-call '(native 0.0)))
    (should (= (video-player-position player) 0.0))
    (should (eq (video-player-desired-state player) 'playing))))

(ert-deftest video-visibility-reconcile-starts-only-on-transition ()
  (let* ((player (video--make-player :handle 'native))
         (target (video--make-target :player player))
         (play-count 0))
    (setf (video-player-targets player) (list target))
    (cl-letf (((symbol-function 'video-native-play)
               (lambda (_handle) (cl-incf play-count)))
              ((symbol-function 'video--show-player-controls) #'ignore))
      (video-player-play player)
      (should (= play-count 1))
      (should-not (video-player-suspended player))
      (video--reconcile-player-visibility player)
      (should (= play-count 1)))))

(ert-deftest video-target-controls-preserve-host-image-map ()
  (let* ((host-entry '((rect . ((0 . 0) . (20 . 20)))
                       host-media nil))
         (canvas `(image :type canvas :map (,host-entry)))
         (player (video--make-player :handle 'native))
         (target (video--make-target
                  :player player :canvas canvas
                  :width 100 :height 80
                  :canvas-width 100 :canvas-height 80)))
    (video--install-target-control-map target)
    (let ((map (plist-get (cdr canvas) :map)))
      (should
       (equal (mapcar #'cadr (seq-take map 3))
              video--control-map-ids))
      (should (equal (car (last map)) host-entry)))))

(ert-deftest video-inline-binds-generic-transport-hotspots ()
  (let ((inline (video--make-inline))
        (map (make-sparse-keymap)))
    (video-inline-bind-controls inline map)
    (should (commandp (lookup-key map [video-control-toggle mouse-1])))
    (should (commandp (lookup-key map [video-control-mute mouse-1])))
    (should (commandp (lookup-key map [video-control-seek mouse-1])))
    (should (commandp (lookup-key map [mouse-movement])))))


(ert-deftest video-progress-hotspot-seeks-with-native-layout ()
  (let* ((player (video--make-player
                  :handle 'native :duration 100.0))
         (target (video--make-target
                  :player player :width 200 :height 100
                  :destination-x 0 :destination-y 0))
         (seek-rectangle
          (aref (video--target-control-layout target) 2))
         (event-x (+ (aref seek-rectangle 0)
                     (/ (aref seek-rectangle 2) 2.0)))
         seek-call)
    (cl-letf (((symbol-function 'video--event-canvas-x)
               (lambda (_event) event-x))
              ((symbol-function 'video-native-seek)
               (lambda (&rest arguments)
                 (setq seek-call arguments)))
              ((symbol-function 'video--show-player-controls) #'ignore))
      (video--seek-target-from-event target 'event))
    (should (equal seek-call '(native 50.0)))))

(ert-deftest video-controls-fade-only-during-playback ()
  (let* ((player (video--make-player :handle 'native))
         (target (video--make-target :player player :controls-until 0.0)))
    (should (= (video--target-controls-opacity target) 0.9))
    (setf (video-player-desired-state player) 'playing)
    (should (= (video--target-controls-opacity target) 0.0))
    (setf (video-target-controls-until target) (+ (float-time) 10.0))
    (should (= (video--target-controls-opacity target) 0.9))))

(ert-deftest video-target-set-view-mutates-one-canvas-identity ()
  (let* ((player (video--make-player :handle 'player))
         (canvas (video--make-canvas 20 10))
         (target (video--make-target
                  :player player :handle 'target :canvas canvas
                  :width 20 :height 10 :canvas-width 20 :canvas-height 10
                  :canvas-follows-target t))
         native-call)
    (cl-letf (((symbol-function 'video-native-target-set-view)
               (lambda (&rest args) (setq native-call args))))
      (video-target-set-view target 40 30 2.0 5.0 7.0 'cover))
    (should (eq canvas (video-target-canvas target)))
    (should (= (plist-get (cdr canvas) :data-width) 40))
    (should (= (plist-get (cdr canvas) :data-height) 30))
    (should (equal native-call '(target 40 30 "cover" 2.0 5.0 7.0)))))

(ert-deftest video-target-view-keeps-host-owned-scene-dimensions ()
  (let* ((player (video--make-player :handle 'player))
         (canvas (video-canvas-create 100 80))
         (target (video--make-target
                  :player player :handle 'target :canvas canvas
                  :width 20 :height 10 :canvas-width 100 :canvas-height 80
                  :destination-x 30 :destination-y 40))
         native-call)
    (cl-letf (((symbol-function 'video-native-target-set-view)
               (lambda (&rest args) (setq native-call args))))
      (video-target-set-view target 40 30 1.0 5.0 6.0 'cover))
    (should (= (video-target-canvas-width target) 100))
    (should (= (video-target-canvas-height target) 80))
    (should (= (plist-get (cdr canvas) :data-width) 100))
    (should (equal native-call '(target 40 30 "cover" 1.0 5.0 6.0)))))

(ert-deftest video-pan-follows-pointer-direction ()
  (let* ((player (video--make-player :handle 'player :width 400 :height 200))
         (target (video--make-target
                  :player player :handle 'target
                  :canvas (video--make-canvas 200 100)
                  :width 200 :height 100 :fit 'contain
                  :scale 1.0 :x 100.0 :y 50.0))
         native-call)
    (cl-letf (((symbol-function 'video-native-target-set-view)
               (lambda (&rest args) (setq native-call args))))
      (video--apply-pan target 20.0 10.0))
    ;; A right/down hand movement reveals content to the left/up.
    (should (= (video-target-x target) 80.0))
    (should (= (video-target-y target) 40.0))
    (should (equal (car native-call) 'target))))

(ert-deftest video-window-resize-preserves-absolute-media-scale ()
  "Changing viewport size must not redefine the virtual media size."
  (let* ((player (video--make-player :handle 'player :width 400 :height 200))
         (target (video--make-target
                  :player player :handle 'target
                  :canvas (video--make-canvas 200 100)
                  :width 200 :height 100 :fit 'contain
                  :canvas-follows-target t))
         native-call)
    (cl-letf (((symbol-function 'video-native-target-set-view)
               (lambda (&rest args) (setq native-call args))))
      (video--fit-target target 'contain)
      (setf (video-target-width target) 100
            (video-target-height target) 50)
      (video--sync-target target))
    (should (= (video-target-scale target) 0.5))
    (should (= (plist-get (cdr (video-target-canvas target)) :data-width) 100))
    (should (equal (seq-take native-call 5)
                   '(target 100 50 "contain" 0.5)))))

(ert-deftest video-window-views-copy-independent-absolute-viewports ()
  "Two windows may share a player without sharing scale or origin."
  (let* ((buffer (current-buffer))
         (first (video--make-view :buffer buffer :scale 2.0 :x 40.0 :y 20.0))
         (second (video--copy-view first buffer)))
    (setf (video--view-scale second) 3.0
          (video--view-x second) 90.0)
    (should-not (eq first second))
    (should (= (video--view-scale first) 2.0))
    (should (= (video--view-x first) 40.0))
    (should (= (video--view-scale second) 3.0))
    (should (= (video--view-x second) 90.0))))

(ert-deftest video-mouse-pan-coalesces-direct-hand-motion ()
  (let* ((window (selected-window))
         (start-position (list window (point-min) (cons 10 20) 0))
         (end-position (list window (point-min) (cons 25 32) 0))
         (start-event (list 'down-mouse-2 start-position))
         (events (list (list 'mouse-movement end-position)
                       (list 'mouse-2 end-position)))
         requests
         (unread-command-events nil))
    (cl-letf (((symbol-function 'video--window-target-valid-p)
               (lambda (_window) t))
              ((symbol-function 'video--cancel-pan) #'ignore)
              ((symbol-function 'read--potential-mouse-event)
               (lambda (&rest _args)
                 (or (pop events) (ert-fail "mouse pan read past release"))))
              ((symbol-function 'video--queue-pan)
               (lambda (&rest args) (push args requests))))
      (video-mouse-pan start-event))
    (should (equal requests (list (list window 15.0 12.0))))
    (should-not unread-command-events)))

(ert-deftest video-mouse-pan-replays-an-unmoved-middle-click ()
  (let* ((window (selected-window))
         (position (list window (point-min) (cons 10 20) 0))
         (start-event (list 'down-mouse-2 position))
         (events (list (list 'mouse-2 position)))
         (unread-command-events nil))
    (cl-letf (((symbol-function 'video--window-target-valid-p)
               (lambda (_window) t))
              ((symbol-function 'video--cancel-pan) #'ignore)
              ((symbol-function 'read--potential-mouse-event)
               (lambda (&rest _args)
                 (or (pop events) (ert-fail "mouse pan read past release")))))
      (video-mouse-pan start-event))
    (should (equal unread-command-events
                   (list (cons 'mouse-2 (cdr start-event)))))))

(ert-deftest video-inline-insertion-is-lazy ()
  (with-temp-buffer
    (let ((inline (video-inline-insert
                   "https://example.test/video.mp4" 'poster 120 80)))
      (should (overlayp (video-inline-overlay inline)))
      (should (eq (overlay-get (video-inline-overlay inline) 'display) 'poster))
      (should-not (video-inline-player inline))
      (video-inline-close inline)
      (should (video-inline-closed inline)))))

(ert-deftest video-native-draws-a-poster-into-a-scene-canvas ()
  (skip-unless (and (featurep 'video-module)
                    (image-type-available-p 'canvas)
                    (file-readable-p (video-test--fixture))))
  (let ((canvas `(image :type canvas :id ,(gensym "video-scene-test-")
                        :data-width 200 :data-height 120)))
    (should
     (video-native-canvas-draw-uri
      canvas 200 120
      (video--normalize-source (video-test--fixture))
      20 15 160 90 "cover"))
    (should
     (video-native-canvas-draw-uri
      canvas 200 120
      (video--normalize-source (video-test--fixture))
      -80 -45 160 90 "cover"))
    (should
     (video-native-canvas-draw-controls
      canvas 200 120 20 15 160 90 t 5.0 10.0 nil 0.9))))

(ert-deftest video-native-decodes-and-copies-a-frame ()
  (skip-unless (and (featurep 'video-module)
                    (image-type-available-p 'canvas)
                    (file-readable-p (video-test--fixture))))
  (let* ((process (make-pipe-process
                   :name " video-native-test"
                   :buffer nil
                   :coding 'no-conversion
                   :noquery t
                   :filter #'ignore))
         (canvas `(image :type canvas :id ,(gensym "video-test-")
                         :data-width 160 :data-height 90))
         player target sequence state)
    (unwind-protect
        (progn
          (setq player
                (video-native-create
                 (video--normalize-source (video-test--fixture)) process))
          (setq target
                (video-native-target-create
                 player 160 90 "contain" 1.0 0.5 0.5))
          (video-native-play player)
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (not sequence) (< (float-time) deadline))
              (accept-process-output process 0.1)
              (setq state (video-native-poll player))
              (setq sequence
                    (video-native-target-copy target canvas 160 90 0 0))))
          (should (integerp sequence))
          (should (> sequence 0))
          (let ((clipped-sequence
                 (video-native-target-copy
                  target canvas 160 90 -80 -45)))
            (should (integerp clipped-sequence))
            (should (>= clipped-sequence sequence)))
          (should (plist-member state :state))
          (should-not (plist-get state :error)))
      (when target
        (ignore-errors (video-native-target-close target)))
      (when player
        (ignore-errors (video-native-close player)))
      (when (process-live-p process)
        (delete-process process)))))

(provide 'video-test)
;;; video-test.el ends here
