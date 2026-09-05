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

(ert-deftest video-normalize-request-headers-validates-and-vectorizes ()
  (should
   (equal
    (video--normalize-request-headers
     '(("Referer" . "https://example.test/")
       ("User-Agent" . "video.el test")))
    ["Referer" "https://example.test/" "User-Agent" "video.el test"]))
  (should-error
   (video--normalize-request-headers '(("Bad Header" . "value"))))
  (should-error
   (video--normalize-request-headers '(("Referer" . "ok\nInjected: value"))))
  (should-error
   (video--normalize-request-headers
    '(("Referer" . "first") ("referer" . "second")))))

(ert-deftest video-canvas-descriptors-own-their-property-lists ()
  (let ((first (video-canvas-create 320 180))
        (second (video-canvas-create 180 320)))
    (plist-put (cdr first) :height 180)
    (plist-put (cdr first) :map 'first-map)
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
  (let* ((player (video--make-player :handle 'native :muted t))
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
                 :handle 'native :position 10.0 :duration 10.0 :seekable t))
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
         (player (video--make-player :handle 'native :seekable t))
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
                  :handle 'native :duration 100.0 :seekable t))
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

(ert-deftest video-live-mode-line-and-seek-contract ()
  (with-temp-buffer
    (setq video--buffer-player
          (video--make-player
           :kind 'video :handle 'native :stream-live t :position 12.0))
    (should (equal (video--mode-line-position) " LIVE"))
    (should-error (video-player-seek video--buffer-player 3.0)
                  :type 'user-error)))

(ert-deftest video-explicit-live-policy-overrides-native-capabilities ()
  (let ((player
         (video--make-player
          :kind 'video :handle 'native :live-hint t :seekable t)))
    (cl-letf (((symbol-function 'video-native-poll)
               (lambda (_handle)
                 '(:state buffering :buffering 25 :seekable t :live nil)))
              ((symbol-function 'video--initialize-player-window-views)
               #'ignore)
              ((symbol-function 'video--update-player-buffering-animation)
               #'ignore)
              ((symbol-function 'video--reconcile-player-visibility)
               #'ignore))
      (video--dispatch player))
    (should (video-player-stream-live player))
    (should-not (video-player-seekable player))))

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

(ert-deftest video-cache-completion-retries-after-early-native-event ()
  (let* ((directory (make-temp-file "video-cache-race-test" t))
         (location (expand-file-name "small-response.part" directory))
         (target (expand-file-name "stable/video.webm" directory))
         (process
          (make-pipe-process
           :name (generate-new-buffer-name " video-cache-race")
           :buffer nil :noquery t))
         callback
         (polls 0)
         (player
          (video--make-player
           :handle 'native :process process :cache-file target
           :cache-complete-function
           (lambda (_player file)
             (setq callback file)))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory target) t)
          (with-temp-file location
            (insert "small complete response"))
          (process-put process 'video-player player)
          (let ((video--cache-poll-delay 0.01)
                (video--cache-poll-limit 3))
            (cl-letf (((symbol-function 'video-native-poll)
                       (lambda (_handle)
                         (cl-incf polls)
                         (if (= polls 1)
                             '(:state paused :buffering 100)
                           (list :state 'paused :buffering 100
                                 :cache-location location))))
                      ((symbol-function 'video--initialize-player-window-views)
                       #'ignore)
                      ((symbol-function 'video--update-player-buffering-animation)
                       #'ignore)
                      ((symbol-function 'video--reconcile-player-visibility)
                       #'ignore))
              (video--event-filter process "e")
              (let ((deadline (+ (float-time) 2)))
                (while (and (< (float-time) deadline)
                            (not (file-regular-p target)))
                  (accept-process-output nil 0.01)))))
          (should (equal callback target))
          (should (file-regular-p target))
          (should-not (file-exists-p location)))
      (setf (video-player-handle player) nil)
      (video-player-close player)
      (delete-directory directory t))))

(ert-deftest video-cache-completion-retry-cancels-with-player ()
  (let* ((directory (make-temp-file "video-cache-close-test" t))
         (player
          (video--make-player
           :handle 'native
           :cache-file (expand-file-name "pending.webm" directory)))
         (video--cache-poll-delay 60.0))
    (unwind-protect
        (progn
          (video--arm-cache-poll player)
          (should (timerp (video-player-cache-poll-timer player)))
          (cl-letf (((symbol-function 'video-native-close) #'ignore))
            (video-player-close player))
          (should-not (video-player-cache-poll-timer player))
          (should (zerop (video-player-cache-poll-remaining player))))
      (video--cancel-cache-poll player)
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

(ert-deftest video-open-creates-and-presents-owned-session ()
  (let ((buffer (generate-new-buffer " *video-open-test*"))
        (player (video--make-player :handle 'native))
        session-arguments
        presented
        played)
    (unwind-protect
        (cl-letf (((symbol-function 'video-session-create)
                   (lambda (&rest arguments)
                     (setq session-arguments arguments)
                     (video--make-session :player player)))
                  ((symbol-function 'video-session-present)
                   (lambda (session &rest arguments)
                     (setq presented (cons session arguments))
                     buffer))
                  ((symbol-function 'video-player-play)
                   (lambda (actual)
                     (setq played actual))))
          (should
           (eq
            (video-open
             "source" :kind 'video :buffer buffer
             :live t
             :cache-file "/tmp/video-open-cache.mp4"
             :cache-complete-function #'ignore
             :request-headers '(("Referer" . "https://example.test/"))
             :display-function #'video-display-buffer-other-frame)
            buffer))
          (should
           (equal
            session-arguments
            (list "source" :kind 'video :muted nil :live t
                  :cache-file "/tmp/video-open-cache.mp4"
                  :cache-complete-function #'ignore
                  :request-headers
                  '(("Referer" . "https://example.test/")))))
          (should
           (equal
            (cdr presented)
            (list :buffer buffer
                  :display-function #'video-display-buffer-other-frame)))
          (should (eq played player)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest video-present-player-borrows-and-preserves-existing-session ()
  (let ((buffer (generate-new-buffer " *video-present-player-test*"))
        (player (video--make-player
                 :handle 'native :desired-state 'playing :position 23.5))
        displayed
        activated
        closed)
    (unwind-protect
        (cl-letf (((symbol-function 'video-display-buffer)
                   (lambda (&rest args)
                     (setq displayed args)))
                  ((symbol-function 'video--activate-presented-buffer)
                   (lambda (media-buffer)
                     (setq activated media-buffer)
                     media-buffer))
                  ((symbol-function 'video-player-close)
                   (lambda (_player)
                     (setq closed t))))
          (should
           (eq (video-present-player player :buffer buffer
                                     :display-function #'ignore)
               buffer))
          (with-current-buffer buffer
            (should (eq video--buffer-player player))
            (should-not video--buffer-owns-player))
          (should (equal displayed (list buffer #'ignore)))
          (should (eq activated buffer))
          (should (eq (video-player-desired-state player) 'playing))
          (should (= (video-player-position player) 23.5))
          (with-current-buffer buffer
            (setq-local video-next-function 'preserved))
          (video-present-player player :buffer buffer
                                :display-function #'ignore)
          (with-current-buffer buffer
            (should (eq video-next-function 'preserved)))
          (kill-buffer buffer)
          (should-not closed))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest video-inline-borrowed-player-survives-surface-close ()
  (let ((player (video--make-player :handle 'native))
        (buffer (generate-new-buffer " *video-inline-borrow-test*"))
        (callback-count 0)
        closed)
    (unwind-protect
        (cl-letf (((symbol-function 'video-player-close)
                   (lambda (_player)
                     (setq closed t))))
          (let ((inline
                  (video-inline-create
                   nil 320 180 :buffer buffer :player player
                   :close-function
                   (lambda (_inline)
                     (cl-incf callback-count)))))
            (should (eq (video-inline-player inline) player))
            (video-inline-close inline)
            (video-inline-close inline)
            (should-not closed)
            (should (= callback-count 1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest video-session-owns-inline-and-buffer-presentation-lifecycle ()
  (let* ((player (video--make-player :handle 'native))
         (session
          (video--make-session :player player :auto-close t))
         (host (generate-new-buffer " *video-session-inline-test*"))
         (viewer (generate-new-buffer " *video-session-viewer-test*"))
         closed)
    (setf (video-player-session player) session)
    (unwind-protect
        (cl-letf (((symbol-function 'video-player-close)
                   (lambda (actual)
                     (should (eq actual player))
                     (setf (video-player-closed actual) t
                           (video-player-handle actual) nil)
                     (setq closed t))))
          (let ((inline
                  (video-session-inline-create
                   session 320 180 :buffer host)))
            (should (= (video-session-presentation-count session) 1))
            (video--prepare-session-buffer session viewer)
            (should (= (video-session-presentation-count session) 2))
            (kill-buffer viewer)
            (should (video-session-live-p session))
            (should (= (video-session-presentation-count session) 1))
            (video-inline-close inline)
            (should closed)
            (should-not (video-session-live-p session))
            (should (video-session-closed session))))
      (when (buffer-live-p viewer)
        (kill-buffer viewer))
      (when (buffer-live-p host)
        (kill-buffer host)))))

(ert-deftest video-inline-borrowed-player-mute-remains-canonical ()
  (let* ((player (video--make-player :handle 'native :muted t))
         (target (video--make-target :player player))
         (inline
           (video--make-inline
            :player player :target target :muted nil)))
    (cl-letf (((symbol-function 'video-player-play) #'ignore)
              ((symbol-function 'video-native-set-muted) #'ignore))
      (should (video-inline-muted-p inline))
      (video-inline-play inline)
      (should (video-player-muted player))
      (video-inline-toggle-muted inline)
      (should-not (video-player-muted player)))))

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
    (should (= (video--view-x first) 40.0))))

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
                  :position 20.0 :duration 100.0 :seekable t))
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
                  :position 20.0 :duration 100.0 :seekable t))
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
                  :kind 'video :handle 'native :position 20.0 :seekable t))
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
      nil 100.0 t t [0.0 1.0]))))

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
                 process 0 nil []))
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
          (should-not (plist-get state :error))
          (should (plist-get state :seekable))
          (should-not (plist-get state :live)))
      (when target
        (ignore-errors (video-native-target-close target)))
      (when player
        (ignore-errors (video-native-close player)))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest video-http-failure-stops-buffering-and-one-toggle-retries ()
  (skip-unless (and (display-graphic-p) (image-type-available-p 'canvas)
                    (executable-find "python3")))
  (let ((fixture (expand-file-name "fixtures/test.webm" video-test--directory))
        (directory (make-temp-file "video-recovery-test-" t))
        (server-buffer (generate-new-buffer " *video-recovery-server*"))
        video-player-error-hook video-player-state-change-hook
        server player port)
    (cl-labels
        ((wait-for (predicate)
           (let ((deadline (+ (float-time) 8)))
             (while (and (< (float-time) deadline) (not (funcall predicate)))
               (accept-process-output nil 0.02)
               (when player (video--dispatch player)))
             (should (funcall predicate)))))
      (unwind-protect
          (progn
            (should (file-readable-p fixture))
            ;; Serve outside Emacs: native pipeline queries may block while
            ;; GStreamer is waiting for an HTTP response.
            (setq server
                  (make-process
                   :name "video-recovery-server" :buffer server-buffer :noquery t
                   :command (list (executable-find "python3") "-u" "-m" "http.server"
                                  "0" "--bind" "127.0.0.1" "--directory" directory)))
            (wait-for
             (lambda ()
               (with-current-buffer server-buffer
                 (goto-char (point-min))
                 (when (re-search-forward (rx "port " (group (+ digit))) nil t)
                   (setq port (string-to-number (match-string 1)))))))
            (setq player
                  (video-player-create
                   (format "http://127.0.0.1:%d/video.webm" port) :muted t))
            (video-player-play player)
            (wait-for (lambda () (video-player-error player)))
            (should-not (video--player-waiting-p player))
            (should (eq (video-player-desired-state player) 'paused))
            (copy-file fixture (expand-file-name "video.webm" directory))
            (video-player-toggle player)
            (wait-for (lambda () (and (> (video-player-width player) 0)
                                      (> (video-player-position player) 0.05))))
            (should-not (video-player-error player)))
        (when player (video-player-close player))
        (when (and server (process-live-p server)) (delete-process server))
        (kill-buffer server-buffer)
        (delete-directory directory t)))))

(ert-deftest video-resize-keeps-preframe-play-control-at-viewport-center ()
  (skip-unless (and (display-graphic-p) (image-type-available-p 'canvas)))
  (let ((fixture (expand-file-name "fixtures/test.webm" video-test--directory))
        video-player-error-hook video-player-state-change-hook
        player viewer sibling)
    (cl-labels
        ((play-hit-p (window)
           (let* ((target (video--window-target window))
                  (x (/ (video-target-width target) 2))
                  (y (/ (video-target-height target) 2)))
             (cl-some
              (lambda (entry)
                (when (eq (cadr entry) 'video-control-toggle)
                  (let* ((bounds (cdar entry))
                         (start (car bounds)) (end (cdr bounds)))
                    (and (<= (car start) x) (< x (car end))
                         (<= (cdr start) y) (< y (cdr end))))))
              (image-property (video-target-canvas target) :map)))))
      (save-window-excursion
        (unwind-protect
            (progn
              (should (file-readable-p fixture))
              (setq player (video-player-create fixture :muted t)
                    viewer (generate-new-buffer " *video-resize-viewer*"))
              (video-present-player player :buffer viewer)
              (video-control-show nil)
              (let ((window (get-buffer-window viewer)))
                (should (play-hit-p window))
                (setq sibling (generate-new-buffer " *video-resize-sibling*"))
                (set-window-buffer (split-window window nil 'right) sibling)
                (video--resize-window-target window)
                (should (play-hit-p window))))
          (when (buffer-live-p viewer) (kill-buffer viewer))
          (when (buffer-live-p sibling) (kill-buffer sibling))
          (when player (video-player-close player)))))))

(provide 'video-test)
;;; video-test.el ends here
