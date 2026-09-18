;;; video-evil.el --- Optional Evil integration for video.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 0WD0
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Modal viewport and inline-player controls, owned alongside video.el.
;; Application-specific commands belong to application-local minor modes.

;;; Code:

(require 'video)

(declare-function turn-off-evil-snipe-mode "evil-snipe" ())
(declare-function turn-off-evil-snipe-override-mode "evil-snipe" ())
(declare-function evil-quit "evil-commands" (&optional force))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))
(declare-function evil-normalize-keymaps "evil-core" (&optional state))
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-refresh-cursor "evil-core" ())
(declare-function evil-visual-activate-hook "evil-states" ())
(declare-function evil-beginning-of-line "evil-commands" ())
(defvar evil-local-mode)
(defvar evil-state)

(defconst video-evil--ignored-commands
  '(;; Editing and text-state commands.  Most are absent in Motion state,
    ;; but keeping them here makes an explicit Normal-state opt-in safe too.
    evil-append evil-append-line evil-insert evil-insert-line
    evil-insert-resume evil-insert-0-line
    evil-change evil-change-line evil-substitute evil-change-whole-line
    evil-delete evil-delete-line evil-delete-char evil-delete-backward-char
    evil-replace evil-replace-state evil-enter-replace-state
    evil-open-below evil-open-above
    evil-paste-after evil-paste-before
    evil-paste-after-cursor-after evil-paste-before-cursor-after
    evil-join evil-indent evil-yank evil-yank-line evil-undo evil-redo
    evil-shift-left evil-shift-right evil-invert-char evil-invert-case
    evil-downcase evil-upcase evil-fill evil-fill-and-move evil-join-whitespace
    evil-ex-repeat-substitute evil-ex-repeat-global-substitute
    evil-visual-char evil-visual-line evil-visual-block evil-visual-restore
    ;; Motions, searches, and text scrolling expose the backing file bytes
    ;; rather than manipulating the Canvas presentation.
    evil-goto-line evil-goto-first-line evil-goto-char evil-goto-column
    evil-forward-word-begin evil-forward-WORD-begin
    evil-forward-word-end evil-forward-WORD-end
    evil-backward-word-begin evil-backward-WORD-begin
    evil-backward-word-end evil-backward-WORD-end
    evil-find-char find-char evil-find-char-backward
    evil-find-char-to find-char-to
    evil-find-char-to-backward find-char-to-backward
    evil-repeat-find-char repeat-find-char
    evil-repeat-find-char-reverse repeat-find-char-reverse
    evil-end-of-line evil-first-non-blank
    evil-beginning-of-visual-line evil-end-of-visual-line
    evil-first-non-blank-of-visual-line evil-last-non-blank
    evil-middle-of-visual-line evil-percentage-of-line
    evil-forward-paragraph evil-backward-paragraph
    evil-forward-sentence-begin evil-backward-sentence-begin
    evil-forward-section-begin evil-forward-section-end
    evil-backward-section-begin evil-backward-section-end
    evil-next-close-paren evil-previous-open-paren
    evil-next-close-brace evil-previous-open-brace evil-jump-item
    evil-next-line-first-non-blank evil-next-line-1-first-non-blank
    evil-previous-line-first-non-blank
    evil-next-visual-line evil-previous-visual-line
    evil-window-top evil-window-middle evil-window-bottom
    evil-scroll-up evil-scroll-down
    evil-scroll-page-up evil-scroll-page-down
    evil-scroll-line-up evil-scroll-line-down
    evil-scroll-column-left evil-scroll-column-right
    evil-scroll-start-column evil-scroll-end-column
    evil-scroll-left evil-scroll-right
    evil-scroll-top-line-to-bottom evil-scroll-bottom-line-to-top
    evil-scroll-line-to-top evil-scroll-line-to-top-first-non-blank
    evil-scroll-line-to-center evil-scroll-line-to-center-first-non-blank
    evil-scroll-line-to-bottom evil-scroll-line-to-bottom-first-non-blank
    evil-search-next evil-ex-search-next
    evil-search-previous evil-ex-search-previous
    evil-search-forward evil-ex-search-forward
    evil-search-backward evil-ex-search-backward
    evil-search-word-forward evil-ex-search-word-forward
    evil-search-word-backward evil-ex-search-word-backward
    evil-search-unbounded-word-forward evil-ex-search-unbounded-word-forward
    evil-search-unbounded-word-backward evil-ex-search-unbounded-word-backward)
  "Evil commands that have no Canvas presentation meaning.")

(defgroup video-evil nil
  "Optional Evil integration for media viewports."
  :group 'video)

(defcustom video-evil-enable-integration t
  "Whether to install video.el's Evil bindings automatically."
  :type 'boolean
  :group 'video-evil)

(defcustom video-evil-initial-state 'motion
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
    ;; File-backed viewers retain their original bytes, but those bytes are not
    ;; user-facing text.  Remap text-oriented commands as one policy rather
    ;; than claiming their literal keys, leaving application modes extensible.
    (dolist (command video-evil--ignored-commands)
      (evil-define-key* '(normal motion) video-mode-map
        (vector 'remap command) #'ignore))
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
      [touchscreen-begin] #'video-touch
      [video-control-toggle touchscreen-begin] #'video-touch
      [video-control-mute touchscreen-begin] #'video-touch
      [video-control-seek touchscreen-begin] #'video-touch
      [video-control-volume touchscreen-begin] #'video-touch
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
      (kbd "Z Z") #'video-quit
      "Q" #'kill-current-buffer
      (kbd "Z Q") #'evil-quit)
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

(with-eval-after-load 'evil
  (video-evil-setup))

(with-eval-after-load 'evil-snipe
  (add-hook 'video-mode-hook #'turn-off-evil-snipe-mode)
  (add-hook 'video-mode-hook #'turn-off-evil-snipe-override-mode))

(provide 'video-evil)
;;; video-evil.el ends here
