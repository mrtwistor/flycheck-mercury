;;; flycheck-mercury.el --- Mercury support in Flycheck -*- lexical-binding: t; -*-

;; Copyright (c) 2014 Matthias Güdemann <matthias.gudemann@gmail.com>
;;
;; Author: Matthias Güdemann <matthias.gudemann@gmail.com>
;; URL: https://github.com/flycheck/flycheck-mercury
;; Keywords: convenience languages tools
;; Version: 0.1-cvs
;; Package-Requires: ((flycheck "0.15") (s "1.9.0") (dash "2.4.0"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Add a Mercury checker to Flycheck using the Melbourne Mercury Compiler.

;;; Code:

(require 's)
(require 'dash)
(require 'flycheck)

(flycheck-def-option-var flycheck-mmc-message-width 1000 mercury-mmc
  "Max width to pass to option `--max-error-line-width' of mmc."
  :type 'integer
  :safe #'integerp)

(flycheck-def-option-var flycheck-mmc-max-message-width 0 mercury-mmc
  "Truncate messages longer than `flycheck-mmc-max-message-width`.
  A value of 0 prevents truncating."
  :type 'integer
  :safe #'integerp)

(flycheck-def-option-var flycheck-mmc-max-message-lines 0 mercury-mmc
  "Truncate messages with more lines than `flycheck-mmc-max-message-lines`.
  A value of 0 prevents truncating."
  :type 'integer
  :safe #'integerp)

(flycheck-def-option-var flycheck-mmc-interface-dirs
    '("Mercury/ints"
      "Mercury/int0s"
      "Mercury/int2s"
      "Mercury/int3s")
    mercury-mmc
  "List of interface directories to pass to option `-I' of mmc.")

(defun flycheck-mmc-assign-error-line (output)
  "Assigns line 1 to errors without line number from OUTPUT.

Some errors do not have a line number assigned, these are the
lines starting with one of:
 * Uncaught Mercury exception
 * Software Error
 * mercury_compile
 * with whitespace
instead of `filename' `:' `line-number' `:'.

We assigne line 1 to these errors as they in general represent
errors concerning the whole module file.  This avoids having a
checker that returns error, but does not display error messages.

Removes message to use `-E' option for more information on errors
for very long error messages."
  (let ((prefix-list '("mercury_compile:" "Uncaught Mercury exception:"
                       "Software Error:" "  ")))
    (-map #'(lambda (zeile)
              (if (-any? #'(lambda (prefix)
                             (s-starts-with? prefix zeile)) prefix-list)
                  (s-append (s-chop-prefixes prefix-list zeile) "foo:001:")
                zeile))
          (-remove #'(lambda (zeile)
                       (s-starts-with? "For more information, recompile with `-E'." zeile))
                   output))))

(defun flycheck-mmc-truncate-message-length (message)
  "Truncate MESSAGE according to `flycheck-mmc-max-message-width`.

If `flycheck-mmc-max-message-width` has a positive value, MESSAGE
is truncated to this length - 3 and `...` is added at the end.
Any value less than or equal to zero has no effect."
  (if (>= 0 flycheck-mmc-max-message-width)
      message
    (s-truncate flycheck-mmc-max-message-width message)))

(defun flycheck-mmc-compute-line-desc-pairs (output)
  "Compute list of (linenumber . part of message) from OUTPUT.

OUTPUT is the raw mercury warning / error message output of the
format: 'filename ':' linenumber ':' errormessage'."
  (mapcar #'(lambda (num-desc)
              (cons (string-to-number (car num-desc))
                    (flycheck-mmc-truncate-message-length
                     (s-chop-prefix " "
                                    (-reduce #'(lambda (zeile rest)
                                                 (concat zeile ":" rest))
                                             (cdr num-desc))))))
          (-remove #'(lambda (x) (eq x nil))
                   (mapcar #'(lambda (zeile)
                               (cdr (split-string zeile ":")))
                           (flycheck-mmc-assign-error-line
                            (split-string output "\n"))))))

(defun flycheck-mmc-truncate-message-lines (num-desc-list)
  "Truncate NUM-DESC-LIST according to `flycheck-mmc-max-message-lines`.

If `flycheck-mmc-max-message-lines` has a positive value, the
number of message lines per source line is truncated to that
value and `...` is added as last line.  Any value less than or
equal to zero has no effect."
  (if (>= 0 flycheck-mmc-max-message-lines)
      num-desc-list
    (if (<= (length num-desc-list) flycheck-mmc-max-message-lines)
        num-desc-list
      (append
       (-take flycheck-mmc-max-message-lines num-desc-list)
       (list (cons (caar num-desc-list) "..."))))))

(defun flycheck-mmc-compute-line-desc-maps (line-desc-pairs)
  "Compute map of line numbers to messages from LINE-DESC-PAIRS.

The input list of pairs of linenumbers and messages is
transformed to a list of lists where each sublist is a list of
cons cells containing the linenumber and message part.  The
result is grouped for line numbers."
  (mapcar #'flycheck-mmc-truncate-message-lines
          (mapcar #'(lambda (elem)
                      (-filter #'(lambda (x)
                                   (eq (car x) elem)) line-desc-pairs))
                  (delete-dups (mapcar #'(lambda (line-desc)
                                           (car line-desc)) line-desc-pairs)))))

(defun flycheck-mmc-compute-final-list (line-desc-maps)
  "Compute alist from LINE-DESC-MAPS.

Computes an alist from the line numbers to the concatenation of
messages for that line number."
  (mapcar #'(lambda (entry)
              (list (car (car entry))
                    (-reduce #'(lambda (prefix rest)
                                 (concat prefix rest "\n"))
                             (cons "" (mapcar #'cdr entry)))))
          line-desc-maps))

(defun flycheck-mmc-compute-flycheck-errors (final-list)
  "Compute the list fo flycheck-error objects from FINAL-LIST."
  (mapcar #'(lambda (x)
              (flycheck-error-new :line (car x)
                                  :message (cadr x)
                                  :level (if (string-match "arning" (cadr x))
                                             'warning
                                           'error)))
          final-list))

(eval-and-compile
  (defun flycheck-mmc-error-parser (output _checker _buffer)
    "Parse the OUTPUT buffer, ignore CHECKER and BUFFER.

Parses the Mercury warning / error output, provides interface
for :error-parser functions for Flycheck."
    (let ((line-desc-pairs (flycheck-mmc-compute-line-desc-pairs output)))
      (let ((line-desc-maps (flycheck-mmc-compute-line-desc-maps line-desc-pairs)))
        (let ((final-list (flycheck-mmc-compute-final-list line-desc-maps)))
          (flycheck-mmc-compute-flycheck-errors final-list))))))

(flycheck-define-checker mercury-mmc
  "A Mercury syntax and type checker using mmc.

See URL `http://mercurylang.org/'."
  :command ("mmc"
            "-e"
            (option-list "-I" flycheck-mmc-interface-dirs)
            (option "--max-error-line-width"
                    flycheck-mmc-message-width
                    flycheck-option-int)
            source)
  :error-parser flycheck-mmc-error-parser
  :modes (mercury-mode prolog-mode))

(add-to-list 'flycheck-checkers 'mercury-mmc)

(provide 'flycheck-mercury)

;; Local Variables:
;; coding: utf-8
;; indent-tabs-mode: nil
;; End:

;;; flycheck-mercury.el ends here
