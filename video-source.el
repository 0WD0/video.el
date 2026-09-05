;;; video-source.el --- Sources for Canvas media  -*- lexical-binding: t; -*-

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

;; Source URIs, local files, media kinds, GIF metadata, and HTTP headers.
;; This module does not load the native playback module.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'image)
(require 'url-util)

(defgroup video nil
  "Canvas-based video playback."
  :group 'multimedia)

(defun video-source-uri (source)
  "Return SOURCE as an absolute URI accepted by GStreamer."
  (unless (and (stringp source) (not (string-empty-p source)))
    (error "Video source must be a non-empty string"))
  (cond
   ((string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" source) source)
   ((or (file-name-absolute-p source) (file-exists-p source))
    (url-encode-url (concat "file://" (expand-file-name source))))
   (t (error "Video source is neither a URI nor a readable file: %s" source))))

(defconst video--http-header-name-regexp
  "\\`[!#$%&'*+.^_`|~0-9A-Za-z-]+\\'"
  "Regexp matching one valid HTTP field name.")

(defun video-source-header-vector (headers)
  "Validate HEADERS and return an alternating name/value vector.

HEADERS is nil or an alist of string field names and values.  Duplicate field
names are rejected case-insensitively.  The returned vector is safe to pass to
the native module."
  (unless (listp headers)
    (error "Video request headers must be an alist"))
  (let ((seen (make-hash-table :test #'equal))
        values)
    (dolist (header headers)
      (unless (and (consp header)
                   (stringp (car header))
                   (string-match-p video--http-header-name-regexp (car header))
                   (stringp (cdr header))
                   (not (string-match-p "[\0\r\n]" (cdr header))))
        (error "Invalid video request header"))
      (let ((name (downcase (car header))))
        (when (gethash name seen)
          (error "Duplicate video request header: %s" (car header)))
        (puthash name t seen))
      (push (car header) values)
      (push (cdr header) values))
    (vconcat (nreverse values))))

(defun video-source-gif-metadata (file)
  "Read GIF frame and loop metadata from local FILE, or return nil.
Only complete GIF streams are accepted.  Read in bounded chunks and skip
compressed image data without decoding it.  Loop counts follow the
NETSCAPE2.0 and ANIMEXTS1.0 application extensions."
  (when (and file (not (file-remote-p file)) (file-readable-p file)
             (file-regular-p file))
    (condition-case nil
        (let ((size (file-attribute-size (file-attributes file)))
              (offset 0) (cache-start 0) (frames 0) loops)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (catch 'video--invalid-gif
              (cl-labels
                  ((bytes (count)
                     (when (> (+ offset count) size)
                       (throw 'video--invalid-gif nil))
                     (unless (and (>= offset cache-start)
                                  (<= (+ offset count)
                                      (+ cache-start (buffer-size))))
                       (erase-buffer)
                       (setq cache-start offset)
                       (insert-file-contents-literally
                        file nil offset (min size (+ offset (max count 65536)))))
                     (when (> (+ (- offset cache-start) count) (buffer-size))
                       (throw 'video--invalid-gif nil))
                     (let ((start (1+ (- offset cache-start))))
                       (setq offset (+ offset count))
                       (buffer-substring-no-properties start (+ start count))))
                   (byte () (aref (bytes 1) 0))
                   (skip (count)
                     (setq offset (+ offset count))
                     (when (> offset size) (throw 'video--invalid-gif nil)))
                   (blocks ()
                     (let ((count (byte)))
                       (while (> count 0)
                         (skip count)
                         (setq count (byte)))))
                   (word (data index)
                     (+ (aref data index) (ash (aref data (1+ index)) 8))))
                (unless (member (bytes 6) '("GIF87a" "GIF89a"))
                  (throw 'video--invalid-gif nil))
                (let ((screen (bytes 7)))
                  (when (or (zerop (word screen 0)) (zerop (word screen 2)))
                    (throw 'video--invalid-gif nil))
                  (when (/= 0 (logand (aref screen 4) #x80))
                    (skip (* 3 (ash 1 (1+ (logand (aref screen 4) 7)))))))
                (let (done)
                  (while (not done)
                    (pcase (byte)
                      (#x3b (setq done t))
                      (#x2c
                       (let ((descriptor (bytes 9)))
                         (when (or (zerop (word descriptor 4))
                                   (zerop (word descriptor 6)))
                           (throw 'video--invalid-gif nil))
                         (when (/= 0 (logand (aref descriptor 8) #x80))
                           (skip (* 3 (ash 1 (1+ (logand (aref descriptor 8) 7)))))))
                       (byte) ; LZW minimum code size.
                       (blocks)
                       (cl-incf frames))
                      (#x21
                       (pcase (byte)
                         (#xff
                          (let* ((length (byte))
                                 (application (bytes length)))
                            (if (and (= length 11)
                                     (member application '("NETSCAPE2.0" "ANIMEXTS1.0")))
                                (let ((count (byte)))
                                  (while (> count 0)
                                    (let ((data (bytes count)))
                                      (when (and (= count 3) (= (aref data 0) 1))
                                        (setq loops (word data 1))))
                                    (setq count (byte))))
                              (blocks))))
                         (_ (blocks))))
                      (_ (throw 'video--invalid-gif nil)))))
                (when (> frames 0)
                  (list :frames frames :loop-count loops))))))
      (file-error nil))))

(defconst video--image-extension-regexp
  "\\.\\(?:avif\\|bmp\\|gif\\|heic\\|heif\\|jpe?g\\|png\\|svgz?\\|tiff?\\|webp\\)\\(?:[?#].*\\)?\\'"
  "File-name suffixes recognized as still image sources.")

(defun video-source-kind (source)
  "Return `image' or `video' for SOURCE."
  (if (or (and (file-readable-p source)
               (condition-case nil
                   (image-type-from-file-header source)
                 (file-error nil)))
          (string-match-p video--image-extension-regexp (downcase source)))
      'image
    'video))

(defun video-source-file (source)
  "Return a local filename for SOURCE, or nil for nonlocal URIs."
  (let ((file
         (cond
          ((string-match "\\`file://\\(?:localhost\\)?\\(/[^?#]*\\)\\(?:[?#].*\\)?\\'" source)
           (decode-coding-string
            (url-unhex-string (match-string 1 source))
            (or file-name-coding-system default-file-name-coding-system 'utf-8)))
          ((string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" source) nil)
          (t (expand-file-name source)))))
    (and file (not (file-remote-p file)) file)))

(provide 'video-source)
;;; video-source.el ends here
