;;; video.el --- Canvas-based video playback for Emacs  -*- lexical-binding: t; -*-

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

;; video.el presents decoded image and video frames through Emacs Canvas
;; viewports.  It provides a dedicated `video-mode' buffer and lazy inline
;; video occurrences.

;;; Code:

(require 'video-view)
(require 'video-inline)

(provide 'video)
;;; video.el ends here
