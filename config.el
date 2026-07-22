;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Place your private configuration here! Remember, you do not need to run 'doom
;; sync' after modifying this file!


;; Some functionality uses this to identify you, e.g. GPG configuration, email
;; clients, file templates and snippets. It is optional.
;; (setq user-full-name "John Doe"
;;       user-mail-address "john@doe.com")

;; Doom exposes five (optional) variables for controlling fonts in Doom:
;;
;; - `doom-font' -- the primary font to use
;; - `doom-variable-pitch-font' -- a non-monospace font (where applicable)
;; - `doom-big-font' -- used for `doom-big-font-mode'; use this for
;;   presentations or streaming.
;; - `doom-symbol-font' -- for symbols
;; - `doom-serif-font' -- for the `fixed-pitch-serif' face
;;
;; See 'C-h v doom-font' for documentation and more examples of what they
;; accept. For example:
;;
;;(setq doom-font (font-spec :family "Fira Code" :size 12 :weight 'semi-light)
;;      doom-variable-pitch-font (font-spec :family "Fira Sans" :size 13))
;;
;; If you or Emacs can't find your font, use 'M-x describe-font' to look them
;; up, `M-x eval-region' to execute elisp code, and 'M-x doom/reload-font' to
;; refresh your font settings. If Emacs still can't find your font, it likely
;; wasn't installed correctly. Font issues are rarely Doom issues!

;; There are two ways to load a theme. Both assume the theme is installed and
;; available. You can either set `doom-theme' or manually load a theme with the
;; `load-theme' function. This is the default:
(setq doom-theme 'doom-one)

;; This determines the style of line numbers in effect. If set to `nil', line
;; numbers are disabled. For relative line numbers, set this to `relative'.

;; If you use `org' and don't want your org files in the default location below,
;; change `org-directory'. It must be set before org loads!
(setq org-directory "~/org/")


;; Whenever you reconfigure a package, make sure to wrap your config in an
;; `with-eval-after-load' block, otherwise Doom's defaults may override your
;; settings. E.g.
;;
;;   (with-eval-after-load 'PACKAGE
;;     (setq x y))
;;
;; The exceptions to this rule:
;;
;;   - Setting file/directory variables (like `org-directory')
;;   - Setting variables which explicitly tell you to set them before their
;;     package is loaded (see 'C-h v VARIABLE' to look them up).
;;   - Setting doom variables (which start with 'doom-' or '+').
;;
;; Here are some additional functions/macros that will help you configure Doom.
;;
;; - `load!' for loading external *.el files relative to this one
;; - `add-load-path!' for adding directories to the `load-path', relative to
;;   this file. Emacs searches the `load-path' when you load packages with
;;   `require' or `use-package'.
;; - `map!' for binding new keys
;;
;; To get information about any of these functions/macros, move the cursor over
;; the highlighted symbol at press 'K' (non-evil users must press 'C-c c k').
;; This will open documentation for it, including demos of how they are used.
;; Alternatively, use `C-h o' to look up a symbol (functions, variables, faces,
;; etc).
;;
;; You can also try 'gd' (or 'C-c c d') to jump to their definition and see how
;; they are implemented.


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

       :prefix ("m" . "doom/help-modules")
       ))

;;; Project commands
(defvar-local my/project-test-command nil
  "Shell command used to test the current project.")

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

(defun my/project-test ()
  "Run the configured test command for the current project."
  (interactive)
  (my/run-project-command
   'my/project-test-command
   "Project test"))

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



;; Permit these string-valued variables in .dir-locals.el files.
(dolist (variable '(my/project-test-command
                    my/project-clean-and-compile-command
                    my/project-run-command))
  (put variable 'safe-local-variable #'stringp))

;;; Keybindings
(map! :leader
      :desc "Execute command"
      "SPC" #'execute-extended-command

      (:prefix ("p" . "project")
       :desc "Test project"
       "t" #'my/project-test

       :desc "Clean and compile project"
       "c" #'my/project-clean-and-compile

       :desc "Run project"
       "r" #'my/project-run

       :desc "Add project"
       "a" #'projectile-add-known-project

       :desc "List projects"
       "p" #'projectile-switch-project

       :desc "Help"
       "h" #'my/projectile-open-readme
       ))


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

(after! projectile
  (map! :leader
        (:prefix ("p" . "project")

         :desc "Switch project"
         "p" #'my/projectile-switch-project

         :desc "Switch project"
         "a" #'projectile-add-known-project
         )
        )
  )

(after! projectile
  (add-to-list 'projectile-project-root-files-bottom-up ".obsidian"))

;; Scratch buffer opens in markdown-mode (SPC x)
(setq doom-scratch-initial-major-mode 'markdown-mode)

;; Hide ** and # markup, keep the pretty fontification
(add-hook 'markdown-mode-hook #'markdown-toggle-markup-hiding)
(setq doom-scratch-initial-major-mode 'markdown-mode)

;; Not fiels with templates.
;;
(defvar my/notes-root "/var/home/zz/Documents/Obsidian/AZ/")
(after! org
  (setq org-roam-directory "/var/home/zz/Documents/org/roam/"
        org-roam-db-location (concat org-roam-directory ".org-roam.db")))
(defun my/--make-note (subdir tag title body)
  "Create an org note in SUBDIR with TAG and TITLE, insert BODY skeleton."
  (let* ((dir  (expand-file-name subdir my/notes-root))
         (slug (string-trim
                (replace-regexp-in-string "[^a-zA-Z0-9]+" "-" (downcase title))
                "-" "-"))
         (file (expand-file-name
                (format "%s-%s.org" (format-time-string "%Y%m%d") slug) dir)))
    (make-directory dir t)
    (find-file file)
    (when (= (buffer-size) 0)   ; don't clobber if it already exists
      (insert (format "#+title: %s\n#+date: %s\n#+filetags: :%s:\n\n%s"
                      title
                      (format-time-string "[%Y-%m-%d %a %H:%M]")
                      tag body))
      (search-backward "* " nil t)
      (end-of-line))))

(defun my/new-idea (title)
  (interactive "sIdea title: ")
  (my/--make-note "ideas" "idea" title
                  "* Summary\n\n* Why it matters\n\n* First concrete step\n"))

(defun my/new-question (title)
  (interactive "sQuestion: ")
  (my/--make-note "questions" "question" title
                  "* The question\n\n* What I already know\n\n* Where to look\n\n* Answer\n"))

(defun my/new-thought (title)
  (interactive "sThought: ")
  (my/--make-note "thoughts" "thought" title
                  "* The thought\n\n* Where it came from\n\n* Does it want to become anything\n"))

(map! :leader
      :prefix ("n" . "notes")
      :desc "List notes"   "i" #'my/new-idea
      :desc "New idea"     "i" #'my/new-idea
      :desc "New question" "q" #'my/new-question
      :desc "New thought"  "T" #'my/new-thought)

(use-package! dictionary
  :commands (dictionary-lookup-definition)
  :config
  (setq dictionary-default-dictionary "*")
  (setq dictionary-server "dict.org"))

(map! :leader
      :desc "Dictionary" "o d" #'dictionary-lookup-definition)
