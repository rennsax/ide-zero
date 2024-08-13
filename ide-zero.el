;;; ide-zero.el --- Configure IDE features in a breeze  -*- lexical-binding: t; -*-

;; Copyright (C) 2024  Bojun Ren

;; Author: Bojun Ren <bj.ren.coding@outlook.com>
;; Maintainer: Bojun Ren <bj.ren.coding@outlook.com>
;; URL: https://github.com/rennsax/ide-zero.git
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience languages tools

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
;; along with this program. If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Configure IDE features in a breeze.

;; Have you felt overwhelmed when trying to configure your favorite LSP servers,
;; linter, formatters, and so on? For these language-specified features, there
;; are several great packages as Emacs's implementations. They are either
;; builtin like Eglot, or third-party but really popular like flycheck and
;; lsp-mode. They expose different variables/functions for users to further
;; configure them.

;; However, what an user cares about at most of time, is just "which backend am
;; I using". For example, you may hear before that Python has several LSP
;; servers: microsoft's pyright, lighter pylsp or python-ruff. An user tells
;; ide-zero, Aha, I want to use pyright as the LSP server when I'm writing
;; Python code. Then ide-zero does that for you, leaving you peace and comfort
;; without touching the trivial details under the hood.

;; This file mainly expose a macro `ide-zero-define', which is used to define
;; user-customized ide-zero modes. For example,
;;
;;      (ide-zero-define go :mode (go-mode go-ts-mode) :lsp ("gopls"))
;;
;; will define a global minor mode `go-ide-zero-mode' for you. When this mode is
;; enabled and a buffer is changed to `go-mode' or `go-ts-mode', features
;; configured by ide-zero will be enabled automatically.

;; You can specify more properties in `ide-zero-define'. Check its documentation.

;; If you care which package is used as the client to communicate with external
;; programs, you can customize `ide-zero-*-client'. For example, if you want to
;; use the builtin linting provider `flymake', then set `ide-zero-linter-client'
;; to flycheck.

;;; Code:

