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

;; Source URIs, local files, media kinds, animation metadata, and HTTP headers.
;; Only the explicit Lottie metadata query loads the native module on demand.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'image)
(require 'url-util)
(require 'json)

(declare-function video-native-lottie-metadata "video-module" (uri))

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

(defun video-source-apng-metadata (source)
  "Read local SOURCE's APNG header metadata without decoding pixels.
Return dimensions, frame count and normalized loop count, or nil when the
header is not APNG.  Skip ancillary payloads and stop before image data.
Playback validates the complete stream; recognition does not hide its errors."
  (when-let* ((file (video-source-file source))
              ((file-regular-p file))
              ((file-readable-p file)))
    (condition-case nil
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (cl-labels ((uint32 (at)
                       (+ (ash (char-after at) 24)
                          (ash (char-after (+ at 1)) 16)
                          (ash (char-after (+ at 2)) 8)
                          (char-after (+ at 3)))))
            (catch 'metadata
              (insert-file-contents-literally file nil 0 33)
              (unless (and (= (buffer-size) 33)
                           (equal (buffer-substring-no-properties 1 9)
                                  (unibyte-string 137 80 78 71 13 10 26 10))
                           (= (uint32 9) 13)
                           (equal (buffer-substring-no-properties 13 17) "IHDR"))
                (throw 'metadata nil))
              (let ((width (uint32 17))
                    (height (uint32 21))
                    (size (file-attribute-size (file-attributes file)))
                    (offset 33))
                (unless (and (> width 0) (> height 0))
                  (throw 'metadata nil))
                (while (<= (+ offset 12) size)
                  (erase-buffer)
                  (insert-file-contents-literally file nil offset (+ offset 8))
                  (unless (= (buffer-size) 8) (throw 'metadata nil))
                  (let ((length (uint32 1))
                        (type (buffer-substring-no-properties 5 9)))
                    (unless (<= (+ offset length 12) size)
                      (throw 'metadata nil))
                    (cond
                     ((equal type "acTL")
                      (unless (= length 8) (throw 'metadata nil))
                      (erase-buffer)
                      (insert-file-contents-literally
                       file nil (+ offset 8) (+ offset 16))
                      (unless (= (buffer-size) 8) (throw 'metadata nil))
                      (let ((frames (uint32 1)) (plays (uint32 5)))
                        (throw 'metadata
                               (and (> frames 0)
                                    (list :width width :height height
                                          :frames frames
                                          :loop-count
                                          (cond ((zerop plays) 0)
                                                ((> plays 1) (1- plays))))))))
                     ((member type '("IDAT" "IEND")) (throw 'metadata nil)))
                    (setq offset (+ offset length 12))))))))
      (file-error nil))))

(defun video-source-format (source)
  "Infer `lottie' or `apng' for recognized local SOURCE contents.
Remote URLs and arbitrary JSON are not claimed.  Recognition does not load
the renderer; a recognized source's actual load errors remain errors."
  (when-let* ((file (video-source-file source))
              ((file-regular-p file))
              ((file-readable-p file)))
    (cond
     ((string-equal (downcase (or (file-name-extension file) "")) "lottie")
      'lottie)
     ((video-source-apng-metadata file) 'apng)
     ((condition-case nil
          (with-temp-buffer
            (insert-file-contents file nil 0 512)
            (goto-char (point-min))
            (skip-chars-forward " \t\r\n")
            (when (eq (char-after) ?{)
              (erase-buffer)
              (insert-file-contents file)
              (goto-char (point-min))
              (let* ((data (json-parse-buffer :object-type 'hash-table
                                            :array-type 'array
                                            :null-object nil :false-object nil))
                     (width (gethash "w" data))
                     (height (gethash "h" data))
                     (rate (gethash "fr" data))
                     (first (gethash "ip" data))
                     (last (gethash "op" data)))
                (and (stringp (gethash "v" data))
                     (vectorp (gethash "layers" data))
                     (numberp width) (> width 0)
                     (numberp height) (> height 0)
                     (numberp rate) (> rate 0)
                     (numberp first) (numberp last) (> last first)))))
        (error nil))
      'lottie))))

(defun video-source-lottie-metadata (source)
  "Return intrinsic animation metadata for local Lottie SOURCE.
Load the native renderer on demand and propagate invalid-source errors."
  (require 'video-module)
  (video-native-lottie-metadata (video-source-uri source)))

(defun video-source-select-format (source format)
  "Validate FORMAT or infer it from SOURCE when FORMAT is nil."
  (unless (memq format '(nil lottie apng))
    (error "Unsupported media source format: %S" format))
  (or format (video-source-format source)))

(defconst video--image-extension-regexp
  "\\.\\(?:apng\\|avif\\|bmp\\|gif\\|heic\\|heif\\|jpe?g\\|png\\|svgz?\\|tiff?\\|webp\\)\\(?:[?#].*\\)?\\'"
  "File-name suffixes recognized as still image sources.")

(defun video-source-kind (source)
  "Return `image' or `video' for SOURCE."
  (if (or (video-source-format source)
          (and (file-readable-p source)
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
