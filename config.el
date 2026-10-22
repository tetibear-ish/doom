;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

(setq doom-theme 'doom-one)
(setq org-directory "~/org/")
(setq display-line-numbers-type 'relative)

;;; Help
(defun my/open-doom-config-file ()
  "Prompt for a Doom config file and open it."
  (interactive)
  (let* ((doom-dir (or (bound-and-true-p doom-user-dir)
                       (expand-file-name "~/.config/doom/")))
         (files '("config.el"
                  "init.el"
                  "packages.el"
                  "cli.el"
                  "custom.el"))
         (existing-files
          (seq-filter
           (lambda (file)
             (file-exists-p (expand-file-name file doom-dir)))
           files))
         (selection
          (completing-read
           "Open Doom config file: "
           existing-files
           nil
           t)))
    (find-file (expand-file-name selection doom-dir))))

(map! :leader

      (:prefix ("h" . "help")
       :desc "Open Doom config file"
       "h" #'my/open-doom-config-file

       :desc "Reload configuration"
       "r" #'doom/reload

       :desc "Module"
       "m" #'doom/help-modules

       :prefix ("m" . "doom/help-modules")
       ))

;;; Project commands
(defun my/--string-alist-p (value)
  "Return non-nil if VALUE is a well-formed alist of (STRING . STRING)
pairs, e.g. `my/project-run-scripts' or `my/project-test-scripts'."
  (and (listp value)
       (seq-every-p (lambda (pair)
                      (and (consp pair)
                           (stringp (car pair))
                           (stringp (cdr pair))))
                    value)))

(defvar-local my/project-test-scripts nil
  "Alist of (NAME . COMMAND) test commands for the current project,
e.g. ((\"unit\" . \"npm test\") (\"e2e\" . \"npm run test:e2e\")).
Selected from via `SPC p t' (`my/project-test'), which also offers a
\"Create new test script...\" entry to define, persist, and run one.
Meant to be set via .dir-locals.el, either by hand or via that prompt.")

(put 'my/project-test-scripts 'safe-local-variable #'my/--string-alist-p)

(defvar-local my/project-clean-and-compile-command nil
  "Shell command used to clean and compile the current project.")

(defvar-local my/project-run-command nil
  "Shell command used to run the current project.")

(defun my/project-root ()
  "Return the current project root, or 'default-directory'."
  (or (doom-project-root)
      default-directory))

(defun my/run-project-command (command-variable description)
  "Run COMMAND-VARIABLE from the project root.

DESCRIPTION is used when prompting for a command."
  (let* ((configured-command (symbol-value command-variable))
         (command
          (or configured-command
              (read-shell-command
               (format "%s command: " description)))))
    (unless (and command
                 (stringp command)
                 (not (string-empty-p command)))
      (user-error "No %s command configured" description))

    (let ((default-directory (my/project-root)))
      (compile command))))

(defun my/--project-compile (root command)
  "Run COMMAND via `compile', with `default-directory' bound to ROOT."
  (let ((default-directory root))
    (compile command)))

(defconst my/--new-test-script-choice "Create new test script..."
  "Sentinel candidate `my/project-test' offers to define a new script.")

(defun my/--project-test-script-create (root source-buffer)
  "Prompt for a new named test script, persist it, then run it.

SOURCE-BUFFER's `my/project-test-scripts' value is read and updated;
ROOT is where the command runs and where .dir-locals.el is written."
  (let ((name (string-trim (read-string "New test script name: "))))
    (when (string-empty-p name)
      (user-error "Test script name can't be empty"))
    (when (assoc name (buffer-local-value 'my/project-test-scripts source-buffer))
      (user-error "A test script named %S already exists" name))
    (let* ((command (string-trim (read-shell-command (format "Command for %S: " name))))
           (updated (cons (cons name command)
                          (buffer-local-value 'my/project-test-scripts source-buffer))))
      (when (string-empty-p command)
        (user-error "Test script command can't be empty"))
      (my/--persist-dir-local-alist 'my/project-test-scripts root updated)
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (setq-local my/project-test-scripts updated)))
      (my/--project-compile root command))))

(defun my/project-test ()
  "Select and run one of the project's configured test scripts (`SPC p t').

Prompts with the names of the test scripts defined in this project's
.dir-locals.el (`my/project-test-scripts'), plus \"Create new test
script...\" to define, persist, and immediately run a new one."
  (interactive)
  ;; If invoked from a non-file buffer (e.g. the project dashboard),
  ;; `my/project-test-scripts' was never populated by the normal
  ;; find-file-time dir-locals machinery, since that only fires for
  ;; file-visiting buffers. Force it, the same way `dired'/`vc-dir' do.
  (unless buffer-file-name
    (hack-dir-local-variables-non-file-buffer))
  (let* ((root (my/project-root))
         (source-buffer (current-buffer))
         (scripts my/project-test-scripts)
         (choice (completing-read "Test script: "
                                   (append (mapcar #'car scripts)
                                           (list my/--new-test-script-choice))
                                   nil t)))
    (if (equal choice my/--new-test-script-choice)
        (my/--project-test-script-create root source-buffer)
      (my/--project-compile root (cdr (assoc choice scripts))))))

(defun my/project-clean-and-compile ()
  "Run the configured clean and compile command for the current project."
  (interactive)
  (my/run-project-command
   'my/project-clean-and-compile-command
   "Project clean and compile"))

(defun my/project-run ()
  "Run the configured run command for the current project."
  (interactive)
  (my/run-project-command
   'my/project-run-command
   "Project run"))

;;;; Persistent, named run scripts (dev servers, watchers, etc.)
;;
;; Unlike `my/project-run', these are long-lived processes: each named
;; script gets its own reusable process buffer (via `comint', like
;; `M-x shell') instead of sharing the single `compile' buffer, so e.g.
;; "dev" and "res:dev" can run at the same time without one killing the
;; other. `SPC p R' opens a menu of the current project's configured
;; scripts.
;;
;; This used to spawn a `vterm' per script, but `vterm' (a) requires
;; explicitly loading `vterm-mode' first since Doom only autoloads
;; that, not the raw `vterm' command, and (b) has to be fed the command
;; as simulated keystrokes after the shell starts, which races the
;; shell's own startup and can silently drop the command. Running the
;; command directly as the process's argv via `make-comint-in-buffer'
;; sidesteps both problems.

(defvar-local my/project-run-scripts nil
  "Alist of (NAME . COMMAND) persistent run scripts for the current
project, e.g. ((\"dev\" . \"npm run dev\") (\"res:dev\" . \"npm run res:dev\")).
Each is run in its own dedicated process buffer via the `SPC p R' menu.
Meant to be set via .dir-locals.el, either by hand or via the menu's
\"Define a new run script...\" entry.")

(put 'my/project-run-scripts 'safe-local-variable #'my/--string-alist-p)

(defun my/--project-run-buffer-name (name)
  "Return the dedicated process buffer name for run script NAME."
  (format "*run:%s:%s*" (projectile-project-name) name))

(defun my/--project-run-buffer (name)
  "Return the live process buffer for run script NAME, or nil."
  (let ((buffer (get-buffer (my/--project-run-buffer-name name))))
    (and buffer
         (buffer-live-p buffer)
         (let ((process (get-buffer-process buffer)))
           (and process (process-live-p process)))
         buffer)))

(defvar-local my/--run-script-exit-status nil
  "Human-readable status of this run-script buffer's last finished
process, e.g. \"Exited 0\" or \"Killed\"; nil while running, or if it
has never exited (fresh buffer).")

(defun my/--project-run-script-sentinel (list-buffer-name process event)
  "Record PROCESS's exit status and refresh LIST-BUFFER-NAME if it's live.

Chains to the normal default sentinel first, so the buffer still gets
the usual \"Process ... finished/exited\" message."
  (internal-default-process-sentinel process event)
  (when (memq (process-status process) '(exit signal))
    (let ((buffer (process-buffer process)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq my/--run-script-exit-status
                (if (eq (process-status process) 'signal)
                    "Killed"
                  (format "Exited %d" (process-exit-status process)))))))
    (let ((list-buffer (get-buffer list-buffer-name)))
      (when (buffer-live-p list-buffer)
        (with-current-buffer list-buffer
          (revert-buffer))))))

(defun my/--project-start-script (name command root)
  "Start COMMAND for run script NAME from ROOT in a fresh process buffer."
  (let* ((default-directory root)
         (buffer-name (my/--project-run-buffer-name name))
         (list-buffer-name (format "*Run Scripts: %s*" (projectile-project-name))))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (with-current-buffer (make-comint-in-buffer
                           name buffer-name
                           shell-file-name nil shell-command-switch command)
      ;; `shell-mode' does this itself; plain `comint-mode' doesn't.
      (add-hook 'comint-output-filter-functions #'ansi-color-process-output nil t)
      (when-let ((process (get-buffer-process (current-buffer))))
        (set-process-sentinel
         process
         (apply-partially #'my/--project-run-script-sentinel list-buffer-name))))))

(defun my/--project-restart-script (name command root)
  "Kill any running process for NAME, then start it again with COMMAND."
  (when-let ((buffer (my/--project-run-buffer name)))
    (when-let ((process (get-buffer-process buffer)))
      (set-process-query-on-exit-flag process nil))
    (kill-buffer buffer))
  (my/--project-start-script name command root))

(defun my/--project-run-script-dispatch (name scripts root)
  "Run or restart run script NAME, looking up its command in SCRIPTS."
  (let ((command (cdr (assoc name scripts))))
    (unless command
      (user-error "No run script named %S configured" name))
    (if (my/--project-run-buffer name)
        (my/--project-restart-script name command root)
      (my/--project-start-script name command root))
    (pop-to-buffer (get-buffer (my/--project-run-buffer-name name)))))

(defun my/--persist-dir-local-alist (variable root value)
  "Persist VALUE as ROOT's .dir-locals.el value for VARIABLE.

Used for both `my/project-run-scripts' and `my/project-test-scripts'."
  (let* ((file (expand-file-name dir-locals-file root))
         (already-open (find-buffer-visiting file)))
    ;; Passing FILE explicitly is required: without it,
    ;; `modify-dir-local-variable' picks the target file from the *current
    ;; buffer's* `buffer-file-name' (falling back to `default-directory'
    ;; only when that's nil), not from ROOT/`default-directory' directly.
    ;; Callers like `my/--new-run-script-finish' invoke this right after
    ;; `kill-buffer'-ing an unrelated scratch buffer, so relying on ambient
    ;; buffer state silently wrote to the wrong (or a nonexistent) project's
    ;; .dir-locals.el, which is why scripts weren't persisting.
    (add-dir-local-variable nil variable value file)
    (when-let ((buffer (find-buffer-visiting file)))
      (with-current-buffer buffer
        (save-buffer)
        (unless already-open
          (kill-buffer))))))

(defvar-local my/--new-run-script-name nil)
(defvar-local my/--new-run-script-root nil)
(defvar-local my/--new-run-script-source-buffer nil)
(defvar-local my/--new-run-script-list-buffer nil)

(defun my/--new-run-script-finish ()
  "Save the buffer's contents as NAME's command, adding or replacing it."
  (interactive)
  (let ((name my/--new-run-script-name)
        (root my/--new-run-script-root)
        (source-buffer my/--new-run-script-source-buffer)
        (list-buffer my/--new-run-script-list-buffer)
        (command (string-trim (buffer-string))))
    (when (string-empty-p command)
      (user-error "Run script command is empty"))
    (kill-buffer)
    (let ((updated (cons (cons name command)
                          (assoc-delete-all name
                                            (buffer-local-value 'my/project-run-scripts
                                                                 source-buffer)
                                            #'equal))))
      (my/--persist-dir-local-alist 'my/project-run-scripts root updated)
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (setq-local my/project-run-scripts updated))))
    (message "Saved run script %S." name)
    (when (buffer-live-p list-buffer)
      (with-current-buffer list-buffer
        (revert-buffer)))))

(defun my/--new-run-script-abort ()
  "Discard the run script command being written."
  (interactive)
  (kill-buffer)
  (message "Discarded changes."))

(defun my/--project-run-script-editor (name root source-buffer list-buffer initial-command)
  "Open a buffer to write NAME's shell command, seeded with INITIAL-COMMAND.

Refreshes LIST-BUFFER (the `my/project-run-scripts-mode' buffer, if any)
once the script is saved."
  (let ((buffer (generate-new-buffer (format "*run script: %s*" name))))
    (with-current-buffer buffer
      (sh-mode)
      (when initial-command
        (insert initial-command))
      (setq-local my/--new-run-script-name name)
      (setq-local my/--new-run-script-root root)
      (setq-local my/--new-run-script-source-buffer source-buffer)
      (setq-local my/--new-run-script-list-buffer list-buffer)
      (setq-local header-line-format
                  (format "Write the shell command for %S.  C-c C-c to save, C-c C-k to discard."
                          name))
      (use-local-map (make-sparse-keymap))
      (set-keymap-parent (current-local-map) sh-mode-map)
      (local-set-key (kbd "C-c C-c") #'my/--new-run-script-finish)
      (local-set-key (kbd "C-c C-k") #'my/--new-run-script-abort))
    (pop-to-buffer buffer)))

(defun my/project-run-script-define-new (root source-buffer &optional list-buffer)
  "Open a buffer to write a new project run script's shell command."
  (let ((name (string-trim (read-string "New run script name: "))))
    (when (string-empty-p name)
      (user-error "Run script name can't be empty"))
    (when (assoc name (buffer-local-value 'my/project-run-scripts source-buffer))
      (user-error "A run script named %S already exists" name))
    (my/--project-run-script-editor name root source-buffer list-buffer nil)))

(defun my/project-run-script-edit (name root source-buffer &optional list-buffer)
  "Open a buffer to edit run script NAME's existing shell command."
  (let ((command (cdr (assoc name (buffer-local-value 'my/project-run-scripts source-buffer)))))
    (unless command
      (user-error "No run script named %S configured" name))
    (my/--project-run-script-editor name root source-buffer list-buffer command)))

;;;; Run-scripts list buffer, `SPC p R' (like `list-processes'/`package-menu')

(defvar-local my/project-run-scripts--root nil
  "Project root this `my/project-run-scripts-mode' buffer is showing.")

(defvar-local my/project-run-scripts--source-buffer nil
  "Buffer whose `my/project-run-scripts' dir-local value this list edits.")

(defun my/--project-run-scripts-status (name)
  "Return a propertized status string for run script NAME: \"Running\",
an exit status like \"Exited 0\"/\"Killed\" left over from its last
run, or \"Not running\" if it's never been started (or its buffer was
since killed)."
  (cond
   ((my/--project-run-buffer name)
    (propertize "Running" 'face 'success))
   ((let ((buffer (get-buffer (my/--project-run-buffer-name name))))
      (and buffer (buffer-live-p buffer)
           (buffer-local-value 'my/--run-script-exit-status buffer)))
    (let ((status (buffer-local-value
                   'my/--run-script-exit-status
                   (get-buffer (my/--project-run-buffer-name name)))))
      (propertize status 'face (if (equal status "Exited 0") 'shadow 'error))))
   (t (propertize "Not running" 'face 'shadow))))

(defun my/--project-run-scripts-entries ()
  "Build `tabulated-list-entries' from the source buffer's run scripts."
  (when (buffer-live-p my/project-run-scripts--source-buffer)
    (mapcar
     (lambda (script)
       (let ((name (car script)))
         (list name (vector name (my/--project-run-scripts-status name)))))
     (buffer-local-value 'my/project-run-scripts my/project-run-scripts--source-buffer))))

(defun my/project-run-scripts-run ()
  "Run or restart the run script at point, or start reading its output."
  (interactive)
  (let ((name (or (tabulated-list-get-id) (user-error "No run script here")))
        (root my/project-run-scripts--root)
        (scripts (buffer-local-value 'my/project-run-scripts
                                      my/project-run-scripts--source-buffer))
        (list-buffer (current-buffer)))
    (my/--project-run-script-dispatch name scripts root)
    (when (buffer-live-p list-buffer)
      (with-current-buffer list-buffer
        (revert-buffer)))))

(defun my/project-run-scripts-delete ()
  "Delete the run script at point, after confirmation."
  (interactive)
  (let ((name (or (tabulated-list-get-id) (user-error "No run script here")))
        (root my/project-run-scripts--root)
        (source-buffer my/project-run-scripts--source-buffer))
    (when (yes-or-no-p (format "Delete run script %S? " name))
      (when-let ((buffer (my/--project-run-buffer name)))
        (when-let ((process (get-buffer-process buffer)))
          (set-process-query-on-exit-flag process nil))
        (kill-buffer buffer))
      (let ((updated (assoc-delete-all name
                                        (buffer-local-value 'my/project-run-scripts
                                                             source-buffer)
                                        #'equal)))
        (my/--persist-dir-local-alist 'my/project-run-scripts root updated)
        (when (buffer-live-p source-buffer)
          (with-current-buffer source-buffer
            (setq-local my/project-run-scripts updated))))
      (message "Deleted run script %S." name)
      (revert-buffer))))

(defun my/project-run-scripts-edit ()
  "Edit the shell command of the run script at point."
  (interactive)
  (let ((name (or (tabulated-list-get-id) (user-error "No run script here"))))
    (my/project-run-script-edit name
                                 my/project-run-scripts--root
                                 my/project-run-scripts--source-buffer
                                 (current-buffer))))

(defun my/project-run-scripts-kill ()
  "Kill the running process for the script at point, without deleting it."
  (interactive)
  (let ((name (or (tabulated-list-get-id) (user-error "No run script here"))))
    (if-let ((buffer (my/--project-run-buffer name)))
        (progn
          (when-let ((process (get-buffer-process buffer)))
            (set-process-query-on-exit-flag process nil))
          (kill-buffer buffer)
          (message "Killed run script %S." name)
          (revert-buffer))
      (message "Run script %S is not running." name))))

(defun my/project-run-scripts-add ()
  "Define a new run script for this project, from the run-scripts list."
  (interactive)
  (my/project-run-script-define-new my/project-run-scripts--root
                                     my/project-run-scripts--source-buffer
                                     (current-buffer)))

(defvar my/project-run-scripts-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    map)
  "Keymap for `my/project-run-scripts-mode'.")

;; evil-collection puts `tabulated-list-mode' (our parent) in evil's normal
;; state, where "a"/"d"/"r"/"g" are already claimed by evil-normal-state-map
;; (append/delete-operator/replace-char/motion-prefix) with higher priority
;; than a plain `define-key' on our own local map. `map!' with an explicit
;; state binds through evil's own override mechanism instead, so it wins.
(map! :map my/project-run-scripts-mode-map
      :n "RET" #'my/project-run-scripts-run
      :n "r"   #'my/project-run-scripts-run
      :n "x"   #'my/project-run-scripts-kill
      :n "e"   #'my/project-run-scripts-edit
      :n "d"   #'my/project-run-scripts-delete
      :n "a"   #'my/project-run-scripts-add
      :n "g"   #'revert-buffer
      :n "q"   #'quit-window)

(define-derived-mode my/project-run-scripts-mode tabulated-list-mode "Run-Scripts"
  "Major mode listing a project's persistent, named run scripts.

RET/\"r\" runs the script at point, or kills and restarts it if it's
already running. \"x\" kills its process without deleting it. \"e\"
edits its command. \"d\" deletes it after confirmation. \"a\" defines
a new one. Changes are persisted to the project's .dir-locals.el."
  (setq tabulated-list-format [("Script" 24 t) ("Status" 12 t)]
        tabulated-list-padding 2
        tabulated-list-sort-key '("Script" . nil)
        tabulated-list-entries #'my/--project-run-scripts-entries)
  ;; Skip `tabulated-list-init-header': it unconditionally overwrites
  ;; `header-line-format' with clickable column labels, which would
  ;; clobber the legend below. Column sorting is still reachable via
  ;; evil-collection's "S" binding (`tabulated-list-sort').
  (setq header-line-format
        (concat "RET/r: run or restart   x: kill   e: edit   d: delete   "
                "a: add new script   g: refresh   q: quit")))

(defun my/project-run-scripts-menu ()
  "Open a list of the current project's persistent run scripts (`SPC p R')."
  (interactive)
  ;; If invoked from a non-file buffer (e.g. the project dashboard),
  ;; `my/project-run-scripts' was never populated by the normal
  ;; find-file-time dir-locals machinery, since that only fires for
  ;; file-visiting buffers. Force it, the same way `dired'/`vc-dir' do,
  ;; so edits here don't get merged against a spuriously empty list.
  (unless buffer-file-name
    (hack-dir-local-variables-non-file-buffer))
  (let* ((root (my/project-root))
         (source-buffer (current-buffer))
         (buffer (get-buffer-create (format "*Run Scripts: %s*"
                                             (projectile-project-name)))))
    (with-current-buffer buffer
      (my/project-run-scripts-mode)
      (setq my/project-run-scripts--root root
            my/project-run-scripts--source-buffer source-buffer)
      (tabulated-list-print))
    (pop-to-buffer buffer)))

;; Permit these string-valued variables in .dir-locals.el files.
(dolist (variable '(my/project-clean-and-compile-command
                    my/project-run-command))
  (put variable 'safe-local-variable #'stringp))

;;; Project dashboard
;;;
;; A per-project landing page: branch/status, recent commits, and recent
;; files. Replaces the "find a file to open" prompt that normally runs
;; after switching to a project's workspace.

(defvar-local my/project-dashboard-root nil
  "Project root the current dashboard buffer is showing.")

(defun my/project-dashboard--git (root &rest args)
  "Run git ARGS in ROOT, returning trimmed stdout, or nil on failure."
  (when (executable-find "git")
    (let ((default-directory root))
      (with-temp-buffer
        (when (zerop (apply #'call-process "git" nil t nil args))
          (string-trim (buffer-string)))))))

(defun my/project-dashboard--recent-files (root limit)
  "Return up to LIMIT entries from `recentf-list' living under ROOT."
  (require 'recentf)
  (let ((root (file-truename root)))
    (seq-take
     (seq-filter (lambda (file) (string-prefix-p root (file-truename file)))
                 recentf-list)
     limit)))

(defun my/--insert-heading (text)
  (insert (propertize text 'face 'magit-section-heading) "\n"))

(defun my/project-dashboard--insert-file-button (file root)
  (insert "  ")
  (insert-text-button
   (file-relative-name file root)
   'action (lambda (_btn) (find-file file))
   'follow-link t
   'help-echo file)
  (insert "\n"))

(defun my/project-dashboard--insert-commit-button (line root)
  "Insert LINE, a \"git log --oneline\" entry, as a clickable button."
  (let ((hash (car (split-string line))))
    (insert "  ")
    (insert-text-button
     line
     'action (lambda (_btn)
               (let ((default-directory root))
                 (magit-show-commit hash)))
     'follow-link t)
    (insert "\n")))

(defun my/project-dashboard--render (root)
  "Render the project dashboard for ROOT into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq my/project-dashboard-root root
          default-directory root)

    (insert (propertize (doom-project-name root) 'face 'doom-dashboard-banner-face) "\n")
    (insert (propertize (abbreviate-file-name root) 'face 'font-lock-comment-face) "\n\n")

    (when-let (branch (my/project-dashboard--git root "rev-parse" "--abbrev-ref" "HEAD"))
      (insert (propertize (format "On branch %s\n\n" branch) 'face 'magit-branch-current)))

    (my/--insert-heading "Changes")
    (let ((status (my/project-dashboard--git root "status" "--short")))
      (if (and status (not (string-empty-p status)))
          (dolist (line (split-string status "\n" t))
            (insert "  " line "\n"))
        (insert "  working tree clean\n")))
    (insert "\n")

    (my/--insert-heading "Recent commits")
    (let ((log (my/project-dashboard--git root "log" "--oneline" "-10")))
      (if (and log (not (string-empty-p log)))
          (dolist (line (split-string log "\n" t))
            (my/project-dashboard--insert-commit-button line root))
        (insert "  (no commits)\n")))
    (insert "\n")

    (my/--insert-heading "Recent files")
    (let ((files (my/project-dashboard--recent-files root 10)))
      (if files
          (dolist (file files)
            (my/project-dashboard--insert-file-button file root))
        (insert "  (none)\n")))
    (insert "\n")

    (insert (propertize "[s] status  [l] log  [f] find file  [g] refresh  [q] quit\n"
                         'face 'font-lock-comment-face))
    (goto-char (point-min))))

(defun my/project-dashboard-refresh ()
  "Refresh the project dashboard buffer."
  (interactive)
  (if my/project-dashboard-root
      (my/project-dashboard--render my/project-dashboard-root)
    (user-error "Not in a project dashboard buffer")))

(defvar my/project-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "g" #'my/project-dashboard-refresh)
    (define-key map "s" #'magit-status)
    (define-key map "l" #'magit-log-current)
    (define-key map "f" #'projectile-find-file)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `my/project-dashboard-mode'.")

(define-derived-mode my/project-dashboard-mode special-mode "Project-Dashboard"
  "Major mode for the per-project dashboard buffer."
  (setq truncate-lines t))

(defun my/project-dashboard (&optional root)
  "Open a dashboard (status, recent commits, recent files) for the
project at ROOT, or the current project."
  (interactive)
  (let* ((root (file-truename (or root (my/project-root))))
         (buf (get-buffer-create (format "*Project: %s*" (doom-project-name root)))))
    (with-current-buffer buf
      (my/project-dashboard-mode)
      (my/project-dashboard--render root))
    (switch-to-buffer buf)))

;; Doom's workspaces module calls this after switching a project's
;; workspace, instead of prompting to open a file.
(setq +workspaces-switch-project-function #'my/project-dashboard)

;;; Keybindings
;;;

(map! :leader
      :desc "Execute command"
      "SPC" #'execute-extended-command

      (:prefix "p"
       :desc "Test project"
       "t" #'my/project-test

       :desc "Clean and compile project"
       "c" #'my/project-clean-and-compile

       :desc "Run project"
       "r" #'my/project-run

       :desc "Run scripts (long-lived)"
       "R" #'my/project-run-scripts-menu

       :desc "Add project"
       "a" #'my/projectile-add-known-project

       :desc "Help"
       "h" #'my/projectile-open-readme

       :desc "Switch project"
       "p" #'my/projectile-switch-project

       :desc "Project dashboard"
       "d" #'my/project-dashboard

       :desc "Project diary"
       "j" #'my/project-diary-open
       )

      (:prefix-map ("d" . "dired")
       :desc "Dired (current window)" "d" #'dired-jump))

;; Global (non-leader) shortcut: open a new Dired buffer at $HOME.
(map! "C-S-h" (cmd! (dired "~/")))

;;; Git
(defun my/github-create-repo ()
  "Create a GitHub repository for the current project via `gh repo
create' and push to it (`SPC g h n').

Requires an existing local git repository (`SPC g i') and the `gh'
CLI, authenticated (`gh auth login')."
  (interactive)
  (let ((root (my/project-root)))
    (unless (file-directory-p (expand-file-name ".git" root))
      (user-error "Not a git repository yet; run `SPC g i' first"))
    (let* ((default-name (file-name-nondirectory (directory-file-name root)))
           (name (read-string (format "GitHub repository name (%s): " default-name)
                               nil nil default-name))
           (visibility (completing-read "Visibility: " '("private" "public") nil t))
           (default-directory root))
      (compile (format "gh repo create %s --%s --source=. --remote=origin --push"
                        (shell-quote-argument name)
                        visibility)))))

(map! :leader
      (:prefix "g"
       :desc "Init repo" "i" #'magit-init

       (:prefix-map ("h" . "github")
        :desc "New repo" "n" #'my/github-create-repo)))

(defun my/projectile-forget-selected-project ()
  "Remove the currently highlighted Vertico project entry from Projectile."
  (interactive)
  (unless (and (bound-and-true-p vertico--index)
               (>= vertico--index 0))
    (user-error "No project candidate is selected"))
  (let ((project
         (substring-no-properties
          (vertico--candidate))))
    (unless (member project projectile-known-projects)
      (user-error "Selected candidate is not a known Projectile project"))
    (when (y-or-n-p
           (format "Forget project %s? "
                   (abbreviate-file-name project)))
      ;; This forgets the entry; it does not delete the directory.
      (projectile-remove-known-project project)

      ;; Swap the stale snapshot for the updated list.
      (setq minibuffer-completion-table
            (projectile-relevant-known-projects))

      ;; Invalidate Vertico's candidate cache so it actually recomputes.
      (setq vertico--input t)

      ;; Force Vertico to recompute and redraw the candidates.
      (vertico--exhibit)
      (message "Forgot project: %s"
               (abbreviate-file-name project)))))

(defun my/projectile-switch-project ()
  "Switch projects, with 'Del' available to forget the selected entry."
  (interactive)
  (minibuffer-with-setup-hook
      (lambda ()
        (local-set-key
         (kbd "<delete>")
         #'my/projectile-forget-selected-project))
    (call-interactively #'projectile-switch-project)))

(defun my/projectile-add-known-project (project-root)
  "Add PROJECT-ROOT to the list of known projects.
Unlike `projectile-add-known-project', a directory with no recognized
project markers (e.g. a fresh empty directory with no `.git') isn't
just added and left to fail the next time you try to switch to it --
offer to `git init' it on the spot instead."
  (interactive (list (read-directory-name "Add to known projects: ")))
  (let ((project-root (file-name-as-directory (expand-file-name project-root))))
    (unless (projectile-project-p project-root)
      (unless (y-or-n-p (format "%s is not a project yet.  Initialize a git repo there? "
                                 (abbreviate-file-name project-root)))
        (user-error "Not added"))
      (let ((default-directory project-root))
        (vc-create-repo 'Git)))
    (projectile-add-known-project project-root)
    (message "Added project: %s" (abbreviate-file-name project-root))))

(after! projectile
  (add-to-list 'projectile-project-root-files-bottom-up ".obsidian"))

;; Scratch buffer opens in markdown-mode (SPC x)
(setq doom-scratch-initial-major-mode 'markdown-mode)

;; Hide ** and # markup, keep the pretty fontification
(add-hook 'markdown-mode-hook #'markdown-toggle-markup-hiding)

;; Zettelkasten-style notes: flat, tag-categorized, linked via org-roam.
;;
(after! org
  (setq org-roam-directory "/Users/tetibear/Org/roam/"
        org-roam-db-location (concat org-roam-directory ".org-roam.db")))

(defvar my/note-categories
  '(("idea"        :tag "idea"
     :template "* Summary\n\n* Why it matters\n\n* First concrete step\n")
    ("observation" :tag "observation"
     :template "* What I noticed\n\n* Context\n\n* Why it stood out\n")
    ("question"    :tag "question"
     :template "* The question\n\n* What I already know\n\n* Where to look\n\n* Answer\n")
    ("feature"     :tag "feature"
     :template "* Summary\n\n* Platform\n\n* First concrete step\n")
    ("monetizable idea"     :tag "monetizable"
     :template "* Summary\n\n* Business Model\n\n* First concrete step\n")
    ("todo"        :tag "todo"
     :template "* Notes\n\n* Done when\n"))
  "Alist mapping a note category name to its `:tag' and `:template'.
Every category prompts for an optional subcategory (hub) note to link to.")

(defun my/--slug (title)
  (string-trim (replace-regexp-in-string "[^a-zA-Z0-9]+" "-" (downcase title)) "-" "-"))

(defun my/--note-file (title)
  (expand-file-name (format "%s-%s.org" (format-time-string "%Y%m%d") (my/--slug title))
                    org-roam-directory))

(defun my/--write-note (file id title tag body)
  "Write a new flat org-roam node to FILE, unless it already exists."
  (find-file file)
  (when (= (buffer-size) 0)
    (insert (format ":PROPERTIES:\n:ID:       %s\n:END:\n#+title: %s\n#+filetags: :%s:\n\n%s"
                    id title tag body))
    (save-buffer)
    (goto-char (point-min))
    (search-forward "* " nil t)
    (end-of-line)))

(defun my/--hub-nodes ()
  "Return an alist of (TITLE . ID) for existing hub/subcategory notes."
  (require 'org-roam)
  (let (result)
    (dolist (node (org-roam-node-list) result)
      (when (member "hub" (org-roam-node-tags node))
        (push (cons (org-roam-node-title node) (org-roam-node-id node)) result)))))

(defun my/--create-hub (title)
  "Create a new hub note titled TITLE; return (ID . TITLE)."
  (let ((id (org-id-new)))
    (my/--write-note (my/--note-file title) id title "hub" "* Notes\n\n")
    (cons id title)))

(defun my/--select-hub ()
  "Prompt for an optional subcategory/hub note; return (ID . TITLE) or nil."
  (let* ((none "[none]")
         (new  "[create new]")
         (hubs (my/--hub-nodes))
         (choice (completing-read "Subcategory: " (append (list none new) (mapcar #'car hubs))
                                  nil t)))
    (cond
     ((equal choice none) nil)
     ((equal choice new) (my/--create-hub (read-string "New subcategory name: ")))
     (t (cons (cdr (assoc choice hubs)) choice)))))

(defun my/new-note ()
  "Create a new note, prompting for a category and an optional subcategory."
  (interactive)
  (let* ((category (completing-read "Category: " (mapcar #'car my/note-categories) nil t))
         (spec (cdr (assoc category my/note-categories)))
         (title (read-string (format "%s title: " (capitalize category))))
         (hub (my/--select-hub))
         (id (org-id-new))
         (body (concat (if hub (format "* Category\n[[id:%s][%s]]\n\n" (car hub) (cdr hub)) "")
                       (plist-get spec :template))))
    (my/--write-note (my/--note-file title) id title (plist-get spec :tag) body)))

(defun my/list-notes ()
  "Find and open any org-roam note."
  (interactive)
  (org-roam-node-find))

(map! :leader
      :prefix ("n" . "notes")
      :desc "New note"     "n" #'my/new-note
      :desc "List notes"   "N" #'my/list-notes
      :desc "Diary (today)" "d" #'org-roam-dailies-goto-today)

;;; Books
;;;
;; Each book is a subdirectory of `my/books-directory', named by slug
;; and holding an "_book.org" with its #+TITLE. Chapters live flat
;; inside their book's directory, each file named "NNN-slug.org" so
;; filename order is reading order; reordering a chapter (`M-j'/`M-k'
;; in `my/book-menu') renumbers files rather than relying on creation
;; order. Each book appears as its own tile on the writing dashboard
;; (`SPC o o'), renamable there with "r"; picking one, or its "Add
;; book" tile, opens `my/book-menu', which shows that book's chapters
;; as buttons (each renamable with "r"), plus "^" to go back to the
;; dashboard.

(defvar my/books-directory (expand-file-name "books/" org-directory)
  "Directory containing one subdirectory per book.")

(defun my/--org-title (file)
  "Return FILE's #+TITLE, or its base filename if it has none yet."
  (or (and (file-exists-p file)
           (with-temp-buffer
             (insert-file-contents file nil 0 2000)
             (goto-char (point-min))
             (when (re-search-forward "^#\\+TITLE:[ \t]*\\(.*\\)$" nil t)
               (string-trim (match-string 1)))))
      (file-name-base file)))

(defun my/--org-set-title (file title)
  "Set FILE's #+TITLE to TITLE, preserving the rest of its contents
(or creating FILE with just that title if it doesn't exist yet)."
  (let ((buf (find-buffer-visiting file)))
    (with-temp-buffer
      (when (file-exists-p file)
        (insert-file-contents file))
      (goto-char (point-min))
      (if (re-search-forward "^#\\+TITLE:.*$" nil t)
          (replace-match (concat "#+TITLE: " title) t t)
        (insert (format "#+TITLE: %s\n" title)))
      (write-region nil nil file nil 'quiet))
    (when buf
      (with-current-buffer buf (revert-buffer t t t)))))

(defun my/--book-meta-file (book-dir)
  (expand-file-name "_book.org" book-dir))

(defun my/--book-title (book-dir)
  "Return BOOK-DIR's book title, falling back to its directory name."
  (let ((meta (my/--book-meta-file book-dir)))
    (if (file-exists-p meta)
        (my/--org-title meta)
      (file-name-nondirectory (directory-file-name book-dir)))))

(defun my/--books-list ()
  "Return the existing book directories, sorted by title."
  (when (file-directory-p my/books-directory)
    (sort (seq-filter #'file-directory-p
                       (directory-files my/books-directory t "\\`[^.]"))
          (lambda (a b) (string< (my/--book-title a) (my/--book-title b))))))

(defun my/book-add ()
  "Create a new book and open its (empty) chapter list
(`SPC o o', then its \"Add book\" tile)."
  (interactive)
  (make-directory my/books-directory t)
  (let* ((title (string-trim (read-string "Book title: ")))
         (dir (expand-file-name (my/--slug title) my/books-directory)))
    (when (string-empty-p title)
      (user-error "Book title can't be empty"))
    (when (file-directory-p dir)
      (user-error "A book named %S already exists" title))
    (make-directory dir t)
    (with-temp-buffer
      (insert (format "#+TITLE: %s\n" title))
      (write-region nil nil (my/--book-meta-file dir)))
    (my/book-menu dir)))

(defun my/--book-chapter-files (book-dir)
  "Return BOOK-DIR's chapter files, sorted into reading order."
  (when (file-directory-p book-dir)
    (sort (directory-files book-dir t "\\`[0-9]\\{3,\\}-.*\\.org\\'")
          #'string<)))

(defun my/--book-chapter-number (file)
  "Return FILE's chapter number, parsed from its filename prefix."
  (if (string-match "\\`\\([0-9]+\\)-" (file-name-nondirectory file))
      (string-to-number (match-string 1 (file-name-nondirectory file)))
    0))

(defun my/--book-chapter-set-number (file number)
  "Rename FILE's chapter-number prefix to NUMBER, returning the new path.
Used to reorder chapters, since filename order is reading order."
  (let* ((dir (file-name-directory file))
         (slug (if (string-match "\\`[0-9]+-\\(.*\\)\\.org\\'" (file-name-nondirectory file))
                   (match-string 1 (file-name-nondirectory file))
                 (file-name-sans-extension (file-name-nondirectory file))))
         (new-file (expand-file-name (format "%03d-%s.org" number slug) dir)))
    (unless (string= (expand-file-name file) new-file)
      (rename-file file new-file)
      (when-let ((buf (find-buffer-visiting file)))
        (with-current-buffer buf (set-visited-file-name new-file t t))))
    new-file))

(defvar-local my/book-menu--book-dir nil
  "Book directory the current chapter-list buffer is showing.")

(defun my/book-add-chapter ()
  "Create a new chapter in the current book and open it
(`SPC o o', pick a book, then \"a\")."
  (interactive)
  (unless (derived-mode-p 'my/book-menu-mode)
    (user-error "Not in a book's chapter list"))
  (let* ((book-dir my/book-menu--book-dir)
         (title (string-trim (read-string "Chapter title: ")))
         (number (1+ (apply #'max 0 (mapcar #'my/--book-chapter-number
                                             (my/--book-chapter-files book-dir)))))
         (file (expand-file-name (format "%03d-%s.org" number (my/--slug title))
                                  book-dir)))
    (when (string-empty-p title)
      (user-error "Chapter title can't be empty"))
    (find-file file)
    (when (= (buffer-size) 0)
      (insert (format "#+TITLE: %s\n\n* \n\n" title))
      (goto-char (point-max))
      (save-buffer))))

(defun my/book-menu--insert-chapter-button (file)
  (insert "  ")
  (insert-text-button
   (format "%d. %s" (my/--book-chapter-number file) (my/--org-title file))
   'action (lambda (_btn) (find-file file))
   'follow-link t
   'help-echo file
   'my/file file)
  (insert "\n"))

(defun my/book-menu--chapter-file-at-point ()
  "Return the chapter file for the button at point, or nil."
  (when-let ((btn (button-at (point))))
    (button-get btn 'my/file)))

(defun my/book-menu--render ()
  (let ((inhibit-read-only t)
        (book-dir my/book-menu--book-dir))
    (erase-buffer)
    (setq default-directory book-dir)
    (insert (propertize (my/--book-title book-dir) 'face 'doom-dashboard-banner-face) "\n")
    (insert (propertize (abbreviate-file-name book-dir) 'face 'font-lock-comment-face) "\n\n")
    (my/--insert-heading "Chapters")
    (let ((files (my/--book-chapter-files book-dir)))
      (if files
          (dolist (file files)
            (my/book-menu--insert-chapter-button file))
        (insert "  (no chapters yet)\n")))
    (insert "\n  ")
    (insert-text-button "+ Add a chapter..."
                         'action (lambda (_btn) (my/book-add-chapter))
                         'follow-link t)
    (insert "\n\n")
    (insert (propertize "RET/click: open   a: add chapter   r: rename   M-j/M-k: move   ^: back to books   g: refresh   q: quit\n"
                         'face 'font-lock-comment-face))
    (goto-char (point-min))))

(defun my/book-menu-refresh ()
  "Refresh the current book's chapter list."
  (interactive)
  (my/book-menu--render))

(defun my/book-menu-rename-chapter ()
  "Rename the chapter at point, i.e. set its #+TITLE
(`SPC o o', pick a book, then \"r\")."
  (interactive)
  (unless (derived-mode-p 'my/book-menu-mode)
    (user-error "Not in a book's chapter list"))
  (let ((file (my/book-menu--chapter-file-at-point)))
    (unless file
      (user-error "No chapter at point"))
    (let ((title (string-trim (read-string "New chapter title: " (my/--org-title file)))))
      (when (string-empty-p title)
        (user-error "Chapter title can't be empty"))
      (my/--org-set-title file title)))
  (my/book-menu--render))

(defun my/book-menu--goto-file (file)
  "Move point to FILE's chapter button, if currently displayed."
  (goto-char (point-min))
  (let ((pos (next-button (point-min) t)))
    (while (and pos (not (equal (button-get (button-at pos) 'my/file) file)))
      (setq pos (next-button pos)))
    (when pos (goto-char pos))))

(defun my/book-menu--move-chapter (delta)
  "Move the chapter at point DELTA places (-1: earlier, 1: later)
in reading order, renumbering files as needed."
  (unless (derived-mode-p 'my/book-menu-mode)
    (user-error "Not in a book's chapter list"))
  (let ((file (my/book-menu--chapter-file-at-point)))
    (unless file
      (user-error "No chapter at point"))
    (let* ((files (my/--book-chapter-files my/book-menu--book-dir))
           (idx (seq-position files file #'string=))
           (other-idx (and idx (+ idx delta))))
      (unless (and other-idx (>= other-idx 0) (< other-idx (length files)))
        (user-error "Already at the %s" (if (> delta 0) "end" "start")))
      (let* ((other (nth other-idx files))
             (n1 (my/--book-chapter-number file))
             (n2 (my/--book-chapter-number other))
             (holding (1+ (apply #'max (mapcar #'my/--book-chapter-number files))))
             (moved (my/--book-chapter-set-number file holding)))
        (my/--book-chapter-set-number other n1)
        (let ((final (my/--book-chapter-set-number moved n2)))
          (my/book-menu--render)
          (my/book-menu--goto-file final))))))

(defun my/book-menu-move-chapter-down ()
  "Move the chapter at point later in reading order (`M-j')."
  (interactive)
  (my/book-menu--move-chapter 1))

(defun my/book-menu-move-chapter-up ()
  "Move the chapter at point earlier in reading order (`M-k')."
  (interactive)
  (my/book-menu--move-chapter -1))

(defvar my/book-menu-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "a" #'my/book-add-chapter)
    (define-key map "r" #'my/book-menu-rename-chapter)
    (define-key map (kbd "M-j") #'my/book-menu-move-chapter-down)
    (define-key map (kbd "M-k") #'my/book-menu-move-chapter-up)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `my/book-menu-mode'.")

;; "^" and "g" are motions (evil-first-non-blank / the goto-map
;; prefix), bound with higher priority than a plain `define-key' by
;; evil's own normal-state-map -- `special-mode' (our parent) gets
;; NORMAL state by default, same as `tabulated-list-mode' above.
;; `map!' with an explicit state binds through evil's own override
;; mechanism instead, so it wins.
(map! :map my/book-menu-mode-map
      :n "^" #'my/writing-dashboard
      :n "g" #'my/book-menu-refresh)

(define-derived-mode my/book-menu-mode special-mode "Book"
  "Major mode listing one book's chapters, with an \"Add a chapter...\"
entry to create the next one, \"r\" to rename the chapter at point,
\"M-j\"/\"M-k\" to reorder it, and \"^\" to return to the book list."
  (setq truncate-lines t))

(defun my/book-menu (book-dir)
  "Open BOOK-DIR's chapter list."
  (let ((buf (get-buffer-create (format "*Book: %s*" (my/--book-title book-dir)))))
    (with-current-buffer buf
      (my/book-menu-mode)
      (setq my/book-menu--book-dir book-dir)
      (my/book-menu--render))
    (switch-to-buffer buf)))

;;; Writing dashboard
;;;
;; A landing page for writing (`SPC o o'), laid out as a row of ASCII-
;; art tiles: a notebook (new note), one tile per in-progress book,
;; an "Add book" tile, and a diary tile. "h"/"j"/"k"/"l" move the
;; selection between tiles (wrapping, and wrapping into further rows
;; if there isn't room for them all on one line) and RET activates
;; whichever tile is selected.

(defconst my/writing-dashboard--tile-width 11
  "Display width of one tile's art/label column.")

(defconst my/writing-dashboard--tile-gap 2
  "Spaces between adjacent tile columns.")

(defconst my/writing-dashboard--art-notebook
  '("┌─────┐"
    "│≡ ≡ ≡│"
    "│≡ ≡ ≡│"
    "└─────┘")
  "ASCII art for the \"new note\" tile.")

(defconst my/writing-dashboard--art-book
  '("       "
    "▛▀▀▀▀▀▜"
    "▌     ▐"
    "▙▄▄▄▄▄▟")
  "ASCII art for a book tile.")

(defconst my/writing-dashboard--art-diary
  '("       "
    "▛▀▀▀▀▀▜"
    "▌  ♥  ▐"
    "▙▄▄▄▄▄▟")
  "ASCII art for the diary tile.")

(defconst my/writing-dashboard--art-add-book
  '("┌─────┐"
    "│     │"
    "│  +  │"
    "└─────┘")
  "ASCII art for the \"add a book\" tile.")

(defvar-local my/writing-dashboard--index 0
  "Index of the currently selected tile.")

(defun my/writing-dashboard--tiles ()
  "Notebook, one tile per in-progress book, \"Add book\", then diary."
  (append
   (list (list :label "Notebook" :art my/writing-dashboard--art-notebook
               :action #'my/new-note))
   (mapcar (lambda (dir)
             (list :label (my/--book-title dir)
                   :art my/writing-dashboard--art-book
                   :dir dir
                   :action (lambda () (my/book-menu dir))))
           (my/--books-list))
   (list (list :label "Add book" :art my/writing-dashboard--art-add-book
               :action #'my/book-add))
   (list (list :label "Diary" :art my/writing-dashboard--art-diary
               :action #'org-roam-dailies-goto-today))))

(defun my/writing-dashboard--per-row (count)
  "How many of COUNT tiles fit per row at the current window width."
  (max 1 (min count (/ (window-body-width)
                        (+ my/writing-dashboard--tile-width
                           my/writing-dashboard--tile-gap)))))

(defun my/writing-dashboard--center (text width)
  "Center TEXT in a field WIDTH wide, truncating if it doesn't fit."
  (let* ((text (if (> (string-width text) width)
                    (truncate-string-to-width text width nil nil "…")
                  text))
         (pad (- width (string-width text)))
         (left (/ pad 2)))
    (concat (make-string left ?\s) text (make-string (- pad left) ?\s))))

(defun my/writing-dashboard--tile-cell (text selected)
  "Center TEXT in one tile column, highlighted when SELECTED."
  (let ((cell (my/writing-dashboard--center text my/writing-dashboard--tile-width)))
    (if selected (propertize cell 'face 'highlight) cell)))

(defun my/writing-dashboard--row-line (row line-fn selected-idx)
  "Render one display line across ROW, a list of (IDX . TILE), using
LINE-FN to pull that line's text out of each tile."
  (mapconcat
   (lambda (idx-tile)
     (my/writing-dashboard--tile-cell (funcall line-fn (cdr idx-tile))
                                       (= (car idx-tile) selected-idx)))
   row
   (make-string my/writing-dashboard--tile-gap ?\s)))

(defun my/writing-dashboard--insert-centered (text &optional face)
  (let* ((width (window-body-width))
         (pad (max 0 (/ (- width (string-width text)) 2))))
    (insert (make-string pad ?\s)
            (if face (propertize text 'face face) text)
            "\n")))

(defun my/writing-dashboard--insert-wrapped-centered (text &optional face)
  "Word-wrap TEXT to the window width, inserting each line centered.
Tile labels truncate hard at `my/writing-dashboard--tile-width'; this is
where the selected tile's full, untruncated title actually gets read."
  (let* ((fill-column (max 20 (- (window-body-width) 8)))
         (wrapped (with-temp-buffer
                    (insert text)
                    (fill-region (point-min) (point-max))
                    (buffer-string))))
    (dolist (line (split-string wrapped "\n"))
      (my/writing-dashboard--insert-centered line face))))

(defun my/writing-dashboard--render ()
  (let* ((inhibit-read-only t)
         (tiles (my/writing-dashboard--tiles))
         (count (length tiles)))
    (setq my/writing-dashboard--index
          (if (zerop count) 0 (mod my/writing-dashboard--index count)))
    (erase-buffer)
    (insert "\n\n")
    (let* ((title " WRITING ")
           (rule (make-string (string-width title) ?═)))
      (my/writing-dashboard--insert-centered (concat "╔" rule "╗") 'doom-dashboard-banner-face)
      (my/writing-dashboard--insert-centered (concat "║" title "║") 'doom-dashboard-banner-face)
      (my/writing-dashboard--insert-centered (concat "╚" rule "╝") 'doom-dashboard-banner-face))
    (insert "\n")
    (if (zerop count)
        (my/writing-dashboard--insert-centered "a quiet place to put words down" 'font-lock-comment-face)
      (my/writing-dashboard--insert-wrapped-centered
       (plist-get (nth my/writing-dashboard--index tiles) :label)
       'doom-dashboard-banner-face))
    (insert "\n\n")
    (if (zerop count)
        (my/writing-dashboard--insert-centered "(nothing here yet)" 'font-lock-comment-face)
      (let* ((per-row (my/writing-dashboard--per-row count))
             (col-step (+ my/writing-dashboard--tile-width my/writing-dashboard--tile-gap))
             (indexed (seq-map-indexed (lambda (tile idx) (cons idx tile)) tiles))
             (rows (seq-partition indexed per-row)))
        (dolist (row rows)
          (let* ((row-width (- (* (length row) col-step) my/writing-dashboard--tile-gap))
                 (indent (make-string (max 0 (/ (- (window-body-width) row-width) 2)) ?\s)))
            (dotimes (line 4)
              (insert indent
                      (my/writing-dashboard--row-line
                       row (lambda (tile) (nth line (plist-get tile :art)))
                       my/writing-dashboard--index)
                      "\n"))
            (insert indent
                    (my/writing-dashboard--row-line
                     row (lambda (tile) (plist-get tile :label))
                     my/writing-dashboard--index)
                    "\n\n")))))
    (my/writing-dashboard--insert-centered "h/j/k/l: move   RET: open   r: rename   g: refresh   q: quit"
                                            'font-lock-comment-face)
    (goto-char (point-min))))

(defun my/writing-dashboard-refresh ()
  "Refresh the writing dashboard buffer."
  (interactive)
  (my/writing-dashboard--render))

(defun my/writing-dashboard--move (delta)
  (let ((count (length (my/writing-dashboard--tiles))))
    (when (> count 0)
      (setq my/writing-dashboard--index (mod (+ my/writing-dashboard--index delta) count))
      (my/writing-dashboard--render))))

(defun my/writing-dashboard-left ()
  "Select the previous tile (`h')."
  (interactive)
  (my/writing-dashboard--move -1))

(defun my/writing-dashboard-right ()
  "Select the next tile (`l')."
  (interactive)
  (my/writing-dashboard--move 1))

(defun my/writing-dashboard-down ()
  "Select the tile one row down (`j')."
  (interactive)
  (my/writing-dashboard--move (my/writing-dashboard--per-row (length (my/writing-dashboard--tiles)))))

(defun my/writing-dashboard-up ()
  "Select the tile one row up (`k')."
  (interactive)
  (my/writing-dashboard--move (- (my/writing-dashboard--per-row (length (my/writing-dashboard--tiles))))))

(defun my/writing-dashboard-activate ()
  "Run the action of the currently selected tile (RET)."
  (interactive)
  (let ((tiles (my/writing-dashboard--tiles)))
    (when tiles
      (funcall (plist-get (nth my/writing-dashboard--index tiles) :action)))))

(defun my/writing-dashboard-rename ()
  "Rename the currently selected book (`r')."
  (interactive)
  (let* ((tiles (my/writing-dashboard--tiles))
         (tile (nth my/writing-dashboard--index tiles))
         (dir (plist-get tile :dir)))
    (unless dir
      (user-error "This tile can't be renamed"))
    (let ((title (string-trim (read-string "New book title: " (my/--book-title dir)))))
      (when (string-empty-p title)
        (user-error "Book title can't be empty"))
      (my/--org-set-title (my/--book-meta-file dir) title)))
  (my/writing-dashboard--render))

(defvar my/writing-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "Keymap for `my/writing-dashboard-mode'.")

;; "h"/"j"/"k"/"l", RET and "g" are all motions (or the goto-map
;; prefix), bound with higher priority than a plain `define-key' by
;; evil's own normal-state-map -- `special-mode' (our parent) gets
;; NORMAL state by default, same as `tabulated-list-mode' above.
;; `map!' with an explicit state binds through evil's own override
;; mechanism instead, so it wins.
(map! :map my/writing-dashboard-mode-map
      :n "h"   #'my/writing-dashboard-left
      :n "l"   #'my/writing-dashboard-right
      :n "j"   #'my/writing-dashboard-down
      :n "k"   #'my/writing-dashboard-up
      :n "RET" #'my/writing-dashboard-activate
      :n "r"   #'my/writing-dashboard-rename
      :n "g"   #'my/writing-dashboard-refresh
      :n "q"   #'quit-window)

(define-derived-mode my/writing-dashboard-mode special-mode "Writing-Dashboard"
  "Major mode for the writing dashboard (`SPC o o'). \"r\" renames
the selected book."
  (setq truncate-lines t
        cursor-type nil))

(defun my/writing-dashboard ()
  "Open the writing dashboard (`SPC o o')."
  (interactive)
  (let ((buf (get-buffer-create "*Writing Dashboard*")))
    (with-current-buffer buf
      (my/writing-dashboard-mode)
      (my/writing-dashboard--render))
    (switch-to-buffer buf)))

;; Overrides the macOS-only default "SPC o o" (`+macos/reveal-in-finder').
(map! :leader
      (:prefix "o"
       :desc "Writing dashboard" "o" #'my/writing-dashboard))

;;; Diary
;;;
;; A persistent, global, chat-style diary (`SPC o d'). The log is one
;; long Markdown file (`my/diary-file'); opening it appends a
;; "## YYYY-MM-DD" heading the first time that happens on a given day.
;; The frame splits into the log (top) and a small compose buffer
;; (bottom) -- type a message and hit RET to send it: it's appended to
;; the log with a timestamp and saved immediately, and the compose
;; buffer clears for the next one. Consecutive messages sent within
;; `my/diary-collapse-seconds' of the previous one share its
;; timestamp instead of getting their own, like grouped texts. `C-j'
;; inserts a literal newline for multi-line messages; `C-c C-k' closes
;; the compose window.

(defvar my/diary-file (expand-file-name "diary.md" org-directory)
  "Path to the persistent, global diary file.")

(defvar my/diary-project-directory (expand-file-name "project-diaries" org-directory)
  "Directory holding one persistent diary file per project, named after
`projectile-project-name'. See `my/project-diary-open' (`SPC p j').")

(defvar my/diary-collapse-seconds 60
  "Diary messages sent within this many seconds of the previous one
share its timestamp instead of getting their own.")

(defun my/--diary-file-for-project ()
  "Return the diary file for the current project."
  (expand-file-name (concat (projectile-project-name) ".md")
                     my/diary-project-directory))

(defun my/--diary-buffer (file)
  "Return the buffer visiting FILE, creating it if needed."
  (make-directory (file-name-directory file) t)
  (unless (file-exists-p file)
    (write-region "" nil file))
  (find-file-noselect file))

(defun my/--diary-ensure-trailing-blank-line ()
  "Make sure point-max ends in a blank line, unless the buffer is empty."
  (goto-char (point-max))
  (unless (bobp)
    (unless (looking-back "\n\n" nil)
      (insert (if (looking-back "\n" nil) "\n" "\n\n")))))

(defun my/--diary-maybe-insert-date-header (file)
  "Append a heading for today to FILE, if it wasn't written to today.

Returns non-nil if a header was inserted, so the caller can treat any
running \"fresh message\" state for FILE as stale."
  (with-current-buffer (my/--diary-buffer file)
    (let* ((today (format-time-string "%Y-%m-%d"))
           (last-day (and (> (buffer-size) 0)
                          (format-time-string
                           "%Y-%m-%d"
                           (file-attribute-modification-time
                            (file-attributes file))))))
      (unless (equal today last-day)
        (my/--diary-ensure-trailing-blank-line)
        (insert (format-time-string "## %Y-%m-%d (%A)\n"))
        (save-buffer)
        t))))

(defun my/--diary-append-message (file text last-time &optional author)
  "Append TEXT to FILE as a new, timestamped entry.

LAST-TIME is the time the previous message to FILE was sent (or nil),
used to decide whether to share its timestamp per
`my/diary-collapse-seconds'. Returns the new last-message time, for
the caller to remember.

AUTHOR, if given, is bolded before TEXT (e.g. a persona's display
name on their replies) and is always shown, even when the timestamp
itself is collapsed -- otherwise a collapsed entry from a different
speaker would look like a continuation of the previous one."
  (let* ((now (current-time))
         (fresh (or (null last-time)
                    (> (float-time (time-subtract now last-time))
                       my/diary-collapse-seconds))))
    (with-current-buffer (my/--diary-buffer file)
      (goto-char (point-max))
      (when fresh
        (my/--diary-ensure-trailing-blank-line)
        (insert (format-time-string "**%H:%M:%S** — " now)))
      (when author
        (insert (format "**%s:** " author)))
      (insert text "  \n")
      (save-buffer)
      (goto-char (point-max)))
    now))

(defvar my/diary-compose-mode-map (make-sparse-keymap)
  "Keymap for `my/diary-compose-mode'.")

(define-minor-mode my/diary-compose-mode
  "Minor mode for a diary's compose buffer.

RET sends the current message to the diary; `C-j' inserts a literal
newline for multi-line messages."
  :lighter " Diary"
  :keymap my/diary-compose-mode-map)

(defvar-local my/diary--target-file nil
  "The diary file this compose buffer's messages are sent to.")

(defvar-local my/diary--last-message-time nil
  "Time the last message was sent from this compose buffer, this
Emacs session. Buffer-local so the global diary and each project
diary -- each with its own compose buffer -- collapse timestamps
independently instead of sharing one clock.")

(defun my/diary-send-message ()
  "Send the compose buffer's contents to its diary and clear it.

If the message @-mentions one of `my/diary-personas' (e.g. \"@mimi\"),
also asks that persona to reply -- see `my/--diary-request-persona-reply'."
  (interactive)
  (let ((text (string-trim (buffer-string)))
        (file my/diary--target-file)
        (compose-buffer (current-buffer)))
    (erase-buffer)
    (unless (string-empty-p text)
      (setq my/diary--last-message-time
            (my/--diary-append-message file text my/diary--last-message-time))
      (when-let* ((buf (find-buffer-visiting file))
                  (win (get-buffer-window buf)))
        (with-selected-window win (goto-char (point-max))))
      (when-let ((persona (my/--diary-mentioned-persona text)))
        (my/--diary-request-persona-reply file compose-buffer persona text)))))

(defun my/diary-close ()
  "Close the diary's compose window."
  (interactive)
  (let ((buf (current-buffer)))
    (when (> (count-windows) 1)
      (delete-window))
    (kill-buffer buf)))

(map! :map my/diary-compose-mode-map
      :i "RET" #'my/diary-send-message
      :n "RET" #'my/diary-send-message
      :i "C-j" #'newline
      :ni "C-c C-k" #'my/diary-close)

(defun my/--diary-open (file compose-buffer-name)
  "Open a chat-style diary: FILE's log on top, a compose buffer named
COMPOSE-BUFFER-NAME below it. Shared by `my/diary-open' and
`my/project-diary-open' -- see either's docstring for the UI."
  (when (and (my/--diary-maybe-insert-date-header file)
             (get-buffer compose-buffer-name))
    ;; A new day's header just went in; any "fresh message" state a
    ;; pre-existing compose buffer was carrying is now stale.
    (with-current-buffer (get-buffer compose-buffer-name)
      (setq my/diary--last-message-time nil)))
  (delete-other-windows)
  (let ((log-buf (my/--diary-buffer file)))
    (with-current-buffer log-buf
      (when (fboundp 'markdown-mode) (markdown-mode))
      (goto-char (point-max)))
    (switch-to-buffer log-buf)
    (select-window (split-window-below (- (window-height) 8)))
    (let ((compose-buf (get-buffer-create compose-buffer-name)))
      (switch-to-buffer compose-buf)
      (when (fboundp 'markdown-mode) (markdown-mode))
      (setq-local my/diary--target-file file)
      (my/diary-compose-mode 1)))
  (evil-insert-state))

(defun my/diary-open ()
  "Open the persistent, global diary (`SPC o d').

Shows the running log (`my/diary-file') on top and a small compose
buffer below it -- type a message and press RET to send it. See
`my/diary-compose-mode' for the rest of the keys."
  (interactive)
  (my/--diary-open my/diary-file "*diary: compose*"))

(defun my/project-diary-open ()
  "Open a diary scoped to the current project (`SPC p j').

Same chat-style log/compose UI as `my/diary-open', but its own file
under `my/diary-project-directory' (named after
`projectile-project-name'), independent of the global diary and every
other project's."
  (interactive)
  (my/--diary-open (my/--diary-file-for-project)
                    (format "*diary: compose: %s*" (projectile-project-name))))

;;;; Diary personas (@-mentions)
;;
;; Type "@mimi <message>" (anywhere in the message) in a diary's compose
;; buffer and, once your message is sent, Mimi -- an OpenAI-backed
;; persona -- replies in the same log a moment later, attributed to her
;; name. Requests run asynchronously (`url-retrieve'), so Emacs never
;; blocks waiting on a reply. Recent lines from the diary are sent along
;; as conversation history (see `my/diary-persona-context-chars'), so
;; replies stay coherent across a session instead of being one-shot.
;;
;; Add another persona by dropping a system-prompt file in
;; `my/diary-personas-directory' and adding an entry to
;; `my/diary-personas' below.

(require 'url)
(require 'json)
(require 'auth-source)

(defvar my/diary-personas-directory (expand-file-name "personas" doom-user-dir)
  "Directory holding one system-prompt file per diary persona.")

(defvar my/diary-persona-default-model "gpt-4o"
  "OpenAI model used for a persona that doesn't set its own :model.")

(defvar my/diary-persona-context-chars 4000
  "How much of a diary's trailing content (in characters) to send as
conversation history when asking a persona to reply. Keeps requests
bounded regardless of how long the diary has grown.")

(defun my/--file-string (file)
  "Return FILE's contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defvar my/diary-personas
  `(("mimi" . (:display-name "Mimi"
               :system-prompt ,(my/--file-string
                                 (expand-file-name "mimi.md" my/diary-personas-directory)))))
  "Alist of diary personas, keyed by their @-mention name (lowercase,
no @). Each value is a plist with :display-name (the label on their
replies), :system-prompt, and optionally :model (an OpenAI model id,
overriding `my/diary-persona-default-model').")

(defun my/--diary-mentioned-persona (text)
  "Return the `my/diary-personas' entry TEXT @-mentions, or nil."
  (let ((case-fold-search t))
    (seq-find (lambda (entry)
                (string-match-p (concat "@" (regexp-quote (car entry)) "\\b") text))
              my/diary-personas)))

(defun my/--diary-openai-api-key ()
  "Look up the OpenAI API key via auth-source (host \"api.openai.com\").

Add a line like the following to ~/.authinfo (or ~/.authinfo.gpg):
  machine api.openai.com login apikey password sk-..."
  (when-let ((found (car (auth-source-search :host "api.openai.com"
                                              :require '(:secret)
                                              :max 1))))
    (let ((secret (plist-get found :secret)))
      (if (functionp secret) (funcall secret) secret))))

(defun my/--diary-recent-messages (file display-name)
  "Return FILE's recent content as a list of (:role ROLE :content TEXT)
plists suitable for an OpenAI `messages' array, inferring ROLE from
whether each entry is attributed to DISPLAY-NAME (\"assistant\") or
not (\"user\"). Only the trailing `my/diary-persona-context-chars'
characters of FILE are considered."
  (when (file-exists-p file)
    (let* ((full (my/--file-string file))
           (tail (if (> (length full) my/diary-persona-context-chars)
                     (substring full (- (length full) my/diary-persona-context-chars))
                   full))
           (assistant-re (concat "^\\*\\*[0-9:]+\\*\\* — \\*\\*"
                                  (regexp-quote display-name) ":\\*\\* \\(.*\\)$"))
           (user-re "^\\*\\*[0-9:]+\\*\\* — \\(.*\\)$")
           turns)
      (dolist (line (split-string tail "\n"))
        (cond
         ((string-match assistant-re line)
          (push (list :role "assistant" :content (match-string 1 line)) turns))
         ((string-match user-re line)
          (push (list :role "user" :content (match-string 1 line)) turns))
         ;; Day headers ("## ...") and system notes ("> ...", e.g. a
         ;; persona reply failure -- see `my/--diary-append-system-note')
         ;; are neither a turn nor a continuation of one; skip them.
         ((or (string-prefix-p "## " line) (string-prefix-p "> " line)))
         ((and turns (not (string-blank-p line)))
          ;; Continuation line of a multi-line message.
          (let ((prev (car turns)))
            (plist-put prev :content
                       (concat (plist-get prev :content) "\n" (string-trim-right line)))))))
      (nreverse turns))))

(defun my/--diary-append-system-note (file text)
  "Append TEXT to FILE as a blockquoted system note (e.g. a persona
reply failure) -- visually distinct from, and excluded from,
`my/--diary-recent-messages''s conversational turns."
  (with-current-buffer (my/--diary-buffer file)
    (goto-char (point-max))
    (my/--diary-ensure-trailing-blank-line)
    (insert "> " text "\n")
    (save-buffer)))

(defun my/--diary-openai-chat (api-key model system-prompt messages callback)
  "Send MESSAGES (a list of (:role ROLE :content TEXT) plists), with
SYSTEM-PROMPT as the system message, to OpenAI's MODEL via the Chat
Completions API. Asynchronous, via `url-retrieve' -- does not block
Emacs. CALLBACK is called with (SUCCESS VALUE): VALUE is the reply
string when SUCCESS is non-nil, or a string describing the error
otherwise."
  (let* ((url-request-method "POST")
         ;; `auth-source' returns the API key as a multibyte string, even
         ;; though its content is pure ASCII. Left alone, concatenating it
         ;; into a header promotes that header to multibyte too, and
         ;; url-http.el's own internal concat later mixes it with the
         ;; genuinely non-ASCII `url-request-data' below -- which forces
         ;; the *combined* request multibyte and reinterprets its raw
         ;; UTF-8 bytes as two-byte "raw 8-bit" chars, tripping url-http's
         ;; unibyte sanity check (Bug#23750) with a `(error "Multibyte
         ;; text in HTTP request: ...")' that dumps the whole request --
         ;; including the persona's entire system prompt -- into the echo
         ;; area. `encode-coding-string' here keeps this header unibyte so
         ;; it can't trigger that promotion.
         (url-request-extra-headers
          `(("Content-Type" . "application/json")
            ("Authorization" . ,(encode-coding-string (concat "Bearer " api-key) 'utf-8))))
         (url-request-data
          (encode-coding-string
           (json-encode
            `(("model" . ,model)
              ("messages" . ,(cons `(("role" . "system") ("content" . ,system-prompt))
                                    (mapcar (lambda (m)
                                              `(("role" . ,(plist-get m :role))
                                                ("content" . ,(plist-get m :content))))
                                            messages)))))
           'utf-8)))
    ;; `url-retrieve' itself -- not just its callback -- can throw
    ;; synchronously while assembling the request (e.g. Bug#23750's
    ;; "Multibyte text in HTTP request" if a header ever slips back to
    ;; being multibyte). Uncaught, that propagates out of the interactive
    ;; command that got us here and Emacs prints it to the echo area raw
    ;; -- which for that particular error means the *entire* request,
    ;; system prompt included. `condition-case' here guarantees a failure
    ;; is always routed through CALLBACK instead.
    (condition-case e
        (url-retrieve
         "https://api.openai.com/v1/chat/completions"
         (lambda (status)
           (unwind-protect
               (condition-case e
                   (if-let ((err (plist-get status :error)))
                       (funcall callback nil (format "%S" err))
                     ;; `url-http-end-of-headers' is not reliably live by
                     ;; the time this callback runs (observed as a marker
                     ;; pointing at no buffer at all, e.g. for chunked
                     ;; responses) -- find the header/body boundary
                     ;; ourselves instead of trusting it.
                     (goto-char (point-min))
                     (let* ((body (if (re-search-forward "\n\n" nil t)
                                      (buffer-substring-no-properties (point) (point-max))
                                    (buffer-substring-no-properties (point-min) (point-max))))
                            (json-object-type 'alist)
                            (json-array-type 'list)
                            (json (json-read-from-string body))
                            (api-error (alist-get 'error json))
                            (reply (alist-get 'content (alist-get 'message (car (alist-get 'choices json))))))
                       (cond
                        (api-error (funcall callback nil (format "%s" (alist-get 'message api-error))))
                        (reply (funcall callback t (string-trim reply)))
                        (t (funcall callback nil (format "Unexpected response: %s" body))))))
                 (error (funcall callback nil (format "Couldn't parse response: %S" e))))
             (kill-buffer)))
         nil t)
      (error (funcall callback nil (format "Couldn't send request: %S" e))))))

(defun my/--diary-request-persona-reply (file compose-buffer persona message)
  "Ask PERSONA to reply to MESSAGE, appending their reply to FILE once
it arrives. Runs asynchronously; does not block Emacs.

If COMPOSE-BUFFER is still live when the reply lands, its
`my/diary--last-message-time' is updated too, so a quick follow-up
message from the user collapses under the same timestamp instead of
getting its own right after PERSONA's."
  (let* ((display-name (plist-get (cdr persona) :display-name))
         (model (or (plist-get (cdr persona) :model) my/diary-persona-default-model))
         (system-prompt (plist-get (cdr persona) :system-prompt))
         (history (my/--diary-recent-messages file display-name))
         (api-key (my/--diary-openai-api-key)))
    (unless api-key
      (user-error "No OpenAI API key found for api.openai.com (see `my/--diary-openai-api-key')"))
    (message "Asking %s..." display-name)
    (my/--diary-openai-chat
     api-key model system-prompt
     (append history (list (list :role "user" :content message)))
     (lambda (success value)
       (if success
           (let* ((last-time (and (buffer-live-p compose-buffer)
                                   (buffer-local-value 'my/diary--last-message-time compose-buffer)))
                  (now (my/--diary-append-message file value last-time display-name)))
             (when (buffer-live-p compose-buffer)
               (with-current-buffer compose-buffer
                 (setq my/diary--last-message-time now))))
         (message "Diary: %s failed to reply: %s" display-name value)
         (my/--diary-append-system-note file (format "%s didn't reply: %s" display-name value)))))))

(use-package! vc)
(use-package! dictionary
  :commands (dictionary-lookup-definition)
  :config
  (setq dictionary-default-dictionary "*")
  (setq dictionary-server "dict.org"))

(defun my/tramp-hoshimi ()
  "Open a Dired buffer on `hoshimi' via TRAMP over SSH."
  (interactive)
  (dired "/ssh:hoshimi:~/"))

(map! :leader
      :desc "Diary"          "o d" #'my/diary-open
      :desc "Dictionary"     "o D" #'dictionary-lookup-definition
      :desc "Hoshimi (TRAMP)" "o h" #'my/tramp-hoshimi)

(use-package! rescript-mode
  :mode ("\\.resi?\\'" . rescript-mode))

(defun my-claude-code-ide ()
  "Continue the current project's Claude conversation, or start a new one."
  (interactive)
  (condition-case nil
      (call-interactively #'claude-code-ide-continue)
    (error
     (call-interactively #'claude-code-ide))))

(use-package! claude-code-ide
  :commands (claude-code-ide
             claude-code-ide-menu)
  ;; Keybindings must live in :init, not :config: :config only runs once the
  ;; package is actually loaded, but the only thing that triggers loading it
  ;; (via the :commands autoloads above) is calling one of these commands in
  ;; the first place. With the map! call in :config, `SPC a c' was never
  ;; registered by anything, so it silently fell through to whatever else
  ;; leader key "a" resolved to (embark's `SPC a' -> `embark-act', bound
  ;; eagerly by Doom's vertico module) instead of entering this prefix.
  :init
  (map! :leader
        (:prefix ("a" . "AI")
         :desc "Claude Code New"   "C" #'claude-code-ide
         :desc "Claude Code"       "c" #'claude-code-ide-continue
         :desc "Claude Code menu"  "m" #'claude-code-ide-menu
         :desc "Toggle Claude"     "t" #'claude-code-ide-toggle
         :desc "Resume session"    "r" #'claude-code-ide-resume))
  :config
  ;; Gives Claude access to Emacs-aware tools such as xref,
  ;; project information, imenu, and tree-sitter.
  (claude-code-ide-emacs-tools-setup)

  ;; Doom already supports vterm nicely.
  (setq claude-code-ide-terminal-backend 'vterm)

  ;; Open Claude on the right.
  (setq claude-code-ide-window-side 'right
        claude-code-ide-window-width 90)

  ;; Launch in "auto" mode: skip all permission prompts, including shell
  ;; commands. Chosen deliberately over the safer --permission-mode
  ;; acceptEdits (which still confirms non-edit actions) for speed; this
  ;; means Claude can run destructive commands without asking first.
  (setq claude-code-ide-cli-extra-flags "--permission-mode bypassPermissions")

  ;; The vterm buffer's prompt was drifting out of sync with its content
  ;; during conversations (rapid redraws, e.g. the prompt box expanding as
  ;; you type, outrunning vterm's rendering). Batch redraws more
  ;; aggressively before they hit the screen; default is 0.005s.
  (setq claude-code-ide-vterm-render-delay 0.02))

;;; Dictation mode
;;;
;; Real-time, GPU-accelerated speech-to-text via whisper.cpp's
;; `whisper-stream' (installed with `brew install whisper-cpp'; ggml's
;; Vulkan backend auto-picks the fastest GPU on this machine -- the
;; discrete Radeon RX 6800 XT -- with no CUDA/ROCm install required).
;; `--step 0' puts it in VAD-triggered mode: instead of continuously
;; re-transcribing a sliding window (which prints ANSI-repainted,
;; ever-changing partial lines), it waits for a pause after speech and
;; prints the finished segment once, as a single clean line like
;; "[00:00.000 --> 00:02.000]  Hello world.\n" -- easy to parse and
;; insert incrementally as it arrives.

(defvar my/dictation-whisper-stream-executable
  "/home/linuxbrew/.linuxbrew/bin/whisper-stream"
  "Path to whisper.cpp's `whisper-stream' executable.")

(defvar my/dictation-model-file
  (expand-file-name "~/.cache/whisper.cpp/ggml-small.en.bin")
  "Path to the GGML Whisper model `my/dictation-mode' transcribes with.")

(defvar-local my/dictation--process nil
  "The running `whisper-stream' process for this buffer, or nil.")

(defvar-local my/dictation--pending ""
  "Unprocessed tail of `whisper-stream' output for this buffer.")

(defun my/--dictation-insert (buffer text)
  "Insert TEXT at point in BUFFER, unless it's empty or a non-speech tag.

whisper.cpp reports things it heard but couldn't transcribe as speech
(background noise, silence) as a single bracketed/parenthesized tag
like \"[BLANK_AUDIO]\" or \"(silence)\" -- those get dropped rather
than typed into the buffer."
  (unless (or (string-empty-p text)
              (string-match-p "\\`[[(].*[])]\\'" text))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (insert text " ")))))

(defun my/--dictation-filter (buffer)
  "Return a process filter that parses `whisper-stream' output into BUFFER."
  (lambda (_process output)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq my/dictation--pending (concat my/dictation--pending output))
        (while (string-match "\n" my/dictation--pending)
          (let ((line (substring my/dictation--pending 0 (match-beginning 0))))
            (setq my/dictation--pending (substring my/dictation--pending (match-end 0)))
            (when (string-match "\\`\\[[0-9:.]+ --> [0-9:.]+\\] *\\(.*\\)" line)
              (my/--dictation-insert buffer (string-trim (match-string 1 line))))))))))

(defun my/--dictation-start ()
  "Launch `whisper-stream' listening on the default mic for this buffer."
  (cond
   ((not (file-executable-p my/dictation-whisper-stream-executable))
    (my/dictation-mode -1)
    (user-error "whisper-stream not found at %s -- `brew install whisper-cpp'"
                my/dictation-whisper-stream-executable))
   ((not (file-exists-p my/dictation-model-file))
    (my/dictation-mode -1)
    (user-error "Whisper model not found at %s" my/dictation-model-file))
   (t
    (let ((buffer (current-buffer)))
      (setq my/dictation--pending "")
      (setq my/dictation--process
            (make-process
             :name "whisper-stream"
             :buffer nil
             :noquery t
             :command (list my/dictation-whisper-stream-executable
                             "--model" my/dictation-model-file
                             "--step" "0"
                             "--length" "15000")
             :filter (my/--dictation-filter buffer)))
      (add-hook 'kill-buffer-hook #'my/--dictation-stop nil t)
      (message "Dictation on -- speak, then pause to commit a segment.")))))

(defun my/--dictation-stop ()
  "Kill this buffer's `whisper-stream' process, if any."
  (when (process-live-p my/dictation--process)
    (delete-process my/dictation--process))
  (setq my/dictation--process nil
        my/dictation--pending "")
  (message "Dictation off."))

(define-minor-mode my/dictation-mode
  "Live, GPU-accelerated speech-to-text: transcribes mic input at point.

Backed by whisper.cpp's `whisper-stream', running Whisper on the GPU
via Vulkan. Speak, then pause briefly; the recognized segment is
inserted at point once whisper.cpp finishes transcribing it."
  :lighter " Dictate"
  (if my/dictation-mode
      (my/--dictation-start)
    (my/--dictation-stop)))

(map! :leader
      (:prefix "t"
       :desc "Dictation" "t" #'my/dictation-mode))

;;; LSP smart jump
(defun my/--xref-item-at-point-p (item)
  "Return non-nil if ITEM's location falls inside the symbol at point."
  (when-let* ((bounds (bounds-of-thing-at-point 'symbol))
              (marker (ignore-errors (xref-location-marker (xref-item-location item)))))
    (and (eq (marker-buffer marker) (current-buffer))
         (<= (car bounds) (marker-position marker) (cdr bounds)))))

(defun my/lsp-jump-or-list-usages ()
  "Jump to a symbol's definition, or list its usages if already there.

If point is on a usage of a symbol, jump straight to its definition
via `xref-find-definitions'. If point is already at the definition
itself, list its usages via `xref-find-references' instead, so one
can be picked from the candidates."
  (interactive)
  (let* ((backend (xref-find-backend))
         (identifier (xref-backend-identifier-at-point backend)))
    (unless identifier
      (user-error "No identifier at point"))
    (if (seq-some #'my/--xref-item-at-point-p
                  (xref-backend-definitions backend identifier))
        (xref-find-references identifier)
      (xref-find-definitions identifier))))

;; Bound on `lsp-mode-map' (rather than globally) so it only takes over
;; C-RET in buffers LSP is actually managing.
(after! lsp-mode
  (map! :map lsp-mode-map
        :n "C-RET" #'my/lsp-jump-or-list-usages
        :i "C-RET" #'my/lsp-jump-or-list-usages))
