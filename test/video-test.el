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

(ert-deftest video-target-set-view-mutates-one-canvas-identity ()
  (let* ((player (video--make-player :handle 'player))
         (canvas (video--make-canvas 20 10))
         (target (video--make-target
                  :player player :handle 'target :canvas canvas
                  :width 20 :height 10))
         native-call)
    (cl-letf (((symbol-function 'video-native-target-set-view)
               (lambda (&rest args) (setq native-call args))))
      (video-target-set-view target 40 30 'cover 2.0 0.25 0.75))
    (should (eq canvas (video-target-canvas target)))
    (should (= (plist-get (cdr canvas) :data-width) 40))
    (should (= (plist-get (cdr canvas) :data-height) 30))
    (should (equal native-call '(target 40 30 "cover" 2.0 0.25 0.75)))))

(ert-deftest video-pan-follows-pointer-direction ()
  (let* ((player (video--make-player :handle 'player :width 400 :height 200))
         (target (video--make-target
                  :player player :handle 'target
                  :canvas (video--make-canvas 200 100)
                  :width 200 :height 100 :fit 'contain
                  :zoom 2.0 :center-x 0.5 :center-y 0.5))
         native-call)
    (cl-letf (((symbol-function 'video-native-target-set-view)
               (lambda (&rest args) (setq native-call args))))
      (video--apply-pan target 20.0 10.0))
    ;; A right/down hand movement reveals content to the left/up.
    (should (< (video-target-center-x target) 0.5))
    (should (< (video-target-center-y target) 0.5))
    (should (equal (car native-call) 'target))))

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