(eval-when-compile (require 'pcase))

(defgroup ide-zero nil
  "Configure LSP features in a breeze."
  :prefix "ide-zero-"
  :group 'convenience
  :group 'languages
  :group 'tools)

;;;; Customization

(defcustom ide-zero-lsp-client 'eglot
  "LSP client used in Emacs."
  :type '(choice (const :tag "Eglot" eglot)
                 (const :tag "lsp-mode" lsp-mode)
                 (const :tag "manateelazycat/lsp-bridge" lsp-bridge)))

(defcustom ide-zero-linter-client 'flycheck
  "Linter client configured by ide-zero."
  :type '(choice (const :tag "Flymake" flymake)
                 (const :tag "Flycheck" flycheck)))

(defcustom ide-zero-linter-lsp-warning t
  "Whether to issue a warning when `:linter lsp' is given but `:lsp' is not."
  :type 'boolean)

;;;; variables/functions declared in other packages

(defvar eglot-server-programs)
(declare-function flycheck-mode "flycheck")
(declare-function flycheck-eglot-mode "flycheck-eglot")

;;;; Global variables that will pass down.

(defvar ide-zero--mode-or-list nil)
(defvar ide-zero--lsp nil)
(defvar ide-zero--linter nil)

;;;; Root macro.

;;;###autoload
(defmacro ide-zero-define (lang &rest plist)
  "Define ide-zero minor mode for LANG with PLIST.

The new minor mode `LANG-ide-zero-mode' is global. When it's
enabled, toggle all features that ide-zero configured for you
when entering the specified major mode(s).

PLIST:

`:mode MODE-OR-LIST'
    Mode or a list of mode. Require.

    For example, `:mode go-mode' or `:mode (go-mode go-ts-mode)'.

    The listed modes will be affected.

`:lsp LSP'
    The LSP server used in the backend. Optional.

    This should be a list of strings, where the first element is
    the executable name, and the rest elements are the arguments
    passed to the executable.

    For example, `:lsp (\"pylsp\")'.

    If not given, configure nothing for LSP.

`:linter LINTER'
    The linter to used. Optional.

    If `ide-zero-linter-client' is flycheck, the value should be
    a valid flycheck checker (determined by
    `flycheck-valid-checker-p').

    If the special value `lsp' is given, ide-zero reuses the LSP
    specified to provide the linter feature. You may make sure
    that your LSP server provides such functionality. This
    typically requires the `:lsp' property is given, otherwise
    the LSP itself may be not enabled correctly. Of course, you
    can manually configure your LSP client `ide-zero-lsp-client'.

    If not given, configure nothing for linter."
  (declare (indent 4))
  (let* ((mode (plist-get plist :mode))
         (lsp (plist-get plist :lsp))
         (linter (plist-get plist :linter))
         (minor-mode-name (format "%s-ide-zero-mode" lang))
         (minor-mode (intern minor-mode-name))
         (setup-h (intern (concat minor-mode-name "-setup-now"))))
    (unless mode
      (user-error "`:mode' property is required!"))
    (unless (or lsp linter)
      (user-error "At least one of `:lsp' or `:linter' should be given!"))
    (setq ide-zero--mode-or-list mode
          ide-zero--lsp lsp
          ide-zero--linter linter)
    (prog1
        `(progn
           (defun ,setup-h () ; TODO: add doc
             (interactive)
             ,@(remove nil (list
                            (ide-zero--handle-lsp)
                            (ide-zero--handle-linter))))
           (define-minor-mode ,minor-mode
             ,(format "Set ide-zero for %s." lang)
             :global t
             :init-value nil
             (if ,minor-mode
                 ,(ide-zero--handle-mode mode setup-h t)
               ,(ide-zero--handle-mode mode setup-h nil))))
      (setq ide-zero--mode-or-list nil
            ide-zero--lsp nil
            ide-zero--linter nil))))

;;;; Miscellaneous helper functions

(defun ide-zero--handle-mode (mode-or-list hook add)
  "Try to add/remove HOOK to/from MODE-OR-LIST, according to ADD."
  (let ((verb (if add 'add-hook 'remove-hook))
        (mode-hook (lambda (mode) (intern (concat (symbol-name mode) "-hook")))))
    (cond
     ((symbolp mode-or-list)
      `(,verb ',(funcall mode-hook mode-or-list) #',hook))
     ((listp mode-or-list)
      (macroexp-progn
       (mapcar (lambda (mode)
                 `(,verb ',(funcall mode-hook mode) #',hook))
               mode-or-list)))
     (t (user-error "Cannot handle mode: %s" mode-or-list)))))

(defun ide-zero--handle-lsp ()
  "Setup LSP as the default backend. ALIST contain additional information."
  (when ide-zero--lsp
  (pcase ide-zero-lsp-client
    ('eglot
     (let ((mode ide-zero--mode-or-list)
           (lsp ide-zero--lsp))
       (with-eval-after-load 'eglot
         (add-to-list 'eglot-server-programs `(,mode . ,lsp))))
     '(eglot-ensure))
    (_ (user-error "Unsupported LSP client: %s" ide-zero-lsp-client)))))

(defun ide-zero--handle-linter ()
  "Handle LINTER."
  (let ((fun-to-call (intern (concat "ide-zero--handle-linter/" (symbol-name ide-zero-linter-client)))))
    (if (fboundp fun-to-call)
        (funcall fun-to-call)
      (user-error "Unsupported linter client: %s" ide-zero-linter-client))))

(defun ide-zero--handle-linter/flycheck ()
  "Handle LINTER for `flycheck'."
  (cond
   ((eq ide-zero--linter 'lsp)
    (when (and ide-zero-linter-lsp-warning
               (null ide-zero--lsp))
      (warn "You've request to reuse the LSP feature for linting, but the \
`:lsp' property is not given."))
    (pcase ide-zero-lsp-client
      ('eglot
       (quote
        ;; HACK: If the current buffer is not managed by elgot,
        ;; `flycheck-eglot--setup' does noting. And since `eglot-ensure' is
        ;; asynchronous, simply `(flycheck-elgot-mode +1)' probably fail to
        ;; setup `flycheck-elgot-mode'. So I examine whether eglot is managing
        ;; this buffer manually, and if not, a hook is injected into
        ;; `eglot-managed-mode-hook' to enable `flycheck-eglot-mode' later. The
        ;; hook will remove itself, so it does not interfere other settings (as
        ;; long as you are not so unlucky).
        (if (eglot-managed-p)
            (flycheck-eglot-mode +1)
          (add-hook 'eglot-managed-mode-hook
                    'flycheck-eglot--enable-and-remove-self-h))))
      (_
       (user-error "You want to integrate flycheck with %s, but that's unsupported!"
                   ide-zero-lsp-client))))
   ((eq ide-zero--linter 'default)
    '(flycheck-mode +1))
   ((symbolp ide-zero--linter)
    `(progn
       (setq flycheck-checker ',ide-zero--linter)
       (flycheck-mode +1)))
   (t (user-error "Cannot handle linter: %s" ide-zero--linter))))

(defun flycheck-eglot--enable-and-remove-self-h ()
  "This hook should be added to `eglot-managed-mode-hook'."
  (flycheck-eglot-mode +1)
  (remove-hook 'eglot-managed-mode-hook
               'flycheck-eglot--enable-and-remove-self-h))

(defun ide-zero--flycheck-resolve-linter (linter-name)
  (let ((checker (intern linter-name)))
    checker))

(provide 'ide-zero)
;;; ide-zero.el ends here
