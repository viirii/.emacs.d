(require 'cider)
(require 'kubernetes)

(defun kubernetes--cluster-names (state)
  (-let* ((config (or (kubernetes-state-config state) (kubernetes-kubectl-await-on-async kubernetes-props state #'kubernetes-kubectl-config-view)))
          ((&alist 'clusters clusters) config))
    (--map (alist-get 'name it) clusters)))

(defcustom kubemacider-kubectl-executable "kubectl"
  "The kubectl command used for Kubernetes commands."
  :group 'kubemacider
  :type 'string)


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
          (cider-connect "localhost" local-port))))))

(defun kubemacider--server-sentinel (process event)
  "Handle server PROCESS EVENT."
  (let* ((server-buffer (process-buffer process))
         (clients (buffer-local-value 'nrepl-client-buffers server-buffer))
         (problem (if (and server-buffer (buffer-live-p server-buffer))
                      (with-current-buffer server-buffer
                        (buffer-substring (point-min) (point-max)))
                    "")))
    (when server-buffer
      (kill-buffer server-buffer))
    (cond
     ((string-match-p "^killed\\|^interrupt" event)
      nil)
     ((string-match-p "^hangup" event)
      (mapc #'cider--close-connection-buffer clients))
     ;; On Windows, a failed start sends the "finished" event. On Linux it sends
     ;; "exited abnormally with code 1".
     (t (error "Could not start server: %s" problem)))))

(defun kubemacider-start-portforward-process (cluster namespace pod-name port &optional callback)
  "Start port-forward process using shell command.
Return a newly created process.
Set `nrepl-server-filter' as the process filter, which starts REPL process
with its own buffer once the server has started.
If CALLBACK is non-nil, it should be function of 1 argument.  Once the
client process is started, the function is called with the client buffer."
  (interactive (kubemacider--interactive-select-cluster-namespace-pod))
  (let* (;; (default-directory (or directory default-directory))
         (serv-buf (get-buffer-create (generate-new-buffer-name
                                       (format "%s-%s-%s"
                                               (last (split-string cluster "_"))
                                               namespace
                                               (first (split-string pod-name "-"))))))
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
    (set-process-sentinel serv-proc 'kubemacider--server-sentinel)
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

(defun kubemacider--interactive-select-cluster-namespace-pod ()
  (let* ((ct (completing-read "Cluster: " (kubernetes--cluster-names (kubernetes-state)) nil t))
         (ns (completing-read "Namespace: " (kubernetes--namespace-names (kubernetes-state)) nil t))
         (local-state `((current-namespace . ,ns) (kubectl-flags ,(format "--cluster=%s" ct))))
         (json-pods (kubernetes-kubectl-await-on-async kubernetes-props local-state #'kubernetes-kubectl-get-pods))
         (pods (--map (alist-get 'name (alist-get 'metadata it)) (alist-get 'items json-pods)))
         (pd (completing-read "Pod: " pods nil t)))
    (list ct ns pd)))

(defun kubemacider-mixpanel-swank ()
  (interactive)
  (let* ((args (kubemacider--interactive-select-cluster-namespace-pod))
         (args (append args (list "0:7777"))))
    (apply 'kubemacider-start-portforward-process args)))

(provide 'kubemacider)
