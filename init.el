;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Set path to dependencies

;; Added by Package.el.  This must come before configurations of
;; installed packages.  Don't delete this line.  If you don't want it,
;; just comment it out by adding a semicolon to the start of the line.
;; You may delete these explanatory comments.
(package-initialize)

(setq site-lisp-dir
      (expand-file-name "site-lisp" user-emacs-directory))

(setq settings-dir
      (expand-file-name "settings" user-emacs-directory))

;; Set up load path
(add-to-list 'load-path settings-dir)
(add-to-list 'load-path site-lisp-dir)

 (add-to-list 'package-archives
   '("melpa-stable" . "http://melpa-stable.milkbox.net/packages/"))

 (add-to-list 'package-archives
   '("melpa" . "http://melpa.milkbox.net/packages/"))

 (add-to-list 'package-archives
   '("marmalade" . "http://marmalade-repo.org/packages/"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Keep emacs Custom-settings in separate file
(setq user-emacs-directory "~/.emacs.d/") ;; for Aquamacs
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(if (file-readable-p custom-file) (load custom-file))

;; Settings for currently logged in user
(setq user-settings-dir
      (concat user-emacs-directory "users/" user-login-name "@" system-name))
(add-to-list 'load-path user-settings-dir)
(load (concat (getenv "HOME") "/analytics/clj/resources/emacs"))

;; ;; Add external projects to load path
;; (dolist (project (directory-files site-lisp-dir t "\\w+"))
;;   (when (file-directory-p project)
;;     (add-to-list 'load-path project)))

;; Write backup files to own directory
(setq backup-directory-alist
      `(("." . ,(expand-file-name
                 (concat user-emacs-directory "backups")))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Load default setting
(load "global")

;; Setup package
(require 'setup-package)

;; Load packages for any systems
(require 'default-packages)

;; Set up appearance early
(require 'appearance)

;; Lets start with a smattering of sanity
(require 'sane-defaults)

;; Don't use expand-region fast keys
;; (setq expand-region-fast-keys-enabled nil)

;; Show expand-region command used
;; (setq er--show-expansion-message t)

;; Setup key bindings
;; (require 'key-bindings)

;; Misc
;; (require 'project-archetypes)
;; (require 'my-misc)

;; For mac
(when is-mac (require 'mac))

;; clipboard
;;(add-to-list 'load-path "~/.emacs.d/elpa/xclip-1.3/")
;;(require 'xclip)
;;(xclip-mode 1)

(add-to-list 'load-path "~/.emacs.d/site-lisp/helm/") ; facultative when installed with make install
(require 'helm-config)
(global-set-key (kbd "M-x") #'helm-M-x)
(global-set-key (kbd "C-x r b") #'helm-filtered-bookmarks)
(global-set-key (kbd "C-x C-f") #'helm-find-files)

(add-to-list 'load-path "~/.emacs.d/site-lisp/nyan-mode")
(when (require 'nyan-mode nil t)
  (nyan-mode))

;; Elisp go-to-definition with M-. and back again with M-,
;; (autoload 'elisp-slime-nav-mode "elisp-slime-nav")
;; (add-hook 'emacs-lisp-mode-hook (lambda () (elisp-slime-nav-mode t) (eldoc-mode 1)))

;; Conclude init by setting up specifics for the current user
(when (file-exists-p user-settings-dir)
  (mapc 'load (directory-files user-settings-dir nil "^[^#].*el$")))
