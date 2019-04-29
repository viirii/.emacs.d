(require 'cider)
(require 'kubernetes)

;;; Code:

(defcustom kubemacider-kubectl-executable "kubectl"
  "The kubectl command used for Kubernetes commands."
  :group 'kubemacider
  :type 'string)

(defun kubernetes--cluster-names (state)
  (-let* ((config (or (kubernetes-state-config state) (kubernetes-kubectl-await-on-async kubernetes-props state #'kubernetes-kubectl-config-view)))
          ((&alist 'clusters clusters) config))
    (--map (alist-get 'name it) clusters)))

(defun kubemacider--portforward-server-filter (process output)
  "Process portforward server output from PROCESS contained in OUTPUT."
  ;; In Windows this can be false:
  (let ((server-buffer (process-buffer process)))
    (when (buffer-live-p server-buffer)
      (with-current-buffer server-buffer
        ;; auto-scroll on new output
        (let ((moving (= (point) (process-mark process))))
          (save-excursion
            (goto-char (process-mark process))
            (insert output)
            (ansi-color-apply-on-region (process-mark process) (point))
            (set-marker (process-mark process) (point)))
          (when moving
            (goto-char (process-mark process))
            (when-let ((win (get-buffer-window)))
              (set-window-point win (point))))))
      ;; detect the port the server is listening on from its output
      (when (string-match "Forwarding from 127.0.0.1:\\([0-9]+\\) -> \\([0-9]+\\)" output)
        (let ((local-port (string-to-number (match-string 1 output)))
              (remote-port (string-to-number (match-string 2 output))))
          (message "port-forwarding started on %s:%s" local-port remote-port)
          (with-current-buffer server-buffer
            (let* ((client-proc (cider-nrepl-connect (thread-first nil
                                                       (plist-put :port local-port)
                                                       (plist-put :server process))))
                   (client-buffer (process-buffer client-proc))
                   (client-buffer-name (replace-regexp-in-string "nrepl-server"
                                                                 "cider-repl"
                                                                 (buffer-name))))
              (with-current-buffer client-buffer
                (rename-buffer client-buffer-name))
              (setq nrepl-client-buffers
                    (cons client-buffer
                          (delete client-buffer nrepl-client-buffers)))
              (when (functionp nrepl-post-client-callback)
                (funcall nrepl-post-client-callback client-buffer)))))))))

(defun kubemacider-start-portforward-process (cluster namespace pod-name port &optional callback)
  "Start port-forward process using shell command.
   Return a newly created process. This follows `nrepl-start-server-process'."
  (interactive (kubemacider--interactive-select-cluster-namespace-pod))
  (let* ((serv-buf (get-buffer-create (generate-new-buffer-name
                                       (nrepl-server-buffer-name
                                        (format "%s-%s-%s"
                                                (car (last (split-string cluster "_")))
                                                namespace
                                                (car (split-string pod-name "-")))))))
         (cmd (mapconcat 'identity
                         (list kubemacider-kubectl-executable
                               (format "--cluster=%s" cluster)
                               (format "--namespace=%s" namespace)
                               "port-forward"
                               pod-name
                               port)
                         " "))
         (serv-proc (start-file-process-shell-command
                     "kubectl-portforward-server" serv-buf cmd)))
    (set-process-filter serv-proc 'kubemacider--portforward-server-filter)
    (set-process-sentinel serv-proc 'nrepl-server-sentinel)
    (set-process-coding-system serv-proc 'utf-8-unix 'utf-8-unix)
    (with-current-buffer serv-buf
      ;; (setq nrepl-project-dir directory)
      (setq nrepl-post-client-callback callback)
      (setq-local nrepl-create-client-buffer-function
                  nrepl-create-client-buffer-function)
      (setq-local nrepl-use-this-as-repl-buffer
                  nrepl-use-this-as-repl-buffer))
    (message "Starting kubectl-portforward server via %s..."
             (propertize cmd 'face 'font-lock-keyword-face))
    serv-proc))

(defun kubemacider--cider-repl-create (endpoint)
  "Create a REPL buffer and install `cider-repl-mode'.
ENDPOINT is a plist as returned by `nrepl-connect'."
  ;; Connection might not have been set as yet. Please don't send requests here.
  (let* ((reuse-buff (not (eq 'new nrepl-use-this-as-repl-buffer)))
         (buff-name (nrepl-make-buffer-name nrepl-repl-buffer-name-template nil
                                            ;; kubemacider--cluster-namespace-pod
                                            "default-name"
                                            (plist-get endpoint :port)
                                            reuse-buff)))
    ;; when reusing, rename the buffer accordingly
    (when (and reuse-buff
               (not (equal buff-name nrepl-use-this-as-repl-buffer)))
      ;; uniquify as it might be Nth connection to the same endpoint
      (setq buff-name (generate-new-buffer-name buff-name))
      (with-current-buffer nrepl-use-this-as-repl-buffer
        (rename-buffer buff-name)))
    (with-current-buffer (get-buffer-create buff-name)
      (unless (derived-mode-p 'cider-repl-mode)
        (cider-repl-mode)
        (setq cider-repl-type "clj"))
      (setq nrepl-err-handler #'cider-default-err-handler)
      (cider-repl-reset-markers)
      (add-hook 'nrepl-response-handler-functions #'cider-repl--state-handler nil 'local)
      (add-hook 'nrepl-connected-hook 'cider--connected-handler nil 'local)
      (add-hook 'nrepl-disconnected-hook 'cider--disconnected-handler nil 'local)
      (current-buffer))))

(defun kubemacider--interactive-select-cluster-namespace-pod ()
  (let* ((ct (completing-read "Cluster: " (kubernetes--cluster-names (kubernetes-state)) nil t))
         (ns (completing-read "Namespace: " (kubernetes--namespace-names (kubernetes-state)) nil t))
         (local-state `((current-namespace . ,ns) (kubectl-flags ,(format "--cluster=%s" ct))))
         (json-pods (kubernetes-kubectl-await-on-async kubernetes-props local-state #'kubernetes-kubectl-get-pods))
         (pods (--map (alist-get 'name (alist-get 'metadata it)) (alist-get 'items json-pods)))
         (pd (completing-read "Pod: " pods nil t)))
    (list ct ns pd)))

(defun kubemacider--add-tramp-method (cluster namespace pod-name)
  (let ((c (car (last (split-string cluster "_"))))
        (n namespace)
        (p (car (split-string pod-name "-"))))
    (add-to-list 'tramp-methods
                 `(,(format "kube-%s-%s-%s" c n p)
                   (tramp-login-program "kubectl")
                   (tramp-login-args
                    (("exec")
                     ("-it")
                     (,pod-name)
                     ("--namespace")
                     (,namespace)
                     ("--cluster")
                     (,cluster)
                     ("/bin/sh")))
                   (tramp-login-env
                    (("SHELL")
                     ("/bin/sh")))
                   (tramp-remote-shell "/bin/sh")))))

(defun kubemacider-mixpanel-swank ()
  (interactive)
  (let* ((cnp (kubemacider--interactive-select-cluster-namespace-pod))
         (args (append cnp (list "0:7777")))
         (nrepl-create-client-buffer-function  #'kubemacider--cider-repl-create))
    (apply 'kubemacider-start-portforward-process args)))

(defun kubemacider-add-tramp-method ()
  (interactive)
  (let* ((cnp (kubemacider--interactive-select-cluster-namespace-pod)))
    (apply 'kubemacider--add-tramp-method cnp)
    (message (format "tramp method added for %s" cnp))))

(provide 'kubemacider)

