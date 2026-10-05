;;; felidae-mode.el --- Major mode for the Felidae language (.fx files) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Felidae Project
;; URL: https://github.com/xnvtserver/Felidae/tree/main/emacs-extension
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages

;;; Commentary:

;; Major mode for editing Felidae (.fx) source files: syntax highlighting,
;; `#'-comment support, a structural buffer formatter/beautifier, a simple
;; interactive indent-line function, and run/check commands that shell out
;; to the `felidae' and `felidae_debug' executables (mirroring the run/check
;; commands in vs-code-extension and intellij-idea-extension).
;;
;; Felidae has no Emacs-native parser available, so - exactly like the
;; VS Code and IntelliJ extensions in this repository, both of which are
;; text-scanning rather than AST/PSI based - this mode's fontification and
;; formatting work directly on buffer text.

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'compile)
(require 'subr-x)
(require 'thingatpt)

(defgroup felidae nil
  "Support for the Felidae language."
  :group 'languages
  :prefix "felidae-")

(defcustom felidae-interpreter-path "felidae"
  "Path to the Felidae interpreter executable.
May be a bare command name resolved via `exec-path', or an absolute path."
  :type 'string
  :group 'felidae)

(defcustom felidae-debug-interpreter-path "felidae_debug"
  "Path to the Felidae AST debugger/checker executable."
  :type 'string
  :group 'felidae)

(defcustom felidae-celidae-path "celidae"
  "Path to the Celidae fact-visualization executable."
  :type 'string
  :group 'felidae)

(defcustom felidae-indent-offset 4
  "Number of columns per indentation level in Felidae source."
  :type 'integer
  :group 'felidae)

;;; Syntax table

(defvar felidae-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?: "." table)
    (modify-syntax-entry ?. "." table)
    (modify-syntax-entry ?, "." table)
    (modify-syntax-entry ?| "." table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?< "." table)
    (modify-syntax-entry ?> "." table)
    (modify-syntax-entry ?+ "." table)
    (modify-syntax-entry ?- "." table)
    (modify-syntax-entry ?* "." table)
    (modify-syntax-entry ?/ "." table)
    table)
  "Syntax table for `felidae-mode'.")

;;; Font-lock

(defface felidae-def-function-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for \`def' introducing a function (def f(...) =>)."
  :group 'felidae)

(defface felidae-def-binding-face
  '((t :inherit font-lock-variable-name-face :weight bold))
  "Face for \`def' introducing a binding or class field (def x := 1.)."
  :group 'felidae)

(defface felidae-def-fact-face
  '((t :inherit font-lock-type-face :weight bold))
  "Face for \`def' introducing a persistent fact (def Name(...).)."
  :group 'felidae)

(defface felidae-block-match-face
  '((t :inherit highlight :weight bold))
  "Face for the opener and \`end' of the block under point."
  :group 'felidae)

(defconst felidae-keywords
  '("def" "class" "extend" "extends" "index" "where" "if" "else" "then" "for" "in" "while" "switch" "case" "default" "break" "continue" "try" "catch" "new" "this" "super" "lambda" "import")
  "Felidae control-flow and declaration keywords.")

(defconst felidae-constants
  '("nil" "true" "false")
  "Felidae literal constants.")

(defconst felidae-type-names
  '("any" "array" "bool" "boolean" "decimal" "double" "float" "int" "number" "string")
  "Felidae primitive type annotations.")

(defconst felidae-library-names
  '("array" "comparison" "console" "csv" "db" "exception" "fact" "fact_analysis"
    "file" "flibrary" "fn" "group" "gtk" "http" "json" "list" "logic" "math"
    "ml" "package" "pair" "plot" "prelude" "probability" "process" "qt" "set"
    "smoke" "str" "system" "thread" "wordnet")
  "Felidae standard-library module names (see docs/builtin-docs.json).")

(defvar felidae-font-lock-keywords
  (list
   ;; Declaration head: `Name(...)' or `Name(...) =>' - method/fact name.
   '("^[ \t]*\\([A-Za-z_][A-Za-z0-9_:.]*\\)[ \t]*(" 1 font-lock-function-name-face)
   ;; `Name extend Parent'
   '("\\_<extend\\_>[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)" 1 font-lock-type-face)
   ;; Global/local bindings: `name := ...'
   '("\\_<\\([A-Za-z_][A-Za-z0-9_]*\\)\\_>[ \t]*:=" 1 font-lock-variable-name-face)
   ;; Library module names before `.' or `:'
   (cons (concat "\\_<" (regexp-opt felidae-library-names) "\\_>[ \t]*[.:]")
         font-lock-builtin-face)
   ;; def declares a function, a binding or a fact; each gets its own face.
   '("\\_<\\(def\\)\\_>[ \t]+[A-Za-z_][A-Za-z0-9_:.]*[ \t]*([^)]*)[ \t]*=>"
     1 'felidae-def-function-face)
   '("\\_<\\(def\\)\\_>[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:" 1 'felidae-def-binding-face)
   '("\\_<\\(def\\)\\_>[ \t]+[A-Za-z_][A-Za-z0-9_:.]*[ \t]*(" 1 'felidae-def-fact-face)
   (cons (regexp-opt felidae-keywords 'symbols) font-lock-keyword-face)
   ;; `end` closers stand out among nested blocks.
   (cons "\\_<end\\_>"'(:inherit font-lock-keyword-face :weight bold :underline t))
   (cons (regexp-opt felidae-constants 'symbols) font-lock-constant-face)
   ;; 'quoted atom' - a data atom, distinct from a string with the same spelling.
   (cons "'[^'\n]*'" font-lock-constant-face)
   ;; Type annotations always follow `:' in this grammar (`name: string');
   ;; Emacs regexps have no lookbehind, so just match the bareword itself.
   (cons (regexp-opt felidae-type-names 'symbols) font-lock-type-face)
   '("\\_<\\([A-Z][A-Za-z0-9_]*\\)\\_>" 1 font-lock-type-face)
   '("\\(=>\\|:=\\|==\\|!=\\|<=\\|>=\\)" 1 font-lock-keyword-face)
   ;; Named-argument keys: `key: value'
   '("\\_<\\([A-Za-z_][A-Za-z0-9_]*\\)\\_>[ \t]*:[^=]" 1 font-lock-constant-face))
  "Font-lock keyword table for `felidae-mode'.")

;;; Formatter - a structural, line-based beautifier.
;;
;; This is a line-for-line port of vs-code-extension/src/formatter.ts's
;; `formatFelidaeLines' (also ported to Java for the IntelliJ plugin as
;; FelidaeFormatter.formatLines) - keep the three in sync. See that file's
;; header comment for the full design rationale: a stack of open "block"
;; levels keyed by the *original* indentation width of the line that opened
;; them (a clause's own `=>', or a nested `if <cond> then'), popped
;; Python-dedent-style, with `else' pairing at (not popping) the level whose
;; width it exactly matches; bracket/brace/paren continuations tracked the
;; same way but keyed off bracket nesting, with multiple brackets opened on
;; one line counting as a single extra level.

(defconst felidae--openers "([{")
(defconst felidae--closers ")]}")

(defun felidae--mask-line (line)
  "Blank out string-literal contents and `#' comments in LINE.
Preserves LINE's length so bracket/keyword scanning by column offset
stays valid, while never misreading a bracket or `=>' that only
appears inside a string or a comment."
  (let ((len (length line))
        (out (make-string (length line) ?\s))
        (i 0)
        (in-string nil))
    (while (< i len)
      (let ((ch (aref line i)))
        (cond
         (in-string
          (cond
           ((and (eq ch ?\\) (< (1+ i) len))
            (aset out i ?x)
            (aset out (1+ i) ?x)
            (setq i (+ i 2)))
           ((eq ch ?\")
            (setq in-string nil)
            (aset out i ?\")
            (setq i (1+ i)))
           (t
            (aset out i ?x)
            (setq i (1+ i)))))
         ((eq ch ?#)
          (setq i len)) ; rest of line stays blank (spaces already filled)
         ((eq ch ?\")
          (setq in-string t)
          (aset out i ?\")
          (setq i (1+ i)))
         (t
          (aset out i ch)
          (setq i (1+ i))))))
    out))

(defun felidae--leading-width (line)
  "Column width of LINE's leading whitespace, expanding tabs to `felidae-indent-offset'."
  (let ((width 0) (i 0) (len (length line)))
    (catch 'done
      (while (< i len)
        (let ((ch (aref line i)))
          (cond
           ((eq ch ?\s) (setq width (1+ width)))
           ((eq ch ?\t) (setq width (+ width felidae-indent-offset)))
           (t (throw 'done width))))
        (setq i (1+ i))))
    width))

(defconst felidae--branch-regexp
  "\\(?:else\\b\\|catch\\b.*\\bthen\\|case\\b.*\\bthen\\|default[ \t]+then\\)[ \t]*\\'"
  "Matches a line that continues the surrounding block (else/catch/case/default).")

(defun felidae--opens-block-p (masked)
  "Non-nil if MASKED opens a block that owns an explicit \`end'.
Only class, def ... =>, for/while ... then, switch and try do; a conditional
\`then' expression has no \`end', and branches continue the surrounding frame."
  (or (string-match-p
       "\\\`[ \t]*class[ \t]+[A-Za-z_][A-Za-z0-9_.]*\\(?:[ \t]+extends?\\b.*\\)?[ \t]*\\'" masked)
      (string-match-p
       "\\\`[ \t]*def[ \t]+[A-Za-z_][A-Za-z0-9_.]*[ \t]*([^)]*)[ \t]*=>[ \t]*\\'" masked)
      (string-match-p
       "\\\`[ \t]*\\(?:for\\b.*\\bthen\\|while\\b.*\\bthen\\|switch\\b.*\\|try\\)[ \t]*\\'" masked)))

(defun felidae-format-lines (raw-lines)
  "Return RAW-LINES (a list of EOL-free strings) reformatted."
  (let ((frame-widths nil)   ; stack (list, head = top) of open block head-widths
        (bracket-levels nil) ; stack of raw-bracket-depth pop thresholds
        (raw-depth 0)
        (output nil)
        (previous-blank t))
    (dolist (raw-line raw-lines)
      (let ((trimmed (string-trim raw-line)))
        (if (string-empty-p trimmed)
            (progn
              (push "" output)
              (setq previous-blank t))
          (let* ((masked (felidae--mask-line raw-line))
                 (is-comment (string-prefix-p "#" trimmed))
                 (is-branch (string-match-p (concat "\\`" felidae--branch-regexp) trimmed))
                 (is-bare-end (string= trimmed "end"))
                 (comment-trusts-column (and is-comment previous-blank))
                 (depth-units 0))
            (setq previous-blank nil)
            (when (and (= raw-depth 0) (or (not is-comment) comment-trusts-column))
              (let ((width (felidae--leading-width raw-line)))
                (cond
                 (is-bare-end (when frame-widths (pop frame-widths)))
                 (is-branch
                  (while (and frame-widths (< width (car frame-widths)))
                    (pop frame-widths)))
                 (t
                  (while (and frame-widths (<= width (car frame-widths)))
                    (pop frame-widths))))))
            (if (or is-bare-end (and is-branch frame-widths))
                (setq depth-units (+ (if is-bare-end (length frame-widths) (1- (length frame-widths)))
                                     (length bracket-levels)))
              (let ((idx 0) (len (length masked)))
                (while (and (< idx len) (memq (aref masked idx) '(?\s ?\t)))
                  (setq idx (1+ idx)))
                (while (and (< idx len) (cl-find (aref masked idx) felidae--closers))
                  (setq raw-depth (1- raw-depth))
                  (while (and bracket-levels (<= raw-depth (car bracket-levels)))
                    (pop bracket-levels))
                  (setq idx (1+ idx)))
                (setq depth-units (+ (length frame-widths) (length bracket-levels)))
                (let ((depth-after-leading raw-depth))
                  (while (< idx len)
                    (let ((ch (aref masked idx)))
                      (cond
                       ((cl-find ch felidae--openers) (setq raw-depth (1+ raw-depth)))
                       ((cl-find ch felidae--closers)
                        (setq raw-depth (1- raw-depth))
                        (while (and bracket-levels (<= raw-depth (car bracket-levels)))
                          (pop bracket-levels)))))
                    (setq idx (1+ idx)))
                  (when (> raw-depth depth-after-leading)
                    (push (1- raw-depth) bracket-levels)))))
            (when (< depth-units 0) (setq depth-units 0))
            (push (concat (make-string (* depth-units felidae-indent-offset) ?\s) trimmed) output)
            (when (and (= raw-depth 0) (not is-comment) (felidae--opens-block-p masked))
              (push (felidae--leading-width raw-line) frame-widths))))))
    (setq output (nreverse output))
    ;; Collapse 2+ blank lines to one, and drop trailing blank lines.
    (let (collapsed)
      (dolist (line output)
        (unless (and (string-empty-p line) collapsed (string-empty-p (car collapsed)))
          (push line collapsed)))
      (while (and collapsed (string-empty-p (car collapsed)))
        (pop collapsed))
      (nreverse collapsed))))

(defun felidae-format-buffer ()
  "Reformat the current buffer's indentation, blank lines, and trailing whitespace."
  (interactive)
  (let* ((original (buffer-string))
         (lines (split-string original "\n"))
         (formatted (concat (string-join (felidae-format-lines lines) "\n") "\n")))
    (unless (string= formatted original)
      (let ((point-line (line-number-at-pos)))
        (erase-buffer)
        (insert formatted)
        (goto-char (point-min))
        (forward-line (1- point-line))))))

;;; Interactive single-line indentation (a lighter-weight heuristic for
;;; typing, distinct from `felidae-format-buffer''s full structural pass).

(defun felidae--previous-code-line ()
  "Return the trimmed text of the nearest non-blank line above point, or nil."
  (save-excursion
    (forward-line -1)
    (while (and (not (bobp)) (string-blank-p (thing-at-point 'line t)))
      (forward-line -1))
    (let ((text (string-trim (or (thing-at-point 'line t) ""))))
      (unless (string-empty-p text) text))))

(defun felidae-indent-line ()
  "Indent the current line using a simple heuristic.
For whole-buffer, structurally exact reindentation use
`felidae-format-buffer' instead."
  (interactive)
  (let* ((current (string-trim (thing-at-point 'line t)))
         (previous (felidae--previous-code-line))
         (level 0))
    (when previous
      (setq level (/ (felidae--leading-width previous) felidae-indent-offset))
      (let ((masked-prev (felidae--mask-line previous)))
        (when (felidae--opens-block-p masked-prev) (setq level (1+ level)))
        (dolist (ch (append masked-prev nil))
          (cond ((cl-find ch felidae--openers) (setq level (1+ level)))
                ((cl-find ch felidae--closers) (setq level (max 0 (1- level))))))))
    (when (or (string-prefix-p ")" current) (string-prefix-p "]" current) (string-prefix-p "}" current))
      (setq level (max 0 (1- level))))
    (when (or (string= current "end")
              (string-match-p (concat "\\`" felidae--branch-regexp) current))
      (setq level (max 0 (1- level))))
    (indent-line-to (* (max 0 level) felidae-indent-offset))))

;;; Run / check commands

(defun felidae-run-file ()
  "Run the current Felidae file with `felidae-interpreter-path'."
  (interactive)
  (unless buffer-file-name (user-error "Buffer is not visiting a file"))
  (save-buffer)
  (compile (mapconcat #'shell-quote-argument
                       (list felidae-interpreter-path buffer-file-name)
                       " ")))

(defun felidae--check-output (file)
  "Run `felidae --check-json' on FILE; return its standard output."
  (condition-case nil
      (with-temp-buffer
        (call-process felidae-interpreter-path nil t nil "--check-json" file)
        (buffer-string))
    (file-missing (user-error "Cannot run %s" felidae-interpreter-path))))

(defun felidae--check-lines (file output)
  "Compilation-style lines for the diagnostics in OUTPUT, the JSON of a check of FILE.
When OUTPUT is not JSON (the interpreter could not check at all) it is
returned as one text line instead."
  (condition-case nil
      (let ((diagnostics (alist-get 'diagnostics
                                    (json-parse-string output :object-type 'alist :array-type 'list))))
        (mapcar (lambda (diagnostic)
                  (let ((start (alist-get 'start diagnostic)))
                    (format "%s:%d:%d: %s: %s" file
                            (or (alist-get 'line start) 1)
                            (or (alist-get 'column start) 1)
                            (or (alist-get 'severity diagnostic) "error")
                            (alist-get 'message diagnostic))))
                diagnostics))
    (error (list (string-trim output)))))

(defun felidae-check-file ()
  "Check the current Felidae file with the interpreter's own parser.
Runs `felidae --check-json' (nothing is executed, no database is opened) and
lists the problems in *Felidae Check*; \\[next-error] walks them."
  (interactive)
  (unless buffer-file-name (user-error "Buffer is not visiting a file"))
  (save-buffer)
  (let* ((file buffer-file-name)
         (lines (felidae--check-lines file (felidae--check-output file)))
         (buffer (get-buffer-create "*Felidae Check*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (mapconcat #'identity lines "\n") (if lines "\n" ""))
        (goto-char (point-min)))
      (setq default-directory (file-name-directory file))
      (compilation-mode))
    (if lines
        (display-buffer buffer)
      (message "Felidae: no problems in %s" (file-name-nondirectory file)))))

(defun felidae-repl ()
  "Open `felidae --repl' in a comint buffer, in this file's folder.
The REPL reads ./init.fx there. While it is open it holds the project's
database, so a run on the same project reports the lock error."
  (interactive)
  (let ((default-directory (if buffer-file-name
                               (file-name-directory buffer-file-name)
                             default-directory)))
    (pop-to-buffer (make-comint "Felidae REPL" felidae-interpreter-path nil "--repl"))))

(defun felidae-send-to-repl (start end)
  "Send the region START..END, or the current line, to the Felidae REPL.
The REPL is started first when it is not running."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (line-beginning-position) (line-end-position))))
  (let ((text (buffer-substring-no-properties start end)))
    (unless (comint-check-proc "*Felidae REPL*")
      (save-selected-window (felidae-repl)))
    (comint-send-string (get-buffer-process "*Felidae REPL*") (concat text "\n"))))

(defun felidae-visualize-file ()
  "Visualize the current Felidae file's fact graph with `felidae-celidae-path'."
  (interactive)
  (unless buffer-file-name (user-error "Buffer is not visiting a file"))
  (save-buffer)
  (compile (mapconcat #'shell-quote-argument
                       (list felidae-celidae-path "--html" buffer-file-name)
                       " ")))

;;; Language server
;;
;; `felidae_debug --lsp' speaks LSP: diagnostics, document symbols and
;; go-to-definition, all computed from the real parse rather than from the
;; text-scanning fallbacks in this file. Registering it with Eglot (built in
;; since Emacs 29) or lsp-mode gives Imenu, Xref and Flymake for free, which
;; is what brings this mode in line with other language modes.

(defcustom felidae-enable-lsp nil
  "Whether to register `felidae-debug-interpreter-path' as a language server.
Off by default: the interpreter no longer provides `--lsp', so enable this only
for a build that does. This mode's built-in text scanning is used instead."
  :type 'boolean
  :group 'felidae)

(defun felidae--server-command (&optional _interactive)
  "Command Eglot should run for a Felidae buffer."
  (list felidae-debug-interpreter-path "--lsp"))

(defun felidae--register-lsp ()
  "Teach Eglot and/or lsp-mode about the Felidae language server."
  (when felidae-enable-lsp
    (with-eval-after-load 'eglot
      (add-to-list 'eglot-server-programs
                   '(felidae-mode . felidae--server-command)))
    (with-eval-after-load 'lsp-mode
      (when (fboundp 'lsp-register-client)
        (add-to-list 'lsp-language-id-configuration '(felidae-mode . "felidae"))
        (lsp-register-client
         (funcall (intern "make-lsp-client")
                  :new-connection (funcall (intern "lsp-stdio-connection")
                                           #'felidae--server-command)
                  :activation-fn (lambda (&rest _) (derived-mode-p 'felidae-mode))
                  :server-id 'felidae))))))

(felidae--register-lsp)

;;;###autoload
(defun felidae-start-lsp ()
  "Start Eglot for the current Felidae buffer."
  (interactive)
  (unless (fboundp 'eglot-ensure)
    (user-error "Eglot is not available; Emacs 29+ or the eglot package is required"))
  (unless (executable-find felidae-debug-interpreter-path)
    (user-error "Felidae language server not found: %s" felidae-debug-interpreter-path))
  (funcall (intern "eglot-ensure")))

;;; Comments / misc

(defun felidae--setup-comments ()
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[ \t]*"))

;;; Folding (hideshow)

(defconst felidae--block-open-regexp
  "^[ \t]*\\(?:class\\_>\\|for\\_>\\|while\\_>\\|switch\\_>\\|try\\_>\\|def[ \t]+[A-Za-z_][A-Za-z0-9_:.]*[ \t]*(.*)[ \t]*=>[ \t]*\\(?:#.*\\)?$\\)"
  "Matches a line that opens a block owning an explicit \`end'.")

(defun felidae--hs-forward-block (_arg)
  "Move point to the end of the \`end' line closing the block opened on this line.
Used as \`hs-forward-sexp-func'; nested blocks are matched by depth."
  (let ((depth 0) (found nil))
    (beginning-of-line)
    (while (and (not found) (not (eobp)))
      (let ((line (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position))))
        (cond
         ((string-match-p felidae--block-open-regexp line)
          (setq depth (1+ depth)))
         ((string-match-p "\\\`[ \t]*end[ \t]*\\(?:#.*\\)?\\'" line)
          (setq depth (1- depth))
          (when (<= depth 0)
            (end-of-line)
            (setq found t)))))
      (unless found (forward-line 1)))
    found))

(with-eval-after-load 'hideshow
  (add-to-list 'hs-special-modes-alist
               (list 'felidae-mode felidae--block-open-regexp "^[ \t]*end\\_>" "#"
                     #'felidae--hs-forward-block nil)))

;;; Selected block: only the block under point has its opener and \`end' marked.

(defvar-local felidae--block-overlays nil
  "Overlays marking the opener and \`end' of the block around point.")

(defun felidae--clear-block-overlays ()
  (mapc #'delete-overlay felidae--block-overlays)
  (setq felidae--block-overlays nil))

(defun felidae--line-opens-p ()
  (save-excursion (beginning-of-line) (looking-at-p felidae--block-open-regexp)))

(defun felidae--line-is-end-p ()
  (save-excursion (beginning-of-line) (looking-at-p "[ \t]*end\\_>")))

(defun felidae--enclosing-block-start ()
  "Return the position of the line opening the innermost block around point."
  (save-excursion
    (beginning-of-line)
    (let ((depth 0) (result nil))
      (cond
       ((felidae--line-opens-p) (setq result (point)))
       (t
        (while (and (not result) (zerop (forward-line -1)))
          (cond
           ((felidae--line-is-end-p) (setq depth (1+ depth)))
           ((felidae--line-opens-p)
            (if (= depth 0) (setq result (point)) (setq depth (1- depth))))))))
      result)))

(defun felidae--mark-word (position length)
  (let ((overlay (make-overlay position (+ position length))))
    (overlay-put overlay 'face 'felidae-block-match-face)
    (push overlay felidae--block-overlays)))

(defun felidae--highlight-block ()
  "Mark the opener and \`end' of the innermost block around point."
  (felidae--clear-block-overlays)
  (let ((start (felidae--enclosing-block-start)))
    (when start
      (save-excursion
        (goto-char start)
        (when (felidae--hs-forward-block 1)
          (beginning-of-line)
          (skip-chars-forward " \t")
          (felidae--mark-word (point) 3)
          (goto-char start)
          (skip-chars-forward " \t")
          (felidae--mark-word (point) (skip-chars-forward "a-z")))))))

;;; Keymap

(defvar felidae-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-f") #'felidae-format-buffer)
    (define-key map (kbd "C-c C-r") #'felidae-run-file)
    (define-key map (kbd "C-c C-c") #'felidae-check-file)
    (define-key map (kbd "C-c C-v") #'felidae-visualize-file)
    (define-key map (kbd "C-c C-z") #'felidae-repl)
    (define-key map (kbd "C-c C-s") #'felidae-send-to-repl)
    (define-key map (kbd "C-c C-l") #'felidae-start-lsp)
    map)
  "Keymap for `felidae-mode'.")

;;;###autoload
(define-derived-mode felidae-mode prog-mode "Felidae"
  "Major mode for editing Felidae (.fx) source files.

\\{felidae-mode-map}"
  :syntax-table felidae-mode-syntax-table
  (setq-local font-lock-defaults '(felidae-font-lock-keywords))
  (setq-local indent-line-function #'felidae-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width felidae-indent-offset)
  (felidae--setup-comments)
  (add-hook 'post-command-hook #'felidae--highlight-block nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.fx\\'" . felidae-mode))

(provide 'felidae-mode)

;;; felidae-mode.el ends here
