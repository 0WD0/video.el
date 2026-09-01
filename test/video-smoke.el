;;; video-smoke.el --- Graphical smoke scenario for video.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 0WD0
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'video)

(defconst video-smoke--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))
(defconst video-smoke--fixture
  (expand-file-name "test/fixtures/test.webm" video-smoke--root))
(defconst video-smoke--screenshot "/tmp/video-el-smoke.png")
(defconst video-smoke--result "/tmp/video-el-smoke-result.el")

(defun video-smoke--finish (dedicated inline)
  "Validate DEDICATED and INLINE playback, export the frame, then exit."
  (condition-case error-data
      (let* ((dedicated-player
              (buffer-local-value 'video--buffer-player dedicated))
             (dedicated-targets (video-player-targets dedicated-player))
             (inline-player (video-inline-player inline))
             (inline-target (video-inline-target inline)))
        (unless (and (video-player-live-p dedicated-player)
                     dedicated-targets
                     (cl-some (lambda (target)
                                (integerp (video-target-last-sequence target)))
                              dedicated-targets))
          (error "Dedicated target did not present a frame"))
        (unless (and (video-player-live-p inline-player)
                     (video-inline-active inline)
                     (integerp (video-target-last-sequence inline-target))
                     (eq (overlay-get (video-inline-overlay inline) 'display)
                         (video-target-canvas inline-target)))
          (error "Inline target did not replace its poster with Canvas"))
        (unless (cl-every (lambda (window) (zerop (window-hscroll window)))
                          (window-list))
          (error "Video playback changed window horizontal scroll"))
        (redisplay t)
        (let ((data (x-export-frames nil 'png)))
          (with-temp-file video-smoke--screenshot
            (set-buffer-multibyte nil)
            (insert data)))
        (with-temp-file video-smoke--result
          (prin1 `(:ok t
                   :dedicated-state ,(video-player-state dedicated-player)
                   :dedicated-targets ,(length dedicated-targets)
                   :inline-state ,(video-player-state inline-player)
                   :inline-active ,(video-inline-active inline)
                   :screenshot ,video-smoke--screenshot)
                 (current-buffer)))
        (kill-emacs 0))
    (error
     (with-temp-file video-smoke--result
       (prin1 `(:ok nil :error ,(error-message-string error-data))
              (current-buffer)))
     (kill-emacs 1))))

(let* ((dedicated (video-open video-smoke--fixture))
       (inline-buffer (get-buffer-create "*Video Inline Smoke*"))
       (inline-window (split-window-right))
       inline)
  (set-window-buffer inline-window inline-buffer)
  (with-current-buffer inline-buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "Inline Canvas playback\n\n")
      (setq inline
            (video-inline-insert video-smoke--fixture "[Preparing video]"
                                 320 180 :fit 'cover :muted t))
      (insert "\n\nThe surrounding text remains ordinary buffer content.\n")))
  (video-inline-play inline)
  (run-at-time 1.0 nil #'video-smoke--finish dedicated inline))

;;; video-smoke.el ends here
