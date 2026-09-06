;;; video-evil.el --- Optional Evil integration for video.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 0WD0
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Modal viewport and inline-player controls, owned alongside video.el.
;; Application-specific commands belong to application-local minor modes.

;;; Code:

(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))
(declare-function evil-normalize-keymaps "evil-core" (&optional state))
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-refresh-cursor "evil-core" ())
(declare-function evil-visual-activate-hook "evil-states" ())
(declare-function evil-beginning-of-line "evil-commands" ())
(defvar evil-local-mode)
(defvar evil-state)

(declare-function video-down "video-view")
(declare-function video-fit-height "video-view")
(declare-function video-fit-width "video-view")
(declare-function video-left "video-view")
(declare-function video-mouse-pan "video-view")
(declare-function video-mouse-seek "video-view")
(declare-function video-next "video-view")
(declare-function video-pan-down "video-view")
(declare-function video-pan-left "video-view")
(declare-function video-pan-right "video-view")
(declare-function video-pan-up "video-view")
(declare-function video-previous "video-view")
(declare-function video-quit "video-view")
(declare-function video-reset-view "video-view")
(declare-function video-right "video-view")
(declare-function video-toggle "video-view")
(declare-function video-toggle-frame "video-view")
(declare-function video-toggle-loop "video-view")
(declare-function video-toggle-muted "video-view")
(declare-function video-up "video-view")
(declare-function video-wheel-pan "video-view")
(declare-function video-wheel-zoom-in "video-view")
(declare-function video-wheel-zoom-out "video-view")
(declare-function video-zoom-in "video-view")
(declare-function video-zoom-out "video-view")
(declare-function video-original-size "video-view")
(declare-function video-set-scale "video-view")


(defvar video-mode-map)
(defvar video-inline-map)

