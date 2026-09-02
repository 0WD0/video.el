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
    (should (equal seek-call '(native 50.0)))
    (should (= (video-player-position player) 50.0))))

(ert-deftest video-controls-fade-only-during-playback ()
  (let* ((player (video--make-player :handle 'native))
         (target (video--make-target :player player :controls-until 0.0)))
    (should (= (video--target-controls-opacity target) 0.9))
    (setf (video-player-desired-state player) 'playing)
    (should (= (video--target-controls-opacity target) 0.0))
    (setf (video-target-controls-until target) (+ (float-time) 10.0))
    (should (= (video--target-controls-opacity target) 0.9))))

(ert-deftest video-network-waiting-state-excludes-local-and-paused-media ()
  (let ((remote (video--make-player
                 :source "https://example.test/video.mp4"
                 :kind 'video :desired-state 'playing
                 :state 'buffering :buffering 25))
        (local (video--make-player
                :source "file:///tmp/video.mp4"
                :kind 'video :desired-state 'playing
                :state 'buffering :buffering 25)))
    (should (video--player-waiting-p remote))
    (should-not (video--player-waiting-p local))
    (setf (video-player-desired-state remote) 'paused)
    (should-not (video--player-waiting-p remote))))

(ert-deftest video-buffered-ranges-normalize-for-transport-drawing ()
  (let ((player (video--make-player
                 :handle 'native :duration 100.0)))
    (cl-letf (((symbol-function 'video-native-buffered-ranges)
               (lambda (handle)
                 (should (eq handle 'native))
                 '((0.0 . 25.0) (50.0 . 75.0)))))
      (should
       (equal (video-player-buffered-ranges player)
              '((0.0 . 25.0) (50.0 . 75.0)))))
    (should
     (equal (video-player-buffered-range-vector player)
            [0.0 0.25 0.5 0.75]))))

(ert-deftest video-buffering-ui-passes-waiting-state-and-ranges ()
  (let* ((player
          (video--make-player
           :source "https://example.test/video.mp4"
           :kind 'video :desired-state 'playing :state 'buffering
           :position 10.0 :duration 100.0 :buffering 35
           :buffered-range-vector [0.0 0.5]
           :buffered-ranges-updated-at (float-time)))
         (target
          (video--make-target
           :player player :canvas 'canvas
           :canvas-width 200 :canvas-height 120
           :destination-x 10 :destination-y 15
           :width 180 :height 90 :presented-frame t
           :controls-until (+ (float-time) 10.0)))
         arguments)
    (cl-letf (((symbol-function 'video-native-canvas-draw-controls)
               (lambda (&rest values) (setq arguments values))))
      (video--draw-target-controls target))
    (should (nth 12 arguments))
    (should (= (nth 13 arguments) 35.0))
    (should (nth 14 arguments))
    (should (equal (nth 15 arguments) [0.0 0.5]))))

(ert-deftest video-mode-line-reports-network-buffering ()
  (with-temp-buffer
    (setq video--buffer-player
          (video--make-player
           :source "https://example.test/video.mp4"
           :kind 'video :handle 'native :desired-state 'playing
           :state 'buffering :buffering 42
           :position 5.0 :duration 10.0))
    (should
     (equal (video--mode-line-position)
            " Buffering 42% 00:05 / 00:10"))))

(ert-deftest video-complete-progressive-cache-is-promoted-atomically ()
  (let* ((directory (make-temp-file "video-cache-test" t))
         (location (expand-file-name "incoming.part" directory))
         (target (expand-file-name "stable/video.mp4" directory))
         callback)
    (unwind-protect
        (progn
          (make-directory (file-name-directory target) t)
          (with-temp-file location
            (insert "complete media"))
          (let ((player
                 (video--make-player
                  :cache-file target
                  :cache-complete-function
                  (lambda (actual-player file)
                    (setq callback (list actual-player file))))))
            (should
             (equal (video--commit-network-cache player location) target))
            (should (equal callback (list player target)))
            (should (file-regular-p target))
            (should-not (file-exists-p location))
            (should-not (video-player-cache-error player))))
      (delete-directory directory t))))

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

(ert-deftest video-target-view-preserves-signed-viewport-origins ()
  (let* ((player (video--make-player :handle 'player))
         (target (video--make-target
                  :player player :handle 'target
                  :canvas (video--make-canvas 200 100)
                  :width 200 :height 100
                  :canvas-width 200 :canvas-height 100))
         native-call)
    (cl-letf (((symbol-function 'video-native-target-set-view)
               (lambda (&rest args) (setq native-call args))))
      (video-target-set-view target 200 100 1.0 -45.5 80.25 'contain))
    (should (= (video-target-x target) -45.5))
    (should (= (video-target-y target) 80.25))
    (should (equal native-call
                   '(target 200 100 "contain" 1.0 -45.5 80.25)))))

(ert-deftest video-fit-centers-small-media-with-negative-origin ()
  (let* ((player (video--make-player
                  :handle 'player :width 100 :height 50))
         (target (video--make-target
                  :player player :handle 'target
                  :canvas (video--make-canvas 200 200)
                  :width 200 :height 200
                  :canvas-width 200 :canvas-height 200))
         native-call)
    (cl-letf (((symbol-function 'video-native-target-set-view)
               (lambda (&rest args) (setq native-call args))))
      (video--fit-target target 'contain))
    (should (= (video-target-scale target) 2.0))
    (should (= (video-target-x target) 0.0))
    (should (= (video-target-y target) -50.0))
    (should (equal native-call
                   '(target 200 200 "contain" 2.0 0.0 -50.0)))))

(ert-deftest video-pan-follows-pointer-beyond-media-edges ()
  (let* ((player (video--make-player :handle 'player :width 400 :height 200))
         (target (video--make-target
                  :player player :handle 'target
                  :canvas (video--make-canvas 200 100)
                  :width 200 :height 100 :fit 'contain
                  :scale 1.0 :x 10.0 :y 5.0))
         native-call)
    (cl-letf (((symbol-function 'video-native-target-set-view)
               (lambda (&rest args) (setq native-call args))))
      (video--apply-pan target 20.0 10.0))
    (should (= (video-target-x target) -10.0))
    (should (= (video-target-y target) -5.0))
    (should (equal (car native-call) 'target))))

(ert-deftest video-wheel-pan-preserves-raw-two-axis-device-deltas ()
  (let* ((window (selected-window))
         (position (list window (point-min) (cons 20 30) 0))
         (event (list 'wheel-down position 1 nil (cons 1.25 -2.5)))
         request
         (unread-command-events nil))
    (cl-letf (((symbol-function 'video--window-target-valid-p)
               (lambda (_window) t))
              ((symbol-function 'read-event)
               (lambda (&rest _args) nil))
              ((symbol-function 'video--queue-pan)
               (lambda (&rest args) (setq request args))))
      (video-wheel-pan event))
    (should (equal request (list window 1.25 -2.5)))))

(ert-deftest video-text-scale-adjust-changes-media-scale ()
  (let* ((player (video--make-player
                  :handle 'player :width 400 :height 200))
         (target (video--make-target
                  :player player :handle 'target
                  :canvas (video--make-canvas 200 100)
                  :width 200 :height 100 :fit 'contain
                  :scale 2.0 :x 300.0 :y 150.0))
         (this-original-command 'text-scale-decrease))
    (cl-letf (((symbol-function 'video--current-target)
               (lambda () target))
              ((symbol-function 'video-native-target-set-view) #'ignore))
      (video-scale-adjust 1))
    (should (= (video-target-scale target) 1.6))))

(ert-deftest video-mode-remaps-text-scale-commands ()
  (should (eq (lookup-key video-mode-map [remap text-scale-increase])
              #'video-scale-adjust))
  (should (eq (lookup-key video-mode-map [remap text-scale-decrease])
              #'video-scale-adjust))
  (should (eq (lookup-key video-mode-map [remap text-scale-adjust])
              #'video-scale-adjust)))

(ert-deftest video-mode-window-buffer-hook-accepts-window-argument ()
  (with-temp-buffer
    (video-mode)
    (should
     (memq #'video--close-stale-window-targets
           window-buffer-change-functions))
    (let ((video--players nil))
      (run-hook-with-args
       'window-buffer-change-functions (selected-window)))))

(ert-deftest video-display-buffer-runs-policy-hooks-and-selects-window ()
  (let ((buffer (generate-new-buffer " *video-display-test*"))
        events)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((origin (selected-window))
                (target (split-window-right)))
            (set-window-buffer target buffer)
            (select-window origin)
            (let ((video-pre-display-buffer-hook
                   (list (lambda () (push (cons 'pre (current-buffer)) events))))
                  (video-post-display-buffer-hook
                   (list (lambda () (push (cons 'post (current-buffer)) events)))))
              (should
               (eq
                (video-display-buffer
                 buffer
                 (lambda (_buffer)
                   (push (cons 'display (current-buffer)) events)
                   target))
                target)))
            (should (eq (selected-window) target))
            (should
             (equal
              (mapcar #'car (nreverse events))
              '(pre display post)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest video-display-buffer-noselect-preserves-selected-window ()
  (let ((buffer (generate-new-buffer " *video-display-noselect-test*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((origin (selected-window))
                (target (split-window-right))
                (video-display-buffer-noselect t))
            (set-window-buffer target buffer)
            (should
             (eq (video-display-buffer buffer (lambda (_buffer) target))
                 target))
            (should (eq (selected-window) origin))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest video-open-accepts-per-call-display-policy ()
  (let ((buffer (generate-new-buffer " *video-open-test*"))
        prepared
        displayed
        activated)
    (unwind-protect
        (cl-letf (((symbol-function 'video--prepare-open-buffer)
                   (lambda (&rest args)
                     (setq prepared args)
                     buffer))
                  ((symbol-function 'video-display-buffer)
                   (lambda (&rest args)
                     (setq displayed args)))
                  ((symbol-function 'video--activate-open-buffer)
                   (lambda (media-buffer)
                     (setq activated media-buffer)
                     media-buffer)))
          (should
           (eq
            (video-open
             "source" :kind 'video :buffer buffer
             :cache-file "/tmp/video-open-cache.mp4"
             :cache-complete-function #'ignore
             :display-function #'video-display-buffer-other-frame)
            buffer))
          (should
           (equal prepared
                  (list "source" 'video buffer
                        "/tmp/video-open-cache.mp4" #'ignore)))
          (should
           (equal displayed
                  (list buffer #'video-display-buffer-other-frame)))
          (should (eq activated buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest video-quit-uses-configured-bury-function ()
  (let ((video-quit-function nil)
        (video-bury-buffer-function
         (lambda () 'configured-bury-result)))
    (should (eq (video-quit) 'configured-bury-result))))

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

(ert-deftest video-mode-routes-left-drag-away-from-text-selection ()
  (should (eq (lookup-key video-mode-map [down-mouse-1])
              #'video-mouse-seek))
  (dolist (id video--control-map-ids)
    (should (eq (lookup-key video-mode-map (vector id 'down-mouse-1))
                #'ignore))))

(ert-deftest video-mouse-seek-previews-relative-local-position-and-resumes ()
  (let* ((window (selected-window))
         (start-position (list window (point-min) (cons 100 20) 0))
         (forward-position (list window (point-min) (cons 150 20) 0))
         (backward-position (list window (point-min) (cons 40 20) 0))
         (start-event (list 'down-mouse-1 start-position))
         (events (list (list 'mouse-movement forward-position)
                       (list 'mouse-movement backward-position)
                       (list 'mouse-1 backward-position)))
         (player (video--make-player
                  :source "file:///test.webm"
                  :kind 'video :handle 'native
                  :desired-state 'playing
                  :position 20.0 :duration 100.0))
         (target (video--make-target :player player))
         (video-mouse-seek-seconds-per-pixel 0.05)
         actions
         (unread-command-events nil))
    (cl-letf (((symbol-function 'video--window-target-valid-p)
               (lambda (_window) t))
              ((symbol-function 'video--window-target)
               (lambda (_window) target))
              ((symbol-function 'read--potential-mouse-event)
               (lambda (&rest _args)
                 (or (pop events) (ert-fail "mouse seek read past release"))))
              ((symbol-function 'video-native-pause)
               (lambda (handle) (push (list 'pause handle) actions)))
              ((symbol-function 'video-player-seek)
               (lambda (actual-player seconds)
                 (should (eq actual-player player))
                 (push (list 'seek seconds) actions)))
              ((symbol-function 'video-native-play)
               (lambda (handle) (push (list 'play handle) actions)))
              ((symbol-function 'video-player-toggle)
               (lambda (_player)
                 (ert-fail "mouse drag toggled playback"))))
      (video-mouse-seek start-event))
    (should (equal (nreverse actions)
                   '((pause native) (seek 22.5) (seek 17.0) (play native))))
    (should-not unread-command-events)))

(ert-deftest video-mouse-seek-previews-only-buffered-remote-positions ()
  (let* ((window (selected-window))
         (start-position (list window (point-min) (cons 100 20) 0))
         (buffered-position (list window (point-min) (cons 140 20) 0))
         (remote-position (list window (point-min) (cons 300 20) 0))
         (start-event (list 'down-mouse-1 start-position))
         (events (list (list 'mouse-movement buffered-position)
                       (list 'mouse-movement remote-position)
                       (list 'mouse-1 remote-position)))
         (player (video--make-player
                  :source "https://example.test/video.webm"
                  :kind 'video :handle 'native
                  :position 20.0 :duration 100.0))
         (target (video--make-target :player player))
         (video-mouse-seek-seconds-per-pixel 0.05)
         requests
         (unread-command-events nil))
    (cl-letf (((symbol-function 'video--window-target-valid-p)
               (lambda (_window) t))
              ((symbol-function 'video--window-target)
               (lambda (_window) target))
              ((symbol-function 'video-player-buffered-ranges)
               (lambda (actual-player)
                 (should (eq actual-player player))
                 '((0.0 . 25.0))))
              ((symbol-function 'read--potential-mouse-event)
               (lambda (&rest _args)
                 (or (pop events) (ert-fail "mouse seek read past release"))))
              ((symbol-function 'video--redisplay-pending-player-frame)
               #'ignore)
              ((symbol-function 'video-player-seek)
               (lambda (actual-player seconds)
                 (should (eq actual-player player))
                 (push seconds requests)))
              ((symbol-function 'video-player-toggle)
               (lambda (_player)
                 (ert-fail "mouse drag toggled playback"))))
      (video-mouse-seek start-event))
    (should (equal (nreverse requests) '(22.0 30.0)))
    (should-not unread-command-events)))

(ert-deftest video-mouse-seek-toggles-an-unmoved-click ()
  (let* ((window (selected-window))
         (position (list window (point-min) (cons 100 20) 0))
         (start-event (list 'down-mouse-1 position))
         (events (list (list 'mouse-1 position)))
         (player (video--make-player
                  :source "file:///test.webm"
                  :kind 'video :handle 'native :position 20.0))
         (target (video--make-target :player player))
         toggled
         (unread-command-events nil))
    (cl-letf (((symbol-function 'video--window-target-valid-p)
               (lambda (_window) t))
              ((symbol-function 'video--window-target)
               (lambda (_window) target))
              ((symbol-function 'read--potential-mouse-event)
               (lambda (&rest _args)
                 (or (pop events) (ert-fail "mouse seek read past release"))))
              ((symbol-function 'video-player-seek)
               (lambda (&rest _args)
                 (ert-fail "unmoved click sought video")))
              ((symbol-function 'video-player-toggle)
               (lambda (actual-player)
                 (setq toggled actual-player))))
      (video-mouse-seek start-event))
    (should (eq toggled player))
    (should-not unread-command-events)))

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
      canvas 200 120 20 15 160 90 t 5.0 10.0 nil 0.9
      nil 100.0 t [0.0 1.0]))))

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
                 (video--normalize-source (video-test--fixture))
                 process 0 nil))
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
          (video-native-target-set-view
           target 160 90 "contain" 1.0 -320.0 -180.0)
          (let ((previous sequence)
                (deadline (+ (float-time) 5.0)))
            (while (and (<= sequence previous) (< (float-time) deadline))
              (accept-process-output process 0.1)
              (video-native-poll player)
              (setq sequence
                    (video-native-target-copy target canvas 160 90 0 0)))
            (should (> sequence previous)))
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