(defgroup video-evil nil
  "Optional Evil integration for media viewports."
  :group 'video)

(defcustom video-evil-enable-integration t
  "Whether to install video.el's Evil bindings automatically."
  :type 'boolean
  :group 'video-evil)

(defcustom video-evil-initial-state 'normal
  "Initial Evil state for media viewers, or nil to leave it unchanged."
  :type '(choice (const normal) (const motion) (const emacs) (const nil))
  :group 'video-evil)

(defun video-evil--hide-cursor ()
  "Hide every Evil state cursor over the media Canvas."
  (dolist (variable '(evil-emacs-state-cursor evil-insert-state-cursor
                     evil-motion-state-cursor evil-normal-state-cursor
                     evil-operator-state-cursor evil-replace-state-cursor
                     evil-visual-state-cursor))
    (set (make-local-variable variable) '(nil)))
  (evil-refresh-cursor))

(defun video-evil--disable-visual-activation ()
  "Keep Canvas gestures from activating Evil visual state."
  (remove-hook 'activate-mark-hook #'evil-visual-activate-hook t)
  (add-hook 'evil-local-mode-hook #'video-evil--disable-visual-activation nil t))

(defun video-evil--configure-buffer ()
  "Apply viewport-specific Evil behavior to the current buffer."
  ;; Install the local-mode hook even if Evil will only be enabled later.
  (video-evil--disable-visual-activation)
  (when (bound-and-true-p evil-local-mode)
    (evil-normalize-keymaps))
  (video-evil--hide-cursor))

(defun video-evil--setup-inline ()
  "Install state-filtered inline playback without claiming insertion keys."
  (when (and video-evil-enable-integration (featurep 'evil) (boundp 'video-inline-map))
    (define-key video-inline-map (kbd "p")
                '(menu-item "Play/pause" video-inline-toggle
                  :filter (lambda (command)
                            (when (and (bound-and-true-p evil-local-mode)
                                       (memq evil-state '(normal motion)))
                              command))))))

(defun video-evil--setup-view ()
  "Install the generic modal vocabulary for media viewports."
  (when (and video-evil-enable-integration (featurep 'evil) (boundp 'video-mode-map))
    (when video-evil-initial-state
      (evil-set-initial-state 'video-mode video-evil-initial-state))
    (add-hook 'video-mode-hook #'video-evil--configure-buffer t)
    ;; Canvas viewers have no editable text.  Remap editing operators rather
    ;; than occupying their literal keys, leaving application modes extensible.
    (dolist (command '(evil-append evil-append-line evil-insert evil-insert-line
                       evil-change evil-change-line evil-substitute
                       evil-change-whole-line evil-delete evil-delete-line
                       evil-delete-char evil-delete-backward-char evil-replace
                       evil-replace-state evil-open-below evil-open-above
                       evil-paste-after evil-paste-before evil-join evil-indent
                       evil-shift-left evil-shift-right evil-invert-char))
      (evil-define-key* 'normal video-mode-map (vector 'remap command) #'ignore))
    (evil-define-key* '(normal motion) video-mode-map
      "h" #'video-pan-left
      "j" #'video-pan-down
      "k" #'video-pan-up
      "l" #'video-pan-right
      [remap evil-backward-char] #'video-pan-left
      [remap evil-next-line] #'video-pan-down
      [remap evil-previous-line] #'video-pan-up
      [remap evil-forward-char] #'video-pan-right
      (kbd "<left>") #'video-left
      (kbd "<right>") #'video-right
      (kbd "<up>") #'video-up
      (kbd "<down>") #'video-down
      (kbd "<wheel-up>") #'video-wheel-pan
      (kbd "<wheel-down>") #'video-wheel-pan
      (kbd "<wheel-left>") #'video-wheel-pan
      (kbd "<wheel-right>") #'video-wheel-pan
      (kbd "S-<wheel-up>") #'video-wheel-pan
      (kbd "S-<wheel-down>") #'video-wheel-pan
      (kbd "S-<wheel-left>") #'video-wheel-pan
      (kbd "S-<wheel-right>") #'video-wheel-pan
      (kbd "C-<wheel-up>") #'video-wheel-zoom-in
      (kbd "C-<wheel-down>") #'video-wheel-zoom-out
      (kbd "<down-mouse-1>") #'video-mouse-seek
      (kbd "<down-mouse-2>") #'video-mouse-pan
      ;; Preserve Evil counts; original-size and reset use z prefixes.
      "0" #'evil-beginning-of-line
      "1" #'digit-argument
      (kbd "z o") #'video-original-size
      (kbd "z 0") #'video-reset-view
      "s" #'video-set-scale
      "+" #'video-zoom-in
      "=" #'video-zoom-in
      "-" #'video-zoom-out
      (kbd "C-+") #'video-zoom-in
      (kbd "C-=") #'video-zoom-in
      (kbd "C--") #'video-zoom-out
      (kbd "C-0") #'video-reset-view
      "W" #'video-fit-width
      "H" #'video-fit-height
      "m" #'video-toggle-muted
      (kbd "RET") #'video-toggle
      (kbd "<return>") #'video-toggle
      "p" #'video-toggle
      "L" #'video-toggle-loop
      "F" #'video-toggle-frame
      (kbd "g j") #'video-next
      (kbd "g k") #'video-previous
      "q" #'video-quit
      "Q" #'kill-current-buffer
      (kbd "Z Q") #'kill-current-buffer)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'video-mode)
          (video-evil--configure-buffer))))))

;;;###autoload
(defun video-evil-setup ()
  "Install video.el's optional Evil bindings, safely and repeatedly.
Customize state-specific bindings in video-mode-map after loading this
library.  No evil-collection integration is required."
  (interactive)
  (video-evil--setup-view)
  (video-evil--setup-inline))

(with-eval-after-load 'video-view
  (video-evil--setup-view))
(with-eval-after-load 'video-inline
  (video-evil--setup-inline))

(with-eval-after-load 'evil
  (video-evil-setup))

(provide 'video-evil)
;;; video-evil.el ends here
