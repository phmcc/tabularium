;;; tabularium.el --- Structured data management with SQL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul H. McClelland

;; Author: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Maintainer: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Version: 0.5.2
;; Package-Requires: ((emacs "29.1"))
;; Keywords: data, sql, tables
;; URL: https://codeberg.org/phmcc/tabularium
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tabularium provides a fast, scalable data entry and management system within
;; Emacs, using SQL as a backend.  The name comes from the Latin tabularium,
;; the official records archive of ancient Rome.
;;
;; Features:
;; - User-configurable schemas defined in Elisp
;; - Minibuffer-based data entry with field-specific completion
;; - Fuzzy search via `completing-read'
;; - Tabulated list view for browsing and editing
;; - Duplicate-and-modify for repetitive entries
;; - Multiple database support with easy switching
;; - TSV/CSV import/export for version control and interoperability
;; - Query functions with completion from historical data
;; - Pluggable database backends (SQLite default; PostgreSQL optional via emacsql-pg)
;;
;; See the README for full documentation and example configurations.

;;; Code:

;;; * 0 Prerequisites

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'tabularium-db)

;; Forward declarations for functions defined in tabularium-menu.el
(declare-function tabularium-hydra/body "tabularium-menu" nil)
(declare-function tabularium-transient "tabularium-menu" nil)
(declare-function tabularium-view-hydra/body "tabularium-menu" nil)
(declare-function tabularium-view-transient "tabularium-menu" nil)

;;; * 1 Foundation

;;; ** 1.1 Customization

(defgroup tabularium nil
  "Structured data management in Emacs using SQL."
  :group 'applications
  :prefix "tabularium-")

(defgroup tabularium-schema nil
  "Schema definition and on-disk schema files."
  :group 'tabularium
  :prefix "tabularium-")

(defgroup tabularium-database nil
  "Database connections, tables, and caching."
  :group 'tabularium
  :prefix "tabularium-")

(defgroup tabularium-display nil
  "Display, formatting, and `view-mode' behavior."
  :group 'tabularium
  :prefix "tabularium-")

(defgroup tabularium-entry nil
  "Entry-mode forms, fields, and long-field editing."
  :group 'tabularium
  :prefix "tabularium-")

(defgroup tabularium-export nil
  "Import and export formats."
  :group 'tabularium
  :prefix "tabularium-")

(defgroup tabularium-registry nil
  "Registry of known databases."
  :group 'tabularium
  :prefix "tabularium-")

(defgroup tabularium-menu nil
  "Menu and dispatch system."
  :group 'tabularium
  :prefix "tabularium-")

(defgroup tabularium-undo nil
  "Undo history and clipboard limits."
  :group 'tabularium
  :prefix "tabularium-")

(defgroup tabularium-faces nil
  "Faces used by Tabularium for highlighting, marking, and modeline display."
  :group 'tabularium
  :prefix "tabularium-")

(defcustom tabularium-schemas nil
  "Alist of named schemas for different databases.

Each entry is (NAME . SCHEMA-PLIST) where NAME is a string and
SCHEMA-PLIST contains:

  :backend - (optional) Backend type: sqlite (default),
             postgresql, mysql
  :file    - Path to SQLite database file (for sqlite backend)
  :connection - (optional) Connection plist for server backends
                (:host :port :database :user :password)
  :fields  - List of field definitions (see below)
  :export-file - (optional) Default path for TSV/CSV exports
  :quick-entry-fields - (optional) Fields for quick entry
  :views   - (optional) List of saved view presets
  :default-sort - (optional) Default sort direction: asc or desc
  :header-function - (optional) Function called during form-buffer
                     render with no arguments; should return a string
                     to insert between the title bar and the field
                     list, or nil for no header.  See also the
                     buffer-local `tabularium-entry-header-function'.

Each field in :fields is a plist with:

  :id     - Symbol, the column name
  :label   - String, shown to user during entry
  :type     - One of: text, number, integer, date, time, datetime,
              choice, boolean
  :primary  - Exactly one field MUST have :primary t
  :default  - (optional) Default value, symbol, or function
  :required - (optional) If non-nil, field cannot be empty
  :choice  - (for type=choice) Valid choice values
  :width    - (optional) Display width in list view
  :hidden   - (optional) If non-nil, hide from list view by default
  :long     - (optional) If non-nil, edit in a dedicated buffer
  :computed - (optional) SQL string or elisp function for virtual fields
  :pattern       - (optional) Regex string the value must match
  :pattern-help  - (optional) Error message shown on :pattern mismatch
  :validate      - (optional) Function (VALUE) returning nil if valid
                   or an error string
  :complete - (optional) Completion source, one of:
              historical, recent, fixed, or a plist of the form
              (:type TYPE ...) where TYPE is one of
              historical, recent, vocabulary, related, filtered,
              function, or union.  See the README for details.

Example with SQLite (default):

  (setq tabularium-schemas
        \\='((\"cases\"
           :file \"~/data/cases.db\"
           :fields
           ((:id row_id :type integer :primary t :label \"ID\")
            (:id date :type date :default today :label \"Date\")
            (:id category :type text :label \"Category\"
             :complete historical)
            (:id status :type choice :label \"Status\"
             :choice (\"Open\" \"Closed\"))
            (:id notes :type text :label \"Notes\")))))

Example with PostgreSQL (requires emacsql):

  (setq tabularium-schemas
        \\='((\"shared-cases\"
           :backend postgresql
           :connection (:host \"localhost\"
                        :database \"cases\"
                        :user \"username\")
           :fields ...)))"
  :type '(alist :key-type string :value-type sexp)
  :group 'tabularium-schema)

(defcustom tabularium-date-format "%Y-%m-%d"
  "Format for date entry and display."
  :type 'string
  :group 'tabularium-display)

(defcustom tabularium-time-format "%H:%M:%S"
  "Format for `:type time' entry, display, and `:default now' values.
Should be an ISO 8601-compatible time format string consumable by
`format-time-string'.  Defaults to seconds precision; set to
\"%H:%M\" for minutes-only display."
  :type 'string
  :group 'tabularium-display)

(defcustom tabularium-datetime-format "%Y-%m-%d %H:%M:%S"
  "Format for `:type datetime' entry, display, and `:default now' values.
Should be an ISO 8601-compatible datetime format string consumable
by `format-time-string'.  The default uses a space separator
between the date and time portions, matching PostgreSQL's default
TIMESTAMP rendering; entry mode accepts either space or T as the
separator on input."
  :type 'string
  :group 'tabularium-display)

(defcustom tabularium-export-format 'tsv
  "Default export format.
TSV is recommended as it handles commas in text fields better."
  :type '(choice (const :tag "Tab-separated (TSV)" tsv)
                 (const :tag "Comma-separated (CSV)" csv))
  :group 'tabularium-export)

(defcustom tabularium-cache-ttl 300
  "Time-to-live for completion cache in seconds."
  :type 'integer
  :group 'tabularium-database)

(defcustom tabularium-view-page-size 500
  "Number of rows to display per page in list view."
  :type 'integer
  :group 'tabularium-display
  :safe #'integerp)

(defcustom tabularium-table-name "data"
  "Name of the main data table in the database."
  :type 'string
  :group 'tabularium-database)

(defcustom tabularium-view-sort-ascending nil
  "Whether to sort list view in ascending order (oldest first).
When nil (default), newest entries appear at the top."
  :type 'boolean
  :group 'tabularium-display
  :safe #'booleanp)

(defcustom tabularium-debug nil
  "When non-nil, print debug messages for troubleshooting."
  :type 'boolean
  :group 'tabularium
  :safe #'booleanp)

(defcustom tabularium-case-sensitive t
  "When non-nil, replace and mark operations use case-sensitive matching.
This affects `tabularium-replace-substring', `tabularium-replace-exact',
`tabularium-replace-pattern', `tabularium-replace-regexp',
`tabularium-replace-query', and the `tabularium-view-mark-*' family.
Toggle interactively with `tabularium-toggle-case-sensitive'.
Default is t, matching standard Emacs/Linux behavior."
  :type 'boolean
  :group 'tabularium-display
  :safe #'booleanp)

(defcustom tabularium-entry-method 'form
  "Preferred method for data entry.
`form' uses a dedicated buffer with fields laid out vertically.
`minibuffer' uses sequential minibuffer prompts."
  :type '(choice (const :tag "Form buffer (visual layout)" form)
                 (const :tag "Minibuffer prompts (sequential)" minibuffer))
  :group 'tabularium-entry)

(defcustom tabularium-entry-display 'side
  "How to display the entry form buffer.
`buffer' replaces the current window.
`side' displays in a side window (default)."
  :type '(choice (const :tag "Replace current window" buffer)
                 (const :tag "Side window" side))
  :group 'tabularium-entry)

(defcustom tabularium-entry-show-type-hints nil
  "Whether the form buffer shows an inline field-type marker.
When non-nil, each field's label in the entry form is followed by
a short type marker — =[I]= integer, =[N]= number, =[D]= date,
=[T]= time, =[DT]= datetime, =[C]= choice, =[B]= boolean — faced
with `shadow'.  When nil (the default) the form shows only the
bare label.

This affects only the form buffer's label area.  The minibuffer
prompts of `tabularium-prompt-entry' and `tabularium-quick-entry'
always show their type hint regardless of this setting, since a
prompt has no other type cue."
  :type 'boolean
  :group 'tabularium-entry)

(defcustom tabularium-long-field-mode 'text-mode
  "Major mode for editing `:long' fields.
Common choices are `text-mode', `org-mode', or `markdown-mode'."
  :type 'function
  :group 'tabularium-entry)

(defcustom tabularium-long-field-display 'side
  "Where to display the long-field editing buffer.
`bottom' opens a horizontal split at the bottom (40% height).
`side' opens a vertical split on the right (40% width)."
  :type '(choice (const :tag "Bottom window" bottom)
                 (const :tag "Side window (right)" side))
  :group 'tabularium-entry)

(defcustom tabularium-menu-system 'auto
  "Preferred menu system for Tabularium.
`auto' uses hydra if available, otherwise transient.
`hydra' always uses hydra.
`transient' always uses transient."
  :type '(choice (const :tag "Auto-detect (hydra preferred)" auto)
                 (const :tag "Hydra" hydra)
                 (const :tag "Transient" transient))
  :group 'tabularium-menu)

(defcustom tabularium-undo-limit 100
  "Maximum number of undo entries to keep per database."
  :type 'integer
  :group 'tabularium-undo)

;; Registry customizations
(defcustom tabularium-registry-file
  (let ((var-dir (if (bound-and-true-p no-littering-var-directory)
                     no-littering-var-directory
                   (locate-user-emacs-file "var/"))))
    (expand-file-name "tabularium/registry.eld" var-dir))
  "File to store the list of known databases.
By default, this is stored in `user-emacs-directory'/var/tabularium/.
If `no-littering' is loaded, uses `no-littering-var-directory' instead."
  :type 'file
  :group 'tabularium-registry)

(defcustom tabularium-registry-max-recent 100
  "Maximum number of databases to track in registry."
  :type 'integer
  :group 'tabularium-registry)

(defcustom tabularium-registry-auto-register-on-open t
  "Whether to automatically register databases when opened."
  :type 'boolean
  :group 'tabularium-registry)

(defcustom tabularium-schema-file-suffix ".schema.el"
  "Suffix for schema files paired with database files.
For a database `mydata.db', the schema file would be `mydata.schema.el'."
  :type 'string
  :group 'tabularium-schema)

;;; ** 1.2 Internal Variables

(defvar tabularium--current-schema-name nil
  "Name of the currently active schema.")

(defvar tabularium--db nil
  "Current database backend object.")

(defvar tabularium--completion-cache (make-hash-table :test 'equal)
  "Cache for completion candidates.")

(defvar tabularium--paired-field-cache (make-hash-table :test 'equal)
  "Cache for paired field mappings (schema:source:target -> hash table).")

(defvar tabularium--vocabulary-cache (make-hash-table :test 'equal)
  "Cache for loaded vocabulary files.
Keys are file paths, values are (MTIME . VALUES) cons cells.")

(defvar tabularium--cache-timestamp nil
  "Timestamp of last cache refresh.")

(defvar-local tabularium--buffer-schema-name nil
  "Schema name for the current buffer.")

(defvar-local tabularium--filter-rules nil
  "List of filter rule plists.
A data rule has :fields (a list of column-name strings), :value,
an optional :op (nil for substring, `= ', `!= ', or a numeric
comparison), and :connective (the logical connective combining it with
the previous rule — `and', `or', `and-not', `or-not', or nil for
the first rule).  The same VALUE is tested against every field in
:fields and the per-field conditions are OR'd.  A saved-view rule
instead carries :raw and :sql.")

(defvar-local tabularium--sort-ascending nil
  "Buffer-local sort order.  Overrides `tabularium-view-sort-ascending'.")

(defvar-local tabularium--marked-entries nil
  "List of marked entry IDs.")

(defvar-local tabularium--view-limit nil
  "Current limit for view, or nil to use `tabularium-view-page-size'.")

(defvar-local tabularium--view-id-range nil
  "Current row-ID restriction for the view, or nil for no restriction.
Two forms are accepted:

  (MIN . MAX)  — a contiguous inclusive range of row IDs;
  (ID ID ...)  — an explicit list of row IDs (a proper list).

`tabularium-view-show-range' stores the contiguous form for a
simple START-END answer and the explicit-list form for a spec
with gaps (e.g. =3-7,12,20-25=).  Use
`tabularium--view-id-range-clause' to turn either form into a SQL
WHERE fragment.")

(defun tabularium--view-id-range-clause (primary-name)
  "Return a SQL condition restricting PRIMARY-NAME to `tabularium--view-id-range'.
Returns nil when no restriction is active.  Handles both the
contiguous (MIN . MAX) cons form and the explicit ID-list form."
  (when tabularium--view-id-range
    (if (and (consp tabularium--view-id-range)
             (not (listp (cdr tabularium--view-id-range))))
        ;; Cons cell (MIN . MAX): contiguous range.
        (format "%s >= %d AND %s <= %d"
                primary-name (car tabularium--view-id-range)
                primary-name (cdr tabularium--view-id-range))
      ;; Proper list of IDs: explicit set.
      (format "%s IN (%s)"
              primary-name
              (mapconcat #'number-to-string
                         tabularium--view-id-range ",")))))

(defvar-local tabularium--current-view nil
  "Name of the currently active saved view, if any.")

(defvar-local tabularium--sort-columns nil
  "List of (COLUMN . DIRECTION) for multi-column sorting.
DIRECTION is \\='asc or \\='desc.  First element is primary sort.")

(defvar-local tabularium--frozen-ids nil
  "List of entry IDs to keep at top of view (frozen rows).")

(defvar-local tabularium--column-order nil
  "Custom column order as list of field names, or nil for schema order.")

(defvar-local tabularium--hidden-columns nil
  "List of column names (symbols) to hide in view mode.")

(defvar-local tabularium--cf-row-faces nil
  "Hash table mapping row-id to a highlight face.
Populated by `tabularium-view--refresh' from the active highlight
rules (scope `row') and consumed by
`tabularium-view--update-cf-display'.  Nil means no row rules apply.")

(defvar-local tabularium--highlight-runtime-rules nil
  "Buffer-local stack of interactively-added highlight rules.
Each element is a rule plist of the same shape as the schema's
`:highlight' rules.  Rules added with `tabularium-view-highlight-numeric'
are pushed here; `tabularium-view-highlight-save' persists one rule
and `tabularium-view-highlight-save-all' the whole stack into the
schema file's `:highlight' property; `tabularium-view-highlight-remove'
empties it.  `tabularium--cf-rules' returns these runtime rules
*ahead of* the schema-declared rules, so the most recently applied
highlight wins — matching the additive, last-applied-first feel of
the filter stack.")

(defvar-local tabularium--highlight-suppressed nil
  "Buffer-local list of saved highlight rules hidden in this view.
When the user removes a saved (schema) highlight rule with
`tabularium-view-highlight-remove', the rule is added here rather
than deleted from the schema — so the schema file is never
touched and a database reload restores every saved rule.
`tabularium--cf-rules' filters these out of the active set.  Only
`tabularium-view-highlight-expunge' permanently removes saved
rules from the schema file; `tabularium-view-highlight-save'
persists the current view state (runtime rules added, suppressed
rules dropped) and then clears both this list and the runtime
stack.")

(defvar-local tabularium--highlight-dup-cache nil
  "Buffer-local cache for `duplicates' highlight rules.
A hash table keyed by field-id symbol; each value is itself a hash
table mapping a stringified cell value to the number of times it
occurs in that column.  Rebuilt once per `tabularium-view--refresh'
so a duplicate-scoped rule needs only an O(1) lookup per cell
instead of rescanning the column.  Nil when no duplicate rule is
active.")

(defvar tabularium-registry--list nil
  "List of known databases (plists with :name :file :schema-file :last-used).")

(defvar tabularium-registry--loaded nil
  "Whether the registry has been loaded from disk.")

(defvar tabularium-registry--loaded-schemas nil
  "List of schema files that have been loaded this session.")

;;; * 2 Infrastructure

;;; ** 2.1 Database Connection

(defun tabularium--build-connection-config ()
  "Build connection config from current schema."
  (let* ((schema (tabularium--current-schema))
         (backend (or (plist-get schema :backend) 'sqlite))
         (config (plist-get schema :connection)))
    ;; For SQLite, merge in :file
    (when (eq backend 'sqlite)
      (setq config (plist-put config :file (plist-get schema :file))))
    (plist-put config :backend backend)))

(defun tabularium--ensure-db ()
  "Ensure database connection is open and schema exists."
  (tabularium--current-schema)  ; Validates schema exists
  (let* ((schema-name (tabularium--schema-name))
         (config (tabularium--build-connection-config)))
    ;; Get or create connection via the abstraction layer
    (setq tabularium--db (tabularium-db-get-connection schema-name config))
    ;; Ensure table exists
    (unless (tabularium-db-table-exists-p tabularium--db tabularium-table-name)
      (tabularium--create-table)))
  tabularium--db)

(defun tabularium--create-table ()
  "Create the database table if it does not exist."
  (let* ((fields (cl-remove-if #'tabularium--computed-field-p
                               (tabularium--schema-fields)))
         (primary-name (tabularium--primary-field-name))
         (columns
          (mapcar (lambda (f)
                    (let* ((name (plist-get f :id))
                           (ftype (plist-get f :type))
                           (sql-type (tabularium-db-sql-type tabularium--db ftype))
                           (choices (plist-get f :choice))
                           (check (when (and (eq ftype 'choice) choices)
                                    (format "%s IN (%s, '')"
                                            (symbol-name name)
                                            (mapconcat (lambda (c)
                                                         (tabularium-db-sql-quote c))
                                                       choices ", ")))))
                      (list :id name
                            :sql-type sql-type
                            :primary (eq name primary-name)
                            :check check)))
                  fields)))
    ;; Create table
    (tabularium-db-create-table tabularium--db tabularium-table-name columns)
    ;; Create indexes for historical completion fields
    (dolist (f fields)
      (when (eq (plist-get f :complete) 'historical)
        (tabularium-db-create-index tabularium--db
                                tabularium-table-name
                                (symbol-name (plist-get f :id)))))))

;;; ** 2.2 Undo/Redo System

;; Forward declaration for kill ring (defined in section 2.3 because the
;; full machinery and customization belong with the kill-ring system, but
;; the undo/redo code references the variable from inside its own body).
(defvar tabularium--kill-ring)

(defvar tabularium--undo-ring (make-hash-table :test 'equal)
  "Hash table mapping schema names to undo lists.
Each entry is a list of row undo operations, newest first.")

(defvar tabularium--redo-ring (make-hash-table :test 'equal)
  "Hash table mapping schema names to redo lists.
Each entry is a list of row redo operations, newest first.")

(defun tabularium--undo-push (operation)
  "Push OPERATION onto the undo stack for current schema."
  (let* ((schema (tabularium--schema-name))
         (stack (gethash schema tabularium--undo-ring)))
    (push operation stack)
    ;; Trim to limit
    (when (> (length stack) tabularium-undo-limit)
      (setq stack (seq-take stack tabularium-undo-limit)))
    (puthash schema stack tabularium--undo-ring)
    ;; Clear redo on new action
    (puthash schema nil tabularium--redo-ring)))

(defun tabularium--undo-pop ()
  "Pop and return the top undo operation, or nil if empty."
  (let* ((schema (tabularium--schema-name))
         (stack (gethash schema tabularium--undo-ring)))
    (when stack
      (let ((op (pop stack)))
        (puthash schema stack tabularium--undo-ring)
        op))))

(defun tabularium--redo-push (operation)
  "Push OPERATION onto the redo stack."
  (let* ((schema (tabularium--schema-name))
         (stack (gethash schema tabularium--redo-ring)))
    (push operation stack)
    (puthash schema stack tabularium--redo-ring)))

(defun tabularium--redo-pop ()
  "Pop and return the top redo operation, or nil if empty."
  (let* ((schema (tabularium--schema-name))
         (stack (gethash schema tabularium--redo-ring)))
    (when stack
      (let ((op (pop stack)))
        (puthash schema stack tabularium--redo-ring)
        op))))

(defun tabularium--apply-undo-op (op)
  "Apply undo operation OP, returning its inverse for redo."
  (pcase (plist-get op :type)
    ('insert
     ;; Undo insert = delete
     (let ((id (plist-get op :row)))
       (tabularium-db-delete tabularium--db tabularium-table-name
                         (tabularium--primary-field-name) id)
       (list :type 'delete :row id :data (plist-get op :data))))
    ('delete
     ;; Undo delete = re-insert
     (let ((data (plist-get op :data)))
       (tabularium-db-insert tabularium--db tabularium-table-name data)
       (list :type 'insert :row (plist-get op :row) :data data)))
    ('update
     ;; Undo update = restore old value
     (let ((id (plist-get op :row))
           (field (plist-get op :field))
           (old-val (plist-get op :old))
           (new-val (plist-get op :new)))
       (tabularium-db-update tabularium--db tabularium-table-name
                         (list (cons field old-val))
                         (tabularium--primary-field-name) id)
       (list :type 'update :row id :field field :old new-val :new old-val)))
    ('paste
     ;; Undo paste = delete inserted rows and restore batch to kill-ring
     (let ((batch (plist-get op :batch))
           (inverse-ops '()))
       ;; Delete all inserted rows
       (dolist (sub-op (reverse (plist-get op :ops)))
         (push (tabularium--apply-undo-op sub-op) inverse-ops))
       ;; Restore batch to kill-ring
       (push batch tabularium--kill-ring)
       (list :type 'unpaste :ops (nreverse inverse-ops) :batch batch)))
    ('unpaste
     ;; Redo paste = re-insert rows and remove batch from kill-ring
     (let ((batch (plist-get op :batch))
           (inverse-ops '()))
       ;; Re-insert all rows
       (dolist (sub-op (reverse (plist-get op :ops)))
         (push (tabularium--apply-undo-op sub-op) inverse-ops))
       ;; Remove batch from kill-ring
       (setq tabularium--kill-ring (delq batch tabularium--kill-ring))
       (list :type 'paste :ops (nreverse inverse-ops) :batch batch)))
    ('yank
     ;; Undo yank = delete inserted rows (do not touch kill-ring)
     (let ((inverse-ops '()))
       (dolist (sub-op (reverse (plist-get op :ops)))
         (push (tabularium--apply-undo-op sub-op) inverse-ops))
       (list :type 'unyank :ops (nreverse inverse-ops))))
    ('unyank
     ;; Redo yank = re-insert rows (do not touch kill-ring)
     (let ((inverse-ops '()))
       (dolist (sub-op (reverse (plist-get op :ops)))
         (push (tabularium--apply-undo-op sub-op) inverse-ops))
       (list :type 'yank :ops (nreverse inverse-ops))))
    ('highlight
     ;; Undo a highlight rule-state change = restore the prior snapshots.
     ;; A `highlight' op records the runtime stack, the schema's
     ;; `:highlight' list, and the buffer-local suppressed-rule list
     ;; both before and after the change; undo swaps in the `before'
     ;; state and returns an op that swaps in `after' for redo.  The
     ;; deliberate `save'/`expunge' file-writing commands are not
     ;; tracked this way.
     (let ((before-runtime (plist-get op :before-runtime))
           (after-runtime (plist-get op :after-runtime))
           (before-schema (plist-get op :before-schema))
           (after-schema (plist-get op :after-schema))
           (before-suppressed (plist-get op :before-suppressed))
           (after-suppressed (plist-get op :after-suppressed)))
       (tabularium--highlight-restore-state
        before-runtime before-schema before-suppressed)
       (list :type 'highlight
             :before-runtime after-runtime
             :after-runtime before-runtime
             :before-schema after-schema
             :after-schema before-schema
             :before-suppressed after-suppressed
             :after-suppressed before-suppressed)))
    ('multi
     ;; Undo multiple ops in reverse order, batched in one transaction
     ;; so undoing a bulk operation is one commit, not one per sub-op.
     (let ((inverse-ops '()))
       (tabularium-db-with-transaction tabularium--db
         (dolist (sub-op (reverse (plist-get op :ops)))
           (push (tabularium--apply-undo-op sub-op) inverse-ops)))
       (list :type 'multi :ops (nreverse inverse-ops))))
    ('swap
     ;; Undo swap = re-swap (swap is its own inverse)
     (let* ((id1 (plist-get op :row1))
            (id2 (plist-get op :row2))
            (primary-name (symbol-name (tabularium--primary-field-name)))
            (temp-id -1))
       (tabularium-db-execute
        tabularium--db
        (format "UPDATE %s SET %s = ? WHERE %s = ?" tabularium-table-name primary-name primary-name)
        (list temp-id id1))
       (tabularium-db-execute
        tabularium--db
        (format "UPDATE %s SET %s = ? WHERE %s = ?" tabularium-table-name primary-name primary-name)
        (list id1 id2))
       (tabularium-db-execute
        tabularium--db
        (format "UPDATE %s SET %s = ? WHERE %s = ?" tabularium-table-name primary-name primary-name)
        (list id2 temp-id))
       (list :type 'swap :row1 id1 :row2 id2)))
    ('move
     ;; Undo move = restore primary keys from before-map using stable ROWIDs
     (let* ((before-map (plist-get op :before-map))
            (primary-name (symbol-name (tabularium--primary-field-name))))
       ;; Snapshot current state for redo
       (let ((current-map (tabularium-db-query
                           tabularium--db
                           (format "SELECT rowid, %s FROM %s"
                                   primary-name tabularium-table-name)
                           nil)))
         (tabularium-db-with-transaction tabularium--db
           ;; Move all to temp IDs first (avoid collision)
           (let ((temp-id -3000))
             (dolist (row before-map)
               (tabularium-db-execute
                tabularium--db
                (format "UPDATE %s SET %s = ? WHERE rowid = ?"
                        tabularium-table-name primary-name)
                (list temp-id (car row)))
               (cl-decf temp-id)))
           ;; Restore original primary keys
           (dolist (row before-map)
             (tabularium-db-execute
              tabularium--db
              (format "UPDATE %s SET %s = ? WHERE rowid = ?"
                      tabularium-table-name primary-name)
              (list (cadr row) (car row)))))
         ;; Return inverse: the current-map becomes the before-map for redo
         (list :type 'move :before-map current-map
               :count (plist-get op :count)))))
    ('add-column
     ;; Undo add-column = drop the column
     (let* ((name (plist-get op :column))
            (field-plist (plist-get op :field-plist))
            (name-str (symbol-name name))
            (schema-name (tabularium--schema-name))
            (fields (tabularium--schema-fields))
            ;; Save position and any data that was entered since adding
            (position (cl-position-if
                       (lambda (f) (eq (plist-get f :id) name)) fields))
            (computed-p (tabularium--computed-field-p field-plist))
            (primary-str (symbol-name (tabularium--primary-field-name)))
            (rows (unless computed-p
                    (tabularium-db-query
                     tabularium--db
                     (format "SELECT %s, %s FROM %s WHERE %s IS NOT NULL AND %s != ''"
                             primary-str name-str tabularium-table-name
                             name-str name-str)
                     nil)))
            (col-data (mapcar (lambda (row) (cons (car row) (cadr row))) rows)))
       ;; Drop the column from the table (rebuild).  Only physical columns
       ;; touch the table; a computed field leaves the schema only.
       (unless computed-p
         (tabularium--rebuild-table-dropping name))
       ;; Remove from schema
       (let* ((schema (assoc schema-name tabularium-schemas))
              (plist (cdr schema))
              (new-fields (cl-remove-if
                           (lambda (f) (eq (plist-get f :id) name))
                           (plist-get plist :fields))))
         (setf (cdr schema) (plist-put plist :fields new-fields))
         (tabularium--save-schema-to-file schema-name))
       ;; Return inverse: delete-column (so redo re-adds it)
       (list :type 'delete-column :column name
             :field-plist field-plist :position position
             :data col-data)))
    ('delete-column
     ;; Undo delete-column = re-add the column and restore data
     (let* ((name (plist-get op :column))
            (field-plist (plist-get op :field-plist))
            (position (plist-get op :position))
            (col-data (plist-get op :data))
            (name-str (symbol-name name))
            (schema-name (tabularium--schema-name))
            (col-type (plist-get field-plist :type))
            (sql-type (pcase col-type
                        ('integer "INTEGER")
                        ('number "REAL")
                        (_ "TEXT")))
            (primary-str (symbol-name (tabularium--primary-field-name)))
            (computed-p (tabularium--computed-field-p field-plist)))
       ;; A computed field has no physical column: restore it to the
       ;; schema only.  A stored field is re-added to the table and its
       ;; saved data restored.
       (unless computed-p
         (tabularium-db-execute tabularium--db
                            (format "ALTER TABLE %s ADD COLUMN %s %s"
                                    tabularium-table-name name-str sql-type)
                            nil)
         ;; Restore data (batched: one commit for the column)
         (tabularium-db-with-transaction tabularium--db
           (dolist (pair col-data)
             (tabularium-db-execute
              tabularium--db
              (format "UPDATE %s SET %s = ? WHERE %s = ?"
                      tabularium-table-name name-str primary-str)
              (list (cdr pair) (car pair))))))
       ;; Re-insert field into schema at original position
       (let* ((schema (assoc schema-name tabularium-schemas))
              (plist (cdr schema))
              (fields (plist-get plist :fields))
              (pos (min (or position (length fields)) (length fields)))
              (new-fields (append (seq-take fields pos)
                                  (list field-plist)
                                  (seq-drop fields pos))))
         (setf (cdr schema) (plist-put plist :fields new-fields))
         (tabularium--save-schema-to-file schema-name))
       ;; Return inverse: add-column (so redo re-deletes it)
       (list :type 'add-column :column name
             :field-plist field-plist)))
    ('reorder-columns
     ;; Undo reorder = restore old column order
     (let* ((old-order (plist-get op :old-order))
            (schema-name (tabularium--schema-name))
            (schema (assoc schema-name tabularium-schemas))
            (plist (cdr schema))
            (fields (plist-get plist :fields))
            (current-order (mapcar (lambda (f) (plist-get f :id)) fields))
            ;; Reorder fields to match old-order
            (new-fields (mapcar (lambda (name)
                                  (cl-find-if (lambda (f) (eq (plist-get f :id) name))
                                              fields))
                                old-order)))
       (setf (cdr schema) (plist-put plist :fields new-fields))
       (tabularium--save-schema-to-file schema-name)
       (setq tabularium--column-order nil)
       ;; Return inverse: reorder with current order
       (list :type 'reorder-columns :old-order current-order)))
    ('filter-change
     ;; Undo a filter change = restore the previous rule stack.  Like
     ;; `sort-change' this is buffer-local view state, not schema.
     (let ((current (copy-sequence tabularium--filter-rules)))
       (setq tabularium--filter-rules (plist-get op :old-filter))
       (tabularium--filter-update-modeline)
       (list :type 'filter-change :old-filter current)))
    ('sort-change
     ;; Undo a sort change = restore the previous key list.  Like
     ;; `view-reorder' this is buffer-local display state, not schema.
     (let ((current (copy-sequence tabularium--sort-columns)))
       (setq tabularium--sort-columns (plist-get op :old-sort))
       (list :type 'sort-change :old-sort current)))
    ('view-reorder
     ;; Undo a view-local column move = restore the prior display order.
     ;; This affects only `tabularium--column-order' (the buffer's display
     ;; order), not the schema; the caller's `revert-buffer' re-renders.
     (let ((current tabularium--column-order))
       (setq tabularium--column-order (plist-get op :old-order))
       (list :type 'view-reorder :old-order current)))
    ('edit-column
     ;; Undo edit-column = restore old field plist
     (let* ((old-field-plist (plist-get op :old-field-plist))
            (current-name (plist-get op :new-name))
            (original-name (plist-get old-field-plist :id))
            (filled-ids (plist-get op :filled-ids))
            (schema-name (tabularium--schema-name)))
       ;; Clear cells that were auto-filled with the new default
       (when filled-ids
         (let* ((col-str (symbol-name current-name))
                (primary-str (symbol-name (tabularium--primary-field-name)))
                (placeholders (mapconcat (lambda (_) "?") filled-ids ", ")))
           (tabularium-db-execute
            tabularium--db
            (format "UPDATE %s SET %s = '' WHERE %s IN (%s)"
                    tabularium-table-name col-str primary-str placeholders)
            filled-ids)))
       ;; If name was changed, rename back in DB
       (unless (eq current-name original-name)
         (tabularium-db-execute tabularium--db
                            (format "ALTER TABLE %s RENAME COLUMN %s TO %s"
                                    tabularium-table-name
                                    (symbol-name current-name)
                                    (symbol-name original-name))
                            nil))
       ;; Restore full field plist in schema
       (let* ((schema (assoc schema-name tabularium-schemas))
              (plist (cdr schema))
              (cur-fields (plist-get plist :fields))
              (field (cl-find-if (lambda (f) (eq (plist-get f :id) current-name))
                                 cur-fields))
              ;; Save current state for redo
              (current-field-plist (copy-sequence field)))
         (when field
           ;; Restore the entire old field plist wholesale, covering every
           ;; attribute the edit may have changed (choice, required, long,
           ;; boolean-pair, computed placeholder, ...), not just a fixed subset.
           (setq cur-fields
                 (mapcar (lambda (f)
                           (if (eq (plist-get f :id) current-name)
                               (copy-sequence old-field-plist)
                             f))
                         cur-fields))
           (setf (cdr schema) (plist-put plist :fields cur-fields)))
         (tabularium--save-schema-to-file schema-name)
         ;; Return inverse (with filled-ids so redo can re-fill)
         (list :type 'edit-column
               :old-field-plist current-field-plist
               :new-name original-name
               :filled-ids filled-ids))))))

;;;###autoload
(defun tabularium-undo ()
  "Undo the last database operation.
Covers row operations (insert, delete, update, paste) and
column operations (add, delete, reorder)."
  (interactive)
  (tabularium--ensure-db)
  (if-let ((op (tabularium--undo-pop)))
      (progn
        (let ((redo-op (tabularium--apply-undo-op op)))
          (tabularium--redo-push redo-op))
        (tabularium--invalidate-cache)
        (when (derived-mode-p 'tabularium-view-mode)
          (let ((saved-id (tabulated-list-get-id))
                (saved-col (tabularium--column-name-at-point)))
            (revert-buffer)
            (tabularium-view--goto-position saved-id saved-col)))
        (message "Undo: %s" (tabularium--describe-op op)))
    (message "Nothing to undo")))

;;;###autoload
(defun tabularium-redo ()
  "Redo the last undone database operation.
Covers row operations (insert, delete, update, paste) and
column operations (add, delete, reorder)."
  (interactive)
  (tabularium--ensure-db)
  (if-let ((op (tabularium--redo-pop)))
      (let ((undo-op (tabularium--apply-undo-op op)))
        ;; Push back to undo without clearing redo
        (let* ((schema (tabularium--schema-name))
               (stack (gethash schema tabularium--undo-ring)))
          (push undo-op stack)
          (puthash schema stack tabularium--undo-ring))
        (tabularium--invalidate-cache)
        (when (derived-mode-p 'tabularium-view-mode)
          (let ((saved-id (tabulated-list-get-id))
                (saved-col (tabularium--column-name-at-point)))
            (revert-buffer)
            (tabularium-view--goto-position saved-id saved-col)))
        ;; Describe the re-performed action (the freshly produced undo-op),
        ;; not the inverse we popped off the redo stack — so redoing a column
        ;; deletion reads "delete column", matching its undo message.
        (message "Redo: %s" (tabularium--describe-op undo-op)))
    (message "Nothing to redo")))

(defun tabularium--describe-op (op)
  "Return human-readable description of OP."
  (pcase (plist-get op :type)
    ('insert (format "insert #%s" (plist-get op :row)))
    ('delete (format "delete #%s" (plist-get op :row)))
    ('update (format "update #%s.%s" (plist-get op :row) (plist-get op :field)))
    ('paste (format "paste %d entries" (length (plist-get op :ops))))
    ('unpaste (format "unpaste %d entries" (length (plist-get op :ops))))
    ('yank (format "yank %d entries" (length (plist-get op :ops))))
    ('unyank (format "unyank %d entries" (length (plist-get op :ops))))
    ('multi (format "%d operations" (length (plist-get op :ops))))
    ('swap (format "swap #%s ↔ #%s" (plist-get op :row1) (plist-get op :row2)))
    ('move (format "move %d %s"
                   (or (plist-get op :count) 1)
                   (if (= 1 (or (plist-get op :count) 1)) "entry" "entries")))
    ('add-column (format "add column %s" (plist-get op :column)))
    ('delete-column (format "delete column %s" (plist-get op :column)))
    ('reorder-columns "reorder columns")
    ('view-reorder "reorder columns")
    ('sort-change "change sort")
    ('filter-change "change filter")
    ('edit-column (format "edit column %s"
                          (plist-get op :new-name)))
    ('highlight
     (let* ((active (lambda (rt sc su)
                      (+ (length rt) (- (length sc) (length su)))))
            (d (- (funcall active (plist-get op :after-runtime)
                           (plist-get op :after-schema)
                           (plist-get op :after-suppressed))
                  (funcall active (plist-get op :before-runtime)
                           (plist-get op :before-schema)
                           (plist-get op :before-suppressed)))))
       (cond ((> d 0) (format "add %d highlight rule%s"
                              d (if (= d 1) "" "s")))
             ((< d 0) (format "remove %d highlight rule%s"
                              (- d) (if (= d -1) "" "s")))
             (t "change highlight rules"))))))

;;;###autoload
(defun tabularium-undo-history ()
  "Show operation history for current database."
  (interactive)
  (let* ((schema (tabularium--schema-name))
         (undo-stack (gethash schema tabularium--undo-ring))
         (redo-stack (gethash schema tabularium--redo-ring)))
    (with-help-window "*Tabularium History*"
      (princ (format "Operation history for %s\n" schema))
      (princ (make-string 40 ?─))
      (princ "\n\nUndo stack:\n")
      (if undo-stack
          (cl-loop for op in undo-stack
                   for i from 1
                   do (princ (format "  %d. %s\n" i (tabularium--describe-op op))))
        (princ "  (empty)\n"))
      (princ "\nRedo stack:\n")
      (if redo-stack
          (cl-loop for op in redo-stack
                   for i from 1
                   do (princ (format "  %d. %s\n" i (tabularium--describe-op op))))
        (princ "  (empty)\n")))))

;;; ** 2.3 Kill Ring System

(defvar tabularium--kill-ring nil
  "Kill ring for copied/cut rows and columns.
Each element is a batch plist with :schema, :type, and :entries or :columns.")

(defcustom tabularium-kill-ring-max 10
  "Maximum number of batches in the tabularium kill ring."
  :type 'integer
  :group 'tabularium-undo)

(defun tabularium-kill-ring-clear ()
  "Clear the tabularium kill ring."
  (interactive)
  (setq tabularium--kill-ring nil)
  (when (derived-mode-p 'tabularium-kill-ring-mode)
    (tabularium-kill-ring--refresh))
  (message "Kill ring cleared"))

(defvar-local tabularium-kill-ring--source-buffer nil
  "Buffer to paste into from kill ring view.")

(defvar-local tabularium-kill-ring--first-line nil
  "Line number of first batch entry in kill ring buffer.")

(defvar-local tabularium-kill-ring--last-line nil
  "Line number of last batch entry in kill ring buffer.")

(defvar-local tabularium-kill-ring--batch-lines nil
  "Alist of (LINE-NUMBER . BATCH-NUM) for batch header navigation.")

(defun tabularium-kill-ring-view ()
  "View contents of the tabularium kill ring."
  (interactive)
  (let ((source-buf (current-buffer))
        (buf (get-buffer-create "*Tabularium Kill Ring*")))
    (with-current-buffer buf
      (tabularium-kill-ring--render source-buf))
    (pop-to-buffer buf)))

(defun tabularium-kill-ring--render (&optional source-buf)
  "Render the kill ring buffer contents.
SOURCE-BUF is the buffer to paste into; preserved across refreshes."
  (let ((inhibit-read-only t)
        (first-line nil)
        (last-line nil)
        (batch-lines '())
        (src (or source-buf tabularium-kill-ring--source-buffer)))
    (erase-buffer)
    ;; Header
    (insert (tabularium--make-box-header "Tabularium Kill Ring" 80) "\n")
    (insert "\n")
    (if (null tabularium--kill-ring)
        (insert "  (empty)\n")
      (let ((batch-num 0))
        (dolist (batch tabularium--kill-ring)
          (cl-incf batch-num)
          (let* ((schema (plist-get batch :schema))
                 (batch-type (tabularium--kill-ring-batch-type batch))
                 (start (point))
                 (line-num (line-number-at-pos)))
            ;; Track first/last for navigation
            (unless first-line (setq first-line line-num))
            (setq last-line line-num)
            (push (cons line-num batch-num) batch-lines)
            ;; Batch header
            (insert (propertize
                     (format "  Batch %d" batch-num)
                     'face 'font-lock-keyword-face
                     'tabularium-batch-num batch-num))
            (if (eq batch-type 'columns)
                ;; Column batch
                (let ((columns (plist-get batch :columns)))
                  (insert (format "  %s — %d %s\n"
                                  schema (length columns)
                                  (if (= 1 (length columns)) "column" "columns")))
                  (let ((col-num 0))
                    (dolist (col columns)
                      (cl-incf col-num)
                      (when (<= col-num 5)
                        (let* ((name (plist-get col :column))
                               (col-type (plist-get (plist-get col :field-plist) :type))
                               (data-count (length (plist-get col :data))))
                          (insert (format "    %d. %s (%s, %d values)\n"
                                          col-num name col-type data-count))))
                      (when (= col-num 6)
                        (insert (format "    … and %d more\n"
                                        (- (length columns) 5)))))))
              ;; Row batch
              (let ((entries (plist-get batch :entries)))
                (insert (format "  %s — %d %s\n"
                                schema (length entries)
                                (if (= 1 (length entries)) "row" "rows")))
                (let ((entry-num 0))
                  (dolist (entry entries)
                    (cl-incf entry-num)
                    (when (<= entry-num 3)
                      (let ((preview (mapconcat
                                      (lambda (pair)
                                        (format "%s=%s"
                                                (car pair)
                                                (truncate-string-to-width
                                                 (format "%s" (cdr pair)) 20 nil nil "…")))
                                      (seq-take entry 3) ", ")))
                        (insert (format "    %d. %s\n" entry-num preview))))
                    (when (= entry-num 4)
                      (insert (format "    … and %d more\n" (- (length entries) 3))))))))
            ;; Tag entire batch section
            (put-text-property start (point) 'tabularium-batch-num batch-num)
            (insert "\n")))))
    ;; Footer
    (insert (tabularium--make-box-footer 80) "\n")
    (insert (format "  Total: %d %s\n\n"
                    (length tabularium--kill-ring)
                    (if (= 1 (length tabularium--kill-ring)) "batch" "batches")))
    (insert "  " (propertize "V" 'face 'help-key-binding) " Paste   "
            (propertize "X" 'face 'help-key-binding) " Clear   "
            (propertize "g" 'face 'help-key-binding) "/"
            (propertize "=" 'face 'help-key-binding) " Refresh   "
            (propertize "q" 'face 'help-key-binding) " Quit\n")
    (insert "  " (propertize "TAB" 'face 'help-key-binding) "/"
            (propertize "S-TAB" 'face 'help-key-binding) " Navigate   "
            (propertize "n" 'face 'help-key-binding) "/"
            (propertize "p" 'face 'help-key-binding) " Next/Prev\n")
    ;; Activate mode, then set buffer-local vars
    (tabularium-kill-ring-mode)
    (setq tabularium-kill-ring--source-buffer src)
    (setq tabularium-kill-ring--first-line (or first-line 3))
    (setq tabularium-kill-ring--last-line (or last-line 3))
    (setq tabularium-kill-ring--batch-lines (nreverse batch-lines))
    ;; Position on first batch
    (goto-char (point-min))
    (when first-line
      (forward-line (1- first-line)))))

(defun tabularium-kill-ring--refresh ()
  "Re-render the kill ring buffer in place."
  (interactive)
  (when (derived-mode-p 'tabularium-kill-ring-mode)
    (tabularium-kill-ring--render)))

(defun tabularium-kill-ring-next-batch ()
  "Move to the next batch in the kill ring buffer."
  (interactive)
  (let* ((current-line (line-number-at-pos))
         (next (cl-find-if (lambda (bl) (> (car bl) current-line))
                           tabularium-kill-ring--batch-lines)))
    (if next
        (progn (goto-char (point-min)) (forward-line (1- (car next))))
      (message "Last batch"))))

(defun tabularium-kill-ring-prev-batch ()
  "Move to the previous batch in the kill ring buffer."
  (interactive)
  (let* ((current-line (line-number-at-pos))
         (prev (cl-find-if (lambda (bl) (< (car bl) current-line))
                           (reverse tabularium-kill-ring--batch-lines))))
    (if prev
        (progn (goto-char (point-min)) (forward-line (1- (car prev))))
      (message "First batch"))))

(defun tabularium-kill-ring-paste-selected ()
  "Paste from kill ring view buffer.
If point is on a batch, paste that batch.  Otherwise paste the top batch.
Automatically detects whether the batch contains rows or columns.
The batch is removed from the kill ring and the buffer is refreshed."
  (interactive)
  (unless tabularium--kill-ring
    (user-error "Kill ring is empty"))
  (let* ((batch-num (get-text-property (point) 'tabularium-batch-num))
         ;; Default to batch 1 (top) if not on a specific batch
         (batch-idx (1- (or batch-num 1)))
         (batch (nth batch-idx tabularium--kill-ring))
         (batch-type (tabularium--kill-ring-batch-type batch))
         (source-buf tabularium-kill-ring--source-buffer))
    (unless (and (buffer-live-p source-buf)
                 (with-current-buffer source-buf
                   (derived-mode-p 'tabularium-view-mode)))
      (user-error "Source view buffer is no longer available"))
    ;; Remove the batch from kill ring
    (setq tabularium--kill-ring (delq batch tabularium--kill-ring))
    ;; Dispatch based on batch type
    (if (eq batch-type 'columns)
        (with-current-buffer source-buf
          (tabularium--paste-column-batch batch))
      (with-current-buffer source-buf
        (tabularium--paste-batch batch)))
    ;; Refresh kill ring display in place
    (tabularium-kill-ring--refresh)))

(defvar tabularium-kill-ring-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "V") #'tabularium-kill-ring-paste-selected)
    (define-key map (kbd "X") #'tabularium-kill-ring-clear)
    (define-key map (kbd "g") #'tabularium-kill-ring--refresh)
    (define-key map (kbd "=") #'tabularium-kill-ring--refresh)
    (define-key map (kbd "TAB") #'tabularium-kill-ring-next-batch)
    (define-key map (kbd "<backtab>") #'tabularium-kill-ring-prev-batch)
    (define-key map (kbd "n") #'tabularium-kill-ring-next-batch)
    (define-key map (kbd "p") #'tabularium-kill-ring-prev-batch)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `tabularium-kill-ring-mode'.")

(define-derived-mode tabularium-kill-ring-mode special-mode "Tabularium Kill Ring"
  "Mode for viewing the tabularium kill ring.")

(defun tabularium--add-to-kill-ring (schema entries &optional type)
  "Add ENTRIES from SCHEMA as a new batch at front of kill ring.
TYPE is \\='rows (default) or \\='columns.  For rows, ENTRIES is a list
of alists.  For columns, ENTRIES is a list of column plists."
  (let ((batch-type (or type 'rows)))
    (push (if (eq batch-type 'columns)
              (list :schema schema :type 'columns :columns entries)
            (list :schema schema :type 'rows :entries entries))
          tabularium--kill-ring)
    (when (> (length tabularium--kill-ring) tabularium-kill-ring-max)
      (setq tabularium--kill-ring
            (seq-take tabularium--kill-ring tabularium-kill-ring-max)))))

(defun tabularium--pop-kill-ring ()
  "Remove and return the first batch from kill ring, or nil if empty."
  (when tabularium--kill-ring
    (pop tabularium--kill-ring)))

(defun tabularium--peek-kill-ring ()
  "Return the first batch from kill ring without removing it."
  (car tabularium--kill-ring))

(defun tabularium--kill-ring-batch-type (batch)
  "Return the type of BATCH: \\='rows or \\='columns.
Legacy batches without :type are treated as rows."
  (or (plist-get batch :type) 'rows))

;;; ** 2.4 Display Ornamentation

(defun tabularium--make-box-header (title &optional width style)
  "Create a centered box-style header with TITLE.
WIDTH defaults to 80 characters.
STYLE can be:
  nil or \\='single - single line: ┌──────[ Title ]──────┐
  \\='double        - double line: ╔══════[ Title ]══════╗
  \\='heavy         - heavy line:  ┏━━━━━━[ Title ]━━━━━━┓"
  (let* ((width (or width 80))
         (title-with-brackets (format "[ %s ]" title))
         (title-len (length title-with-brackets))
         (available (- width 2))  ; subtract corners
         (padding (- available title-len))
         (left-pad (/ padding 2))
         (right-pad (- padding left-pad)))
    (pcase style
      ('double
       (concat "╔"
               (make-string left-pad ?═)
               title-with-brackets
               (make-string right-pad ?═)
               "╗"))
      ('heavy
       (concat "┏"
               (make-string left-pad ?━)
               title-with-brackets
               (make-string right-pad ?━)
               "┓"))
      (_  ; single (default)
       (concat "┌"
               (make-string left-pad ?─)
               title-with-brackets
               (make-string right-pad ?─)
               "┐")))))

(defun tabularium--make-box-footer (&optional width style)
  "Create a box-style footer line.
WIDTH defaults to 80 characters.
STYLE can be:
  nil or \\='single - single line: └────────────────────┘
  \\='double        - double line: ╚════════════════════╝
  \\='heavy         - heavy line:  ┗━━━━━━━━━━━━━━━━━━━━┛"
  (let ((width (or width 80)))
    (pcase style
      ('double
       (concat "╚" (make-string (- width 2) ?═) "╝"))
      ('heavy
       (concat "┗" (make-string (- width 2) ?━) "┛"))
      (_  ; single (default)
       (concat "└" (make-string (- width 2) ?─) "┘")))))

;;; * 3 Registry

;;; ** 3.1 Schema File Paths

(defun tabularium-registry--schema-file-for-db (db-file)
  "Return the schema file path for DB-FILE.
For `/path/to/mydata.db', returns `/path/to/mydata.schema.el'."
  (let ((base (file-name-sans-extension (expand-file-name db-file))))
    (concat base tabularium-schema-file-suffix)))

(defun tabularium-registry--schema-file-exists-p (db-file)
  "Return non-nil if a schema file exists for DB-FILE."
  (file-exists-p (tabularium-registry--schema-file-for-db db-file)))

;;; ** 3.2 Persistence

(defun tabularium-registry--ensure-loaded ()
  "Load registry from disk if not already loaded."
  (unless tabularium-registry--loaded
    (tabularium-registry--load)))

(defun tabularium-registry--load ()
  "Load the registry from `tabularium-registry-file'.
Normalizes paths to use ~/ for portability."
  (setq tabularium-registry--list nil)
  (when (file-exists-p tabularium-registry-file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents tabularium-registry-file)
          (setq tabularium-registry--list (read (current-buffer))))
      (error
       (message "Tabularium: Error loading registry: %s" (error-message-string err))
       (setq tabularium-registry--list nil))))
  ;; Normalize paths to abbreviated form for cross-machine portability
  (dolist (entry tabularium-registry--list)
    (when-let ((f (plist-get entry :file)))
      (plist-put entry :file (abbreviate-file-name f)))
    (when-let ((sf (plist-get entry :schema-file)))
      (plist-put entry :schema-file (abbreviate-file-name sf))))
  (setq tabularium-registry--loaded t))

(defun tabularium-registry--save ()
  "Save the registry to `tabularium-registry-file'.
Abbreviates all file paths to use ~/ for portability across machines."
  (let ((dir (file-name-directory tabularium-registry-file)))
    (unless (file-exists-p dir)
      (make-directory dir t)))
  (with-temp-file tabularium-registry-file
    (let ((print-length nil)
          (print-level nil)
          ;; Abbreviate paths before writing
          (portable-list
           (mapcar (lambda (entry)
                     (let ((e (copy-sequence entry)))
                       (when (plist-get e :file)
                         (plist-put e :file
                                    (abbreviate-file-name (plist-get e :file))))
                       (when (plist-get e :schema-file)
                         (plist-put e :schema-file
                                    (abbreviate-file-name (plist-get e :schema-file))))
                       e))
                   tabularium-registry--list)))
      (insert ";; Tabularium database registry -*- lisp-data -*-\n")
      (insert ";; This file is auto-generated.\n\n")
      (pp portable-list (current-buffer)))))

;;; ** 3.3 Internal Management

(defun tabularium-registry--find-entry (name-or-file)
  "Find registry entry by NAME-OR-FILE."
  (cl-find-if (lambda (entry)
                (or (equal (plist-get entry :name) name-or-file)
                    (equal (plist-get entry :file) name-or-file)
                    (and (plist-get entry :file)
                         (equal (expand-file-name (plist-get entry :file))
                                (expand-file-name name-or-file)))))
              tabularium-registry--list))

(defun tabularium-registry--add (entry)
  "Add or update ENTRY in the registry."
  (tabularium-registry--ensure-loaded)
  (let* ((name (plist-get entry :name))
         (file (plist-get entry :file))
         (existing (or (and name (tabularium-registry--find-entry name))
                       (and file (tabularium-registry--find-entry file)))))
    (if existing
        ;; Update existing entry
        (progn
          (plist-put existing :last-used (float-time))
          (when (plist-get entry :file)
            (plist-put existing :file (plist-get entry :file)))
          (when (plist-get entry :schema-file)
            (plist-put existing :schema-file (plist-get entry :schema-file))))
      ;; Add new entry
      (push entry tabularium-registry--list))
    ;; Trim to max
    (when (> (length tabularium-registry--list) tabularium-registry-max-recent)
      (setq tabularium-registry--list
            (seq-take (seq-sort-by (lambda (e) (or (plist-get e :last-used) 0))
                                   #'>
                                   tabularium-registry--list)
                      tabularium-registry-max-recent)))
    (tabularium-registry--save)))

(defun tabularium-registry--remove (name-or-file)
  "Remove entry matching NAME-OR-FILE from registry."
  (tabularium-registry--ensure-loaded)
  (setq tabularium-registry--list
        (cl-remove-if (lambda (entry)
                        (or (equal (plist-get entry :name) name-or-file)
                            (equal (plist-get entry :file) name-or-file)
                            (and (plist-get entry :file)
                                 (equal (expand-file-name (plist-get entry :file))
                                        (expand-file-name name-or-file)))))
                      tabularium-registry--list))
  (tabularium-registry--save))

;;; ** 3.4 Schema File Loading

(defun tabularium-registry--load-schema-file (schema-file)
  "Load SCHEMA-FILE and register its schema.
Returns the schema name if successful, nil otherwise."
  (when (file-exists-p schema-file)
    (condition-case err
        (progn
          (load schema-file nil t)
          (push schema-file tabularium-registry--loaded-schemas)
          ;; The schema file should have added to tabularium-schemas
          ;; Return the name of the most recently added schema
          (caar tabularium-schemas))
      (error
       (message "Tabularium: Error loading schema %s: %s"
                schema-file (error-message-string err))
       nil))))

(defun tabularium-registry--ensure-schema-loaded (db-file)
  "Ensure the schema for DB-FILE is loaded.
Returns the schema name if found/loaded, nil otherwise."
  (let ((schema-file (tabularium-registry--schema-file-for-db db-file)))
    (cond
     ;; Schema file exists but not loaded
     ((and (file-exists-p schema-file)
           (not (member schema-file tabularium-registry--loaded-schemas)))
      (tabularium-registry--load-schema-file schema-file))
     ;; Check if already in tabularium-schemas by file
     (t
      (car (cl-find-if (lambda (s)
                         (equal (expand-file-name (plist-get (cdr s) :file))
                                (expand-file-name db-file)))
                       tabularium-schemas))))))

;;; ** 3.5 Completion Interface

(defun tabularium-registry--all-databases ()
  "Get combined list of all known databases.
Merges registry entries with `tabularium-schemas', deduplicating by file path."
  (tabularium-registry--ensure-loaded)
  (let ((result '())
        (seen-files (make-hash-table :test 'equal)))
    ;; First, add from registry (most recent first)
    (dolist (entry (seq-sort-by (lambda (e) (or (plist-get e :last-used) 0))
                                #'>
                                tabularium-registry--list))
      (let ((file (plist-get entry :file)))
        (when (and file (not (gethash (expand-file-name file) seen-files)))
          (puthash (expand-file-name file) t seen-files)
          (push entry result))))
    ;; Then, add from tabularium-schemas
    (dolist (schema tabularium-schemas)
      (let ((file (plist-get (cdr schema) :file)))
        (when (and file (not (gethash (expand-file-name file) seen-files)))
          (puthash (expand-file-name file) t seen-files)
          (push (list :name (car schema)
                      :file file
                      :schema-file (tabularium-registry--schema-file-for-db file))
                result))))
    (nreverse result)))

(defun tabularium-registry--format-last-used (timestamp)
  "Format TIMESTAMP as a relative time string."
  (if timestamp
      (let* ((diff (- (float-time) timestamp))
             (days (floor (/ diff 86400))))
        (cond
         ((< diff 3600) "< 1 hour ago")
         ((< diff 86400)
          (let ((h (floor (/ diff 3600))))
            (format "%d hour%s ago" h (if (= h 1) "" "s"))))
         ((= days 1) "yesterday")
         ((< days 7) (format "%d day%s ago" days (if (= days 1) "" "s")))
         ((< days 30)
          (let ((w (floor (/ days 7))))
            (format "%d week%s ago" w (if (= w 1) "" "s"))))
         (t (format-time-string "%Y-%m-%d" timestamp))))
    "never"))

(defun tabularium-registry--annotation-function (candidate)
  "Annotation function for database CANDIDATE."
  (when-let ((entry (tabularium-registry--find-entry candidate)))
    (let* ((file (plist-get entry :file))
           (last-used (plist-get entry :last-used))
           (has-schema (and file (tabularium-registry--schema-file-exists-p file)))
           (parts '()))
      ;; File path (abbreviated)
      (when file
        (push (propertize (abbreviate-file-name file)
                          'face 'completions-annotations)
              parts))
      ;; Schema indicator
      (push (propertize (if has-schema "[schema]" "[no schema]")
                        'face (if has-schema 'success 'warning))
            parts)
      ;; Last used
      (when last-used
        (push (propertize (tabularium-registry--format-last-used last-used)
                          'face 'font-lock-doc-face)
              parts))
      (when parts
        (concat "  " (string-join (nreverse parts) "  "))))))

(defun tabularium-registry--completion-table ()
  "Build completion table for database selection."
  (let* ((databases (tabularium-registry--all-databases))
         (names (mapcar (lambda (e) (plist-get e :name)) databases)))
    (lambda (string pred action)
      (if (eq action 'metadata)
          '(metadata
            (category . tabularium-database)
            (annotation-function . tabularium-registry--annotation-function))
        (complete-with-action action names string pred)))))

;;; ** 3.6 Interactive Commands

;;;###autoload
(defun tabularium-register-database (db-file)
  "Register an existing database DB-FILE.
Offers schema creation options if no schema file exists."
  (interactive
   (list (read-file-name "Database file: " nil nil t nil
                         (lambda (f) (or (file-directory-p f)
                                        (string-suffix-p ".db" f))))))
  (let* ((db-file (expand-file-name db-file))
         (schema-file (tabularium-registry--schema-file-for-db db-file)))
    (unless (file-exists-p db-file)
      (user-error "Database file does not exist: %s" db-file))

    ;; If schema does not exist, offer options
    (unless (file-exists-p schema-file)
      (tabularium-register--resolve-missing-schema db-file schema-file))

    ;; Load the schema, with recovery on failure
    (let ((schema-name (tabularium-register--load-or-recover schema-file db-file)))
      ;; Check if the :file path in the loaded schema matches actual db-file
      (tabularium-register--check-path-mismatch schema-name schema-file db-file)

      ;; Register
      (tabularium-registry--add
       (list :name schema-name
             :file db-file
             :schema-file schema-file
             :last-used (float-time)))
      (message "Registered: %s" schema-name)
      (tabularium-registry--refresh-if-visible)
      ;; Offer to open
      (when (y-or-n-p (format "Open '%s' now? " schema-name))
        (tabularium-open schema-name)
        (tabularium-view)))))

(defun tabularium-register--resolve-missing-schema (db-file schema-file)
  "Prompt the user to provide or create a schema for DB-FILE.
The resulting schema is written to SCHEMA-FILE."
  (let ((choice (completing-read
                 (format "No schema found at %s.  How to proceed? "
                         (file-name-nondirectory schema-file))
                 '("Create from database structure (auto-detect)"
                   "Search for existing schema file"
                   "Create manually (wizard)"
                   "Cancel")
                 nil t)))
    (cond
     ((string-prefix-p "Create from database" choice)
      (tabularium-register--create-schema-from-db db-file schema-file))

     ((string-prefix-p "Search for" choice)
      (tabularium-register--search-and-validate-schema db-file schema-file))

     ((string-prefix-p "Create manually" choice)
      (let* ((name (read-string "Database name: "
                                (file-name-base db-file)))
             (fields (tabularium-wizard--read-fields)))
        (when (null fields)
          (user-error "Cannot register database with no fields"))
        (let ((content (tabularium-wizard--generate-schema-file
                        name db-file fields)))
          (with-temp-file schema-file
            (insert content)))
        (message "Created schema file: %s" schema-file)))

     (t (user-error "Registration canceled")))))

(defun tabularium-register--search-and-validate-schema (db-file schema-file)
  "Prompt the user to locate a schema file and validate it against DB-FILE.
On success, copies the validated schema to SCHEMA-FILE."
  (let ((found-file (read-file-name "Locate schema file: "
                                     (file-name-directory db-file)
                                     nil t nil
                                     (lambda (f)
                                       (or (file-directory-p f)
                                           (string-suffix-p tabularium-schema-file-suffix f)
                                           (string-suffix-p ".el" f))))))
    (unless (file-exists-p found-file)
      (user-error "File not found: %s" found-file))

    ;; Validate compatibility
    (let ((result (tabularium-register--validate-schema-against-db
                   found-file db-file)))
      (cond
       ;; Schema could not be parsed at all
       ((plist-get result :error)
        (user-error "Cannot read schema: %s" (plist-get result :error)))

       ;; Perfect match
       ((plist-get result :ok)
        (copy-file found-file schema-file t)
        (message "Schema validated and copied to %s" schema-file))

       ;; Mismatches found — let the user decide
       (t
        (let ((missing (plist-get result :missing))
              (extra (plist-get result :extra)))
          (if (y-or-n-p
               (format (concat "Schema/database column mismatch:\n"
                               "%s%s"
                               "Use this schema anyway? ")
                       (if missing
                           (format "  DB columns not in schema: %s\n"
                                   (string-join missing ", "))
                         "")
                       (if extra
                           (format "  Schema fields not in DB: %s\n"
                                   (string-join extra ", "))
                         "")))
              (progn
                (copy-file found-file schema-file t)
                (message "Schema copied to %s (with mismatches)" schema-file))
            (user-error "Registration canceled — schema not compatible"))))))))

(defun tabularium-register--load-or-recover (schema-file db-file)
  "Load SCHEMA-FILE for the database at DB-FILE, offering recovery if it fails.
Return the schema name on success."
  (let ((schema-name (tabularium-registry--load-schema-file schema-file)))
    (if schema-name
        schema-name
      ;; Load failed — offer recovery
      (let ((choice (completing-read
                     (format "Failed to load %s.  How to proceed? "
                             (file-name-nondirectory schema-file))
                     '("Recreate from database structure (auto-detect)"
                       "Search for a different schema file"
                       "Edit the schema file manually"
                       "Cancel")
                     nil t)))
        (cond
         ((string-prefix-p "Recreate" choice)
          (tabularium-register--create-schema-from-db db-file schema-file)
          (or (tabularium-registry--load-schema-file schema-file)
              (user-error "Still unable to load schema from %s" schema-file)))

         ((string-prefix-p "Search" choice)
          (tabularium-register--search-and-validate-schema db-file schema-file)
          (or (tabularium-registry--load-schema-file schema-file)
              (user-error "Still unable to load schema from %s" schema-file)))

         ((string-prefix-p "Edit" choice)
          (find-file schema-file)
          (user-error "Edit the schema file, then re-run `tabularium-register-database'"))

         (t (user-error "Registration canceled")))))))

(defun tabularium-register--check-path-mismatch (schema-name schema-file db-file)
  "Check that SCHEMA-NAME's :file (from SCHEMA-FILE) matches DB-FILE, offering to fix it."
  (let* ((schema (assoc schema-name tabularium-schemas))
         (schema-db-file (and schema (plist-get (cdr schema) :file)))
         (schema-db-file-expanded
          (and schema-db-file (expand-file-name schema-db-file))))
    (when (and schema-db-file-expanded
               (not (equal schema-db-file-expanded db-file)))
      (if (y-or-n-p (format (concat "Schema :file path mismatch!\n"
                                    "  Schema says: %s\n"
                                    "  Actual file: %s\n"
                                    "Update schema file? ")
                            schema-db-file db-file))
          (progn
            (plist-put (cdr schema) :file db-file)
            (tabularium-db-update-schema-file-path schema-file db-file)
            (message "Updated schema file with correct path"))
        (message "Warning: schema path not updated")))))

(defun tabularium-register--open-temp-db (db-file)
  "Open a temporary database connection to DB-FILE.
Returns the backend object.  Caller should close with
`tabularium-db-disconnect'."
  (let ((db (tabularium-db-create-backend 'sqlite)))
    (tabularium-db-connect db (list :file db-file))
    db))

(defun tabularium-register--get-db-columns (db-file)
  "Return a list of column name strings in DB-FILE.
Opens a temporary connection, reads PRAGMA table_info, and closes it."
  (let* ((db (tabularium-register--open-temp-db db-file))
         (tables (tabularium-db-query
                  db "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"))
         (table-name (caar tables))
         (columns (when table-name
                    (tabularium-db-query db (format "PRAGMA table_info(%s)" table-name)))))
    (tabularium-db-disconnect db)
    (mapcar (lambda (col) (nth 1 col)) columns)))

(defun tabularium-register--validate-schema-against-db (schema-file db-file)
  "Validate that SCHEMA-FILE is compatible with DB-FILE.
Returns a plist (:ok BOOL :schema-name STR :missing LIST :extra LIST)
where :missing are DB columns absent from the schema and :extra are
schema fields absent from the database."
  (let* ((db-columns (tabularium-register--get-db-columns db-file))
         ;; Load schema into a temp environment to inspect fields
         (schema-name nil)
         (schema-fields nil))
    ;; Temporarily load and extract field names without polluting tabularium-schemas
    (let ((saved-schemas (copy-sequence tabularium-schemas)))
      (condition-case err
          (progn
            (load schema-file nil t)
            (let ((new (car (cl-set-difference tabularium-schemas saved-schemas
                                               :test #'equal))))
              (when new
                (setq schema-name (car new))
                (setq schema-fields
                      (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                              (plist-get (cdr new) :fields)))))
            ;; Restore original schemas
            (setq tabularium-schemas saved-schemas))
        (error
         (setq tabularium-schemas saved-schemas)
         (list :ok nil :error (error-message-string err)))))
    (if (null schema-fields)
        (list :ok nil :error "Could not extract fields from schema")
      (let ((missing (cl-set-difference db-columns schema-fields :test #'string-equal))
            (extra (cl-set-difference schema-fields db-columns :test #'string-equal)))
        (list :ok (and (null missing) (null extra))
              :schema-name schema-name
              :missing missing
              :extra extra)))))

(defun tabularium-register--create-schema-from-db (db-file schema-file)
  "Create a schema file for DB-FILE by reading its structure.
Writes the schema to SCHEMA-FILE."
  (let* ((db (tabularium-register--open-temp-db db-file))
         (tables (tabularium-db-query db "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"))
         (table-name (if (= (length tables) 1)
                         (caar tables)
                       (completing-read "Which table? "
                                        (mapcar #'car tables) nil t)))
         (columns (tabularium-db-query db (format "PRAGMA table_info(%s)" table-name)))
         (schema-name (read-string "Database name: "
                                   (replace-regexp-in-string "-" " " (file-name-base db-file))))
         (fields '()))
    ;; Build fields from columns
    ;; PRAGMA table_info returns: (cid name type notnull dflt_value pk)
    (dolist (col columns)
      (let* ((col-name (nth 1 col))
             (col-type (downcase (or (nth 2 col) "text")))
             (is-pk (= (nth 5 col) 1))
             (tabularium-type (cond
                               ((string-match-p "int" col-type) 'integer)
                               ((string-match-p "real\\|float\\|double\\|numeric" col-type) 'number)
                               ((string-match-p "date" col-type) 'date)
                               (t 'text)))
             (field (list :id (intern col-name)
                          :type tabularium-type
                          :label (capitalize (replace-regexp-in-string "_" " " col-name)))))
        (when is-pk
          (setq field (plist-put field :primary t)))
        (push field fields)))
    (setq fields (nreverse fields))
    ;; Close the temporary connection
    (tabularium-db-disconnect db)
    ;; Generate schema file
    (let ((schema-content (tabularium-wizard--generate-schema-file schema-name db-file fields)))
      (with-temp-file schema-file
        (insert schema-content)))
    (message "Created schema from database structure: %s" schema-file)
    ;; Offer to edit
    (when (y-or-n-p "Edit schema file to customize? ")
      (find-file schema-file))))

;;;###autoload
(defun tabularium-forget-database (name)
  "Remove database NAME from the registry (files are not deleted)."
  (interactive
   (list (or (and (derived-mode-p 'tabularium-registry-mode)
                  (tabularium-registry--db-at-point))
             (completing-read "Delete database: "
                              (tabularium-registry--completion-table)
                              nil t))))
  (unless name
    (user-error "No database specified"))
  ;; Confirm before forgetting
  (unless (yes-or-no-p (format "Files will not be deleted.  Forget database '%s'? " name))
    (user-error "Canceled"))
  ;; Remove from registry
  (tabularium-registry--remove name)
  ;; Also remove from in-memory schemas
  (setq tabularium-schemas (assoc-delete-all name tabularium-schemas))
  ;; Clear current schema if it was the one being forgotten
  (when (equal tabularium--current-schema-name name)
    (setq tabularium--current-schema-name nil)
    (setq tabularium--db nil))
  ;; Refresh registry display if visible
  (tabularium-registry--refresh-if-visible)
  (message "Removed database: %s" name))

;;;###autoload
(defun tabularium-expunge-database (name)
  "Remove database NAME from the registry AND delete its files.
Deletes the database file, schema file, and any WAL/SHM files.
Closes the database first if it is currently open."
  (interactive
   (list (or (and (derived-mode-p 'tabularium-registry-mode)
                  (tabularium-registry--db-at-point))
             (completing-read "Expunge database: "
                              (tabularium-registry--completion-table)
                              nil t))))
  (unless name
    (user-error "No database specified"))
  (tabularium-registry--ensure-loaded)
  (let* ((entry (tabularium-registry--find-entry name))
         (schema (assoc name tabularium-schemas))
         (db-file (or (and entry (plist-get entry :file))
                      (and schema (plist-get (cdr schema) :file))))
         (db-path (when db-file (expand-file-name db-file)))
         (schema-file (when db-path
                        (tabularium-registry--schema-file-for-db db-path)))
         (files-to-delete
          (delq nil (list
                     (when (and db-path (file-exists-p db-path)) db-path)
                     (when (and schema-file (file-exists-p schema-file)) schema-file)
                     (when (and db-path (file-exists-p (concat db-path "-wal")))
                       (concat db-path "-wal"))
                     (when (and db-path (file-exists-p (concat db-path "-shm")))
                       (concat db-path "-shm"))))))
    (unless (yes-or-no-p
             (format "EXPUNGE '%s'?  This will permanently delete:\n  %s\nProceed? "
                     name
                     (if files-to-delete
                         (mapconcat #'abbreviate-file-name files-to-delete "\n  ")
                       "(no files found — registry entry only)")))
      (user-error "Canceled"))
    ;; Close if currently open
    (when (equal tabularium--current-schema-name name)
      (tabularium-close))
    ;; Delete files
    (dolist (f files-to-delete)
      (condition-case err
          (progn (delete-file f)
                 (message "Deleted %s" (abbreviate-file-name f)))
        (error (message "Could not delete %s: %s"
                        (abbreviate-file-name f) (error-message-string err)))))
    ;; Remove from registry and in-memory schemas
    (tabularium-registry--remove name)
    (setq tabularium-schemas (assoc-delete-all name tabularium-schemas))
    (tabularium-registry--refresh-if-visible)
    (message "Expunged '%s' (%d files deleted)" name (length files-to-delete))))

;;;###autoload
(defun tabularium-rename-database (old-name new-name)
  "Rename database from OLD-NAME to NEW-NAME.
Performs a coordinated rename across four locations: the in-memory
schema in `tabularium-schemas', the registry entry, the schema
file on disk, and the SQLite database file on disk (plus any
SQLite WAL/SHM sidecar files).  Each rename is confirmed
interactively so the user can opt out of any individual step
while still completing the others.

If the database is currently open, its connection is closed first
to free file handles before the on-disk renames, and the view
buffer (if any) is renamed to match the new schema name.

Errors part-way through leave the state inconsistent; the in-memory
schema, registry, and disk are best kept in sync, so re-run the
command or edit the registry and schema file by hand if a step
fails."
  (interactive
   (let* ((old (completing-read "Rename database: "
                                (tabularium-registry--completion-table)
                                nil t))
          (new (read-string (format "Rename '%s' to: " old) old)))
     (list old new)))
  (when (equal old-name new-name)
    (user-error "Names are the same, nothing to rename"))
  (when (assoc new-name tabularium-schemas)
    (user-error "A schema named '%s' already exists" new-name))
  (let* ((entry (tabularium-registry--find-entry old-name))
         (_ (unless entry
              (user-error "No registry entry for '%s'" old-name)))
         (old-db-file (and entry (plist-get entry :file)
                           (expand-file-name (plist-get entry :file))))
         (old-schema-file (and entry (plist-get entry :schema-file)
                               (expand-file-name
                                (plist-get entry :schema-file))))
         (slug (tabularium-rename--make-slug new-name))
         (_ (when (string-empty-p slug)
              (user-error
               "New name '%s' has no filesystem-safe characters" new-name)))
         (new-db-file (and old-db-file
                           (expand-file-name
                            (concat slug ".db")
                            (file-name-directory old-db-file))))
         (new-schema-file (and old-schema-file
                               (expand-file-name
                                (concat slug tabularium-schema-file-suffix)
                                (file-name-directory old-schema-file))))
         (was-open (equal tabularium--current-schema-name old-name))
         ;; Decisions collected up front
         (rename-db-p (and new-db-file
                           (not (equal old-db-file new-db-file))
                           (y-or-n-p
                            (format "Rename database file to %s? "
                                    (file-name-nondirectory new-db-file)))))
         (rename-schema-p (and old-schema-file
                               (file-exists-p old-schema-file)
                               new-schema-file
                               (not (equal old-schema-file new-schema-file))
                               (y-or-n-p
                                (format "Rename schema file to %s? "
                                        (file-name-nondirectory
                                         new-schema-file)))))
         ;; Renaming the schema file without updating its contents would
         ;; leave the file's embedded :file and `tabularium-define-schema'
         ;; arguments stale, so the rename implies a content update.
         (update-schema-contents-p
          (or rename-schema-p
              (and old-schema-file (file-exists-p old-schema-file)
                   (y-or-n-p
                    "Update schema file contents (name, :file, headers)? "))))
         ;; Effective post-rename paths (used everywhere after this point)
         (effective-db-file (if rename-db-p new-db-file old-db-file))
         (effective-schema-file (if rename-schema-p new-schema-file
                                  old-schema-file)))
    ;; Sanity-check targets before any destructive work
    (when (and rename-db-p (file-exists-p new-db-file))
      (user-error "Target database file already exists: %s" new-db-file))
    (when (and rename-schema-p (file-exists-p new-schema-file))
      (user-error "Target schema file already exists: %s" new-schema-file))

    ;; Step 1: close any open connection so the SQLite file handle is freed
    ;; before we touch the files on disk.  Without this, on some platforms
    ;; `rename-file' will succeed but the open handle keeps writing to a
    ;; ghost inode.
    (when was-open
      (tabularium-close))

    ;; Step 2: rename the database file on disk (plus WAL/SHM sidecars)
    (when (and rename-db-p (file-exists-p old-db-file))
      (rename-file old-db-file new-db-file)
      (dolist (suffix '("-wal" "-shm" "-journal"))
        (let ((old-side (concat old-db-file suffix))
              (new-side (concat new-db-file suffix)))
          (when (file-exists-p old-side)
            (rename-file old-side new-side)))))

    ;; Step 3: update the schema file's contents in place (still at the
    ;; old path), then rename the file itself.  Doing the content update
    ;; first means the rename can fail without leaving stale content.
    (when update-schema-contents-p
      (tabularium-rename--update-schema-file-contents
       old-schema-file old-name new-name
       (and rename-db-p effective-db-file)
       slug))
    (when rename-schema-p
      (rename-file old-schema-file new-schema-file))

    ;; Step 4: update the in-memory schema entry
    (let ((schema (assoc old-name tabularium-schemas)))
      (when schema
        (setcar schema new-name)
        (when rename-db-p
          (plist-put (cdr schema) :file effective-db-file))))

    ;; Step 5: update `tabularium--current-schema-name' if it pointed at
    ;; the renamed schema
    (when (equal tabularium--current-schema-name old-name)
      (setq tabularium--current-schema-name new-name))

    ;; Step 6: update the registry entry.  Use :name (not :id — that was a
    ;; long-standing bug that caused the registry to never see the new
    ;; name) and the abbreviated forms of the post-rename paths.
    (let ((reg-entry (tabularium-registry--find-entry old-name)))
      (when reg-entry
        (plist-put reg-entry :name new-name)
        (plist-put reg-entry :file (abbreviate-file-name effective-db-file))
        (when effective-schema-file
          (plist-put reg-entry :schema-file
                     (abbreviate-file-name effective-schema-file)))))
    (tabularium-registry--save)
    (tabularium-registry--refresh-if-visible)

    ;; Step 7: rename the view buffer if one was open
    (let ((old-buf (get-buffer (format "*%s*" old-name))))
      (when (buffer-live-p old-buf)
        (with-current-buffer old-buf
          (rename-buffer (format "*%s*" new-name) t)
          (when (boundp 'tabularium--buffer-schema-name)
            (setq-local tabularium--buffer-schema-name new-name)))))

    ;; Step 8: reopen if the database was open before the rename
    (when was-open
      (tabularium-open new-name))

    (message "Renamed '%s' to '%s'" old-name new-name)))

(defun tabularium-rename--make-slug (name)
  "Convert NAME to a filesystem-safe slug.
Lowercases NAME, replaces any run of non-alphanumeric characters
with a single hyphen, and trims leading/trailing hyphens.  Returns
the empty string if NAME contains no alphanumeric characters.

The implementation deliberately uses `[^a-z0-9]+' rather than an
enumerated character class — the previous form spelled out the
characters to strip and got the regex-inside-character-class
escape rules wrong, so parentheses and brackets survived.
Matching the negation is both simpler and harder to get wrong."
  (let* ((lowered (downcase name))
         (replaced (replace-regexp-in-string "[^a-z0-9]+" "-" lowered))
         (trimmed (replace-regexp-in-string "\\`-\\|-\\'" "" replaced)))
    trimmed))

(defun tabularium-rename--make-provide-symbol (slug)
  "Convert SLUG to a provide symbol name."
  (concat slug "-schema"))

(defun tabularium-rename--update-schema-file-contents (schema-file _old-name new-name new-db-path slug)
  "Update SCHEMA-FILE contents with new name, db path, and provide statement.
OLD-NAME and NEW-NAME are the schema names.
NEW-DB-PATH is the new database path (or nil to leave unchanged).
SLUG is the filesystem-safe version of the name."
  (with-temp-buffer
    (insert-file-contents schema-file)
    (goto-char (point-min))

    ;; Update tabularium-define-schema name
    (when (re-search-forward
           "(tabularium-define-schema\\s-+\"[^\"]*\""
           nil t)
      (replace-match (format "(tabularium-define-schema \"%s\"" new-name)))

    ;; Update :file path if provided
    (when new-db-path
      (goto-char (point-min))
      (when (re-search-forward "^\\([ \t]*:file[ \t]+\\)\"[^\"]*\"" nil t)
        (replace-match (format "\\1\"%s\"" (abbreviate-file-name new-db-path)))))

    ;; Update file header comment if present
    (goto-char (point-min))
    (when (re-search-forward "^;;; [^ ]+ --- " nil t)
      (beginning-of-line)
      (when (looking-at ";;; \\([^ ]+\\) ---")
        (replace-match (format ";;; %s.schema.el ---" slug))))

    ;; Update provide statement
    (goto-char (point-min))
    (when (re-search-forward "(provide '\\([^)]+\\))" nil t)
      (replace-match (format "(provide '%s)"
                             (tabularium-rename--make-provide-symbol slug))))

    ;; Update "ends here" comment
    (goto-char (point-min))
    (when (re-search-forward "^;;; .+ ends here" nil t)
      (replace-match (format ";;; %s.schema.el ends here" slug)))

    (write-region (point-min) (point-max) schema-file)
    t))

;;; ** 3.7 Registry Buffer & Mode

(defun tabularium-registry--shorten-path (path max-len)
  "Shorten PATH to fit within MAX-LEN characters.
Uses `abbreviate-file-name' first, then truncates to show ~/first/.../last/file."
  (let ((short (abbreviate-file-name path)))
    (if (<= (length short) max-len)
        short
      ;; Need to shorten: show ~/first_folder/.../last_folder/filename
      (let* ((filename (file-name-nondirectory short))
             (dir (file-name-directory short))
             (dir-parts (split-string (directory-file-name dir) "/" t))
             (home-prefix (if (string-prefix-p "~" short) "~/" "/")))
        ;; Remove ~ from parts if present
        (when (and (string-prefix-p "~" short) (> (length dir-parts) 0))
          (setq dir-parts (cdr dir-parts)))  ; remove empty or ~ part
        (let* ((first-folder (car dir-parts))
               (last-folder (car (last dir-parts)))
               ;; Try full format: ~/first/.../last/filename
               (full-format (if (and first-folder last-folder
                                     (not (string= first-folder last-folder)))
                                (concat home-prefix first-folder "/.../" last-folder "/" filename)
                              ;; Only one folder level
                              (concat home-prefix (or last-folder "") "/.../" filename)))
               ;; Simpler format without first folder: ~/.../last/filename
               (simple-format (concat home-prefix ".../" (or last-folder "") "/" filename)))
          (cond
           ;; Try full format first
           ((<= (length full-format) max-len)
            full-format)
           ;; Fall back to simple format
           ((<= (length simple-format) max-len)
            simple-format)
           ;; Last resort: truncate filename
           (t
            (let* ((available (- max-len (length home-prefix) 4 (length last-folder) 1))  ; ".../" + "/"
                   (trunc-name (if (> available 8)
                                   (concat (substring filename 0 (- available 3)) "...")
                                 (substring filename 0 (min (length filename) 12)))))
              (concat home-prefix ".../" (or last-folder "") "/" trunc-name)))))))))

;; Buffer-local variables for registry navigation bounds
(defvar-local tabularium-registry--first-line nil
  "First line number containing a database entry.")

(defvar-local tabularium-registry--last-line nil
  "Last line number containing a database entry.")

(defvar tabularium-registry--marked-names nil
  "List of database names currently marked in the registry buffer.
Stored globally rather than buffer-locally because the registry
buffer is a singleton and `tabularium-registry-mode' (derived from
`special-mode') kills buffer-local variables every time the buffer
is rebuilt by `tabularium-registry'.  A global survives the
refresh so marks persist across `tabularium-registry--refresh-if-visible'.")

(defun tabularium-registry--render (buf)
  "Render the registry listing into BUF and enable `tabularium-registry-mode'.
Fills BUF with the current database list and key hints and sets
the navigation bounds, but neither displays nor selects it —
callers arrange display.  The open database, if any, is flagged
with a `+' in the mark column (a `*' for a marked row takes
precedence)."
  (let ((databases (tabularium-registry--all-databases)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (first-entry-line nil)
            (last-entry-line nil)
            ;; Layout: 2 indent + 20 name + 1 space + 8 schema + 1 space = 32, leaving 48 for path
            (max-path-len 46))
        (erase-buffer)
        ;; Header - heavy lines for registry distinction
        (insert (tabularium--make-box-header "Tabularium Registry" 80 'heavy) "\n")
        (insert "\n")
        (insert (format "  %-20s %-8s %s\n" "Name" "Schema?" "Path"))
        (insert (propertize (concat "  " (make-string 76 ?━) "\n") 'face 'shadow))
        ;; Database entries with text properties
        (dolist (entry databases)
          (let* ((name (plist-get entry :name))
                 (file (plist-get entry :file))
                 (has-schema (and file (tabularium-registry--schema-file-exists-p file)))
                 (display-path (if file
                                   (tabularium-registry--shorten-path file max-path-len)
                                 "-"))
                 (marked (and name (member name tabularium-registry--marked-names)))
                 (open (and name tabularium--current-schema-name
                            (string= name tabularium--current-schema-name)))
                 ;; Mark column: `*' marked (highest priority), else `+'
                 ;; for the open database, else blank.
                 (indicator (cond
                             (marked (propertize "*" 'face 'tabularium-marked-face))
                             (open (propertize "+" 'face 'tabularium-registry-open-face))
                             (t " ")))
                 (start (point))
                 (line-num (line-number-at-pos start)))
            ;; Track first/last entry lines for navigation bounds
            (unless first-entry-line
              (setq first-entry-line line-num))
            (setq last-entry-line line-num)
            (insert (propertize
                     (format "%s %-20s %-8s %s\n"
                             indicator
                             (truncate-string-to-width (or name "?") 20)
                             (if has-schema "Yes" "No")
                             display-path)
                     'tabularium-db-name name
                     'face (and marked 'tabularium-marked-face)))))
        ;; Footer - heavy lines to match header
        (insert "\n")
        (insert (tabularium--make-box-footer 80 'heavy) "\n")
        (insert (format "  Total: %d databases\n" (length databases)))
        (insert "  " (propertize "+" 'face 'tabularium-registry-open-face)
                " marks the open database\n\n")
        (insert "  " (propertize "RET" 'face 'help-key-binding) "/"
                (propertize "O" 'face 'help-key-binding) " Open + View   "
                (propertize "o" 'face 'help-key-binding) " Open   "
                (propertize "v" 'face 'help-key-binding) " View   "
                (propertize "C" 'face 'help-key-binding) " Create   "
                (propertize "+" 'face 'help-key-binding) " Register   "
                (propertize "?" 'face 'help-key-binding) " Describe\n")
        (insert "  " (propertize "." 'face 'help-key-binding) " Edit schema   "
                (propertize "$" 'face 'help-key-binding) " Rename   "
                (propertize "d" 'face 'help-key-binding) " Duplicate   "
                (propertize "D" 'face 'help-key-binding) " Delete   "
                (propertize "X" 'face 'help-key-binding) " Expunge   "
                (propertize "x" 'face 'help-key-binding) " Action\n")
        (insert "  " (propertize "m" 'face 'help-key-binding) " Mark   "
                (propertize "u" 'face 'help-key-binding) " Unmark   "
                (propertize "U" 'face 'help-key-binding) " Unmark all   "
                (propertize "t" 'face 'help-key-binding) " Toggle   "
                (propertize "c" 'face 'help-key-binding) " Close\n")
        (insert "  " (propertize "i" 'face 'help-key-binding) "/"
                (propertize "<" 'face 'help-key-binding) " Import   "
                (propertize "e" 'face 'help-key-binding) "/"
                (propertize ">" 'face 'help-key-binding) " Export   "
                (propertize "/" 'face 'help-key-binding) " Dired\n")
        (insert "  " (propertize "q" 'face 'help-key-binding) " Quit   "
                (propertize "g" 'face 'help-key-binding) "/"
                (propertize "=" 'face 'help-key-binding) " Refresh\n")
        ;; Activate mode FIRST (kills local variables)
        (tabularium-registry-mode)
        ;; THEN store bounds for navigation (after mode is active)
        (setq tabularium-registry--first-line (or first-entry-line 5))
        (setq tabularium-registry--last-line (or last-entry-line 5))))))

(defun tabularium-registry--refresh-if-visible ()
  "Refresh the registry buffer if it exists, preserving cursor position."
  (when-let ((buf (get-buffer "*Tabularium Registry*")))
    (with-current-buffer buf
      (let ((line (line-number-at-pos)))
        (tabularium-registry--render buf)
        (goto-char (point-min))
        (forward-line (1- line))))))

(defun tabularium-registry--name-position (name)
  "Return the buffer position of the registry row for NAME, or nil.
Assumes the current buffer is the rendered registry."
  (when name
    (save-excursion
      (goto-char (point-min))
      (let (pos)
        (while (and (not pos) (not (eobp)))
          (when (equal name (get-text-property (line-beginning-position)
                                               'tabularium-db-name))
            (setq pos (line-beginning-position)))
          (forward-line 1))
        pos))))

(defun tabularium-registry--refresh-to-db (db-name)
  "Re-render the registry buffer (if open) and move point to DB-NAME.
Called after opening a database so the freshly opened entry — now
sorted to the top by `:last-used' — is current and already under
point by the time the user returns to the registry, without
stealing focus from the current window.  Point is mirrored into
every window showing the buffer so a later mark does not jump."
  (when-let ((buf (get-buffer "*Tabularium Registry*")))
    (tabularium-registry--render buf)
    (with-current-buffer buf
      (let ((pos (or (tabularium-registry--name-position db-name)
                     (next-single-property-change (point-min)
                                                  'tabularium-db-name))))
        (when pos
          (goto-char pos)
          (dolist (win (get-buffer-window-list buf nil t))
            (set-window-point win pos)))))))

;;;###autoload
(defun tabularium-registry ()
  "Display a buffer listing all known databases."
  (interactive)
  (let ((buf (get-buffer-create "*Tabularium Registry*")))
    (tabularium-registry--render buf)
    (switch-to-buffer buf)
    ;; Position cursor at the first database entry — applied after the
    ;; buffer is displayed so window-point doesn't get reset back to
    ;; (point-min) by Emacs's redisplay machinery.
    (goto-char (point-min))
    (let ((pos (next-single-property-change (point-min) 'tabularium-db-name)))
      (when pos (goto-char pos)))))

(defun tabularium-registry--db-at-point ()
  "Return the database name at point, or nil."
  (get-text-property (line-beginning-position) 'tabularium-db-name))

(defun tabularium-registry-open-at-point ()
  "Open the database at point.
If another database is already open, prompt to close it first."
  (interactive)
  (if-let ((db-name (tabularium-registry--db-at-point)))
      (progn
        ;; Check if a database is already open
        (when (and tabularium--current-schema-name
                   (not (string= tabularium--current-schema-name db-name)))
          (if (yes-or-no-p (format "Close '%s' and open '%s'? "
                                   tabularium--current-schema-name db-name))
              (tabularium-close)
            (user-error "Canceled")))
        (tabularium-open db-name)
        (message "Opened database: %s" db-name))
    (user-error "No database at point")))

(defun tabularium-registry-next-entry ()
  "Move to the next entry, respecting bounds."
  (interactive)
  (let ((current-line (line-number-at-pos))
        (last-line (or tabularium-registry--last-line 5)))
    (if (< current-line last-line)
        (forward-line 1)
      (message "Last entry"))))

(defun tabularium-registry-prev-entry ()
  "Move to the previous entry, respecting bounds."
  (interactive)
  (let ((current-line (line-number-at-pos))
        (first-line (or tabularium-registry--first-line 5)))
    (if (> current-line first-line)
        (forward-line -1)
      (message "First entry"))))

(defvar tabularium-registry-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'tabularium-registry-open-and-view-at-point)
    (define-key map (kbd "O") #'tabularium-registry-open-and-view-at-point)
    (define-key map (kbd "o") #'tabularium-registry-open-at-point)
    (define-key map (kbd "v") #'tabularium-registry-open-and-view-at-point)
    (define-key map (kbd "C") #'tabularium-create-database)
    (define-key map (kbd "R") #'tabularium-register-database)
    (define-key map (kbd "c") #'tabularium-close)
    (define-key map (kbd "$") #'tabularium-registry-rename-at-point)
    (define-key map (kbd "+") #'tabularium-registry-duplicate-at-point)
    (define-key map (kbd "D") #'tabularium-registry-delete-at-point)
    (define-key map (kbd "X") #'tabularium-registry-expunge-at-point)
    (define-key map (kbd "m") #'tabularium-registry-mark)
    (define-key map (kbd "u") #'tabularium-registry-unmark)
    (define-key map (kbd "U") #'tabularium-registry-unmark-all)
    (define-key map (kbd "t") #'tabularium-registry-toggle-marks)
    (define-key map (kbd "x") #'tabularium-registry-execute)
    (define-key map (kbd ".") #'tabularium-registry-edit-schema-at-point)
    (define-key map (kbd "i") #'tabularium-import)
    (define-key map (kbd "e") #'tabularium-registry-export-at-point)
    (define-key map (kbd "<") #'tabularium-import)
    (define-key map (kbd ">") #'tabularium-registry-export-at-point)
    (define-key map (kbd "?") #'tabularium-registry-describe-at-point)
    (define-key map (kbd "g") #'tabularium-registry)
    (define-key map (kbd "=") #'tabularium-registry)
    (define-key map (kbd "TAB") #'tabularium-registry-next-entry)
    (define-key map (kbd "<backtab>") #'tabularium-registry-prev-entry)
    (define-key map (kbd "n") #'tabularium-registry-next-entry)
    (define-key map (kbd "p") #'tabularium-registry-prev-entry)
    (define-key map (kbd "/") #'tabularium-registry-dired-at-point)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `tabularium-registry-mode'.")

(defun tabularium-registry--open-at-point-and (action)
  "Open the database at point, then call ACTION.
Prompts before switching if another database is open."
  (if-let ((db-name (tabularium-registry--db-at-point)))
      (progn
        (when (and tabularium--current-schema-name
                   (not (string= tabularium--current-schema-name db-name)))
          (if (yes-or-no-p (format "Close '%s' and open '%s'? "
                                   tabularium--current-schema-name db-name))
              (progn
                (when-let ((old-buf (get-buffer (format "*%s*" tabularium--current-schema-name))))
                  (kill-buffer old-buf))
                (tabularium-close))
            (user-error "Canceled")))
        (tabularium-open db-name)
        (funcall action))
    (user-error "No database at point")))

(defun tabularium-registry-open-and-view-at-point ()
  "Open the database at point and show the view buffer."
  (interactive)
  (tabularium-registry--open-at-point-and #'tabularium-view))

(defun tabularium-registry-dired-at-point ()
  "Visit the directory of the database at point in Dired, in a new window.
The other window is selected with point on the database file, so
its sidecar files (the schema, any WAL/SHM) are visible alongside
it.  Bound to `/' in the registry."
  (interactive)
  (if-let ((db-name (tabularium-registry--db-at-point)))
      (let* ((entry (tabularium-registry--find-entry db-name))
             (db-file (plist-get entry :file)))
        (unless db-file
          (user-error "No file recorded for '%s'" db-name))
        (let ((expanded (expand-file-name db-file)))
          (unless (file-exists-p (file-name-directory expanded))
            (user-error "Directory does not exist: %s"
                        (file-name-directory expanded)))
          ;; `dired-jump' in the other window puts point on the file
          ;; itself when the file exists, otherwise just opens the dir.
          (if (file-exists-p expanded)
              (dired-jump-other-window expanded)
            (dired-other-window (file-name-directory expanded)))))
    (user-error "No database at point")))

(defun tabularium-registry-edit-schema-at-point ()
  "Edit the schema file for the database at point."
  (interactive)
  (if-let ((db-name (tabularium-registry--db-at-point)))
      (let* ((entry (tabularium-registry--find-entry db-name))
             (db-file (plist-get entry :file))
             (schema-file (and db-file (tabularium-registry--schema-file-for-db db-file))))
        (if (and schema-file (file-exists-p schema-file))
            (find-file schema-file)
          (user-error "Schema file not found for %s" db-name)))
    (user-error "No database at point")))

(defun tabularium-registry--do-rename (names)
  "Rename each database in NAMES, prompting for each new name.
NAMES is a list of database names.  An empty response or a name
identical to the current one skips that database.  Per-database
errors are caught and reported so one failure does not abort the
rest.  Iterates a snapshot copy since `tabularium-rename-database'
mutates the registry as it runs."
  (dolist (name (copy-sequence names))
    (let ((new-name (read-string
                     (format "Rename '%s' to (empty to skip): " name)
                     name)))
      (unless (or (string-empty-p new-name) (equal new-name name))
        (condition-case err
            (tabularium-rename-database name new-name)
          (error (message "Skipped '%s': %s"
                           name (error-message-string err))))))))

(defun tabularium-registry--do-duplicate (names)
  "Duplicate each database in NAMES, prompting for each new name.
NAMES is a list of database names.  An empty name response skips
that database; a database with no associated schema file is
skipped with a message.  Per-database errors are caught.

Each copy is created in the source database's own directory by
default.  When called for one or more databases the user is first
asked whether to place the copies in a custom directory instead;
answering no (the default) keeps every copy beside its source.
The new database file is named from the new display name's slug,
so no per-file path prompt is needed."
  (let* ((custom-dir
          (when (and names
                     (y-or-n-p
                      "Place the duplicate(s) in a custom directory? "))
            (file-name-as-directory
             (expand-file-name
              (read-directory-name "Directory for duplicate(s): "))))))
    (dolist (name (copy-sequence names))
      (condition-case err
          (let* ((entry (tabularium-registry--find-entry name))
                 (source-schema (and entry (plist-get entry :schema-file))))
            (if (not source-schema)
                (message "Skipped '%s': no schema file" name)
              (let* ((new-name (read-string
                                (format "Duplicate '%s' as (empty to skip): "
                                        name)
                                (concat name " copy")))
                     ;; Default location: the source database's own
                     ;; directory, unless a custom one was chosen.
                     (dir (or custom-dir
                              (and (plist-get entry :file)
                                   (file-name-directory
                                    (expand-file-name
                                     (plist-get entry :file))))
                              (expand-file-name "~/")))
                     (slug (tabularium-wizard--filename-slug new-name))
                     (base (concat (if (string-empty-p slug)
                                       "database" slug)
                                   ".db"))
                     (db-file (expand-file-name base dir)))
                (unless (string-empty-p new-name)
                  (tabularium-create-database-from-schema-file
                   (expand-file-name source-schema)
                   new-name
                   db-file)))))
        (error (message "Skipped '%s': %s"
                        name (error-message-string err)))))))

(defun tabularium-registry--do-delete (names)
  "Forget each database in NAMES from the registry after one confirmation.
Database files are left on disk.  NAMES is a list of database
names.  Per-database errors are caught."
  (let ((count (length names)))
    (when (yes-or-no-p
           (if (= count 1)
               (format "Forget '%s'?  Files will not be deleted. "
                       (car names))
             (format "Forget %d database(s)?  Files will not be deleted. "
                     count)))
      (dolist (name (copy-sequence names))
        (condition-case err
            (progn
              (tabularium-registry--remove name)
              (setq tabularium-schemas
                    (assoc-delete-all name tabularium-schemas))
              (when (equal tabularium--current-schema-name name)
                (setq tabularium--current-schema-name nil
                      tabularium--db nil)))
          (error (message "Skipped '%s': %s"
                           name (error-message-string err)))))
      (message "Forgot %d database(s)" count))))

(defun tabularium-registry--do-expunge (names)
  "Expunge each database in NAMES after one confirmation.
The database file, schema file, and SQLite WAL/SHM/journal
sidecars are PERMANENTLY DELETED.  NAMES is a list of database
names.  Per-database errors are caught."
  (let ((count (length names)))
    (when (yes-or-no-p
           (if (= count 1)
               (format
                "Expunge '%s'?  Database and schema files will be permanently deleted. "
                (car names))
             (format
              "Expunge %d database(s)?  Database and schema files will be permanently deleted. "
              count)))
      (let ((deleted 0))
        (dolist (name (copy-sequence names))
          (condition-case err
              (let* ((entry (tabularium-registry--find-entry name))
                     (db-file (and entry (plist-get entry :file)))
                     (db-path (and db-file (expand-file-name db-file)))
                     (schema-file
                      (and db-path
                           (tabularium-registry--schema-file-for-db db-path)))
                     (files (delq nil
                                  (list
                                   (and db-path (file-exists-p db-path)
                                        db-path)
                                   (and schema-file
                                        (file-exists-p schema-file)
                                        schema-file)
                                   (and db-path
                                        (file-exists-p (concat db-path "-wal"))
                                        (concat db-path "-wal"))
                                   (and db-path
                                        (file-exists-p (concat db-path "-shm"))
                                        (concat db-path "-shm"))
                                   (and db-path
                                        (file-exists-p
                                         (concat db-path "-journal"))
                                        (concat db-path "-journal"))))))
                (when (equal tabularium--current-schema-name name)
                  (tabularium-close))
                (dolist (f files)
                  (delete-file f)
                  (cl-incf deleted))
                (tabularium-registry--remove name)
                (setq tabularium-schemas
                      (assoc-delete-all name tabularium-schemas)))
            (error (message "Skipped '%s': %s"
                             name (error-message-string err)))))
        (message "Expunged %d database(s), %d file(s) deleted"
                 count deleted)))))

(defun tabularium-registry-rename-at-point ()
  "Rename databases from the registry.
Acts on the marked databases if any are marked, otherwise on the
database at point — the marked-or-at-point paradigm used by
`view-mode' row operations.  Each database is renamed via
`tabularium-rename-database' with its own interactive prompt for
the new name.  Marks are cleared afterward."
  (interactive)
  (let ((names (tabularium-registry--targets)))
    (tabularium-registry--do-rename names)
    (setq tabularium-registry--marked-names nil)
    (tabularium-registry--refresh-if-visible)))

(defun tabularium-registry-duplicate-at-point ()
  "Duplicate database schemas from the registry as new empty databases.
Acts on the marked databases if any are marked, otherwise on the
database at point.  Each duplicate delegates to
`tabularium-create-database-from-schema-file' — a \"Save As\" for
schemas that keeps the field definitions, saved views, conditional
formatting, default sort, and backend choice but starts with no
rows.  Each database prompts for its own new name and file path.
Marks are cleared afterward."
  (interactive)
  (let ((names (tabularium-registry--targets)))
    (tabularium-registry--do-duplicate names)
    (setq tabularium-registry--marked-names nil)
    (tabularium-registry--refresh-if-visible)))

(defun tabularium-registry-delete-at-point ()
  "Forget databases from the registry (files are not deleted).
Acts on the marked databases if any are marked, otherwise on the
database at point.  A single confirmation covers the whole set.
Marks are cleared afterward."
  (interactive)
  (let ((names (tabularium-registry--targets)))
    (tabularium-registry--do-delete names)
    (setq tabularium-registry--marked-names nil)
    (tabularium-registry--refresh-if-visible)))

(defun tabularium-registry-expunge-at-point ()
  "Expunge databases from the registry, deleting their files.
Acts on the marked databases if any are marked, otherwise on the
database at point.  The database file, schema file, and SQLite
WAL/SHM/journal sidecars are PERMANENTLY DELETED.  A single
confirmation covers the whole set.  Marks are cleared afterward."
  (interactive)
  (let ((names (tabularium-registry--targets)))
    (tabularium-registry--do-expunge names)
    (setq tabularium-registry--marked-names nil)
    (tabularium-registry--refresh-if-visible)))

(defun tabularium-registry-describe-at-point ()
  "Show `tabularium-describe-database' for the database at point.
Describes the database without opening a connection — the schema
file and file metadata are read from disk.  The row count is
shown only if the database happens to already be open; otherwise
it appears as a dash.  This makes it a quick, side-effect-free way
to profile a database straight from the registry listing."
  (interactive)
  (let ((name (tabularium-registry--db-at-point)))
    (unless name
      (user-error "No database at point"))
    (tabularium-describe-database name)))

(defun tabularium-registry--do-export (names)
  "Export each database in NAMES, prompting per database for format and file.
NAMES is a list of database names.  Each database is opened just
long enough to run `tabularium-export'; a database that was not
already open is closed again afterward, and the previously-current
database (if any) is reopened so the registry export leaves no
database unexpectedly open.  Per-database errors are caught."
  (let ((prior tabularium--current-schema-name))
    (dolist (name (copy-sequence names))
      (condition-case err
          (let ((was-open (equal tabularium--current-schema-name name)))
            (unless was-open
              (tabularium-open name))
            (call-interactively #'tabularium-export)
            (unless was-open
              (tabularium-close)))
        (error (message "Skipped '%s': %s"
                         name (error-message-string err)))))
    ;; Restore whatever database was current before the batch.
    (when (and prior (not (equal tabularium--current-schema-name prior)))
      (condition-case nil
          (tabularium-open prior)
        (error nil)))))

(defun tabularium-registry-export-at-point ()
  "Export databases from the registry.
Acts on the marked databases if any are marked, otherwise on the
database at point — the marked-or-at-point paradigm used by
`view-mode' row operations.  Each database is opened just long
enough to run `tabularium-export' (which prompts for format and
output file), then closed again if it was not already open.
Marks are cleared afterward."
  (interactive)
  (let ((names (tabularium-registry--targets)))
    (tabularium-registry--do-export names)
    (setq tabularium-registry--marked-names nil)
    (tabularium-registry--refresh-if-visible)))

;;; *** 3.7.1 Registry Marking and Batch Operations

(defun tabularium-registry-mark ()
  "Mark the database at point and move to the next entry.
Marked databases are acted on together by
`tabularium-registry-execute'."
  (interactive)
  (let ((name (tabularium-registry--db-at-point)))
    (unless name
      (user-error "No database at point"))
    (cl-pushnew name tabularium-registry--marked-names :test #'equal)
    (tabularium-registry--refresh-if-visible)
    (tabularium-registry-next-entry)))

(defun tabularium-registry-unmark ()
  "Unmark the database at point and move to the next entry."
  (interactive)
  (let ((name (tabularium-registry--db-at-point)))
    (unless name
      (user-error "No database at point"))
    (setq tabularium-registry--marked-names
          (delete name tabularium-registry--marked-names))
    (tabularium-registry--refresh-if-visible)
    (tabularium-registry-next-entry)))

(defun tabularium-registry-unmark-all ()
  "Clear all marks in the registry buffer."
  (interactive)
  (setq tabularium-registry--marked-names nil)
  (tabularium-registry--refresh-if-visible)
  (message "Cleared all marks"))

(defun tabularium-registry-toggle-marks ()
  "Toggle marks: mark every unmarked database and unmark every marked one."
  (interactive)
  (let ((all (mapcar (lambda (e) (plist-get e :name))
                     (tabularium-registry--all-databases))))
    (setq tabularium-registry--marked-names
          (cl-remove-if (lambda (n)
                          (member n tabularium-registry--marked-names))
                        all))
    (tabularium-registry--refresh-if-visible)
    (message "%d database(s) now marked"
             (length tabularium-registry--marked-names))))

(defun tabularium-registry--targets ()
  "Return the database names a registry action should operate on.
Follows the marked-or-at-point paradigm used by view-mode row
operations: if any databases are marked, return the marked set
\(stale marks pruned); otherwise return a single-element list with
the database at point.  Signals a `user-error' if neither is
available.

The return value is always a fresh list safe to iterate even
while the registry mutates underneath \(callers still snapshot
with `copy-sequence' when the loop body renames or deletes)."
  (let* ((known (mapcar (lambda (e) (plist-get e :name))
                        (tabularium-registry--all-databases)))
         (live (cl-remove-if-not (lambda (n) (member n known))
                                 tabularium-registry--marked-names)))
    (setq tabularium-registry--marked-names live)
    (or (copy-sequence live)
        (when-let ((at-point (tabularium-registry--db-at-point)))
          (list at-point))
        (user-error "No database marked or at point"))))

(defun tabularium-registry-execute ()
  "Run a chosen batch operation on the marked databases or the one at point.
Prompts for the action — rename, duplicate, delete (forget), or
expunge — then applies it via the same workers the dedicated keys
use.  Acts on the marked set if any databases are marked, else on
the database at point.  This is the menu-driven entry point; the
=$=/=d=/=D=/=X= keys invoke the individual actions directly.
Marks are cleared afterward."
  (interactive)
  (let* ((names (tabularium-registry--targets))
         (count (length names))
         (action (intern
                  (completing-read
                   (format "Action on %d database(s): " count)
                   '("rename" "duplicate" "delete" "expunge")
                   nil t))))
    (pcase action
      ('rename (tabularium-registry--do-rename names))
      ('duplicate (tabularium-registry--do-duplicate names))
      ('delete (tabularium-registry--do-delete names))
      ('expunge (tabularium-registry--do-expunge names)))
    (setq tabularium-registry--marked-names nil)
    (tabularium-registry--refresh-if-visible)))

(define-derived-mode tabularium-registry-mode special-mode "Tabularium-Registry"
  "Mode for listing known databases.")

;;; ** 3.8 Open / Close

;;;###autoload
(defun tabularium-close ()
  "Close the current database connection.
Also discards the database's view buffer, so re-opening it starts
from the schema's default view rather than the view that was
active when it was closed."
  (interactive)
  (when tabularium--current-schema-name
    (let ((name tabularium--current-schema-name))
      (tabularium-db-close-connection name)
      (setq tabularium--db nil)
      (setq tabularium--current-schema-name nil)
      (tabularium--invalidate-cache)
      ;; Discard the view buffer so its sort/filter/hidden state does
      ;; not survive a close → reopen; a live buffer would otherwise be
      ;; reused by `tabularium-view'.
      (when-let ((buf (get-buffer (format "*%s*" name))))
        (kill-buffer buf))
      ;; Clear the registry's `+' open indicator if it is on screen.
      (tabularium-registry--refresh-if-visible)
      (message "Closed database: %s" name))))

;;;###autoload
(defun tabularium-open (name)
  "Open database NAME, loading its schema file if present."
  (interactive
   (list (completing-read "Open database: "
                          (tabularium-registry--completion-table)
                          nil nil nil nil tabularium--current-schema-name)))
  (tabularium-registry--ensure-loaded)
  ;; Find the entry
  (let ((entry (tabularium-registry--find-entry name)))
    (unless entry
      ;; Maybe it is a schema name in tabularium-schemas
      (when-let ((schema (assoc name tabularium-schemas)))
        (setq entry (list :name name
                          :file (plist-get (cdr schema) :file)))))
    (unless entry
      (user-error "Database '%s' not found.  Use `tabularium-create-database' to create one" name))
    (let* ((db-file (plist-get entry :file))
           (schema-name (tabularium-registry--ensure-schema-loaded db-file)))
      (unless schema-name
        (user-error "No schema found for %s.  Create one with `tabularium-create-database'" db-file))
      ;; Ask before closing existing connection if switching
      (when (and tabularium--current-schema-name
                 (not (equal schema-name tabularium--current-schema-name)))
        (unless (yes-or-no-p (format "Close '%s' and open '%s'? "
                                     tabularium--current-schema-name schema-name))
          (user-error "Canceled"))
        (tabularium-close))
      ;; Open the database
      (setq tabularium--current-schema-name schema-name)
      (tabularium--ensure-db)
      ;; Update registry
      (when tabularium-registry-auto-register-on-open
        (tabularium-registry--add
         (list :name schema-name
               :file db-file
               :schema-file (tabularium-registry--schema-file-for-db db-file)
               :last-used (float-time))))
      (message "Opened: %s (%s)" schema-name (abbreviate-file-name db-file))
      ;; Re-render the registry (if open) so the just-opened entry is
      ;; bumped to the top and selected before the user returns to it.
      (tabularium-registry--refresh-to-db schema-name))))

;;;###autoload
(defun tabularium-schema-switch ()
  "Switch to a different database/schema."
  (interactive)
  (let ((name (completing-read "Switch to schema: "
                               (tabularium-registry--completion-table)
                               nil t)))
    (tabularium-open name)))

;;; ** 3.9 Database Creation Wizard

(defvar tabularium-wizard--field-types
  '(("text"     . text)
    ("integer"  . integer)
    ("number"   . number)
    ("date"     . date)
    ("time"     . time)
    ("datetime" . datetime)
    ("choice"   . choice)
    ("boolean"  . boolean))
  "Alist of field type names to symbols.
Each entry is shown in the wizard's type prompt.")

(defvar tabularium-wizard--completion-types
  '(("none"       . nil)
    ("historical" . historical)
    ("recent"     . recent)
    ("vocabulary" . vocabulary)
    ("related"    . related))
  "Alist of completion-source names exposed by the wizard.
Advanced sources (filtered, function, union) are not included
because they require additional configuration best done by
editing the schema file directly.")

(defun tabularium-wizard--slugify (s)
  "Convert string S into a lowercase Lisp-symbol-safe slug.
Replaces non-alphanumeric characters with underscores, collapses
runs, and strips leading/trailing underscores.  Returns a string."
  (let* ((trimmed (string-trim s))
         (lowered (downcase trimmed))
         (replaced (replace-regexp-in-string "[^a-z0-9]+" "_" lowered))
         (stripped (replace-regexp-in-string "\\`_\\|_\\'" "" replaced)))
    stripped))

(defun tabularium-wizard--filename-slug (s)
  "Convert string S into a filename-safe slug.
Like `tabularium-wizard--slugify' but uses hyphens instead of
underscores, matching common filename conventions."
  (let* ((trimmed (string-trim s))
         (lowered (downcase trimmed))
         (replaced (replace-regexp-in-string "[^a-z0-9]+" "-" lowered))
         (stripped (replace-regexp-in-string "\\`-\\|-\\'" "" replaced)))
    stripped))

(defun tabularium-wizard--titlecase (s)
  "Convert underscored slug S to a Title Case prompt string.
e.g. \"first_name\" → \"First Name\"."
  (let ((words (split-string (replace-regexp-in-string "_" " " s) " +" t)))
    (mapconcat #'capitalize words " ")))

(defun tabularium-wizard--breadcrumb (field-index segments active-attr
                                                  &optional hint)
  "Build a breadcrumb prefix ending with the CURRENT prompt attribute.
FIELD-INDEX is the 1-based ordinal.

SEGMENTS is a list of already-known attribute values in display
order (the field name, then the display label, then a type
symbol).  String segments are shown in double quotes; symbols are
rendered with `prin1-to-string'.  Empty or nil segments are
skipped.

ACTIVE-ATTR is the symbol or string for the attribute being
prompted (e.g. \\='label, \\='type, \\='completion).  Rendered in
UPPERCASE as the final segment of the breadcrumb.

HINT, when non-nil, is a short hint string shown in square
brackets after ACTIVE-ATTR — e.g. \"empty to finish\" or a default
value.  No brackets are added if HINT is nil.

For yes/no questions, use `tabularium-wizard--breadcrumb-ask'
instead, which uses Title-Case + a question mark.

Example outputs:
  FIELD #1 > LABEL [empty to finish]:
  FIELD #1 > \"Patient Name\" > ID [patient_name]:
  FIELD #1 > \"Patient Name\" > \"patient_name\" > TYPE:
  FIELD #1 > \"Color\" > \"color\" > choice > CHOICE #1 [empty to finish]:"
  (let* ((head (format "FIELD #%d" field-index))
         (rendered-segments
          (mapcar (lambda (s)
                    (cond
                     ((null s) nil)
                     ((and (stringp s) (string-empty-p s)) nil)
                     ((stringp s) (format "\"%s\"" s))
                     (t (prin1-to-string s))))
                  segments))
         (parts (cons head (delq nil rendered-segments)))
         (path (mapconcat #'identity parts " > "))
         (attr-str (upcase (if (symbolp active-attr)
                               (symbol-name active-attr)
                             active-attr))))
    (if hint
        (format "%s > %s [%s]: " path attr-str hint)
      (format "%s > %s: " path attr-str))))

(defun tabularium-wizard--breadcrumb-ask (field-index segments question)
  "Build a breadcrumb prefix for a yes/no QUESTION.
FIELD-INDEX and SEGMENTS are as in `tabularium-wizard--breadcrumb'.

QUESTION is a short Title-Case phrase ending with `?'.  It is
rendered verbatim as the final breadcrumb segment.

No `[y/n]' hint is appended because `y-or-n-p' already adds its own
`(y or n)' suffix.

Example output:
  FIELD #1 > \"...\" > \"...\" > text > Long-form?
  FIELD #1 > \"...\" > \"...\" > date > Default to today?"
  (let* ((head (format "FIELD #%d" field-index))
         (rendered-segments
          (mapcar (lambda (s)
                    (cond
                     ((null s) nil)
                     ((and (stringp s) (string-empty-p s)) nil)
                     ((stringp s) (format "\"%s\"" s))
                     (t (prin1-to-string s))))
                  segments))
         (parts (cons head (delq nil rendered-segments)))
         (path (mapconcat #'identity parts " > ")))
    (format "%s > %s " path question)))

(defun tabularium-wizard--read-validated (prompt type &optional initial allow-empty)
  "Read a string for PROMPT, looping until input is valid for TYPE.
TYPE is passed to `tabularium--validate-field-value'.  INITIAL, when
given, pre-fills the minibuffer (used by edit-mode prompts).  When
ALLOW-EMPTY is non-nil an empty entry returns nil; otherwise empty
input is rejected (the create wizard reaches this prompt only after
the user opts in to a default).  Returns the validated string, or nil
for an accepted empty entry."
  (let ((result nil)
        (current-initial initial)
        (done nil))
    (while (not done)
      (let* ((input (read-string prompt current-initial))
             (trimmed (string-trim input))
             (err (cond
                   ((string-empty-p trimmed)
                    (unless allow-empty
                      "Value cannot be empty.  Please enter a value"))
                   (t (tabularium--validate-field-value trimmed type)))))
        (cond
         ((and (string-empty-p trimmed) allow-empty)
          (setq result nil done t))
         (err
          (message "%s" err)
          (sit-for 1.0)
          (setq current-initial trimmed))
         (t
          (setq result trimmed done t)))))
    result))

(defun tabularium-wizard--read-field-edit-default (type choices boolean-pair current bc ask)
  "Read a default value in edit mode for a field of TYPE.
CHOICES and BOOLEAN-PAIR are the field's choice list / boolean pair (if
any); CURRENT is the field's existing default; BC and ASK are the
breadcrumb-prompt closures from `tabularium-wizard--read-field'.  The
current default pre-fills the prompt and an empty entry removes it.
Returns the new default (string, number, or symbol) or nil."
  (pcase type
    ((or 'date 'time 'datetime)
     (let ((now-word (if (eq type 'date) "today" "now")))
       (if (y-or-n-p (funcall ask (format "Default to %s?" now-word)))
           (if (eq type 'date) 'today 'now)
         (let* ((fmt (pcase type
                       ('date "YYYY-MM-DD")
                       ('time "HH:MM[:SS]")
                       ('datetime "YYYY-MM-DD HH:MM[:SS]")))
                (v (tabularium-wizard--read-validated
                    (funcall bc 'default (concat fmt ", empty for none"))
                    type (and (stringp current) current) t)))
           (if (or (null v) (string-empty-p v)) nil v)))))
    ('choice
     (let ((v (completing-read
               (funcall bc 'default "empty for none")
               (cons "" choices) nil t nil nil
               (if current (format "%s" current) ""))))
       (if (string-empty-p v) nil v)))
    ('boolean
     (let ((v (completing-read
               (funcall bc 'default "empty for none")
               (cons "" (or boolean-pair tabularium--boolean-pair-anchors))
               nil t nil nil
               (if current (format "%s" current) ""))))
       (if (string-empty-p v) nil v)))
    ('integer
     (let ((v (tabularium-wizard--read-validated
               (funcall bc 'default "empty for none") 'integer
               (and current (format "%s" current)) t)))
       (and v (not (string-empty-p v)) (string-to-number v))))
    ('number
     (let ((v (tabularium-wizard--read-validated
               (funcall bc 'default "empty for none") 'number
               (and current (format "%s" current)) t)))
       (and v (not (string-empty-p v)) (string-to-number v))))
    (_
     (let ((v (read-string (funcall bc 'default "empty for none")
                           (and current (format "%s" current)))))
       (if (string-empty-p v) nil v)))))

(defun tabularium-wizard--read-field (field-index existing-fields &optional existing-field)
  "Interactively read a single field definition.
FIELD-INDEX is the 1-based ordinal shown in the prompt.
EXISTING-FIELDS is the list of fields already defined; used for
the `related' completion source which needs to pick a sibling
field.

EXISTING-FIELD, when non-nil, is the field plist being edited: every
prompt then pre-fills with that field's current value, the label may be
kept by pressing RET, and the default and width prompts are asked
directly (rather than behind a yes/no gate) with an empty entry meaning
\"no default\" / \"auto width\".

The prompt sequence is label -> id -> type -> type specifics -> required
-> default -> width -> computed -> long.  Asking for the label first
lets the wizard suggest a sluggified ID as a default, so the user can
just press RET to accept it.

Returns a field plist, or nil when an empty label is entered to finish
the field-definition phase (create mode only)."
  (let* ((ex existing-field)
         (ex-label (and ex (or (plist-get ex :label)
                               (symbol-name (plist-get ex :id)))))
         (ex-type (and ex (plist-get ex :type)))
         (ex-choices (and ex (plist-get ex :choice)))
         (ex-boolean-pair (and ex (plist-get ex :boolean-pair)))
         (ex-complete (and ex (plist-get ex :complete)))
         (ex-required (and ex (plist-get ex :required)))
         (ex-default (and ex (plist-get ex :default)))
         (ex-width (and ex (plist-get ex :width)))
         (ex-long (and ex (plist-get ex :long)))
         (ex-computed (and ex (plist-get ex :_computed-placeholder)))
         (label (tabularium-wizard--read-field-label field-index ex-label))
         field)
    (unless (string-empty-p label)
      (let* ((suggested-id (if ex
                               (symbol-name (plist-get ex :id))
                             (let ((s (tabularium-wizard--slugify label)))
                               (if (string-empty-p s) "field" s))))
             (id-slug (tabularium-wizard--read-field-id field-index label
                                                        suggested-id))
             (type-name (completing-read
                         (tabularium-wizard--breadcrumb
                          field-index (list label id-slug) 'type)
                         tabularium-wizard--field-types nil t nil nil
                         (if ex
                             (or (car (rassq ex-type
                                             tabularium-wizard--field-types))
                                 "text")
                           "text")))
             (type (alist-get type-name tabularium-wizard--field-types
                              nil nil #'equal))
             ;; All later prompts share the same path of (label id type)
             (segs (list label id-slug type))
             (bc (lambda (attr &optional hint)
                   (tabularium-wizard--breadcrumb field-index segs attr hint)))
             (ask (lambda (question)
                    (tabularium-wizard--breadcrumb-ask
                     field-index segs question)))
             (choices nil)
             (boolean-pair nil)
             (completion nil)
             (vocabulary-file nil)
             (related-field nil)
             (default nil)
             (width nil)
             (long nil)
             (required nil)
             (computed-placeholder nil))
        ;; For choice type, gather the candidate list (pre-filled in edit
        ;; mode when the field is still a choice).
        (when (eq type 'choice)
          (setq choices (tabularium-wizard--read-choices
                         segs field-index (and ex ex-choices))))
        ;; For boolean type, pick the canonical pair upfront so the column
        ;; is locked to one style (Yes/No, True/False, 1/0, ...).
        (when (eq type 'boolean)
          (let* ((pair-labels (mapcar (lambda (p)
                                        (format "%s / %s" (car p) (cadr p)))
                                      tabularium--boolean-pairs))
                 (picked (completing-read
                          (funcall bc 'boolean-pair)
                          pair-labels nil t nil nil
                          (if (and ex ex-boolean-pair)
                              (format "%s / %s"
                                      (car ex-boolean-pair)
                                      (cadr ex-boolean-pair))
                            (car pair-labels)))))
            (setq boolean-pair
                  (nth (cl-position picked pair-labels :test #'equal)
                       tabularium--boolean-pairs))))
        ;; Completion options apply to text type only
        (when (eq type 'text)
          (let* ((comp-default
                  (if ex
                      (cond
                       ((null ex-complete) "none")
                       ((symbolp ex-complete)
                        (or (car (rassq ex-complete
                                        tabularium-wizard--completion-types))
                            "none"))
                       ((consp ex-complete)
                        (or (car (rassq (plist-get ex-complete :type)
                                        tabularium-wizard--completion-types))
                            "none"))
                       (t "none"))
                    "none"))
                 (comp-name (completing-read
                             (funcall bc 'completion)
                             tabularium-wizard--completion-types nil t nil nil
                             comp-default))
                 (comp-sym (alist-get comp-name
                                      tabularium-wizard--completion-types
                                      nil nil #'equal)))
            (setq completion comp-sym)
            (pcase completion
              ('vocabulary
               (setq vocabulary-file
                     (read-file-name (funcall bc 'vocabulary-file) nil
                                     (and (consp ex-complete)
                                          (plist-get ex-complete :source)))))
              ('related
               (let ((sibling-names
                      (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                              existing-fields)))
                 (if sibling-names
                     (setq related-field
                           (intern
                            (completing-read
                             (funcall bc 'related-field)
                             sibling-names nil t nil nil
                             (and (consp ex-complete)
                                  (symbolp (plist-get ex-complete :field))
                                  (symbol-name
                                   (plist-get ex-complete :field))))))
                   (message
                    "No previously-defined fields to relate to; reverting to none.")
                   (sit-for 1.5)
                   (setq completion nil)))))))
        ;; Required
        (setq required
              (if ex
                  (y-or-n-p (funcall ask (format "Required? (now %s)"
                                                 (if ex-required "yes" "no"))))
                (y-or-n-p (funcall ask "Required?"))))
        ;; Default value.  Create mode gates behind a yes/no; edit mode asks
        ;; directly, pre-filling the current default (empty removes it).
        (if ex
            (setq default (tabularium-wizard--read-field-edit-default
                           type choices boolean-pair ex-default bc ask))
          (when (y-or-n-p (funcall ask "Default value?"))
            (setq default
                  (pcase type
                    ('date (if (y-or-n-p (funcall ask "Default to today?"))
                               'today
                             (tabularium-wizard--read-validated
                              (funcall bc 'date-format "YYYY-MM-DD")
                              'date)))
                    ('time (if (y-or-n-p (funcall ask "Default to now?"))
                               'now
                             (tabularium-wizard--read-validated
                              (funcall bc 'time-format "HH:MM[:SS]")
                              'time)))
                    ('datetime (if (y-or-n-p (funcall ask "Default to now?"))
                                   'now
                                 (tabularium-wizard--read-validated
                                  (funcall bc 'datetime-format
                                           "YYYY-MM-DD HH:MM[:SS]")
                                  'datetime)))
                    ('choice (completing-read (funcall bc 'default) choices nil t))
                    ('integer (string-to-number
                               (tabularium-wizard--read-validated
                                (funcall bc 'default) 'integer)))
                    ('number (string-to-number
                              (tabularium-wizard--read-validated
                               (funcall bc 'default) 'number)))
                    ('boolean (completing-read
                               (funcall bc 'default)
                               (or boolean-pair
                                   tabularium--boolean-pair-anchors)
                               nil t))
                    (_ (read-string (funcall bc 'default)))))))
        ;; Optional column width
        (if ex
            (let ((w (tabularium-wizard--read-validated
                      (funcall bc 'width "empty for auto") 'integer
                      (and ex-width (number-to-string ex-width)) t)))
              (setq width (and w (string-to-number w))))
          (when (y-or-n-p (funcall ask "Set width?"))
            (setq width (string-to-number
                         (tabularium-wizard--read-validated
                          (funcall bc 'width) 'integer)))))
        ;; Optional :computed placeholder for later schema-file editing
        (setq computed-placeholder
              (if ex
                  (y-or-n-p (funcall ask (format "Computed? (now %s)"
                                                 (if ex-computed "yes" "no"))))
                (y-or-n-p (funcall ask "Computed?"))))
        ;; Long-form editing buffer (text type only)
        (when (eq type 'text)
          (setq long
                (if ex
                    (y-or-n-p (funcall ask (format "Long-form? (now %s)"
                                                   (if ex-long "yes" "no"))))
                  (y-or-n-p (funcall ask "Long-form?")))))
        ;; Build field plist now that every value is gathered
        (setq field (list :id (intern id-slug)
                          :label label
                          :type type))
        (when choices
          (setq field (plist-put field :choice choices)))
        (when boolean-pair
          (setq field (plist-put field :boolean-pair boolean-pair)))
        ;; Completion: simple symbols stored bare, complex sources as plists
        (cond
         ((memq completion '(historical recent))
          (setq field (plist-put field :complete completion)))
         ((and (eq completion 'vocabulary) vocabulary-file)
          (setq field (plist-put field :complete
                                 (list :type 'vocabulary
                                       :source vocabulary-file))))
         ((and (eq completion 'related) related-field)
          (setq field (plist-put field :complete
                                 (list :type 'related
                                       :field related-field)))))
        (when required
          (setq field (plist-put field :required t)))
        (when default
          (setq field (plist-put field :default default)))
        (when width
          (setq field (plist-put field :width width)))
        (when long
          (setq field (plist-put field :long t)))
        (when computed-placeholder
          (setq field (plist-put field :_computed-placeholder t)))))
    field))

(defun tabularium-wizard--read-field-label (field-index &optional default)
  "Read the display label for the field at FIELD-INDEX.
With no DEFAULT, empty input ends the field-definition loop.  When
DEFAULT is given (edit mode) it pre-fills the prompt and is returned on
empty input, so the loop is not ended.  Return the label string."
  (read-string (tabularium-wizard--breadcrumb
                field-index nil 'label
                (if default "empty to keep" "empty to finish"))
               nil nil default))

(defun tabularium-wizard--read-field-id (field-index label suggested)
  "Read a field's ID (code identifier).
FIELD-INDEX is the ordinal; LABEL is the already-entered display
label (shown in the breadcrumb); SUGGESTED is a sluggified
default offered in square brackets and used when the user just
hits RET.

Loops until the input is a valid Lisp symbol or the user accepts
the suggested slug.  Returns the chosen ID string."
  (let ((result nil))
    (while (null result)
      (let* ((raw (read-string
                   (tabularium-wizard--breadcrumb
                    field-index (list label) 'id suggested)
                   nil nil suggested))
             (trimmed (string-trim raw)))
        (cond
         ;; Empty (defensive — read-string with DEFAULT-VALUE returns it for RET)
         ;; Accept the suggested slug if we somehow get an empty string.
         ((string-empty-p trimmed)
          (setq result suggested))
         ;; Already a valid symbol
         ((string-match-p "\\`[a-z][a-z0-9_]*\\'" trimmed)
          (setq result trimmed))
         ;; Needs sluggification; offer either to accept or re-enter
         (t
          (let ((slug (tabularium-wizard--slugify trimmed)))
            (cond
             ((string-empty-p slug)
              (message "'%s' has no usable characters; please re-enter." trimmed)
              (sit-for 1.5))
             ((y-or-n-p (format "'%s' is not a valid identifier; use '%s'? "
                                trimmed slug))
              (setq result slug))
             (t nil)))))))
    result))

(defun tabularium-wizard--read-choices (segments field-index &optional defaults)
  "Read a list of choices.
SEGMENTS is the breadcrumb segment list inherited from the parent
field prompt; FIELD-INDEX is the same field's ordinal.  Each prompt is
rendered as e.g.
  FIELD #1 > \"color\" > \"Color\" > choice > CHOICE #1 [empty to finish]:
One choice per prompt; commas are kept verbatim.  An empty entry ends
the list.  DEFAULTS, when given (edit mode), pre-fills successive
prompts with the current choices so they can be kept or changed."
  (let ((choices '())
        (choice nil)
        (n 1))
    (while (not (string-empty-p
                 (setq choice (string-trim
                               (read-string
                                (tabularium-wizard--breadcrumb
                                 field-index segments
                                 (format "choice #%d" n)
                                 "empty to finish")
                                nil nil (nth (1- n) defaults))))))
      (push choice choices)
      (setq n (1+ n)))
    (nreverse choices)))

(defun tabularium-wizard--read-fields ()
  "Read multiple field definitions.
Returns list of field plists."
  (let ((fields '())
        (field nil)
        (has-primary nil)
        (idx 1))
    ;; Suggest adding a row-ID field first
    (when (y-or-n-p "Add an auto-increment row-ID field first (recommended)? ")
      (push '(:id row_id :label "ID" :type integer :primary t :width 5) fields)
      (setq has-primary t))
    ;; Read remaining fields, passing existing fields for `related' lookup
    (while (setq field (tabularium-wizard--read-field idx (reverse fields)))
      (when (and (plist-get field :primary) has-primary)
        (message "A primary key is already defined; ignoring :primary on this field.")
        (setq field (plist-put field :primary nil)))
      (when (plist-get field :primary)
        (setq has-primary t))
      (push field fields)
      (setq idx (1+ idx)))
    (nreverse fields)))

(defun tabularium-wizard--format-field (field)
  "Format a single FIELD plist as a string suitable for the schema file.
If FIELD contains :_computed-placeholder, append a commented-out
:computed example line on a new indented line so the user can
fill it in later."
  (let ((items '())
        (placeholder (plist-get field :_computed-placeholder)))
    (push (format ":id %s" (plist-get field :id)) items)
    (push (format ":label \"%s\"" (plist-get field :label)) items)
    (push (format ":type %s" (plist-get field :type)) items)
    (when (plist-get field :primary)
      (push ":primary t" items))
    (when (plist-get field :required)
      (push ":required t" items))
    (when (plist-get field :width)
      (push (format ":width %d" (plist-get field :width)) items))
    (when (plist-get field :long)
      (push ":long t" items))
    (when (plist-get field :complete)
      ;; `:complete' may be a bare symbol (historical, recent) or a plist
      ;; (vocabulary, related, …).  Either form prints correctly via %S.
      (push (format ":complete %S" (plist-get field :complete)) items))
    (when (plist-get field :choice)
      (push (format ":choice %S" (plist-get field :choice)) items))
    (when (plist-get field :boolean-pair)
      (push (format ":boolean-pair %S" (plist-get field :boolean-pair)) items))
    (when (plist-get field :pattern)
      (push (format ":pattern %S" (plist-get field :pattern)) items))
    (when (plist-get field :pattern-help)
      (push (format ":pattern-help %S" (plist-get field :pattern-help)) items))
    (when (plist-get field :validate)
      (push (format ":validate %S" (plist-get field :validate)) items))
    (when (plist-get field :default)
      (let ((def (plist-get field :default)))
        (push (format ":default %s"
                      (if (or (symbolp def) (numberp def))
                          def
                        (format "\"%s\"" def)))
              items)))
    (if placeholder
        ;; Multi-line form with commented-out :computed inside the parens
        (concat "(" (string-join (nreverse items) " ") "\n"
                "      ;; :computed (lambda (row) ...)\n"
                "      )")
      (concat "(" (string-join (nreverse items) " ") ")"))))

(defun tabularium-wizard--format-schema-property (key value)
  "Format a single KEY/VALUE pair for inclusion in a schema definition.
Returns a string of the form `  :KEY VALUE\\n', pretty-printed
when VALUE is a list, with sensible indentation for readability.
Used by `tabularium-wizard--generate-schema-file' when carrying
schema-level properties forward from an existing schema.

Values that are not self-evaluating — non-nil lists and non-keyword
symbols such as `asc' — are quoted, so the emitted schema file
reads them as literal data rather than evaluating them (an
unquoted `asc' would signal a void-variable error on load)."
  (let* ((needs-quote (or (and (consp value))
                          (and (symbolp value)
                               value
                               (not (eq value t))
                               (not (keywordp value)))))
         (printed (if (and (listp value) value)
                      ;; Pretty-print lists; pp adds its own trailing newline
                      (let ((pp-escape-newlines nil))
                        (string-trim (pp-to-string value)))
                    (prin1-to-string value)))
         (value-str (if needs-quote (concat "'" printed) printed)))
    (format "  %s %s\n" key value-str)))

(defun tabularium-wizard--generate-schema-file (name db-file fields
                                                     &optional feature-name
                                                     extra-properties)
  "Generate contents for a schema file.
NAME is the schema display name, DB-FILE is the database path,
FIELDS is the list of field definitions, FEATURE-NAME is the
feature to provide (defaults to NAME-slug-schema), and
EXTRA-PROPERTIES is an optional plist of additional schema-level
properties to include (e.g. `:default-sort', `:views',
`:highlight', `:quick-entry-fields', `:backend',
`:connection').  EXTRA-PROPERTIES are emitted after `:fields' in
the order they appear in the plist."
  (let* ((slug (let ((s (tabularium-wizard--filename-slug name)))
                 (if (string-empty-p s) "database" s)))
         (feature (or feature-name (intern (concat slug "-schema")))))
    (with-temp-buffer
      (insert (format ";;; %s.el --- Schema for %s -*- lexical-binding: t; -*-\n\n"
                      feature name))
      (insert ";;; Commentary:\n\n")
      (insert (format ";; Schema definition for the %s database.\n" name))
      (insert (format ";; Database file: %s\n" (abbreviate-file-name db-file)))
      (insert ";;\n")
      (insert ";; This file is automatically loaded when the database is opened.\n")
      (insert ";; Add custom functions below the schema definition.\n\n")
      (insert ";;; Code:\n\n")
      (insert "(require 'tabularium)\n\n")
      ;; Schema definition
      (insert ";;; Schema Definition\n\n")
      (insert (format "(tabularium-define-schema \"%s\"\n" name))
      (insert (format "  :file \"%s\"\n" (abbreviate-file-name db-file)))
      (insert "  :fields\n")
      (insert "  '(")
      (let ((first t))
        (dolist (field fields)
          (if first
              (setq first nil)
            (insert "\n    "))
          (insert (tabularium-wizard--format-field field))))
      (insert ")")
      ;; Extra schema-level properties carried over from a source schema
      (when extra-properties
        (let ((tail extra-properties))
          (while tail
            (let ((key (car tail))
                  (value (cadr tail)))
              (insert "\n")
              (insert (tabularium-wizard--format-schema-property key value)))
            (setq tail (cddr tail)))))
      (insert ")\n\n")
      ;; Custom functions section
      (insert ";;; Custom Functions\n\n")
      (insert ";; Add database-specific functions here.\n")
      (insert ";; Examples:\n")
      (insert ";;\n")
      (insert (format ";;   (defun %s-count-by-field (field value)\n" slug))
      (insert ";;     \"Count records where FIELD equals VALUE.\"\n")
      (insert ";;     (interactive ...)\n")
      (insert ";;     ...)\n")
      (insert ";;\n")
      (insert (format ";;   (defhydra %s-hydra (:color blue :hint nil)\n" slug))
      (insert ";;     \"Custom hydra for this database.\"\n")
      (insert ";;     ...)\n\n")
      ;; Provide
      (insert (format "(provide '%s)\n\n" feature))
      (insert (format ";;; %s.el ends here\n" feature))
      (buffer-string))))

(defun tabularium-wizard--finalize (name db-file fields &optional extra-properties)
  "Write schema, register, and open a wizard-built database.
NAME, DB-FILE, and FIELDS come from any of the wizard entry points
\(regular, quick, header-row, from-schema-file).  Writes the
schema file, loads it, adds the registry entry, opens the
database (which creates the .db file via the table-create path),
and offers to open the schema file for further editing.
EXTRA-PROPERTIES is an optional plist of schema-level properties
to carry over (used by `tabularium-create-database-from-schema-file'
to preserve views, highlight rules, etc. from the source
schema).  Common tail for all of the `tabularium-create-database-*'
commands."
  (when (null fields)
    (user-error "Cannot create database with no fields"))
  (let* ((db-file (expand-file-name db-file))
         (schema-file (tabularium-registry--schema-file-for-db db-file))
         (dir (file-name-directory db-file)))
    ;; Confirm overwrites
    (when (file-exists-p db-file)
      (unless (y-or-n-p (format "Database %s exists.  Overwrite? " db-file))
        (user-error "Aborted")))
    (when (file-exists-p schema-file)
      (unless (y-or-n-p (format "Schema %s exists.  Overwrite? " schema-file))
        (user-error "Aborted")))
    (unless (file-exists-p dir)
      (make-directory dir t))
    ;; Write the schema file
    (let ((schema-content (tabularium-wizard--generate-schema-file
                           name db-file fields nil extra-properties)))
      (with-temp-file schema-file
        (insert schema-content)))
    (message "Created schema file: %s" schema-file)
    ;; Load (signal early if it fails to parse)
    (unless (tabularium-registry--load-schema-file schema-file)
      (user-error
       "Failed to load generated schema %s.  Edit the file to fix it"
       schema-file))
    (tabularium-registry--add
     (list :name name
           :file db-file
           :schema-file schema-file
           :last-used (float-time)))
    (tabularium-open name)
    (tabularium-registry--refresh-if-visible)
    (when (y-or-n-p "Open schema file for editing? ")
      (find-file schema-file))))

;;;###autoload
(defun tabularium-create-database (name db-file)
  "Create a new database NAME at DB-FILE using an interactive wizard.
Walks through field definition, creates the schema and database files,
registers the database, and opens it.

NAME is the display name shown in the registry and form title bars;
it may contain spaces and punctuation.  The database filename and
the schema's Lisp feature name are derived from a sluggified version
of NAME to keep them filesystem- and symbol-safe."
  (interactive
   (let* ((name (read-string "Database display name (e.g. \"New Database\"): "))
          (default-dir (expand-file-name "~/"))
          (slug (tabularium-wizard--filename-slug name))
          (default-base (concat (if (string-empty-p slug) "database" slug) ".db"))
          (db-file (read-file-name "Database file: " default-dir default-base
                                   nil default-base)))
     (list name db-file)))
  (tabularium-wizard--finalize name db-file
                               (tabularium-wizard--read-fields)))

;;; *** 3.9.1 Quick Spec Parser

(defun tabularium-wizard--parse-quick-flag (flag)
  "Classify a single FLAG token from the quick-spec syntax.
Returns one of:
  \(:plist KEY VALUE\) for boolean flags (required, primary, long).
  \(:choice (\"a\" \"b\" \"c\")\) when FLAG contains pipes.
  \(:unknown FLAG\) otherwise."
  (cond
   ((or (string= flag "required") (string= flag "req"))
    (list :plist :required t))
   ((or (string= flag "primary") (string= flag "pk"))
    (list :plist :primary t))
   ((string= flag "long")
    (list :plist :long t))
   ((string-match-p "|" flag)
    (list :choice (split-string flag "|" t "[ \t]+")))
   (t (list :unknown flag))))

(defun tabularium--parse-quick-spec (spec)
  "Parse SPEC, a quick-startup wizard spec string, into a fields list.
Each field token in SPEC is `ID:TYPE[:FLAG[:FLAG...]]', tokens are
separated by whitespace.  Types are any of `text', `integer',
`number', `date', `time', `choice', `boolean'.  Flags may be any
of: `required'/`req', `primary'/`pk', `long', or a pipe-separated
list of choices for `choice' fields (e.g. `Open|Closed|Pending').

If no field declares `:primary' the standard
`row_id:integer:primary' field is automatically prepended.
Multiple `:primary' declarations are reduced to the first, with a
warning."
  (let* ((tokens (split-string spec nil t))
         (valid-types (mapcar #'cdr tabularium-wizard--field-types))
         (fields '())
         (has-primary nil))
    (dolist (tok tokens)
      (let* ((parts (split-string tok ":"))
             (id-str (car parts))
             (type-str (cadr parts))
             (flag-strs (cddr parts)))
        (when (string-empty-p id-str)
          (user-error "Quick spec: empty field id in token '%s'" tok))
        (unless type-str
          (user-error "Quick spec: missing type for field '%s'" id-str))
        (let* ((id-slug (tabularium-wizard--slugify id-str))
               (id (intern (if (string-empty-p id-slug) id-str id-slug)))
               (type (intern type-str))
               (label (tabularium-wizard--titlecase id-slug))
               (plist (list :id id :label label :type type)))
          (unless (memq type valid-types)
            (user-error "Quick spec: unknown type '%s' for field '%s'"
                        type-str id-str))
          (dolist (flag flag-strs)
            (pcase (tabularium-wizard--parse-quick-flag flag)
              (`(:plist ,key ,val)
               (when (and (eq key :primary) has-primary)
                 (message
                  "Quick spec: ignoring extra :primary on '%s' (already set)"
                  id)
                 (setq val nil))
               (when val
                 (setq plist (plist-put plist key val))
                 (when (eq key :primary) (setq has-primary t))))
              (`(:choice ,choices)
               (setq plist (plist-put plist :choice choices)))
              (`(:unknown ,f)
               (message "Quick spec: ignoring unknown flag '%s' on '%s'"
                        f id))))
          ;; Boolean fields need a canonical pair
          (when (eq type 'boolean)
            (setq plist (plist-put plist :boolean-pair
                                   (car tabularium--boolean-pairs))))
          (push plist fields))))
    (setq fields (nreverse fields))
    ;; Auto-prepend a row-ID field if no primary specified
    (unless has-primary
      (push '(:id row_id :label "ID" :type integer :primary t :width 5) fields))
    fields))

;;;###autoload
(defun tabularium-create-database-quick (name db-file spec)
  "Create a new database NAME at DB-FILE from a one-line SPEC string.
SPEC is a compact field specification of the form
`ID:TYPE[:FLAG[:FLAG...]] ID:TYPE...'.

Example:
  row_id:integer:primary date:date status:choice:Open|Closed amount:number

Flags: `required'/`req', `primary'/`pk', `long', or a pipe-separated
list of choices for `choice' fields.  Types: text, integer, number,
date, time, choice, boolean.  Labels default to the title-cased ID;
if no `:primary' is declared, the standard `row_id' integer primary
key is prepended automatically.

For an interactive walkthrough of every field property, use
`tabularium-create-database' instead."
  (interactive
   (let* ((name (read-string "Database display name (e.g. \"Quick DB\"): "))
          (default-dir (expand-file-name "~/"))
          (slug (tabularium-wizard--filename-slug name))
          (default-base (concat (if (string-empty-p slug) "database" slug)
                                ".db"))
          (db-file (read-file-name "Database file: " default-dir default-base
                                   nil default-base))
          (spec (read-string
                 "Spec (e.g. `date:date amount:number notes:text:long'): ")))
     (list name db-file spec)))
  (tabularium-wizard--finalize name db-file
                               (tabularium--parse-quick-spec spec)))

;;; *** 3.9.2 Header-Row Parser

(defun tabularium--parse-header-row (line)
  "Parse a single header LINE into a list of text fields.
Auto-detects the separator: tab > pipe > comma.  Each column name
is preserved verbatim as the label and sluggified into the field
id; the standard `row_id:integer:primary' field is prepended."
  (let* ((trimmed (string-trim line))
         (sep (cond ((string-match-p "\t" trimmed) "\t")
                    ((string-match-p "|" trimmed) "|")
                    ((string-match-p "," trimmed) ",")
                    (t nil)))
         (cols (if sep
                   (mapcar #'string-trim (split-string trimmed sep))
                 (list trimmed))))
    (when (or (null cols) (and (= (length cols) 1)
                               (string-empty-p (car cols))))
      (user-error "Header parser: no columns found in '%s'" line))
    (let ((fields '())
          (seen-ids (make-hash-table :test 'equal))
          (idx 1))
      (dolist (col cols)
        (let* ((slug (tabularium-wizard--slugify col))
               (base (if (string-empty-p slug) (format "field%d" idx) slug))
               ;; Disambiguate duplicates by appending a counter
               (id-str (if (gethash base seen-ids)
                           (let ((n 2))
                             (while (gethash (format "%s_%d" base n) seen-ids)
                               (cl-incf n))
                             (format "%s_%d" base n))
                         base)))
          (puthash id-str t seen-ids)
          (push (list :id (intern id-str)
                      :label (if (string-empty-p col) (format "Field %d" idx) col)
                      :type 'text)
                fields))
        (cl-incf idx))
      (cons '(:id row_id :label "ID" :type integer :primary t :width 5)
            (nreverse fields)))))

;;;###autoload
(defun tabularium-create-database-from-header (name db-file header)
  "Create a new database NAME at DB-FILE from a pasted HEADER row.
HEADER is a single line of column names separated by tabs, pipes,
or commas (auto-detected, in that priority order).  Every column
becomes a `:type text' field; the standard `row_id' integer
primary key is prepended automatically.  Refine field types
afterwards either by editing the schema file or by accepting the
prompt that appears on success.

This command is the fastest way to bootstrap a database from a
copied spreadsheet header; use `tabularium-import' if you want to
import the data rows along with the header."
  (interactive
   (let* ((name (read-string "Database display name: "))
          (default-dir (expand-file-name "~/"))
          (slug (tabularium-wizard--filename-slug name))
          (default-base (concat (if (string-empty-p slug) "database" slug)
                                ".db"))
          (db-file (read-file-name "Database file: " default-dir default-base
                                   nil default-base))
          (header (read-string "Header row (tab/pipe/comma separated): ")))
     (list name db-file header)))
  (tabularium-wizard--finalize name db-file
                               (tabularium--parse-header-row header)))

;;; *** 3.9.3 Existing Schema File

;;;###autoload
(defun tabularium-create-database-from-schema-file (source-schema-file name db-file)
  "Create a new database NAME at DB-FILE using SOURCE-SCHEMA-FILE as a template.
Reads the schema definition from SOURCE-SCHEMA-FILE and writes a
new schema file that mirrors it — same field definitions, same
saved views, same highlight rules, same default sort, same
backend choice — but with the new NAME and `:file' pointing at
DB-FILE.  The new database itself is empty; only the schema is
carried over.

Use this as a \"save as\" for schemas: keep the structure of an
existing database while starting fresh with no rows.  Schema-level
properties carried over: `:fields', `:default-sort', `:views',
`:highlight', `:quick-entry-fields', `:backend',
`:connection'.  Not carried over: `:file' (replaced) and
`:export-file' (would clash with the source's exports)."
  (interactive
   (let* ((source (read-file-name
                   "Source schema file: "
                   (expand-file-name "~/") nil t nil
                   (lambda (f)
                     (or (file-directory-p f)
                         (string-suffix-p tabularium-schema-file-suffix f)))))
          (name (read-string "New database display name: "))
          (default-dir (expand-file-name "~/"))
          (slug (tabularium-wizard--filename-slug name))
          (default-base (concat (if (string-empty-p slug) "database" slug)
                                ".db"))
          (db-file (read-file-name "New database file: "
                                   default-dir default-base
                                   nil default-base)))
     (list source name db-file)))
  (let ((source-schema-file (expand-file-name source-schema-file)))
    (unless (file-exists-p source-schema-file)
      (user-error "Source schema file not found: %s" source-schema-file))
    ;; Load the source schema into memory so we can read its properties.
    ;; It stays loaded after this command returns — harmless, since its
    ;; :file path is unchanged and any later `tabularium-open' on the
    ;; source name still resolves correctly.
    (let ((source-name (tabularium-registry--load-schema-file
                        source-schema-file)))
      (unless source-name
        (user-error "Failed to load source schema file %s" source-schema-file))
      (when (equal source-name name)
        (user-error
         "New name must differ from the source schema's name (%s)"
         source-name))
      (let* ((source (tabularium--get-schema source-name))
             (fields (plist-get source :fields))
             (extras (tabularium--schema-carry-over-properties source)))
        (unless fields
          (user-error "Source schema %s has no :fields" source-name))
        (tabularium-wizard--finalize name db-file fields extras)
        (message
         "Created %s from %s (fields, views, and formatting carried over)"
         name (file-name-nondirectory source-schema-file))))))

(defun tabularium--cf-rule-round-trippable-p (rule)
  "Return non-nil if RULE can be safely written to a schema file and re-read.
A rule is round-trippable when its `:test', if present, is either
absent or a literal lambda list (a cons whose car is the symbol
`lambda').  Closures and byte-compiled function objects cannot be
emitted to a `.el' file without breaking the reader, so rules
containing them are filtered out and the user is notified."
  (let ((test (plist-get rule :test)))
    (or (null test)
        (and (consp test) (eq (car test) 'lambda)))))

(defun tabularium--schema-carry-over-properties (source)
  "Extract schema-level properties from SOURCE that should propagate to a copy.
Returns a plist suitable for the EXTRA-PROPERTIES argument of
`tabularium-wizard--finalize'.  `:file' and `:fields' are emitted
by the generator itself and excluded here.  `:export-file' is
excluded because the new database should not write into the
source database's export path.  `:highlight' rules whose `:test'
is a compiled closure (rather than a literal lambda list) cannot
round-trip through the generated schema file and are filtered out
with a message."
  (let ((carry-keys '(:default-sort :views :highlight
                      :quick-entry-fields :backend :connection))
        (result '()))
    (dolist (key (reverse carry-keys))
      (let ((value (plist-get source key)))
        ;; Filter highlight rules that can't round-trip
        (when (eq key :highlight)
          (let* ((safe (cl-remove-if-not
                        #'tabularium--cf-rule-round-trippable-p value))
                 (dropped (- (length value) (length safe))))
            (when (> dropped 0)
              (message
               "Dropped %d highlight rule(s) with non-literal :test (can't round-trip through schema file)"
               dropped))
            (setq value (and safe safe))))
        (when value
          (setq result (cons key (cons value result))))))
    result))

;;; ** 3.10 Sync Safety

;;;###autoload
(defun tabularium-sync-prepare ()
  "Prepare databases for syncing (Syncthing, Dropbox, etc.).
This checkpoints and closes all connections, ensuring a clean state.
Call this before suspending your laptop or when you're done working."
  (interactive)
  (tabularium-db--prepare-for-sync)
  (setq tabularium--current-schema-name nil)
  (setq tabularium--db nil))

;;;###autoload
(defun tabularium-sync-checkpoint ()
  "Checkpoint all databases without closing connections.
This flushes the write-ahead log to the main database file."
  (interactive)
  (tabularium-db--checkpoint-all))

;;;###autoload
(defun tabularium-sync-fix-paths ()
  "Convert absolute paths in schema files to use ~ for the home directory.
This fixes portability issues when syncing databases between machines
with different home directories (e.g., via Syncthing or Dropbox).

Scans all registered databases and rewrites any schema file that
contains a fully expanded home directory path."
  (interactive)
  (tabularium-registry--ensure-loaded)
  (let ((fixed 0)
        (skipped 0)
        (home (expand-file-name "~/")))
    (dolist (entry tabularium-registry--list)
      (let ((schema-file (or (plist-get entry :schema-file)
                             (and (plist-get entry :file)
                                  (tabularium-registry--schema-file-for-db
                                   (plist-get entry :file))))))
        (when (and schema-file (file-exists-p schema-file))
          (with-temp-buffer
            (insert-file-contents schema-file)
            (let ((modified nil))
              ;; Fix :file paths that contain expanded home directory
              (goto-char (point-min))
              (while (re-search-forward
                      (format "\\(:file[ \t]+\"\\)%s"
                              (regexp-quote home))
                      nil t)
                (replace-match "\\1~/" nil nil)
                (setq modified t))
              ;; Also fix comment lines with the path
              (goto-char (point-min))
              (while (re-search-forward
                      (format "\\(;; Database file: \\)%s"
                              (regexp-quote home))
                      nil t)
                (replace-match "\\1~/" nil nil)
                (setq modified t))
              (if modified
                  (progn
                    (write-region (point-min) (point-max) schema-file)
                    (setq fixed (1+ fixed)))
                (setq skipped (1+ skipped))))))))
    ;; Also fix in-memory schemas
    (dolist (schema tabularium-schemas)
      (let ((file (plist-get (cdr schema) :file)))
        (when (and file (string-prefix-p home file))
          (plist-put (cdr schema) :file (abbreviate-file-name file)))))
    ;; Also fix registry entries
    (let ((reg-fixed 0))
      (dolist (entry tabularium-registry--list)
        (let ((changed nil))
          (when-let ((f (plist-get entry :file)))
            (when (string-prefix-p home f)
              (plist-put entry :file (abbreviate-file-name f))
              (setq changed t)))
          (when-let ((sf (plist-get entry :schema-file)))
            (when (string-prefix-p home sf)
              (plist-put entry :schema-file (abbreviate-file-name sf))
              (setq changed t)))
          (when changed (cl-incf reg-fixed))))
      (when (> reg-fixed 0)
        (tabularium-registry--save))
      (message "Fixed %d schema file%s, %d registry entr%s (%d already portable)"
               fixed (if (= fixed 1) "" "s")
               reg-fixed (if (= reg-fixed 1) "y" "ies")
               skipped))))

;;;###autoload
(defun tabularium-sync-cleanup-wal-files ()
  "Delete orphaned WAL and SHM files for all known databases.
Safe to delete when database is closed."
  (interactive)
  (let* ((files (delq nil (mapcar (lambda (s) (plist-get (cdr s) :file))
                                  tabularium-schemas)))
         (cleaned (tabularium-db-cleanup-wal-files files)))
    (if (zerop cleaned)
        (message "No orphaned WAL/SHM files found")
      (message "Cleaned up %d file(s)" cleaned))))

;;; * 4 Schema and Field Management

;;; ** 4.1 Schema Definition

;;;###autoload
(defun tabularium-define-schema (name &rest args)
  "Define a Tabularium schema with NAME and properties ARGS.
This registers the schema in `tabularium-schemas' for later use.

ARGS is a plist with the following keys:
  :file    - Path to SQLite database file
  :fields  - List of field definitions (exactly one must have :primary t)
  :backend - (optional) Backend type: sqlite (default), postgresql, mysql
  :connection - (optional) Connection plist for server backends
  :export-file - (optional) Default path for TSV/CSV exports
  :quick-entry-fields - (optional) Fields for quick entry mode
  :views   - (optional) List of saved view presets
  :default-sort - (optional) Default sort direction: \\='asc or \\='desc
  :highlight - (optional) List of highlight (conditional-format) rules

View definitions are plists with:
  :name    - Display name for the view
  :default - If t, apply this view when opening the database
  :filter  - SQL WHERE clause (or nil to clear filter)
  :columns - List of column symbols to show (hides others)
  :sort    - Sort spec: (column . direction) for single-column,
             or ((col1 . dir1) (col2 . dir2)) for multi-column.
             Direction is \\='asc or \\='desc
  :rows    - (optional) Row-ID restriction: a (MIN . MAX) cons for a
             contiguous range, or a list of IDs for an explicit set

Conditional-formatting rules are plists with:
  :scope   - \\='row or \\='cell (required)
  :field   - For cell scope, the field symbol to test
  :test    - Function returning non-nil on match.
             Cell scope: (lambda (value row-alist) ...).
             Row scope:  (lambda (row-alist) ...).
  :value   - Shorthand: literal compared with `equal' (no :test needed)
  :face    - Face to apply on match.

Rules are evaluated in declared order; first match wins."
  (let* ((fields (plist-get args :fields))
         (has-primary (cl-find-if (lambda (f) (plist-get f :primary)) fields)))
    ;; Validate: a primary key field is required
    (unless has-primary
      (error "Schema '%s': no field has :primary t.  \
  Tabularium requires a primary key field (typically an integer row ID) \
  for row identification, undo/redo, move, sort, and mark operations.  \
  Add :primary t to one field, e.g. (:id row_id :type integer :primary t :label \"ID\")"
             name))
    (let ((existing (assoc name tabularium-schemas)))
      (if existing
          ;; Update existing schema
          (setcdr existing args)
        ;; Add new schema
        (push (cons name args) tabularium-schemas)))
    name))

(defun tabularium--get-schema (name)
  "Get schema plist for NAME."
  (cdr (assoc name tabularium-schemas)))

(defun tabularium--current-schema ()
  "Get the current schema plist."
  (or (and tabularium--buffer-schema-name
           (tabularium--get-schema tabularium--buffer-schema-name))
      (and tabularium--current-schema-name
           (tabularium--get-schema tabularium--current-schema-name))
      (user-error "No schema selected.  Use `tabularium-open' first")))

(defun tabularium--schema-name ()
  "Get the current schema name."
  (or tabularium--buffer-schema-name
      tabularium--current-schema-name))

(defun tabularium--schema-file ()
  "Get the database file path from current schema."
  (when-let ((file (plist-get (tabularium--current-schema) :file)))
    (expand-file-name file)))

(defun tabularium--schema-fields ()
  "Get the field definitions from current schema."
  (plist-get (tabularium--current-schema) :fields))

(defun tabularium--schema-views ()
  "Get the saved views from current schema."
  (plist-get (tabularium--current-schema) :views))

(defun tabularium--schema-default-view ()
  "Get the default view from current schema, if any."
  (cl-find-if (lambda (v) (plist-get v :default))
              (tabularium--schema-views)))

(defun tabularium--schema-default-sort ()
  "Get the default sort direction from current schema.
Returns \\='asc (default) or \\='desc."
  (or (plist-get (tabularium--current-schema) :default-sort)
      'asc))

(defun tabularium--schema-export-file ()
  "Get the export file path from current schema."
  (or (plist-get (tabularium--current-schema) :export-file)
      (let ((file (tabularium--schema-file)))
        (when file
          (concat (file-name-sans-extension file)
                  (if (eq tabularium-export-format 'tsv) ".tsv" ".csv"))))))

(defun tabularium--schema-quick-fields ()
  "Get the quick entry fields, or all fields if not specified."
  (or (plist-get (tabularium--current-schema) :quick-entry-fields)
      (mapcar (lambda (f) (plist-get f :id)) (tabularium--schema-fields))))

(defun tabularium--field-by-name (name)
  "Get field definition for NAME."
  (cl-find-if (lambda (f) (eq (plist-get f :id) name))
              (tabularium--schema-fields)))

(defun tabularium--stored-field-names ()
  "Return name strings for all non-computed fields."
  (mapcar (lambda (f) (symbol-name (plist-get f :id)))
          (cl-remove-if #'tabularium--computed-field-p
                        (tabularium--schema-fields))))

(defun tabularium--filterable-field-names ()
  "Return name strings for fields usable in a SQL clause.
Stored fields plus computed fields whose `:computed' is a SQL
expression — those can be filtered and sorted by substituting the
expression.  Fields computed in Emacs Lisp have no SQL form and are
omitted."
  (mapcar (lambda (f) (symbol-name (plist-get f :id)))
          (cl-remove-if
           (lambda (f)
             (and (tabularium--computed-field-p f)
                  (not (tabularium--computed-sql-expression f))))
           (tabularium--schema-fields))))

(defun tabularium--field-sql-ref (field)
  "Return the SQL reference for FIELD, a field-name string or symbol.
A stored field resolves to its bare column name and a SQL-expression
computed field to that expression in parentheses, so both can be used
in WHERE and ORDER BY clauses.  Returns nil for a field computed in
Emacs Lisp, which exists only as a NULL placeholder in the query and
therefore cannot be filtered or sorted by the database."
  (let* ((sym (if (stringp field) (intern field) field))
         ;; The lookup needs a current schema; SQL-building callers may run
         ;; without one (and pure SQL tests do), so fall back to treating
         ;; the field as a plain column name rather than signalling.
         (plist (ignore-errors (tabularium--field-by-name sym))))
    (cond
     ((null plist) (format "%s" field))
     ((not (tabularium--computed-field-p plist)) (symbol-name sym))
     ((tabularium--computed-sql-expression plist)
      (format "(%s)" (tabularium--computed-sql-expression plist)))
     (t nil))))

(defun tabularium--rebuild-table-dropping (col)
  "Rebuild the data table, dropping physical column COL.
Carries over only the stored (non-computed) columns, so a schema
that defines computed fields rebuilds cleanly — computed fields are
never physical table columns and must be omitted from the backup
SELECT.  COL is a stored field name (symbol); it is the one column
omitted from the rebuilt table.  Reads the current schema, so call
before removing COL from it."
  (let* ((keep-names (cl-remove-if
                      (lambda (n) (string= n (symbol-name col)))
                      (tabularium--stored-field-names)))
         (cols-str (string-join keep-names ", ")))
    (tabularium-db-execute
     tabularium--db
     (format "CREATE TABLE %s_backup AS SELECT %s FROM %s"
             tabularium-table-name cols-str tabularium-table-name)
     nil)
    (tabularium-db-execute
     tabularium--db (format "DROP TABLE %s" tabularium-table-name) nil)
    (tabularium-db-execute
     tabularium--db
     (format "ALTER TABLE %s_backup RENAME TO %s"
             tabularium-table-name tabularium-table-name)
     nil)))

(defun tabularium--field-accepts-value-p (field-name value)
  "Return non-nil if FIELD-NAME's schema allows VALUE.
Choice fields with a `:choice' list reject values not in that list
\(empty values are always allowed).  Other types accept any value."
  (let* ((fields (tabularium--schema-fields))
         (field (cl-find-if
                 (lambda (f) (string= (symbol-name (plist-get f :id))
                                      (if (symbolp field-name)
                                          (symbol-name field-name)
                                        field-name)))
                 fields))
         (choices (and field (plist-get field :choice)))
         (val (format "%s" (or value ""))))
    (or (null choices)
        (string-empty-p val)
        (member val choices))))

(defun tabularium--fields-accepting-value (field-names value)
  "Filter FIELD-NAMES to those whose schema allows VALUE.
Returns a cons (ACCEPTED . REJECTED) where ACCEPTED is the filtered
list of field names safe to operate on, and REJECTED is the list of
field names rejected because VALUE is not a valid choice."
  (let ((accepted nil)
        (rejected nil))
    (dolist (name field-names)
      (if (tabularium--field-accepts-value-p name value)
          (push name accepted)
        (push name rejected)))
    (cons (nreverse accepted) (nreverse rejected))))

(defun tabularium--field-choices (field-name)
  "Return the `:choice' list for FIELD-NAME, or nil if unconstrained."
  (let* ((fields (tabularium--schema-fields))
         (field (cl-find-if
                 (lambda (f) (string= (symbol-name (plist-get f :id))
                                      (if (symbolp field-name)
                                          (symbol-name field-name)
                                        field-name)))
                 fields)))
    (and field (plist-get field :choice))))

(defun tabularium--field-crm (&optional include-computed prompt)
  "Prompt for field selection using `completing-read-multiple'.
Returns a list of field name strings, or nil meaning all fields.
The `<<ALL>>' sentinel (or an empty answer) means every field;
double angle brackets mark it as a sentinel distinct from any real
field name.

With INCLUDE-COMPUTED non-nil the candidate list also offers
computed fields (highlight rules can target computed columns;
filters and marks cannot, since there is no stored column to
query).  PROMPT overrides the default minibuffer prompt."
  (let* ((all-fields
          (cond
           ;; `sql': every field usable in a filter.  Elisp-computed fields
           ;; qualify too — they are filtered in Emacs after the fetch.
           ((eq include-computed 'sql)
            (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                    (tabularium--schema-fields)))
           (include-computed
            (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                    (tabularium--schema-fields)))
           (t (tabularium--stored-field-names))))
         (candidates (cons "<<ALL>>" all-fields))
         (selected (completing-read-multiple
                    (or prompt "Fields [<<ALL>>, or comma-separated]: ")
                    candidates nil t nil nil "<<ALL>>")))
    (if (or (null selected)
            (member "<<ALL>>" selected))
        nil
      selected)))

;;; ** 4.2 Schema File Operations

(defun tabularium--save-schema-to-file (schema-name)
  "Save the current in-memory schema for SCHEMA-NAME to its schema file.
Creates the file if it does not exist.  Preserves all schema properties."
  (let* ((schema (assoc schema-name tabularium-schemas))
         (plist (cdr schema))
         (db-file (plist-get plist :file))
         (schema-file (tabularium-registry--schema-file-for-db db-file))
         (fields (plist-get plist :fields))
         ;; Collect all extra properties beyond :file and :fields
         (extra-keys '())
         (plist-copy (copy-sequence plist)))
    ;; Extract extra properties
    (cl-remf plist-copy :file)
    (cl-remf plist-copy :fields)
    (while plist-copy
      (push (car plist-copy) extra-keys)
      (push (cadr plist-copy) extra-keys)
      (setq plist-copy (cddr plist-copy)))
    (setq extra-keys (nreverse extra-keys))
    (with-temp-file schema-file
      (insert (format ";;; %s --- Schema for %s -*- lexical-binding: t; -*-\n\n"
                      (file-name-nondirectory schema-file) schema-name))
      (insert "(require 'tabularium)\n\n")
      (insert ";; Schema definition (auto-generated)\n")
      (insert ";; Last modified: " (format-time-string "%Y-%m-%d %H:%M:%S") "\n\n")
      (insert "(tabularium-define-schema \"" schema-name "\"\n")
      (insert "  :file \"" (abbreviate-file-name db-file) "\"\n")
      (insert "  :fields\n")
      ;; Pretty-print fields, one per line
      (insert "  '(")
      (let ((first t))
        (dolist (field fields)
          (if first
              (setq first nil)
            (insert "\n    "))
          (insert (prin1-to-string field))))
      (insert ")")
      ;; Write extra properties (views, export-file, quick-entry-fields, etc.)
      (while extra-keys
        (let ((key (pop extra-keys))
              (val (pop extra-keys)))
          (when val
            (insert (format "\n  %s %s" key
                            (if (or (listp val) (symbolp val))
                                (format "'%S" val)
                              (prin1-to-string val)))))))
      (insert ")\n\n")
      (insert ";;; " (file-name-nondirectory schema-file) " ends here\n"))
    (message "Schema saved to %s" schema-file)))

;;; ** 4.3 Schema Commands

;;;###autoload
(defun tabularium-schema-edit ()
  "Edit the schema file for the current database."
  (interactive)
  (unless tabularium--current-schema-name
    (user-error "No database open.  Use `tabularium-open' first"))
  (let* ((schema (assoc tabularium--current-schema-name tabularium-schemas))
         (db-file (plist-get (cdr schema) :file))
         (schema-file (tabularium-registry--schema-file-for-db db-file)))
    (if (file-exists-p schema-file)
        (find-file schema-file)
      (user-error "Schema file not found: %s" schema-file))))

;;;###autoload
(defun tabularium-schema-view ()
  "Display the current database schema in a read-only buffer."
  (interactive)
  (unless tabularium--current-schema-name
    (user-error "No database open.  Use `tabularium-open' first"))
  (let* ((schema (assoc tabularium--current-schema-name tabularium-schemas))
         (db-file (plist-get (cdr schema) :file))
         (schema-file (tabularium-registry--schema-file-for-db db-file)))
    (if (file-exists-p schema-file)
        (with-current-buffer (get-buffer-create "*Tabularium Schema*")
          (erase-buffer)
          (insert-file-contents schema-file)
          (emacs-lisp-mode)
          (goto-char (point-min))
          (pop-to-buffer (current-buffer)))
      ;; Show from memory
      (let* ((name (car schema))
             (plist (cdr schema))
             (fields (plist-get plist :fields)))
        (with-current-buffer (get-buffer-create "*Tabularium Schema*")
          (erase-buffer)
          (emacs-lisp-mode)
          (insert (format ";; Schema: %s (in memory, no file)\n\n" name))
          (insert (tabularium-wizard--generate-schema-file name db-file fields nil))
          (goto-char (point-min))
          (pop-to-buffer (current-buffer)))))))

;;;###autoload
(defun tabularium-schema-reload ()
  "Reload the current schema from its file.
Useful after editing the schema file externally."
  (interactive)
  (unless tabularium--current-schema-name
    (user-error "No database open.  Use `tabularium-open' first"))
  (let* ((schema-name tabularium--current-schema-name)
         (entry (tabularium-registry--find-entry schema-name))
         (db-file (plist-get entry :file))
         (schema-file (tabularium-registry--schema-file-for-db db-file)))
    (unless (and schema-file (file-exists-p schema-file))
      (user-error "Schema file not found for %s" schema-name))
    ;; Remove old schema from memory
    (setq tabularium-schemas (assoc-delete-all schema-name tabularium-schemas))
    ;; Reload the schema file
    (load schema-file nil t)
    ;; Invalidate cache
    (tabularium--invalidate-cache)
    ;; Refresh view if open
    (when-let ((view-buf (get-buffer (format "*%s*" schema-name))))
      (with-current-buffer view-buf
        (revert-buffer)))
    (message "Reloaded schema: %s" schema-name)))

;;;###autoload
(defun tabularium-schema-rename-field (old-name new-name)
  "Rename field OLD-NAME to NEW-NAME in the current schema.
Updates both the database column and the schema file.  Refuses to
rename the primary-key field (use `tabularium-create-database' to
restructure if needed).  Undoable.

This is a focused single-property variant of
`tabularium-view-column-edit'."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (primary (tabularium--primary-field-name))
          (renamable (cl-remove-if
                      (lambda (f) (eq (plist-get f :id) primary))
                      fields))
          (choices (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                           renamable))
          (old (intern (completing-read "Rename field: " choices nil t)))
          (new (intern (read-string (format "Rename '%s' to: "
                                            (symbol-name old))))))
     (list old new)))
  (unless tabularium--current-schema-name
    (user-error "No database open"))
  (when (eq old-name new-name)
    (user-error "Old and new names are identical"))
  (when (eq old-name (tabularium--primary-field-name))
    (user-error "Cannot rename the primary-key field"))
  (when (tabularium--field-by-name new-name)
    (user-error "A field named '%s' already exists" new-name))
  ;; Delegate to the multi-property column editor with a copy of the field
  ;; whose identifier is the new name (a rename touches only :id).
  (let ((field (tabularium--field-by-name old-name)))
    (tabularium-view-column-edit
     (list (list :old-name old-name
                 :new-field (plist-put (copy-sequence field) :id new-name))))))

;;; ** 4.4 Computed Fields

;; Computed fields can be defined in the schema with:
;;   :computed EXPRESSION
;; Where EXPRESSION can be:
;;   - A string: SQL expression (e.g., "price * quantity")
;;   - A function: Elisp function receiving the row alist, returns computed value
;;   - A plist with :sql or :elisp key for explicit type
;;
;; Example schema:
;;   (:id total :type number :label "Total" :computed "price * quantity")
;;   (:id status :type text :label "Status" :computed (:elisp my-status-fn))
;;   (:id age :type integer :label "Age" :computed (:sql "strftime('%Y', 'now') - birth_year"))

;;; *** 4.4.1 Core Functions

(defun tabularium--computed-field-p (field)
  "Return non-nil if FIELD is a computed field."
  (plist-get field :computed))

(defun tabularium--compute-field-value (field row-alist)
  "Compute the value for computed FIELD given ROW-ALIST."
  (let ((computation (plist-get field :computed)))
    (cond
     ;; String = SQL expression (evaluated in query)
     ((stringp computation) nil)  ; Handled in SQL
     ;; Function = elisp function
     ((functionp computation)
      (funcall computation row-alist))
     ;; Plist with :elisp
     ((and (listp computation) (plist-get computation :elisp))
      (let ((fn (plist-get computation :elisp)))
        (if (functionp fn)
            (funcall fn row-alist)
          (eval fn))))
     ;; Plist with :sql = handled in query
     ((and (listp computation) (plist-get computation :sql))
      nil))))

(defun tabularium--computed-sql-expression (field)
  "Get SQL expression for computed FIELD, or nil if elisp-computed."
  (let ((computation (plist-get field :computed)))
    (cond
     ((stringp computation) computation)
     ((and (listp computation) (plist-get computation :sql))
      (plist-get computation :sql))
     (t nil))))

(defun tabularium--build-select-with-computed (visible-fields)
  "Build SELECT clause including computed fields for VISIBLE-FIELDS.
Each visible field contributes exactly one SELECT item, in order:

  * a plain stored field            → the bare column name;
  * a SQL-expression computed field → \"(EXPR) AS name\";
  * an elisp `:computed' field      → \"NULL AS name\", a literal
    placeholder.  An elisp-computed field has no physical column,
    so referencing it by name would be a SQL error; the NULL holds
    the slot in the right position and `tabularium--apply-elisp-computed'
    fills in the real value afterwards."
  (mapcar (lambda (f)
            (let* ((name (symbol-name (plist-get f :id)))
                   (computed (tabularium--computed-field-p f))
                   (sql-expr (tabularium--computed-sql-expression f)))
              (cond
               (sql-expr (format "(%s) AS %s" sql-expr name))
               ;; Elisp-computed: no column exists — emit a placeholder.
               (computed (format "NULL AS %s" name))
               (t name))))
          visible-fields))

(defun tabularium--apply-elisp-computed (rows visible-fields computed-fields
                                               display-offset &optional context-fields)
  "Apply elisp computed field values to ROWS.
VISIBLE-FIELDS is the ordered list of visible field plists.
COMPUTED-FIELDS is the subset with elisp :computed specs.
DISPLAY-OFFSET is the column offset for the primary key.

CONTEXT-FIELDS, when non-nil, is an ordered list of extra stored
field plists whose values the caller appended to each row after
the visible columns (see `tabularium-view--refresh').  They are
folded into the computation alist so a computed field can depend
on a column the user has hidden, but are not themselves written
back; the caller trims them off before display."
  (let ((visible-names (mapcar (lambda (f) (plist-get f :id)) visible-fields)))
    (mapcar
     (lambda (row)
       (let* ((row-list (copy-sequence row))
              (data (nthcdr display-offset row-list))
              ;; Build alist from all visible fields for computation context
              (alist (cl-mapcar
                      (lambda (f val) (cons (plist-get f :id) val))
                      visible-fields data)))
         ;; Fold in any hidden context columns (trailing values).
         (when context-fields
           (setq alist
                 (append alist
                         (cl-mapcar
                          (lambda (f val) (cons (plist-get f :id) val))
                          context-fields
                          (nthcdr (length visible-fields) data)))))
         ;; Compute each elisp field and update the row
         (dolist (cf computed-fields)
           (let* ((name (plist-get cf :id))
                  (value (tabularium--compute-field-value cf alist))
                  (pos (cl-position name visible-names))
                  (idx (when pos (+ display-offset pos))))
             (when (and idx value)
               (setf (nth idx row-list) value))))
         row-list))
     rows)))

;;; *** 4.4.2 Computational Helpers

;; The functions below are intended for use inside `:computed' lambdas
;; in schema files.  Each receives the current row as an alist of
;; (FIELD-NAME . VALUE) pairs.

;;; *** 4.4.2.1 Conditional Logic

(defun tabularium-fn-if (condition then-value else-value)
  "Return THEN-VALUE if CONDITION is truthy, else ELSE-VALUE."
  (if condition then-value else-value))

(defun tabularium-fn-case (value &rest clauses)
  "Match VALUE against CLAUSES for computed fields.
CLAUSES are (test-value result) pairs, with optional final default."
  (let ((default (if (= (mod (length clauses) 2) 1)
                     (car (last clauses))
                   nil))
        (pairs (if (= (mod (length clauses) 2) 1)
                   (butlast clauses)
                 clauses)))
    (or (cl-loop for (test result) on pairs by #'cddr
                 when (equal value test) return result)
        default)))

;;; *** 4.4.2.2 Same-Row Numeric and String Aggregation

(defun tabularium--field-numeric (row-alist name)
  "Return ROW-ALIST's NAME field value coerced to a number, or 0."
  (let ((v (alist-get name row-alist)))
    (cond
     ((null v) 0)
     ((numberp v) v)
     ((stringp v)
      (if (string-empty-p v) 0
        (let ((n (string-to-number v)))
          (if (and (zerop n) (not (string-match-p "\\`0+\\(\\.0*\\)?\\'" v)))
              0
            n))))
     (t 0))))

(defun tabularium-fn-sum-fields (row-alist &rest field-names)
  "Sum the numeric values of FIELD-NAMES in ROW-ALIST.
Non-numeric and missing values count as 0."
  (apply #'+ 0 (mapcar (lambda (name)
                         (tabularium--field-numeric row-alist name))
                       field-names)))

(defun tabularium-fn-concat-fields (row-alist separator &rest field-names)
  "Concatenate FIELD-NAMES from ROW-ALIST joined by SEPARATOR.
Empty and missing fields are skipped (no leading or trailing SEPARATOR)."
  (string-join
   (delq nil
         (mapcar (lambda (name)
                   (let ((v (alist-get name row-alist)))
                     (cond
                      ((null v) nil)
                      ((and (stringp v) (string-empty-p v)) nil)
                      (t (format "%s" v)))))
                 field-names))
   separator))

;;; *** 4.4.2.3 Date Arithmetic

(defun tabularium-fn-today ()
  "Return today's date as an ISO 8601 string (YYYY-MM-DD)."
  (format-time-string "%Y-%m-%d"))

(defun tabularium-fn-time-now ()
  "Return the current time as an ISO 8601 string (HH:MM:SS).
Companion to `tabularium-fn-today' and `tabularium-fn-datetime-now',
intended for use in `:computed' lambdas on `:type time' fields."
  (format-time-string "%H:%M:%S"))

(defun tabularium-fn-datetime-now ()
  "Return the current timestamp as an ISO 8601 string.
Emits the space-separated form (`YYYY-MM-DD HH:MM:SS') so the
result round-trips identically through SQLite TEXT storage and
PostgreSQL TIMESTAMP columns.  Use this for `:type datetime'
fields or any field that records a wall-clock instant."
  (format-time-string "%Y-%m-%d %H:%M:%S"))

(defun tabularium--parse-datetime (s)
  "Parse S as an ISO 8601 datetime; return an Emacs time value or nil.
Accepts either space or T as the date/time separator.  S may
optionally omit seconds.  Returns nil on empty or unparseable
input rather than signaling an error, so callers can safely
chain results through computed-field arithmetic."
  (when (and s (stringp s) (not (string-empty-p s)))
    (let* ((normalized (replace-regexp-in-string "T" " " s))
           (parsed (parse-time-string normalized))
           (sec (nth 0 parsed))
           (min (nth 1 parsed))
           (hr  (nth 2 parsed))
           (day (nth 3 parsed))
           (mon (nth 4 parsed))
           (yr  (nth 5 parsed)))
      (when (and day mon yr)
        (ignore-errors
          (encode-time (or sec 0) (or min 0) (or hr 0) day mon yr))))))

(defun tabularium--parse-time (s)
  "Parse S as an HH:MM[:SS] time-of-day; return seconds since midnight or nil.
Empty input and malformed strings return nil so callers can guard
with `when'.  The result is always in the range [0, 86400)."
  (when (and s (stringp s)
             (string-match
              "\\`\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\(?::\\([0-9]\\{2\\}\\)\\)?\\'"
              s))
    (let ((h (string-to-number (match-string 1 s)))
          (m (string-to-number (match-string 2 s)))
          (sec (if (match-string 3 s)
                   (string-to-number (match-string 3 s))
                 0)))
      (+ (* h 3600) (* m 60) sec))))

(defun tabularium--format-time-of-day (seconds)
  "Format SECONDS (an integer count) as HH:MM:SS.
SECONDS is first reduced modulo 86400 so out-of-range or negative
counts wrap into a valid time-of-day."
  (let* ((s (mod seconds 86400))
         (h (/ s 3600))
         (m (/ (mod s 3600) 60))
         (sec (mod s 60)))
    (format "%02d:%02d:%02d" h m sec)))

(defun tabularium-fn-date-add (date days)
  "Return DATE plus DAYS as an ISO date string.
DATE is parsed with `parse-time-string'; DAYS may be negative."
  (when (and date (not (string-empty-p date)))
    (let* ((parsed (parse-time-string date))
           (sec (encode-time
                 (or (nth 0 parsed) 0)
                 (or (nth 1 parsed) 0)
                 (or (nth 2 parsed) 0)
                 (nth 3 parsed)
                 (nth 4 parsed)
                 (nth 5 parsed))))
      (format-time-string "%Y-%m-%d"
                          (time-add sec (* days 86400))))))

(defun tabularium-fn-date-diff (date1 date2)
  "Return the number of days between DATE1 and DATE2 (DATE2 − DATE1).
Both arguments are ISO date strings.  Returns nil if either is
empty or cannot be parsed as a date."
  (when (and date1 date2
             (not (string-empty-p date1))
             (not (string-empty-p date2)))
    (let* ((p1 (parse-time-string date1))
           (p2 (parse-time-string date2)))
      ;; `parse-time-string' fills unparseable components with nil;
      ;; `encode-time' then signals on a nil day/month/year.  If either
      ;; date is missing any of those, treat the input as unparseable
      ;; and return nil rather than crashing.
      (when (and (nth 3 p1) (nth 4 p1) (nth 5 p1)
                 (nth 3 p2) (nth 4 p2) (nth 5 p2))
        (let ((t1 (encode-time (or (nth 0 p1) 0) (or (nth 1 p1) 0)
                               (or (nth 2 p1) 0)
                               (nth 3 p1) (nth 4 p1) (nth 5 p1)))
              (t2 (encode-time (or (nth 0 p2) 0) (or (nth 1 p2) 0)
                               (or (nth 2 p2) 0)
                               (nth 3 p2) (nth 4 p2) (nth 5 p2))))
          (round (/ (float-time (time-subtract t2 t1)) 86400)))))))

(defun tabularium-fn-time-add (time seconds)
  "Return TIME plus SECONDS as an HH:MM:SS string.
TIME is an HH:MM or HH:MM:SS string; SECONDS may be negative or
greater than a day.  The result wraps modulo 24 hours so an input
near midnight plus a negative offset returns a valid late-evening
time of day rather than going negative.  Returns nil if TIME is
empty or malformed."
  (when-let ((base (tabularium--parse-time time)))
    (tabularium--format-time-of-day (+ base (or seconds 0)))))

(defun tabularium-fn-time-diff (start end)
  "Return the difference END − START in integer seconds.
Both arguments are HH:MM or HH:MM:SS strings.  The result is
positive when END is later than START, zero when they are equal,
and negative when END is earlier — no day-wrap inference is
attempted, so callers who want a positive duration across midnight
should pass the arguments themselves with that interpretation, or
use `tabularium-fn-datetime-diff' with full datetime values.
Returns nil if either argument is empty or malformed."
  (let ((s (tabularium--parse-time start))
        (e (tabularium--parse-time end)))
    (when (and s e) (- e s))))

(defun tabularium-fn-datetime-add (datetime seconds)
  "Return DATETIME plus SECONDS as a `YYYY-MM-DD HH:MM:SS' string.
DATETIME accepts either separator form (space or T) on input but
the result is always emitted with a space.  SECONDS may be
negative or large enough to cross multiple day boundaries.
Returns nil if DATETIME is empty or unparseable."
  (when-let ((base (tabularium--parse-datetime datetime)))
    (format-time-string
     "%Y-%m-%d %H:%M:%S"
     (time-add base (or seconds 0)))))

(defun tabularium-fn-datetime-diff (start end)
  "Return the difference END − START in integer seconds across days.
Both arguments are datetime strings (space or T separator).  The
result is signed: positive when END is later, negative when
earlier.  Returns nil if either argument is empty or unparseable.
Use `tabularium-fn-duration-format' to render the result as a
human-readable string."
  (let ((s (tabularium--parse-datetime start))
        (e (tabularium--parse-datetime end)))
    (when (and s e)
      (round (float-time (time-subtract e s))))))

(defun tabularium-fn-datetime-date (datetime)
  "Return the date portion of DATETIME as a `YYYY-MM-DD' string.
DATETIME accepts either separator form (space or T) on input.
Returns nil on empty or unparseable input."
  (when-let ((parsed (tabularium--parse-datetime datetime)))
    (format-time-string "%Y-%m-%d" parsed)))

(defun tabularium-fn-datetime-time (datetime)
  "Return the time-of-day portion of DATETIME as an `HH:MM:SS' string.
DATETIME accepts either separator form (space or T) on input.
Returns nil on empty or unparseable input."
  (when-let ((parsed (tabularium--parse-datetime datetime)))
    (format-time-string "%H:%M:%S" parsed)))

(defun tabularium-fn-datetime-combine (date time)
  "Combine DATE and TIME into a `YYYY-MM-DD HH:MM:SS' datetime string.
DATE is an ISO date string; TIME is an HH:MM or HH:MM:SS string.
Returns nil if either argument is empty.  The output always
includes seconds; a TIME of `09:30' is emitted as `09:30:00'."
  (when (and date time
             (stringp date) (stringp time)
             (not (string-empty-p date)) (not (string-empty-p time)))
    (let* ((time-secs (tabularium--parse-time time))
           (date-parsed (parse-time-string date))
           (day (nth 3 date-parsed))
           (mon (nth 4 date-parsed))
           (yr  (nth 5 date-parsed)))
      (when (and time-secs day mon yr)
        (let ((base (encode-time 0 0 0 day mon yr)))
          (format-time-string
           "%Y-%m-%d %H:%M:%S"
           (time-add base time-secs)))))))

(defun tabularium-fn-duration-format (seconds &optional style)
  "Format SECONDS (an integer count) as a human-readable duration string.
STYLE is a symbol controlling output form:

  `colon' (the default) — `H:MM:SS', with hours growing past 24 as
                          needed (e.g. 90061 → `25:01:01').
  `units'                — `Hh Mm Ss', omitting leading zero
                          components (e.g. 90061 → `25h 1m 1s';
                          61 → `1m 1s'; 5 → `5s').

A negative SECONDS is rendered with a leading `-' and the
absolute value formatted as above.  Returns nil when SECONDS is
nil."
  (when seconds
    (let* ((neg (< seconds 0))
           (s (abs seconds))
           (h (/ s 3600))
           (m (/ (mod s 3600) 60))
           (sec (mod s 60))
           (body
            (pcase (or style 'colon)
              ('colon (format "%d:%02d:%02d" h m sec))
              ('units
               (cond
                ((> h 0) (format "%dh %dm %ds" h m sec))
                ((> m 0) (format "%dm %ds" m sec))
                (t (format "%ds" sec))))
              (_ (format "%d:%02d:%02d" h m sec)))))
      (if neg (concat "-" body) body))))

(defun tabularium-fn-age (date &optional reference)
  "Return the number of years between DATE and REFERENCE (default today).
DATE is an ISO date string.  Returns nil if DATE is empty.
The result is the integer number of completed years
\(birthdays not yet reached do not count)."
  (when (and date (not (string-empty-p date)))
    (let* ((ref (or reference (tabularium-fn-today)))
           (p1 (parse-time-string date))
           (p2 (parse-time-string ref))
           (y1 (nth 5 p1)) (m1 (nth 4 p1)) (d1 (nth 3 p1))
           (y2 (nth 5 p2)) (m2 (nth 4 p2)) (d2 (nth 3 p2))
           (years (- y2 y1)))
      (when (or (< m2 m1) (and (= m2 m1) (< d2 d1)))
        (cl-decf years))
      years)))

;;; *** 4.4.2.4 Cross-Row Lookup and Aggregation

;; These query the current database directly and require an open
;; connection.  They are safe to call inside `:computed' lambdas
;; because computed fields are evaluated only when the database is
;; active.

(defun tabularium-fn-lookup (lookup-field lookup-value return-field)
  "Return RETURN-FIELD from the first row where LOOKUP-FIELD = LOOKUP-VALUE.
Returns nil when no matching row exists."
  (when (and tabularium--db lookup-field return-field)
    (let* ((sql (format "SELECT %s FROM %s WHERE %s = %s LIMIT 1"
                        return-field
                        tabularium-table-name
                        lookup-field
                        (tabularium-db-sql-quote lookup-value)))
           (result (tabularium-db-query-single tabularium--db sql)))
      (car result))))

(defun tabularium-fn-count-where (field value)
  "Return the count of rows where FIELD = VALUE."
  (when (and tabularium--db field)
    (let* ((sql (format "SELECT COUNT(*) FROM %s WHERE %s = %s"
                        tabularium-table-name field
                        (tabularium-db-sql-quote value)))
           (result (tabularium-db-query-single tabularium--db sql)))
      (or (car result) 0))))

(defun tabularium-fn-sum-where (sum-field filter-field filter-value)
  "Return the sum of SUM-FIELD across rows where FILTER-FIELD = FILTER-VALUE."
  (when (and tabularium--db sum-field filter-field)
    (let* ((sql (format "SELECT SUM(%s) FROM %s WHERE %s = %s"
                        sum-field tabularium-table-name
                        filter-field
                        (tabularium-db-sql-quote filter-value)))
           (result (tabularium-db-query-single tabularium--db sql)))
      (or (car result) 0))))

(defun tabularium--primary-field ()
  "Get the primary key field.
Signals an error if no field has :primary t."
  (or (cl-find-if (lambda (f) (plist-get f :primary)) (tabularium--schema-fields))
      (error "Schema has no :primary field.  \
  Add :primary t to one field definition")))

(defun tabularium--primary-field-name ()
  "Get the name of the primary key field."
  (plist-get (tabularium--primary-field) :id))

;;; ** 4.5 Completion

;; Completion types: historical, recent, fixed, vocabulary, related,
;; filtered, function, union.  See `tabularium-schemas' docstring for details.

;;; *** 4.5.0 Field-Value Validation

(defun tabularium--validate-field-value (value type)
  "Check whether VALUE is acceptable input for a field of TYPE.
Returns nil when valid, or an error string when invalid.

Empty values are always valid (so users can clear a field).
Date validation is strict YYYY-MM-DD; time accepts HH:MM and
HH:MM:SS with leading zeros; datetime accepts YYYY-MM-DD HH:MM
and YYYY-MM-DDTHH:MM (with optional :SS); integer rejects
decimals; number accepts integers and decimals.  Other types
pass through."
  (cond
   ((or (null value) (and (stringp value) (string-empty-p value)))
    nil)
   ((eq type 'integer)
    (unless (string-match-p "\\`-?[0-9]+\\'" value)
      (format "Invalid integer: '%s'" value)))
   ((eq type 'number)
    (unless (string-match-p "\\`-?[0-9]+\\(\\.[0-9]+\\)?\\'" value)
      (format "Invalid number: '%s'" value)))
   ((eq type 'date)
    (unless (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'"
                            value)
      (format "Invalid date: '%s'.  Expected YYYY-MM-DD" value)))
   ((eq type 'time)
    (unless (string-match-p
             "\\`[0-9]\\{2\\}:[0-9]\\{2\\}\\(:[0-9]\\{2\\}\\)?\\'"
             value)
      (format "Invalid time: '%s'.  Expected HH:MM or HH:MM:SS" value)))
   ((eq type 'datetime)
    (unless (string-match-p
             "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[T ][0-9]\\{2\\}:[0-9]\\{2\\}\\(:[0-9]\\{2\\}\\)?\\'"
             value)
      (format
       "Invalid datetime: '%s'.  Expected YYYY-MM-DD HH:MM[:SS]"
       value)))
   (t nil)))

(defun tabularium--validate-pattern (value field)
  "Check VALUE against FIELD's `:pattern' regex, if any.
Returns nil when valid (or no pattern declared), or an error
string.  Empty values are always valid.  When `:pattern-help' is
declared on the field, it is used verbatim as the error message;
otherwise a generic message is generated from the pattern itself.

Pattern matching is always case-sensitive regardless of the
ambient `case-fold-search'.  A schema author who wants
case-insensitive matching should write the regex accordingly
\(e.g. =[A-Za-z]+= instead of =[A-Z]+=)."
  (let ((pattern (plist-get field :pattern))
        ;; Schema-defined patterns are documented contracts; the user
        ;; chose the character classes deliberately.  Respect them.
        (case-fold-search nil))
    (cond
     ((or (null pattern) (null value)
          (and (stringp value) (string-empty-p value)))
      nil)
     ((not (stringp pattern))
      (format "Field %s: `:pattern' must be a regex string, got %S"
              (plist-get field :id) pattern))
     ((string-match-p pattern value) nil)
     (t (or (plist-get field :pattern-help)
            (format "Invalid value '%s': does not match pattern '%s'"
                    value pattern))))))

(defun tabularium--validate-custom (value field)
  "Check VALUE against FIELD's `:validate' function, if any.
The function is called with the value as its single argument and
should return nil when valid, or an error string when invalid.
Empty values are passed through unchanged.  Errors raised by the
function are caught and reported as validation failures."
  (let ((validator (plist-get field :validate)))
    (cond
     ((or (null validator) (null value)
          (and (stringp value) (string-empty-p value)))
      nil)
     ((not (functionp validator))
      (format "Field %s: `:validate' must be a function, got %S"
              (plist-get field :id) validator))
     (t (condition-case err
            (funcall validator value)
          (error (format "Validation error: %s"
                         (error-message-string err))))))))

(defun tabularium--validate-field-input (value field)
  "Validate VALUE against FIELD's full validation chain.
Returns nil when valid, or an error string explaining the first
failure.  Checks, in order: type validity, `:pattern' regex,
custom `:validate' function.  Empty values short-circuit to nil."
  (when (and value (stringp value) (not (string-empty-p value)))
    (or (tabularium--validate-field-value value (plist-get field :type))
        (tabularium--validate-pattern value field)
        (tabularium--validate-custom value field))))

;;; *** 4.5.1 Boolean Pairs

(defvar tabularium--boolean-pairs
  '(("yes" "no")
    ("Yes" "No")
    ("YES" "NO")
    ("true" "false")
    ("True" "False")
    ("TRUE" "FALSE")
    ("t" "f")
    ("T" "F")
    ("y" "n")
    ("Y" "N")
    ("1" "0"))
  "Canonical pairs for `:type boolean' fields.
Each entry is a (TRUTHY FALSY) list.  A column's pair is either
declared explicitly via the schema's `:boolean-pair' property or
inferred from the first non-empty value already in the column.
Once a pair is established, entry-mode restricts completion to
those two values to keep the column internally consistent.")

(defvar tabularium--boolean-pair-anchors
  (mapcar #'car tabularium--boolean-pairs)
  "Initial-pick candidates for a brand-new boolean column.
Picking one of these values selects the corresponding pair from
`tabularium--boolean-pairs' for the rest of the column.")

(defun tabularium--boolean-pair-for-value (value)
  "Return the (TRUTHY FALSY) pair containing VALUE, or nil.
VALUE is compared case-sensitively against entries in
`tabularium--boolean-pairs'."
  (when (and value (stringp value) (not (string-empty-p value)))
    (cl-find-if (lambda (pair) (member value pair))
                tabularium--boolean-pairs)))

(defun tabularium--boolean-pair-for (field)
  "Return the (TRUTHY FALSY) pair governing FIELD, or nil if none yet.
Resolution order: explicit `:boolean-pair' on the field plist
takes precedence; otherwise, the column is sampled for the first
non-empty value and matched against `tabularium--boolean-pairs'.
If neither source yields a value, nil is returned so the caller
falls back to the canonical anchor list."
  (or
   ;; 1. Explicit schema declaration
   (let ((declared (plist-get field :boolean-pair)))
     (cond
      ((and (listp declared) (= (length declared) 2)) declared)
      ((and (consp declared) (atom (cdr declared)))
       (list (car declared) (cdr declared)))
      (t nil)))
   ;; 2. Inference from existing data
   (when (and tabularium--db tabularium--current-schema-name)
     (let* ((col-name (symbol-name (plist-get field :id)))
            (primary (tabularium--primary-field-name))
            (sql (format
                  "SELECT %s FROM %s WHERE %s IS NOT NULL AND %s != '' LIMIT 1"
                  col-name tabularium-table-name col-name col-name)))
       (ignore primary)
       (condition-case _
           (let* ((rows (tabularium-db-query tabularium--db sql))
                  (sample (and rows (caar rows))))
             (tabularium--boolean-pair-for-value sample))
         (error nil))))))

(defun tabularium--invalidate-cache ()
  "Invalidate the completion and paired field caches."
  (clrhash tabularium--completion-cache)
  (clrhash tabularium--paired-field-cache)
  (setq tabularium--cache-timestamp nil))

(defun tabularium--load-vocabulary-file (file)
  "Load vocabulary from FILE, using cache if unchanged.
FILE should contain one value per line.  Empty lines and lines
starting with # are ignored."
  (let* ((expanded (expand-file-name file))
         (cached (gethash expanded tabularium--vocabulary-cache))
         (current-mtime (when (file-exists-p expanded)
                          (float-time (file-attribute-modification-time
                                       (file-attributes expanded))))))
    (cond
     ;; File does not exist
     ((not current-mtime)
      (message "Tabularium: vocabulary file not found: %s" expanded)
      nil)
     ;; Cache hit and file unchanged
     ((and cached (= (car cached) current-mtime))
      (cdr cached))
     ;; Need to load/reload
     (t
      (let ((values (with-temp-buffer
                      (insert-file-contents expanded)
                      (let ((lines '()))
                        (goto-char (point-min))
                        (while (not (eobp))
                          (let ((line (string-trim
                                       (buffer-substring-no-properties
                                        (line-beginning-position)
                                        (line-end-position)))))
                            (unless (or (string-empty-p line)
                                        (string-prefix-p "#" line))
                              (push line lines)))
                          (forward-line 1))
                        (nreverse lines)))))
        (puthash expanded (cons current-mtime values) tabularium--vocabulary-cache)
        values)))))

(defun tabularium--get-historical-values (field-name &optional limit)
  "Get distinct historical values for FIELD-NAME, ranked by frequency.
Optional LIMIT restricts the number of results."
  (tabularium--ensure-db)
  (let ((sql (format "SELECT %s, COUNT(*) as freq FROM %s
                      WHERE %s IS NOT NULL AND %s != ''
                      GROUP BY %s ORDER BY freq DESC%s"
                     field-name tabularium-table-name
                     field-name field-name field-name
                     (if limit (format " LIMIT %d" limit) ""))))
    (mapcar #'car (tabularium-db-query tabularium--db sql))))

(defun tabularium--get-recent-values (field-name &optional limit)
  "Get distinct historical values for FIELD-NAME, ranked by recency.
Most recently used values appear first.
Optional LIMIT restricts the number of results."
  (tabularium--ensure-db)
  (let ((sql (format "SELECT %s, MAX(rowid) as latest FROM %s
                      WHERE %s IS NOT NULL AND %s != ''
                      GROUP BY %s ORDER BY latest DESC%s"
                     field-name tabularium-table-name
                     field-name field-name field-name
                     (if limit (format " LIMIT %d" limit) ""))))
    (mapcar #'car (tabularium-db-query tabularium--db sql))))

(defun tabularium--get-filtered-values (field-name where-clause &optional limit)
  "Get historical values for FIELD-NAME filtered by WHERE-CLAUSE.
Optional LIMIT restricts the number of results."
  (tabularium--ensure-db)
  (let ((sql (format "SELECT %s, COUNT(*) as freq FROM %s
                      WHERE %s IS NOT NULL AND %s != '' AND (%s)
                      GROUP BY %s ORDER BY freq DESC%s"
                     field-name tabularium-table-name
                     field-name field-name where-clause field-name
                     (if limit (format " LIMIT %d" limit) ""))))
    (condition-case err
        (mapcar #'car (tabularium-db-query tabularium--db sql))
      (error
       (message "Tabularium: filtered completion error: %s" (error-message-string err))
       nil))))

(defun tabularium--get-related-values (field-name related-field related-value &optional limit)
  "Get values for FIELD-NAME that co-occur with RELATED-VALUE in RELATED-FIELD.
Returns values ranked by frequency of co-occurrence.
Optional LIMIT restricts the number of results."
  (tabularium--ensure-db)
  (if (or (null related-value)
          (and (stringp related-value) (string-empty-p related-value)))
      ;; No related value yet, return all historical
      (tabularium--get-historical-values field-name limit)
    ;; Filter by related field
    (let ((sql (format "SELECT %s, COUNT(*) as freq FROM %s
                        WHERE %s IS NOT NULL AND %s != ''
                        AND %s = %s
                        GROUP BY %s ORDER BY freq DESC%s"
                       field-name tabularium-table-name
                       field-name field-name
                       related-field (tabularium-db-sql-quote related-value)
                       field-name
                       (if limit (format " LIMIT %d" limit) ""))))
      (condition-case err
          (let ((results (mapcar #'car (tabularium-db-query tabularium--db sql))))
            ;; If no results with filter, fall back to all historical
            (or results (tabularium--get-historical-values field-name limit)))
        (error
         (message "Tabularium: related completion error: %s" (error-message-string err))
         (tabularium--get-historical-values field-name limit))))))

(defun tabularium--parse-complete-spec (complete-spec)
  "Parse COMPLETE-SPEC into a normalized plist.
Handles both simple symbols and extended plist forms.
Returns a plist with at least :type key, or nil."
  (cond
   ;; nil -> no completion
   ((null complete-spec)
    nil)
   ;; Simple symbol (historical, recent, fixed)
   ((symbolp complete-spec)
    (list :type complete-spec))
   ;; Already a plist with :type
   ((and (listp complete-spec) (plist-get complete-spec :type))
    complete-spec)
   ;; List starting with a symbol (shorthand form)
   ((and (listp complete-spec) (symbolp (car complete-spec)))
    (pcase (car complete-spec)
      ('vocabulary
       (if (stringp (cadr complete-spec))
           (list :type 'vocabulary :source (cadr complete-spec))
         (list :type 'vocabulary :values (cdr complete-spec))))
      ('related
       (list :type 'related :field (cadr complete-spec)))
      ('filtered
       (list :type 'filtered :where (cadr complete-spec)))
      ('function
       (list :type 'function :fn (cadr complete-spec)))
      ('union
       (list :type 'union :sources (cdr complete-spec)))
      (_
       (message "Tabularium: unknown completion shorthand: %S" complete-spec)
       nil)))
   (t
    (message "Tabularium: invalid completion spec: %S" complete-spec)
    nil)))

(defun tabularium--get-completion-candidates (field &optional context)
  "Get completion candidates for FIELD.
CONTEXT is an optional alist of current field values (for related completion).
Returns a list of strings."
  (let* ((field-name (plist-get field :id))
         (complete-spec (plist-get field :complete))
         (choices (plist-get field :choice))
         (parsed (tabularium--parse-complete-spec complete-spec)))

    ;; Handle :choice for choice type when no :complete specified
    (when (and (null parsed) (eq (plist-get field :type) 'choice) choices)
      (setq parsed (list :type 'fixed :values choices)))

    (when parsed
      (let* ((comp-type (plist-get parsed :type))
             (limit (plist-get parsed :limit))
             (cache-key (format "%s:%s:%s"
                                (tabularium--schema-name)
                                field-name
                                comp-type)))

        ;; Check cache validity for cacheable types
        (when (memq comp-type '(historical recent filtered))
          (when (or (null tabularium--cache-timestamp)
                    (> (- (float-time) tabularium--cache-timestamp) tabularium-cache-ttl))
            (tabularium--invalidate-cache)
            (setq tabularium--cache-timestamp (float-time))))

        (pcase comp-type
          ;; Historical: frequency-ranked
          ('historical
           (or (gethash cache-key tabularium--completion-cache)
               (let ((values (tabularium--get-historical-values
                              (symbol-name field-name) limit)))
                 (puthash cache-key values tabularium--completion-cache)
                 values)))

          ;; Recent: recency-ranked
          ('recent
           (or (gethash cache-key tabularium--completion-cache)
               (let ((values (tabularium--get-recent-values
                              (symbol-name field-name) limit)))
                 (puthash cache-key values tabularium--completion-cache)
                 values)))

          ;; Fixed: static list (from :choice or inline)
          ('fixed
           (or choices (plist-get parsed :values)))

          ;; Vocabulary: external file or inline list
          ('vocabulary
           (let ((source (plist-get parsed :source))
                 (values (plist-get parsed :values)))
             (when tabularium-debug
               (message "Tabularium DEBUG: vocabulary source=%S values=%S" source values))
             (cond
              (source
               (let ((loaded (tabularium--load-vocabulary-file source)))
                 (when tabularium-debug
                   (message "Tabularium DEBUG: loaded %d values from %s"
                            (length loaded) source))
                 loaded))
              (values values)
              (t nil))))

          ;; Related: values that co-occur with another field's current value
          ('related
           (let* ((related-field (plist-get parsed :field))
                  (related-value (when context
                                   (alist-get related-field context))))
             (tabularium--get-related-values
              (symbol-name field-name)
              (symbol-name related-field)
              related-value
              limit)))

          ;; Filtered: historical with SQL WHERE clause
          ('filtered
           (let ((where-clause (plist-get parsed :where)))
             (or (gethash (format "%s:%s" cache-key where-clause)
                          tabularium--completion-cache)
                 (let ((values (tabularium--get-filtered-values
                                (symbol-name field-name) where-clause limit)))
                   (puthash (format "%s:%s" cache-key where-clause)
                            values tabularium--completion-cache)
                   values))))

          ;; Function: call user-provided function
          ('function
           (let ((fn (plist-get parsed :fn)))
             (when (and fn (fboundp fn))
               (condition-case err
                   (funcall fn field-name context)
                 (error
                  (message "Tabularium: completion function error: %s"
                           (error-message-string err))
                  nil)))))

          ;; Union: combine multiple sources
          ('union
           (let ((sources (plist-get parsed :sources))
                 (all-values '()))
             (dolist (source sources)
               ;; Create a temporary field spec with the sub-completion
               (let* ((temp-field (plist-put (copy-sequence field) :complete source))
                      (sub-values (tabularium--get-completion-candidates temp-field context)))
                 (setq all-values (append all-values sub-values))))
             ;; Remove duplicates while preserving order
             (delete-dups all-values)))

          ;; Unknown type
          (_
           (message "Tabularium: unknown completion type: %s" comp-type)
           nil))))))

;;;###autoload
(defun tabularium-completion-debug (field-name)
  "Debug completion configuration for FIELD-NAME."
  (interactive
   (list (completing-read "Field: "
                          (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                                  (tabularium--schema-fields)))))
  (tabularium--ensure-db)
  (let* ((field-def (tabularium--field-by-name (intern field-name)))
         (complete-spec (plist-get field-def :complete))
         (parsed (tabularium--parse-complete-spec complete-spec))
         (candidates (tabularium--get-completion-candidates field-def)))
    (with-help-window "*Tabularium Completion Debug*"
      (princ (format "Field: %s\n" field-name))
      (princ (format "Raw :complete spec: %S\n" complete-spec))
      (princ (format "Parsed spec: %S\n" parsed))
      (princ (format "Completion type: %s\n" (plist-get parsed :type)))
      (princ (format "\nCandidates (%d):\n" (length candidates)))
      (dolist (c (seq-take candidates 20))
        (princ (format "  %s\n" c)))
      (when (> (length candidates) 20)
        (princ (format "  ... and %d more\n" (- (length candidates) 20)))))))

;;;###autoload
(defun tabularium-completion-clear-cache ()
  "Clear the vocabulary file cache."
  (interactive)
  (clrhash tabularium--vocabulary-cache)
  (message "Vocabulary cache cleared"))

;;; ** 4.6 Related Field Autofill Support

(defun tabularium--build-autofill-cache (source-field target-field)
  "Build a frequency-weighted mapping from SOURCE-FIELD to TARGET-FIELD.
Returns a hash table where each source value maps to its most
frequently co-occurring target value."
  (tabularium--ensure-db)
  (let* ((mapping (make-hash-table :test 'equal))
         (sql (format "SELECT %s, %s, COUNT(*) as freq FROM %s
                      WHERE %s IS NOT NULL AND %s != ''
                      AND %s IS NOT NULL AND %s != ''
                      GROUP BY %s, %s ORDER BY freq DESC"
                      source-field target-field tabularium-table-name
                      source-field source-field
                      target-field target-field
                      source-field target-field))
         (rows (condition-case err
                   (tabularium-db-query tabularium--db sql)
                 (error
                  (when tabularium-debug
                    (message "DEBUG build-autofill-cache SQL ERROR: %s" (error-message-string err)))
                  nil))))
    (when tabularium-debug
      (message "DEBUG build-autofill-cache: %s->%s, got %d rows"
               source-field target-field (length rows)))
    ;; Process rows (already sorted by frequency descending)
    ;; First occurrence of each source value is the most frequent pairing
    (dolist (row rows)
      (let ((source-val (nth 0 row))
            (target-val (nth 1 row)))
        (when (and source-val target-val
                   (not (gethash source-val mapping)))
          (puthash source-val target-val mapping))))
    mapping))

(defun tabularium--get-autofill-value (source-field source-value target-field)
  "Get the most frequently co-occurring TARGET-FIELD value for SOURCE-VALUE.
SOURCE-FIELD is the field that was just filled, TARGET-FIELD is the
field to auto-fill."
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (cache-key (format "%s:%s->%s" schema-name source-field target-field))
         (mapping (or (gethash cache-key tabularium--paired-field-cache)
                      (let ((new-mapping (tabularium--build-autofill-cache
                                          (symbol-name source-field)
                                          (symbol-name target-field))))
                        (when tabularium-debug
                          (message "DEBUG get-autofill-value: built cache for %s->%s, %d entries"
                                   source-field target-field (hash-table-count new-mapping)))
                        (puthash cache-key new-mapping tabularium--paired-field-cache)
                        new-mapping)))
         (result (gethash source-value mapping)))
    (when tabularium-debug
      (message "DEBUG get-autofill-value: lookup '%s' in %s->%s = %s"
               source-value source-field target-field (or result "NIL")))
    result))

(defun tabularium--find-autofill-targets (source-field-name)
  "Find all fields that should autofill when SOURCE-FIELD-NAME is entered.
Returns a list of field plists that have :complete with :type related,
:field SOURCE-FIELD-NAME, and :autofill t."
  (let ((fields (tabularium--schema-fields)))
    (cl-remove-if-not
     (lambda (f)
       (let* ((complete-spec (plist-get f :complete))
              (parsed (tabularium--parse-complete-spec complete-spec)))
         (and (eq (plist-get parsed :type) 'related)
              (eq (plist-get parsed :field) source-field-name)
              (plist-get parsed :autofill))))
     fields)))

;;; ** 4.7 Highlight Rules (Conditional Formatting)

;; Schema-level rules that drive how rows and individual cells are
;; faced in `tabularium-view-mode'.  A rule is a plist:
;;
;;   (:scope row  :test FN :face FACE)
;;   (:scope cell :field FIELD :test FN :face FACE)
;;
;; The :test function receives the row alist (rows) or the cell value
;; followed by the row alist (cells) and returns non-nil on a match.
;; First match wins.
;;
;; As shorthand, :value LIT replaces :test with an `equal' check; the
;; LIT side is coerced to a string for cell scope.

(defvar tabularium--cf-rules-cache 'unset
  "Per-refresh memo of `tabularium--cf-rules', or the symbol `unset'.
The view's print path resolves the active highlight rules once per
refresh and binds this around the row/cell rendering loop, so the
identical rule list is not recomputed once per cell.  When unbound
\(value `unset') `tabularium--cf-rules' computes fresh every call,
preserving the original behavior for any interactive caller.")

(defun tabularium--cf-rules ()
  "Return the active highlight rules, or nil.
Memoized for the duration of a view refresh via
`tabularium--cf-rules-cache'; see `tabularium--compute-cf-rules'
for the actual computation."
  (if (eq tabularium--cf-rules-cache 'unset)
      (tabularium--compute-cf-rules)
    tabularium--cf-rules-cache))

(defun tabularium--compute-cf-rules ()
  "Compute the active highlight rules, or nil.
Combines the active schema's `:highlight' rules — minus any saved
rules the user has hidden in this view (see
`tabularium--highlight-suppressed') — with the buffer-local
runtime rules in `tabularium--highlight-runtime-rules'.  Validates
each rule's `:scope', drops malformed entries with a message, and
returns the survivors in evaluation order: saved rules first as
the stable base, runtime rules stacked on top so a freshly
applied highlight takes precedence."
  (let* ((schema-rules
          (plist-get (tabularium--get-schema (tabularium--schema-name))
                     :highlight))
         (visible-schema
          (if tabularium--highlight-suppressed
              (cl-remove-if (lambda (r)
                              (member r tabularium--highlight-suppressed))
                            schema-rules)
            schema-rules))
         (raw (append visible-schema tabularium--highlight-runtime-rules)))
    (when raw
      (delq nil
            (mapcar
             (lambda (rule)
               (let ((scope (plist-get rule :scope)))
                 (cond
                  ((memq scope '(row cell column)) rule)
                  (t (message
                      "Tabularium highlight: ignoring rule with bad :scope %S"
                      scope)
                     nil))))
             raw)))))

(defun tabularium--highlight-builtin-matches-p (rule value &optional row-alist)
  "Return non-nil if a built-in highlight RULE matches cell VALUE.
ROW-ALIST is the whole row, needed by row-scoped builtins.  RULE
carries a `:builtin' key naming the rule type.  All built-in types
are pure data — no closures — so they round-trip cleanly through a
schema file.  Supported types:

  compare     — `:op' is one of the strings \">\" \"<\" \">=\" \"<=\"
                \"=\" \"!=\"; `:operand' is the literal compared
                against.  Numeric comparison when both sides parse
                as numbers, string comparison otherwise — and since
                ISO date/time strings sort chronologically as text,
                string comparison gives correct date/time ordering.
  regex       — `:regex' is a regexp; matches when it is found in
                VALUE.  Case-sensitive.
  duplicates  — matches when VALUE occurs more than once in its
                column; uses `tabularium--highlight-dup-cache'.
  all         — always matches; used by the quick column-highlight
                commands to paint a whole column.
  rows        — row-scoped; `:row-ids' is a list of primary-key
                values, matches when the row's id is among them;
                used by the quick row-highlight command."
  (let* ((type (plist-get rule :builtin))
         (str (if value (format "%s" value) ""))
         (blank (string-empty-p (string-trim str))))
    (pcase type
      ('all t)
      ('rows
       (let* ((pk (tabularium--primary-field-name))
              (id (and pk (alist-get pk row-alist)))
              (ids (plist-get rule :row-ids)))
         (and id (member (format "%s" id)
                          (mapcar (lambda (x) (format "%s" x)) ids)))))
      ('regex
       (let ((rx (plist-get rule :regex)))
         (and rx (not blank)
              (let ((case-fold-search nil))
                (string-match-p rx str)))))
      ('duplicates
       (let* ((field (plist-get rule :field))
              (tbl (and tabularium--highlight-dup-cache
                        (gethash field tabularium--highlight-dup-cache))))
         (and tbl (not blank)
              (> (or (gethash str tbl) 0) 1))))
      ('unique
       (let* ((field (plist-get rule :field))
              (tbl (and tabularium--highlight-dup-cache
                        (gethash field tabularium--highlight-dup-cache))))
         (and tbl (not blank)
              (= (or (gethash str tbl) 0) 1))))
      ('compare
       (let* ((op (plist-get rule :op))
              (operand (plist-get rule :operand))
              (operand-str (format "%s" (or operand "")))
              (num-cell (and (not blank)
                             (string-match-p "\\`-?[0-9.]+\\'" str)
                             (string-to-number str)))
              (num-op (and (string-match-p "\\`-?[0-9.]+\\'" operand-str)
                           (string-to-number operand-str)))
              (numeric (and num-cell num-op)))
         (unless blank
           (pcase op
             ("="  (if numeric (= num-cell num-op) (string= str operand-str)))
             ("!=" (if numeric (/= num-cell num-op) (not (string= str operand-str))))
             (">"  (if numeric (> num-cell num-op) (string> str operand-str)))
             ("<"  (if numeric (< num-cell num-op) (string< str operand-str)))
             (">=" (if numeric (>= num-cell num-op)
                     (not (string< str operand-str))))
             ("<=" (if numeric (<= num-cell num-op)
                     (not (string> str operand-str))))
             (_ nil)))))
      (_ nil))))

(defun tabularium--cf-rule-matches-p (rule value row-alist)
  "Return non-nil if RULE applies to VALUE in ROW-ALIST.
For row-scoped rules VALUE is ignored.  A `:builtin' rule is
dispatched to `tabularium--highlight-builtin-matches-p' (cell
scope only).  The `:value' shorthand is honored for cell rules
only and is compared with `equal' after string-coercion.  A custom
`:test' function is called with VALUE and ROW-ALIST for cell
rules, or just ROW-ALIST for row rules."
  (let ((scope (plist-get rule :scope))
        (builtin (plist-get rule :builtin))
        (test (plist-get rule :test))
        (has-value (plist-member rule :value))
        (lit (plist-get rule :value)))
    (condition-case err
        (cond
         ;; A rule limited to certain rows never applies outside them.
         ;; The row id is always in ROW-ALIST, even when the primary key
         ;; is not a visible column.
         ((and (plist-get rule :rows)
               (not (member (cdr (assq (tabularium--primary-field-name)
                                       row-alist))
                            (plist-get rule :rows))))
          nil)
         ;; Built-in rule types — cell scope, plus the row-scoped `rows'.
         ((and builtin (eq scope 'cell))
          (tabularium--highlight-builtin-matches-p rule value row-alist))
         ((and builtin (eq scope 'row) (eq builtin 'rows))
          (tabularium--highlight-builtin-matches-p rule value row-alist))
         ;; A row rule naming a field tests that field's value in the row,
         ;; tinting the whole row when it matches — the row analogue of a
         ;; cell rule, and the mirror of a row filter.
         ((and builtin (eq scope 'row) (plist-get rule :field))
          (tabularium--highlight-builtin-matches-p
           rule (cdr (assq (plist-get rule :field) row-alist)) row-alist))
         ((and builtin (eq scope 'row))
          (message
           "Tabularium highlight: :builtin rules are cell-scoped; ignoring")
          nil)
         ;; :value shorthand — cell scope only
         ((and (not test) has-value (eq scope 'cell))
          (equal (format "%s" (or lit ""))
                 (format "%s" (or value ""))))
         ((and (not test) has-value (eq scope 'row))
          (message
           "Tabularium highlight: ignoring row rule with :value (use :test instead)")
          nil)
         ;; Custom predicate
         ((functionp test)
          (if (eq scope 'cell)
              (funcall test value row-alist)
            (funcall test row-alist)))
         (t nil))
      (error
       (message "Tabularium highlight: rule error (%s); skipping"
                (error-message-string err))
       nil))))

(defun tabularium--cf-row-face (row-alist)
  "Return the face(s) to apply to ROW-ALIST per row-scoped highlight rules.
Every row-scoped rule that matches contributes its `:face'; the
faces are stacked into a list (in rule-evaluation order), so
several rules can decorate the same row at once — for example one
rule adding `bold' and another a background color.  Returns a
single face symbol when exactly one rule matches, a list when
several do, or nil when none do."
  (let ((faces '()))
    (dolist (rule (tabularium--cf-rules))
      (when (and (eq (plist-get rule :scope) 'row)
                 (tabularium--cf-rule-matches-p rule nil row-alist))
        (push (plist-get rule :face) faces)))
    (cond ((null faces) nil)
          ((null (cdr faces)) (car faces))
          (t (nreverse faces)))))

(defvar-local tabularium--highlight-column-faces nil
  "Alist of (FIELD-ID . FACES) for column rules that matched this refresh.
A column-scoped rule considers every column, so which columns it tints
is known only once the rows have been fetched.  Recomputed each refresh
by `tabularium-view--refresh'; the cell-face path then does a lookup.")

(defun tabularium--highlight-column-rule-matches-p (rule field rows
                                                         visible-fields
                                                         display-offset)
  "Return non-nil if RULE matches column FIELD over ROWS.
A column rule carries no column of its own — it is offered every column
and tints the ones that match — so FIELD is supplied here and folded
into the rule, which also gives the duplicate and unique tests the
column they count values in.  Rows are limited to those named by the
rule's `:rows', when it has any.  A rule carrying `:columns' tints only
those columns, so FIELD outside that set never matches."
  (let* ((cols (plist-get rule :columns))
         (idx (cl-position field visible-fields
                           :key (lambda (f) (plist-get f :id))))
         (ids (plist-get rule :rows))
         (probe (plist-put (copy-sequence rule) :field field)))
    (when (and idx (or (null cols) (memq field cols)))
      (cl-some
       (lambda (r)
         (and (or (null ids) (member (car r) ids))
              (tabularium--highlight-builtin-matches-p
               probe (nth (+ display-offset idx) r)
               (tabularium--cf-row-alist r visible-fields display-offset))))
       rows))))

(defun tabularium--highlight-column-face-alist (rules rows visible-fields
                                                      display-offset)
  "Return an alist of (FIELD-ID . FACES) for the column RULES that matched."
  (let ((out '()))
    (dolist (rule rules)
      (when (eq (plist-get rule :scope) 'column)
        (dolist (f visible-fields)
          (let ((field (plist-get f :id)))
            (when (tabularium--highlight-column-rule-matches-p
                   rule field rows visible-fields display-offset)
              (push (plist-get rule :face) (alist-get field out)))))))
    out))

(defun tabularium--cf-cell-face (field-id value row-alist)
  "Return the face(s) for FIELD-ID's VALUE in ROW-ALIST per cell-scoped highlight rules.
FIELD-ID is a symbol matching a rule's `:field', and ROW-ALIST is the
row being rendered.  Every cell rule
on that field that matches contributes its `:face'; the faces are
stacked into a list (in rule-evaluation order), so highlight rules
compose — bold from one rule, italic from a second, a background
from a third.  Returns a single face when one rule matches, a list
when several do, or nil when none do."
  (let ((faces '()))
    (dolist (rule (tabularium--cf-rules))
      (when (or (and (eq (plist-get rule :scope) 'cell)
                     (memq (plist-get rule :field) (list field-id '*))
                     (tabularium--cf-rule-matches-p rule value row-alist))
                )
        (push (plist-get rule :face) faces)))
    ;; Column rules tint every cell of the columns they matched; which
    ;; columns those are was settled once for this refresh.
    (dolist (face (alist-get field-id tabularium--highlight-column-faces))
      (push face faces))
    (cond ((null faces) nil)
          ((null (cdr faces)) (car faces))
          (t (nreverse faces)))))

(defun tabularium--cf-row-alist (row visible-fields display-offset)
  "Build a field-name → value alist for ROW.
ROW is a database result row, VISIBLE-FIELDS is the ordered field
list used to build the SELECT, and DISPLAY-OFFSET is 0 when the
primary key is among them or 1 when it was prepended.  Used by the
CF predicates so user functions can refer to fields by symbol.
The primary-key field is always included, even when it is not a
visible column, so row-scoped rules can match on the row id."
  (let* ((values (nthcdr display-offset row))
         (alist (cl-mapcar (lambda (f v) (cons (plist-get f :id) v))
                           visible-fields values)))
    ;; When the primary key was prepended (offset 1) it is not in
    ;; VISIBLE-FIELDS; add it so row-id rules can see it.
    (if (and (= display-offset 1) row)
        (cons (cons (tabularium--primary-field-name) (car row)) alist)
      alist)))

;;; *** 4.7.1 Interactive Highlight Commands

(defun tabularium--highlight-schema-rules ()
  "Return the active schema's saved `:highlight' rule list."
  (plist-get (tabularium--get-schema (tabularium--schema-name))
             :highlight))

(defun tabularium--highlight-set-schema-rules (rules)
  "Replace the active schema's saved `:highlight' rules with RULES.
Updates only the in-memory schema; the schema file is rewritten
only by `tabularium-view-highlight-save' and
`tabularium-view-highlight-expunge'."
  (let ((schema (assoc (tabularium--schema-name) tabularium-schemas)))
    (when schema
      (setf (cdr schema)
            (plist-put (cdr schema) :highlight rules)))))

(defun tabularium--highlight-restore-state (runtime schema-rules suppressed)
  "Restore the highlight rule state to RUNTIME, SCHEMA-RULES, SUPPRESSED.
RUNTIME becomes the buffer-local runtime stack; SCHEMA-RULES
becomes the in-memory schema `:highlight' list; SUPPRESSED becomes
the buffer-local list of hidden saved rules.  Used by the undo
system to revert a highlight rule-set change."
  (setq tabularium--highlight-runtime-rules (copy-sequence runtime))
  (setq tabularium--highlight-suppressed (copy-sequence suppressed))
  (tabularium--highlight-set-schema-rules (copy-sequence schema-rules))
  (tabularium--highlight-sync))

(defmacro tabularium--highlight-with-undo (&rest body)
  "Run BODY, recording the highlight rule-state change for undo.
Snapshots the runtime stack, the schema `:highlight' list, and the
buffer-local suppressed-rule list before and after BODY; if any
changed, pushes a `highlight' undo operation.  BODY is responsible
for the mutation itself and for refreshing the view."
  (declare (indent 0) (debug t))
  `(let ((tabularium--hl-before-runtime
          (copy-sequence tabularium--highlight-runtime-rules))
         (tabularium--hl-before-schema
          (copy-sequence (tabularium--highlight-schema-rules)))
         (tabularium--hl-before-suppressed
          (copy-sequence tabularium--highlight-suppressed)))
     (prog1 (progn ,@body)
       (let ((after-runtime
              (copy-sequence tabularium--highlight-runtime-rules))
             (after-schema
              (copy-sequence (tabularium--highlight-schema-rules)))
             (after-suppressed
              (copy-sequence tabularium--highlight-suppressed)))
         (unless (and (equal tabularium--hl-before-runtime after-runtime)
                      (equal tabularium--hl-before-schema after-schema)
                      (equal tabularium--hl-before-suppressed
                             after-suppressed))
           (tabularium--undo-push
            (list :type 'highlight
                  :before-runtime tabularium--hl-before-runtime
                  :after-runtime after-runtime
                  :before-schema tabularium--hl-before-schema
                  :after-schema after-schema
                  :before-suppressed tabularium--hl-before-suppressed
                  :after-suppressed after-suppressed))
           (tabularium--highlight-sync))))))

(defvar tabularium--highlight-rule-rows nil
  "Row ids a column-scoped highlight rule should be judged over.
Bound by `tabularium-view-highlight-new\=' and folded into the rule by
`tabularium--highlight-add-rules\='; nil means every row.")

(defvar tabularium--highlight-rule-scope 'cell
  "Scope given to rules built by the typed highlight commands.
`cell\=' tints the matching cells, `row\=' tints the whole row when the
tested field matches.  Bound by `tabularium-view-highlight-new\='; the
commands default to cell scope when called directly.")

(defun tabularium--highlight-read-face ()
  "Prompt for a highlight face from `tabularium-highlight-faces'.
Returns the chosen face symbol."
  (let* ((names (mapcar #'car tabularium-highlight-faces))
         (choice (completing-read
                  (format "Highlight face (default %s): " (car names))
                  names nil t nil nil (car names))))
    (cdr (assoc choice tabularium-highlight-faces))))

(defun tabularium--highlight-read-fields (&optional types prompt)
  "Prompt for the columns a new highlight rule should target.
Uses a `completing-read-multiple' field selector with the
`<<ALL>>' sentinel — the same selector the filter and mark
commands use — so a rule can target one column, several, or every
applicable column.

With TYPES nil every visible column is offered (computed columns
included, since highlight rules can target them).  When TYPES is a
list of field-type symbols, only columns of those types are
offered — used by the numeric/comparison rule, which is
meaningless on, say, a free-text column.  PROMPT overrides the
minibuffer prompt.  Returns a list of field-id symbols.

Signals a `user-error' when no column qualifies."
  (let* ((all-fields (tabularium-view--ordered-visible-fields))
         (eligible (if types
                       (cl-remove-if-not
                        (lambda (f) (memq (plist-get f :type) types))
                        all-fields)
                     all-fields))
         (names (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                        eligible)))
    (unless names
      (user-error "No %scolumns to highlight"
                  (if types "applicable " "")))
    (let* ((selected (completing-read-multiple
                      (or prompt
                          "Highlight columns [<<ALL>>, or comma-separated]: ")
                      (cons "<<ALL>>" names) nil t nil nil "<<ALL>>"))
           (syms (if (or (null selected) (member "<<ALL>>" selected))
                     (mapcar (lambda (f) (plist-get f :id)) eligible)
                   (mapcar #'intern selected))))
      (or syms (user-error "No columns to highlight")))))

(defun tabularium--highlight-scope-wrap (rule field)
  "Wrap RULE's target in the braces that mark its scope, with rows prefixed.
For a column rule the brace names the eligible columns (`*\=' meaning
every column, or the chosen subset); for a row or value rule it names
FIELD.  A leading =[…]= shows the rows the rule is judged over, when
narrowed to a subset."
  (let* ((rows (plist-get rule :rows))
         (inner (if (eq (plist-get rule :scope) 'column)
                    (tabularium--format-column-ids (plist-get rule :columns))
                  (format "%s" field)))
         (body (format "{%s}" inner)))
    (if rows
        (format "[%s]%s" (tabularium--format-row-ids rows) body)
      body)))

(defun tabularium--highlight-scope-tag (rule)
  "Return a short word for what RULE tints: rows, a column, or values."
  (pcase (plist-get rule :scope)
    ('row "row")
    ('column "col")
    (_ "value")))

(defun tabularium--highlight-describe-rule (rule)
  "Return a short human-readable description of a highlight RULE.
Built-in rule types are rendered with logical/operator notation
rather than prose: `≈' for regexp match and `∈ dups' for
membership in the set of duplicated values, matching the
AND/OR/NOT operator style used by the filter stack."
  (let ((field (plist-get rule :field))
        (builtin (plist-get rule :builtin)))
    (pcase builtin
      ('compare (format "%s %s %s" (tabularium--highlight-scope-wrap rule field)
                        (plist-get rule :op)
                        (plist-get rule :operand)))
      ('regex (format "%s ≈ /%s/" (tabularium--highlight-scope-wrap rule field)
                      (plist-get rule :regex)))
      ('duplicates (format "%s ∈ dups"
                           (tabularium--highlight-scope-wrap rule field)))
      ('unique (format "%s ∉ dups"
                       (tabularium--highlight-scope-wrap rule field)))
      ('all (format "{%s}" field))
      ('rows (format "[%s]"
                     (tabularium--format-row-ids (plist-get rule :row-ids))))
      (_ (if (plist-member rule :value)
             (format "%s = %s" (tabularium--highlight-scope-wrap rule field)
                     (plist-get rule :value))
           (format "%s (custom)"
                   (tabularium--highlight-scope-wrap rule field)))))))

(defun tabularium--highlight-collapse-rules (rules)
  "Collapse RULES that cover every visible column into a single rule.
Choosing `<<ALL>>\=' columns otherwise yields one rule per column, which
buries the rules list.  When cell rules differ only by `:field\=' and
together cover every visible column, they become one rule whose
`:field\=' is the symbol `*\=', displayed as ={*}=."
  (if (or (null (cdr rules))
          ;; Only cell rules collapse: `*' has no meaning for a row rule
          ;; (which tests one named field) or a column rule (which must
          ;; know which column it tints), and duplicate/unique rules each
          ;; need their own column to count values in.
          (not (eq (plist-get (car rules) :scope) 'cell))
          (memq (plist-get (car rules) :builtin) '(duplicates unique)))
      rules
    (let* ((visible (mapcar (lambda (f) (plist-get f :id))
                            (tabularium-view--ordered-visible-fields)))
           (fields (mapcar (lambda (r) (plist-get r :field)) rules))
           ;; Everything but :field is compared, so rules differing in
           ;; their row restriction are never merged.
           (rest (lambda (r) (let ((c (copy-sequence r)))
                               (cl-remf c :field) c)))
           (same (cl-every (lambda (r) (equal (funcall rest r)
                                              (funcall rest (car rules))))
                           rules)))
      (if (and same visible
               (cl-every (lambda (f) (memq f fields)) visible))
          (list (plist-put (copy-sequence (car rules)) :field '*))
        rules))))

(defun tabularium--highlight-add-rules (rules)
  "Append RULES to the runtime highlight stack and refresh the view.
RULES is a list of rule plists.  They go on the end, which is the top
of the stack: `tabularium--cf-cell-face\=' collects faces in evaluation
order and the last match ends up first in the face list, so the newest
rule overrides the ones beneath it.  The change is recorded for undo."
  (setq rules (tabularium--highlight-collapse-rules rules))
  (tabularium--highlight-with-undo
    (setq tabularium--highlight-runtime-rules
          (append tabularium--highlight-runtime-rules
                  (mapcar
                   (lambda (rule)
                     ;; A column rule carries the rows it is judged over.
                     (if (and tabularium--highlight-rule-rows
                              (eq (plist-get rule :scope) 'column))
                         (plist-put (copy-sequence rule)
                                    :rows tabularium--highlight-rule-rows)
                       rule))
                   rules))))
  (revert-buffer)
  (if (cl-some (lambda (r) (eq (plist-get r :scope) 'column)) rules)
      ;; A column rule tints only the columns that matched, which is
      ;; knowable only once the refresh above has judged them — so report
      ;; the matches, not the columns that were searched.
      ;; A column rule is offered every column, so the count is simply how
      ;; many took the highlight.
      (let ((hit (length tabularium--highlight-column-faces)))
        (message "Highlight added: %d column%s matched"
                 hit (if (= 1 hit) "" "s")))
    (message "Highlight added: %s%s"
             (tabularium--highlight-describe-rule (car rules))
             (if (> (length rules) 1)
                 (format " (+%d more columns)" (1- (length rules)))
               ""))))

(defun tabularium--highlight-columns-hint (fields)
  "Return a bracketed hint string naming the chosen FIELDS.
Lists the field-id symbols, or an ellipsis when there are more
than three — matching the square-bracket hint style of the other
Tabularium prompts."
  (if (> (length fields) 3)
      "[…]"
    (format "[%s]" (mapconcat #'symbol-name fields ","))))

;;;###autoload
(defun tabularium-view-highlight-numeric (fields op operand face)
  "Add a numeric/comparison highlight rule for FIELDS.
FIELDS is a list of column-id symbols; OP is one of the comparison
strings (>, <, >=, <=, =, !=); OPERAND is the literal compared
against; FACE is the face to apply.  Cells in each column whose
value satisfies the comparison are highlighted.

Numeric comparison is used when both the cell and the operand
parse as numbers, string comparison otherwise.  Because ISO
date/time strings (=YYYY-MM-DD=, =HH:MM=, =YYYY-MM-DD HH:MM=)
order chronologically as text, the same rule expresses
\"later/earlier than\" for date, time, and datetime columns — so
those columns are offered alongside the numeric ones.

Interactively only columns where a comparison is meaningful —
integer, number, date, time, and datetime — are offered in the
`completing-read-multiple' selector.  The rule is added to the
buffer-local runtime stack; use `tabularium-view-highlight-save'
to persist it."
  (interactive
   (let* ((fields (tabularium--highlight-read-fields
                   '(integer number date time datetime)
                   "Highlight columns [<<ALL>> numeric/date, or list]: "))
          (hint (tabularium--highlight-columns-hint fields))
          (op (completing-read (format "Operator %s: " hint)
                               '(">" "<" ">=" "<=" "=" "!=") nil t)))
     (list fields op
           (read-string (format "Highlight %s where value %s: " hint op))
           (tabularium--highlight-read-face))))
  (tabularium--highlight-add-rules
   (mapcar (lambda (field)
             (list :scope tabularium--highlight-rule-scope :field field :builtin 'compare
                   :op op :operand operand :face face))
           fields)))

;;;###autoload
(defun tabularium-view-highlight-unique (fields face)
  "Highlight cells whose value occurs exactly once in their column.
FIELDS is a list of column-id symbols; FACE is the face to apply.  The
complement of `tabularium-view-highlight-duplicates\=', for spotting the
values that stand alone in the current view.

Interactively the columns are chosen with a `completing-read-multiple\='
selector (the `<<ALL>>\=' sentinel means every visible column).  The
rule is added to the runtime stack; persist with
`tabularium-view-highlight-save\='."
  (interactive
   (let ((fields (tabularium--highlight-read-fields)))
     (list fields (tabularium--highlight-read-face))))
  (tabularium--highlight-add-rules
   (mapcar (lambda (field)
             (list :scope tabularium--highlight-rule-scope :field field :builtin 'unique :face face))
           fields)))

;;;###autoload
(defun tabularium-view-highlight-duplicates (fields face)
  "Highlight cells whose value is duplicated within their column.
FIELDS is a list of column-id symbols; FACE is the face to apply.
A cell matches when its value occurs more than once in the same
column of the current view.

Interactively the columns are chosen with a `completing-read-multiple'
selector (the `<<ALL>>' sentinel means every visible column).  The
rule is added to the runtime stack; persist with
`tabularium-view-highlight-save'."
  (interactive
   (list (tabularium--highlight-read-fields)
         (tabularium--highlight-read-face)))
  (tabularium--highlight-add-rules
   (mapcar (lambda (field)
             (list :scope tabularium--highlight-rule-scope :field field :builtin 'duplicates
                   :face face))
           fields)))

;;;###autoload
(defun tabularium-view-highlight-regexp (fields regexp face)
  "Highlight cells in FIELDS whose text matches REGEXP.
FIELDS is a list of column-id symbols; REGEXP is an Emacs regexp,
matched case-sensitively; FACE is the face to apply.

Interactively the columns are chosen with a `completing-read-multiple'
selector (the `<<ALL>>' sentinel means every visible column).  The
rule is added to the runtime stack; persist with
`tabularium-view-highlight-save'."
  (interactive
   (let* ((fields (tabularium--highlight-read-fields))
          (hint (tabularium--highlight-columns-hint fields))
          (regexp (read-regexp
                   (format "Highlight %s cells matching regexp: " hint))))
     (when (string-empty-p regexp)
       (user-error "Empty regexp"))
     (list fields regexp (tabularium--highlight-read-face))))
  (tabularium--highlight-add-rules
   (mapcar (lambda (field)
             (list :scope tabularium--highlight-rule-scope :field field :builtin 'regex
                   :regex regexp :face face))
           fields)))

;;;###autoload
(defun tabularium-view-highlight-substring (fields value face)
  "Highlight cells in FIELDS containing the literal text VALUE.
FIELDS is a list of column-id symbols; FACE is the face to apply.
The text is matched literally (it is regexp-quoted), case-sensitively;
use `tabularium-view-highlight-regexp' for pattern matching.  The
highlight counterpart of `tabularium-view-filter-substring'.

Interactively the columns are chosen with a `completing-read-multiple'
selector (the `<<ALL>>' sentinel means every visible column)."
  (interactive
   (let* ((fields (tabularium--highlight-read-fields))
          (hint (tabularium--highlight-columns-hint fields))
          (value (read-string
                  (format "Highlight %s cells containing: " hint))))
     (when (string-empty-p value)
       (user-error "Empty text"))
     (list fields value (tabularium--highlight-read-face))))
  (tabularium--highlight-add-rules
   (mapcar (lambda (field)
             (list :scope tabularium--highlight-rule-scope :field field :builtin 'regex
                   :regex (regexp-quote value) :face face))
           fields)))

;;;###autoload
(defun tabularium-view-highlight-exact (fields value face)
  "Highlight cells in FIELDS whose value is exactly VALUE.
FIELDS is a list of column-id symbols; FACE is the face to apply.
The highlight counterpart of `tabularium-view-filter-exact'.

Interactively the columns are chosen with a `completing-read-multiple'
selector (the `<<ALL>>' sentinel means every visible column)."
  (interactive
   (let* ((fields (tabularium--highlight-read-fields))
          (hint (tabularium--highlight-columns-hint fields))
          (value (read-string
                  (format "Highlight %s cells equal to: " hint))))
     (list fields value (tabularium--highlight-read-face))))
  (tabularium--highlight-add-rules
   (mapcar (lambda (field)
             (list :scope tabularium--highlight-rule-scope :field field :builtin 'compare
                   :op "=" :operand value :face face))
           fields)))

;;;###autoload
(defun tabularium-view-highlight-datetime (fields op operand face)
  "Highlight cells in FIELDS by a chronological comparison.
FIELDS is a list of column-id symbols; OP is one of the comparison
strings (\"<\", \">\", \"=\"); OPERAND is the ISO date/time compared
against; FACE is the face to apply.

One command covers date, time, and datetime columns, since ISO strings
order chronologically as text.  The prompts adapt their format hint and
validation to the type of the chosen columns.  The highlight
counterpart of `tabularium-view-filter-datetime'; a `range' is
expressed there rather than here, as a highlight rule tests one
comparison at a time."
  (interactive
   (let* ((fields (tabularium--highlight-read-fields
                   '(date time datetime)
                   "Highlight columns [<<ALL>> date/time, or list]: "))
          (hint (tabularium--highlight-columns-hint fields))
          (type (tabularium--datetime-field-type fields))
          (fmt (tabularium--datetime-format-hint type))
          (op-name (completing-read (format "Comparison %s: " hint)
                                    '("before" "after" "exact") nil t))
          (op (pcase op-name ("before" "<") ("after" ">") (_ "=")))
          (operand (tabularium-wizard--read-validated
                    (format "Highlight %s %s [%s]: " hint op-name fmt)
                    type)))
     (list fields op operand (tabularium--highlight-read-face))))
  (tabularium--highlight-add-rules
   (mapcar (lambda (field)
             (list :scope tabularium--highlight-rule-scope :field field :builtin 'compare
                   :op op :operand operand :face face))
           fields)))

(defun tabularium--highlight-sync ()
  "Refresh an open Highlight Rules List buffer, if any.
Called after the highlight rules change (add, remove, undo) so the
list buffer stays in step with the view without a manual `g'."
  (let ((buf (get-buffer "*Highlight Rules List*")))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (derived-mode-p 'tabularium-highlight-mode)
          (let ((saved-n (tabularium--highlight-n-at-point)))
            (tabularium--highlight-refresh)
            (when saved-n
              (tabularium--highlight-goto-n saved-n))))))))

(defun tabularium--highlight-all-rules ()
  "Return all highlight rules as a numbered list, in evaluation order.
Each element is a plist (:n N :rule RULE :saved BOOL).  Saved
schema rules come first — they are the stable, persisted base and
keep their order across sessions — then the runtime rules added
this session; numbering is 1-based and continuous across both
groups, so the number reflects the stacking hierarchy.

Saved rules that have been hidden in this view (see
`tabularium--highlight-suppressed') are omitted — they no longer
take effect and so are not part of the active set."
  (let ((n 0) (out '()))
    (dolist (r (tabularium--highlight-schema-rules))
      (unless (member r tabularium--highlight-suppressed)
        (cl-incf n)
        (push (list :n n :rule r :saved t) out)))
    (dolist (r tabularium--highlight-runtime-rules)
      (cl-incf n)
      (push (list :n n :rule r :saved nil) out))
    (nreverse out)))

(defun tabularium--highlight-face-label (face)
  "Return a display label for FACE, rendered in FACE itself.
Uses the palette name from `tabularium-highlight-faces' (for example
\"bg: Red\") so the label states which attribute the rule sets, and
propertizes it with FACE so the effect is visible directly."
  (if (null face)
      ""
    (let ((name (or (car (rassq face tabularium-highlight-faces))
                    (symbol-name face))))
      (propertize name 'face face))))

(defun tabularium--highlight-entry-label (entry)
  "Return the `completing-read' label for a numbered rule ENTRY.
Includes a swatch of the rule's own face, so the list shows which rule
produces which formatting."
  (let* ((rule (plist-get entry :rule))
         (swatch (tabularium--highlight-face-label (plist-get rule :face))))
    (format "%d. %s%s%s%s"
            (plist-get entry :n)
            (format "%s  " (tabularium--highlight-scope-tag rule))
            (if (string-empty-p swatch) "" (concat swatch "  "))
            (tabularium--highlight-describe-rule rule)
            (if (plist-get entry :saved) "  [saved]" "  [unsaved]"))))

;;;###autoload
(defun tabularium-view-highlight-new ()
  "Add a highlight rule, walking the shared rule-creation prompts.
Asks for the target (rows, columns, or values), then the rule type, then
the set to search, then the operand and face — see
`tabularium--read-rule'.  The target decides what a match tints: the
whole row, the whole column, or just the matching cells.

A column rule considers its eligible columns — every column by default,
or a chosen subset — and tints the ones that match, judged over the rows
named at step three; it is the transpose of a column filter."
  (interactive)
  (let* ((spec (tabularium--read-rule 'highlight))
         (target (plist-get spec :target))
         (face (plist-get spec :face))
         (op (plist-get spec :op))
         (value (plist-get spec :value))
         (builtin (pcase (plist-get spec :rule-type)
                    ("substring" 'regex)
                    ("regexp" 'regex)
                    ("unique" 'unique)
                    ("duplicates" 'duplicates)
                    (_ 'compare)))
         (base (pcase (plist-get spec :rule-type)
                 ("substring" (list :builtin 'regex
                                    :regex (regexp-quote (or value ""))))
                 ("regexp" (list :builtin 'regex :regex value))
                 ("unique" (list :builtin 'unique))
                 ("duplicates" (list :builtin 'duplicates))
                 (_ (list :builtin builtin
                          :op (pcase op
                                ('before "<") ('after ">") ('between "=")
                                ((pred symbolp) (symbol-name op))
                                (_ op))
                          :operand value)))))
    (cond
     ;; Column target: one rule, judged over the searched rows.
     ((equal target "column(s)")
      (tabularium--highlight-add-rules
       (list (append (list :scope 'column :face face) base
                     (when (plist-get spec :rows)
                       (list :rows (plist-get spec :rows)))
                     (when (plist-get spec :columns)
                       (list :columns (plist-get spec :columns)))))))
     ;; Row or value target: one rule per searched column.
     (t
      (let ((scope (if (equal target "row(s)") 'row 'cell))
            ;; Row and value rules alike apply only within these rows.
            (rows (plist-get spec :rows)))
        (tabularium--highlight-add-rules
         (mapcar (lambda (name)
                   (append (list :scope scope :field (intern name) :face face)
                           base
                           (when rows (list :rows rows))))
                 (plist-get spec :fields))))))))

;;;###autoload
(defun tabularium-view-highlight-rows (face)
  "Quick-highlight the marked rows, or the row at point if none are marked.
Prompts only for FACE.  Adds a row-scoped `rows' rule pinned to
those row ids — it appears in the Highlight Rules List like any
other rule and can be removed or saved there.  A fast way to flag
a handful of rows without composing a full rule."
  (interactive (list (tabularium--highlight-read-face)))
  (unless (derived-mode-p 'tabularium-view-mode)
    (user-error "Not in a Tabularium view"))
  (let* ((from-marks (and tabularium--marked-entries t))
         (ids (or tabularium--marked-entries
                  (when-let ((id (tabularium--id-at-point)))
                    (list id)))))
    (unless ids
      (user-error "No marked rows and no row at point"))
    (tabularium--highlight-add-rules
     (list (list :scope 'row :builtin 'rows
                 :row-ids (copy-sequence ids) :face face)))
    ;; The marks have served their purpose — clear them so the next
    ;; operation starts clean.
    (when from-marks
      (setq tabularium--marked-entries nil)
      (tabularium-view--update-mark-display))))

;;;###autoload
(defun tabularium-view-highlight-column (face)
  "Quick-highlight every cell of the column at point.
Prompts only for FACE.  Adds a cell-scoped `all' rule for the
column under point — it appears in the Highlight Rules List like
any other rule.  A fast way to tint a whole column."
  (interactive (list (tabularium--highlight-read-face)))
  (unless (derived-mode-p 'tabularium-view-mode)
    (user-error "Not in a Tabularium view"))
  (let ((col (tabularium--column-name-at-point)))
    (unless col
      (user-error "No column at point"))
    (tabularium--highlight-add-rules
     (list (list :scope 'cell :builtin 'all :field col :face face)))))

;;;###autoload
(defun tabularium-view-highlight-columns (fields face)
  "Quick-highlight every cell of one or more chosen columns.
Prompts for FIELDS with the `<<ALL>>' / comma-separated selector,
then for FACE.  Adds one cell-scoped `all' rule per column; each
appears in the Highlight Rules List."
  (interactive
   (let ((fields (tabularium--highlight-read-fields)))
     (list fields (tabularium--highlight-read-face))))
  (tabularium--highlight-add-rules
   (mapcar (lambda (col)
             (list :scope 'cell :builtin 'all :field col :face face))
           fields)))

;;;###autoload
(defun tabularium-view-highlight-remove (target)
  "Remove highlight rule(s) from the current view.
TARGET is a numbered rule ENTRY plist (see
`tabularium--highlight-all-rules'), or one of two sentinel symbols:

  `all'      remove every rule, runtime and saved;
  `unsaved'  remove every runtime (unsaved) rule.

Interactively every active rule is listed — runtime and saved
alike — each numbered, alongside the `<<ALL>>' sentinel (the
default) and `<<UNSAVED>>'.  Selecting an individual rule removes
just that rule.

Removing a saved rule does not touch the schema file, nor even
the in-memory schema: the rule is merely hidden in this view (see
`tabularium--highlight-suppressed').  Reopening the database
restores every saved rule.  To persist the current view state use
`s' (`tabularium-view-highlight-save'); to permanently discard
every saved rule from the schema file use `X'
\(`tabularium-view-highlight-expunge').  The change is recorded
for undo."
  (interactive
   (let* ((entries (tabularium--highlight-all-rules))
          (entry-alist (mapcar (lambda (e)
                                 (cons (tabularium--highlight-entry-label e)
                                       e))
                               entries))
          (candidates (append '("<<ALL>>" "<<UNSAVED>>")
                              (mapcar #'car entry-alist)))
          (choice (completing-read
                   "Remove highlight [<<ALL>>]: "
                   candidates nil t nil nil "<<ALL>>")))
     (list (cond ((equal choice "<<ALL>>") 'all)
                 ((equal choice "<<UNSAVED>>") 'unsaved)
                 (t (cdr (assoc choice entry-alist)))))))
  (cond
   ((eq target 'all)
    (let* ((entries (tabularium--highlight-all-rules))
           (n (length entries)))
      (if (zerop n)
          (message "No highlight rules to remove")
        (tabularium--highlight-with-undo
          (setq tabularium--highlight-runtime-rules nil)
          ;; Hide every active saved rule — the schema is untouched,
          ;; so a database reload brings them all back.
          (dolist (e entries)
            (when (plist-get e :saved)
              (cl-pushnew (plist-get e :rule)
                          tabularium--highlight-suppressed
                          :test #'equal))))
        (revert-buffer)
        (message "Removed %d highlight rule%s (schema file unchanged)"
                 n (if (= n 1) "" "s")))))
   ((eq target 'unsaved)
    (if (null tabularium--highlight-runtime-rules)
        (message "No unsaved highlight rules to remove")
      (let ((n (length tabularium--highlight-runtime-rules)))
        (tabularium--highlight-with-undo
          (setq tabularium--highlight-runtime-rules nil))
        (revert-buffer)
        (message "Removed %d unsaved highlight rule%s (schema file unchanged)"
                 n (if (= n 1) "" "s")))))
   ((null target)
    (message "No highlight rule selected"))
   (t
    (let ((rule (plist-get target :rule))
          (saved (plist-get target :saved)))
      (tabularium--highlight-with-undo
        (if saved
            ;; Hide the saved rule for this view; the schema keeps it.
            (cl-pushnew rule tabularium--highlight-suppressed
                        :test #'equal)
          (setq tabularium--highlight-runtime-rules
                (delq rule tabularium--highlight-runtime-rules))))
      (revert-buffer)
      (message "Removed 1 highlight rule (schema file unchanged)")))))

;;;###autoload
(defun tabularium-view-highlight-expunge ()
  "Expunge the saved highlight rules from the schema file.
Removes the `:highlight' property from the active schema and
writes the schema file, permanently discarding every saved
highlight rule.  Runtime rules added this session are not touched
\(use `tabularium-view-highlight-remove' for those).  Prompts for
confirmation, since this rewrites the schema file."
  (interactive)
  (let* ((schema-name (tabularium--schema-name))
         (schema (assoc schema-name tabularium-schemas))
         (plist (cdr schema))
         (existing (and plist (plist-get plist :highlight))))
    (unless schema
      (user-error "No schema for the current database"))
    (if (null existing)
        (message "No saved highlight rules to expunge")
      (when (yes-or-no-p
             (format "Expunge %d saved highlight rule%s from the schema? "
                     (length existing)
                     (if (= 1 (length existing)) "" "s")))
        (let ((n (length existing)))
          (setq plist (plist-put plist :highlight nil))
          (setf (cdr schema) plist)
          (tabularium--save-schema-to-file schema-name)
          (revert-buffer)
          (tabularium--highlight-sync)
          (message
           "Expunged %d highlight rule%s (schema file %s updated)"
           n (if (= n 1) "" "s")
           (file-name-nondirectory
            (tabularium-registry--schema-file-for-db
             (plist-get plist :file)))))))))

(defun tabularium--highlight-write-schema (rules)
  "Write RULES as the active schema's `:highlight' and save the file."
  (let* ((schema-name (tabularium--schema-name))
         (schema (assoc schema-name tabularium-schemas)))
    (unless schema
      (user-error "No schema for the current database"))
    (setf (cdr schema)
          (plist-put (cdr schema) :highlight rules))
    (tabularium--save-schema-to-file schema-name)))

;;;###autoload
(defun tabularium-view-highlight-save (rule &optional quiet)
  "Save one runtime highlight RULE into the schema file.
Prompts for one of the rules added this session and persists just
that rule — appending it to the schema's `:highlight' property,
writing the schema file, and dropping it from the runtime stack.
The other runtime rules, and any rules hidden in this view, are
left as they are.

With QUIET non-nil the per-rule confirmation message and the view
refresh are skipped — used when a caller drives this in a loop and
will report and refresh once at the end.

To persist the whole view state at once use
`tabularium-view-highlight-save-all' (bound `h S')."
  (interactive
   (progn
     (unless tabularium--highlight-runtime-rules
       (user-error "No unsaved highlight rules to save"))
     (let* ((rules tabularium--highlight-runtime-rules)
            (alist (let ((i 0))
                     (mapcar (lambda (r)
                               (cl-incf i)
                               (cons (format "%d. %s" i
                                              (tabularium--highlight-describe-rule
                                               r))
                                     r))
                             (reverse rules))))
            (choice (completing-read "Save highlight rule: "
                                     (mapcar #'car alist) nil t)))
       (list (cdr (assoc choice alist))))))
  (unless (memq rule tabularium--highlight-runtime-rules)
    (user-error "Not a current runtime rule"))
  (let* ((schema-name (tabularium--schema-name))
         (schema (assoc schema-name tabularium-schemas))
         (existing (plist-get (cdr schema) :highlight)))
    (tabularium--highlight-write-schema (append existing (list rule)))
    (setq tabularium--highlight-runtime-rules
          (delq rule tabularium--highlight-runtime-rules))
    (unless quiet
      (revert-buffer)
      (tabularium--highlight-sync)
      (message "Saved highlight rule: %s"
               (tabularium--highlight-describe-rule rule)))))

;;;###autoload
(defun tabularium-view-highlight-save-all ()
  "Save the whole view's highlight state into the schema file.
Persists the active highlight set — the schema's existing saved
rules, minus any hidden in this view (see
`tabularium--highlight-suppressed'), plus every runtime rule added
this session — and writes the schema file, so the highlights
persist across sessions the same way `tabularium-view-save'
persists a view.  The runtime stack and the suppressed list are
then cleared, since the saved set now reflects the view.

To save just one runtime rule use `tabularium-view-highlight-save'
\(bound `h s')."
  (interactive)
  (unless (or tabularium--highlight-runtime-rules
              tabularium--highlight-suppressed)
    (user-error "No highlight changes to save"))
  (let* ((schema-name (tabularium--schema-name))
         (schema (assoc schema-name tabularium-schemas))
         (existing (plist-get (cdr schema) :highlight))
         ;; Drop the rules hidden in this view.
         (kept (if tabularium--highlight-suppressed
                   (cl-remove-if
                    (lambda (r) (member r tabularium--highlight-suppressed))
                    existing)
                 existing))
         ;; Runtime rules are most-recent-first; reverse so they append
         ;; in the order they were added, after the kept rules.
         (merged (append kept
                         (reverse tabularium--highlight-runtime-rules)))
         (n-added (length tabularium--highlight-runtime-rules))
         (n-dropped (- (length existing) (length kept))))
    (unless schema
      (user-error "No schema for the current database"))
    (tabularium--highlight-write-schema merged)
    (setq tabularium--highlight-runtime-rules nil)
    (setq tabularium--highlight-suppressed nil)
    (revert-buffer)
    (tabularium--highlight-sync)
    (message "Saved highlight rules to the schema (%d added, %d removed)"
             n-added n-dropped)))

;;; *** 4.7.2 Highlight Rules Buffer

(defvar-local tabularium--highlight-view nil
  "The view buffer whose highlight rules a Highlight Rules buffer edits.")

(defvar-local tabularium--highlight-marks nil
  "List of rule numbers marked for removal in a Highlight Rules buffer.")

(defvar-local tabularium--highlight-first-pos nil
  "Buffer position of the first rule entry, for cursor placement.")

(defvar-local tabularium--highlight-first-line nil
  "Line number of the first rule entry, for bounded cursor motion.")

(defvar-local tabularium--highlight-last-line nil
  "Line number of the last rule entry, for bounded cursor motion.")

(defun tabularium--highlight-refresh ()
  "Redraw the Highlight Rules List buffer from the owning view's rules.
Uses the single-line box ornament — this is a lightweight
`view-mode' side buffer — with key hints faced like the registry
and the cursor left on the first rule."
  (let ((inhibit-read-only t)
        (entries (with-current-buffer tabularium--highlight-view
                   (tabularium--highlight-all-rules)))
        (marks tabularium--highlight-marks)
        (first-pos nil)
        (first-line nil)
        (last-line nil))
    (erase-buffer)
    (insert (tabularium--make-box-header "Highlight Rules List" 80 'single)
            "\n\n")
    (insert (format "  %-3s %-6s %-6s %-16s %s\n"
                    "#" "Saved?" "Type" "Face" "Rule"))
    (insert (propertize (concat "  " (make-string 76 ?─) "\n")
                        'face 'shadow))
    (if (null entries)
        (insert (propertize "  No highlight rules.\n" 'face 'shadow))
      (dolist (entry entries)
        (let* ((n (plist-get entry :n))
               (rule (plist-get entry :rule))
               (saved (plist-get entry :saved))
               (marked (memq n marks))
               (start (point))
               (line (line-number-at-pos start)))
          (unless first-pos
            (setq first-pos start first-line line))
          (setq last-line line)
          (let ((text (format "%s %-3d %-6s %-6s %-16s %s\n"
                              (if marked
                                  (propertize "*" 'face 'tabularium-marked-face)
                                " ")
                              n
                              (if saved "Yes" "No")
                              (tabularium--highlight-scope-tag rule)
                              (tabularium--highlight-face-label
                               (plist-get rule :face))
                              (tabularium--highlight-describe-rule rule))))
            ;; Only override the line face when marked; propertizing with a
            ;; nil face would erase the swatch's own face.
            (when marked
              (setq text (propertize text 'face 'tabularium-marked-face)))
            (insert (propertize text 'tabularium-highlight-n n))))))
    (insert "\n")
    (insert (tabularium--make-box-footer 80 'single) "\n")
    (insert (format "  Total: %d rule%s\n\n"
                    (length entries)
                    (if (= 1 (length entries)) "" "s")))
    (insert "  " (propertize "I" 'face 'help-key-binding) " Insert   "
            (propertize "A" 'face 'help-key-binding) " Add   "
            (propertize "m" 'face 'help-key-binding) " Mark   "
            (propertize "u" 'face 'help-key-binding) " Unmark   "
            (propertize "U" 'face 'help-key-binding) " Unmark all   "
            (propertize "t" 'face 'help-key-binding) " Toggle   "
            (propertize "x" 'face 'help-key-binding) " Remove\n")
    (insert "  " (propertize "TAB" 'face 'help-key-binding) "/"
            (propertize "S-TAB" 'face 'help-key-binding) " Nav   "
            (propertize "M-p" 'face 'help-key-binding) "/"
            (propertize "M-n" 'face 'help-key-binding) " Move   "
            (propertize "RET" 'face 'help-key-binding) " Modify\n")
    (insert "  " (propertize "." 'face 'help-key-binding) " Save   "
            (propertize ">" 'face 'help-key-binding) " Save all   "
            (propertize "X" 'face 'help-key-binding) " Expunge\n")
    (insert "  " (propertize "q" 'face 'help-key-binding) " Quit   "
            (propertize "g" 'face 'help-key-binding) "/"
            (propertize "=" 'face 'help-key-binding) " Refresh\n")
    (setq tabularium--highlight-first-pos
          (or first-pos (point-min)))
    (setq tabularium--highlight-first-line (or first-line 5))
    (setq tabularium--highlight-last-line (or last-line 5))
    (goto-char tabularium--highlight-first-pos)))

(defun tabularium--highlight-n-at-point ()
  "Return the rule number on the current line, or nil."
  (get-text-property (line-beginning-position) 'tabularium-highlight-n))

(defun tabularium--highlight-goto-n (n)
  "Move point to the line of rule number N, if present.
Point is only moved when N is found; return the position, or nil."
  (let ((pos (save-excursion
               (goto-char (point-min))
               (let (found)
                 (while (and (not found) (not (eobp)))
                   (when (eql n (get-text-property (line-beginning-position)
                                                   'tabularium-highlight-n))
                     (setq found (line-beginning-position)))
                   (forward-line 1))
                 found))))
    (when pos (goto-char pos) pos)))

(defun tabularium-highlight-mark ()
  "Mark the highlight rule at point for removal, then advance.
At the last rule, point stays on it rather than leaving the list."
  (interactive)
  (let ((n (tabularium--highlight-n-at-point)))
    (unless n (user-error "No highlight rule at point"))
    (cl-pushnew n tabularium--highlight-marks)
    (tabularium--highlight-refresh)
    (or (tabularium--highlight-goto-n (1+ n))
        (tabularium--highlight-goto-n n))))

(defun tabularium-highlight-unmark ()
  "Unmark the highlight rule at point, then advance.
At the last rule, point stays on it rather than leaving the list."
  (interactive)
  (let ((n (tabularium--highlight-n-at-point)))
    (unless n (user-error "No highlight rule at point"))
    (setq tabularium--highlight-marks
          (delq n tabularium--highlight-marks))
    (tabularium--highlight-refresh)
    (or (tabularium--highlight-goto-n (1+ n))
        (tabularium--highlight-goto-n n))))

(defun tabularium-highlight-unmark-all ()
  "Clear all marks in the Highlight Rules List buffer."
  (interactive)
  (setq tabularium--highlight-marks nil)
  (tabularium--highlight-refresh))

(defun tabularium-highlight-next ()
  "Move to the next rule, respecting bounds."
  (interactive)
  (if (< (line-number-at-pos)
         (or tabularium--highlight-last-line 5))
      (forward-line 1)
    (message "Last rule")))

(defun tabularium-highlight-prev ()
  "Move to the previous rule, respecting bounds."
  (interactive)
  (if (> (line-number-at-pos)
         (or tabularium--highlight-first-line 5))
      (forward-line -1)
    (message "First rule")))

(defun tabularium-highlight-remove ()
  "Remove the marked highlight rules, or the rule at point if none marked."
  (interactive)
  (let* ((nums (or tabularium--highlight-marks
                   (when-let ((n (tabularium--highlight-n-at-point)))
                     (list n))))
         (view tabularium--highlight-view))
    (unless nums (user-error "No highlight rule marked or at point"))
    (with-current-buffer view
      (let* ((entries (tabularium--highlight-all-rules))
             (doomed (cl-remove-if-not
                      (lambda (e) (memq (plist-get e :n) nums))
                      entries)))
        (tabularium--highlight-with-undo
          (dolist (entry doomed)
            (let ((rule (plist-get entry :rule)))
              (if (plist-get entry :saved)
                  ;; Hide the saved rule for this view; the schema
                  ;; keeps it (consistent with `h x').
                  (cl-pushnew rule tabularium--highlight-suppressed
                              :test #'equal)
                (setq tabularium--highlight-runtime-rules
                      (delq rule tabularium--highlight-runtime-rules))))))
        (revert-buffer)))
    (setq tabularium--highlight-marks nil)
    (tabularium--highlight-refresh)
    (message "Removed %d highlight rule%s (schema file unchanged)"
             (length nums) (if (= 1 (length nums)) "" "s"))))

(defun tabularium-highlight-toggle-marks ()
  "Toggle every mark in the Highlight Rules List buffer."
  (interactive)
  (let ((all (mapcar (lambda (e) (plist-get e :n))
                     (with-current-buffer tabularium--highlight-view
                       (tabularium--highlight-all-rules))))
        (n-at (tabularium--highlight-n-at-point)))
    (setq tabularium--highlight-marks
          (cl-set-difference all tabularium--highlight-marks))
    (tabularium--highlight-refresh)
    (when n-at (tabularium--highlight-goto-n n-at))))

(defun tabularium-highlight-new ()
  "Add a new highlight rule from the Highlight Rules List buffer.
Runs `tabularium-view-highlight-new' in the owning view, which
prompts for the rule type."
  (interactive)
  (with-current-buffer tabularium--highlight-view
    (call-interactively #'tabularium-view-highlight-new))
  (tabularium--highlight-refresh))

(defun tabularium-highlight-insert ()
  "Insert a new highlight rule at the rule at point.
Prompts for a rule as `tabularium-highlight-new' does, then places it
at the current line.  A new rule is always an unsaved (runtime) rule
and the saved and unsaved groups are kept distinct, so when point is
on a saved rule the new rule is placed at the head of the unsaved
group — the nearest position it can occupy.  With no rule at point it
simply adds."
  (interactive)
  (let ((n (tabularium--highlight-n-at-point))
        (view tabularium--highlight-view)
        entry saved target before added)
    (with-current-buffer view
      (setq entry (when n (nth (1- n) (tabularium--highlight-all-rules))))
      (setq saved (plist-get entry :saved))
      (setq target (plist-get entry :rule))
      (setq before (length tabularium--highlight-runtime-rules))
      (call-interactively #'tabularium-view-highlight-new)
      (let ((k (- (length tabularium--highlight-runtime-rules) before)))
        (setq added (> k 0))
        ;; New rules are pushed onto the head of the runtime stack; move
        ;; them down to the position of the rule at point in that group.
        (when (and added target (not saved))
          (let* ((runtime tabularium--highlight-runtime-rules)
                 (new-rules (seq-take runtime k))
                 (rest (seq-drop runtime k))
                 (idx (or (cl-position target rest :test #'equal) 0)))
            (setq tabularium--highlight-runtime-rules
                  (append (seq-take rest idx)
                          new-rules
                          (seq-drop rest idx)))
            (revert-buffer)))))
    (tabularium--highlight-refresh)
    (when n (tabularium--highlight-goto-n n))
    (when (and added saved)
      (message "New rules are unsaved; inserted above the unsaved rules"))))

(defun tabularium-highlight-save ()
  "Save the marked highlight rules, or the rule at point if none marked.
Only unsaved (runtime) rules can be saved; a marked rule that is
already saved in the schema is skipped.  To save every rule at
once use `S' (`tabularium-highlight-save-all')."
  (interactive)
  (let* ((nums (or tabularium--highlight-marks
                   (when-let ((n (tabularium--highlight-n-at-point)))
                     (list n))))
         (view tabularium--highlight-view)
         (saved-count 0))
    (unless nums (user-error "No highlight rule marked or at point"))
    (with-current-buffer view
      (let* ((entries (tabularium--highlight-all-rules))
             (chosen (cl-remove-if-not
                      (lambda (e) (memq (plist-get e :n) nums))
                      entries))
             (runtime (cl-remove-if #'(lambda (e) (plist-get e :saved))
                                    chosen)))
        (dolist (entry runtime)
          (let ((rule (plist-get entry :rule)))
            (when (memq rule tabularium--highlight-runtime-rules)
              (tabularium-view-highlight-save rule t)
              (cl-incf saved-count))))
        ;; Refresh the view once, after the whole batch.
        (when (> saved-count 0)
          (revert-buffer))))
    (setq tabularium--highlight-marks nil)
    (tabularium--highlight-refresh)
    (message "Saved %d highlight rule%s%s"
             saved-count (if (= 1 saved-count) "" "s")
             (if (< saved-count (length nums))
                 " (already-saved rules skipped)" ""))))

(defun tabularium-highlight-save-all ()
  "Save the whole view's highlight state from the rules list buffer."
  (interactive)
  (with-current-buffer tabularium--highlight-view
    (call-interactively #'tabularium-view-highlight-save-all))
  (tabularium--highlight-refresh))

(defun tabularium-highlight-expunge ()
  "Expunge the marked rules, or the rule at point if none are marked.
Permanently discards the selected rules: saved rules are removed
from the schema's `:highlight' property and the schema file is
rewritten; runtime (unsaved) rules are dropped from the session
stack.  Unlike `x' (remove), expunge has no safety net — a saved
rule expunged here does not return on a database reload.  Prompts
once for confirmation."
  (interactive)
  (let* ((nums (or tabularium--highlight-marks
                   (when-let ((n (tabularium--highlight-n-at-point)))
                     (list n))))
         (view tabularium--highlight-view))
    (unless nums (user-error "No highlight rule marked or at point"))
    (with-current-buffer view
      (let* ((entries (tabularium--highlight-all-rules))
             (chosen (cl-remove-if-not
                      (lambda (e) (memq (plist-get e :n) nums))
                      entries))
             (saved-rules (mapcar (lambda (e) (plist-get e :rule))
                                  (cl-remove-if-not
                                   (lambda (e) (plist-get e :saved))
                                   chosen)))
             (runtime-rules (mapcar (lambda (e) (plist-get e :rule))
                                    (cl-remove-if
                                     (lambda (e) (plist-get e :saved))
                                     chosen)))
             (total (+ (length saved-rules) (length runtime-rules))))
        (when (yes-or-no-p
               (format "Expunge %d highlight rule%s%s? "
                       total (if (= 1 total) "" "s")
                       (if saved-rules
                           (format " (%d from the schema file)"
                                   (length saved-rules))
                         "")))
          (when saved-rules
            (tabularium--highlight-write-schema
             (cl-remove-if (lambda (r) (member r saved-rules))
                           (tabularium--highlight-schema-rules))))
          (when runtime-rules
            (setq tabularium--highlight-runtime-rules
                  (cl-remove-if (lambda (r) (member r runtime-rules))
                                tabularium--highlight-runtime-rules)))
          (revert-buffer)
          (message "Expunged %d highlight rule%s%s"
                   total (if (= 1 total) "" "s")
                   (if saved-rules " (schema file updated)" "")))))
    (setq tabularium--highlight-marks nil)
    (tabularium--highlight-refresh)))

(defun tabularium-highlight-revert ()
  "Refresh the Highlight Rules List buffer."
  (interactive)
  (tabularium--highlight-refresh))

(defun tabularium--highlight-move (direction)
  "Move the rule at point one step in DIRECTION (`up' or `down').
Reordering happens within the rule's own group — saved rules
reorder among the saved rules, runtime rules among the runtime
rules — since the saved/runtime boundary is meaningful.  Crossing
it would mean saving or unsaving, which `s' and `x' handle."
  (let ((n (tabularium--highlight-n-at-point))
        (view tabularium--highlight-view))
    (unless n (user-error "No highlight rule at point"))
    (with-current-buffer view
      (let* ((entries (tabularium--highlight-all-rules))
             (entry (nth (1- n) entries))
             (saved (plist-get entry :saved))
             (group (if saved
                        (cl-remove-if-not (lambda (e) (plist-get e :saved))
                                          entries)
                      (cl-remove-if (lambda (e) (plist-get e :saved))
                                     entries)))
             ;; Index of this rule within its own group.
             (gi (cl-position n group :key (lambda (e) (plist-get e :n))))
             (gj (if (eq direction 'up) (1- gi) (1+ gi))))
        (when (or (< gj 0) (>= gj (length group)))
          (user-error "Cannot move %s any further within the %s rules"
                      direction (if saved "saved" "unsaved")))
        (let* ((rules (mapcar (lambda (e) (plist-get e :rule)) group))
               (tmp (nth gi rules)))
          (setf (nth gi rules) (nth gj rules))
          (setf (nth gj rules) tmp)
          (if saved
              (tabularium--highlight-write-schema rules)
            ;; The runtime group is displayed in storage order, so it is
            ;; stored back as-is; reversing here would scramble the group.
            (setq tabularium--highlight-runtime-rules rules)))
        (revert-buffer)))
    (tabularium--highlight-refresh)
    (tabularium--highlight-goto-n (if (eq direction 'up) (1- n) (1+ n)))))

(defun tabularium-highlight-move-up ()
  "Move the highlight rule at point one position earlier in its group."
  (interactive)
  (tabularium--highlight-move 'up))

(defun tabularium-highlight-move-down ()
  "Move the highlight rule at point one position later in its group."
  (interactive)
  (tabularium--highlight-move 'down))

(defun tabularium-highlight-modify ()
  "Re-enter the highlight rule at point.
Removes the rule and restarts `tabularium-view-highlight-new' from the
top, so the scope — row(s), column(s), or value(s) — is asked again
along with the type, columns, operands, and face.  A saved rule being
modified is first hidden (the schema is untouched until you save
again); the replacement is a new runtime rule."
  (interactive)
  (let ((n (tabularium--highlight-n-at-point))
        (view tabularium--highlight-view))
    (unless n (user-error "No highlight rule at point"))
    (with-current-buffer view
      (let* ((entry (nth (1- n) (tabularium--highlight-all-rules)))
             (rule (plist-get entry :rule))
             (saved (plist-get entry :saved)))
        (if saved
            (cl-pushnew rule tabularium--highlight-suppressed :test #'equal)
          (setq tabularium--highlight-runtime-rules
                (cl-remove rule tabularium--highlight-runtime-rules
                           :test #'equal :count 1)))
        (revert-buffer)
        (call-interactively #'tabularium-view-highlight-new)))
    (tabularium--highlight-refresh)))

(defvar tabularium-highlight-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "A") #'tabularium-highlight-new)
    (define-key map (kbd "I") #'tabularium-highlight-insert)
    (define-key map (kbd "m") #'tabularium-highlight-mark)
    (define-key map (kbd "u") #'tabularium-highlight-unmark)
    (define-key map (kbd "U") #'tabularium-highlight-unmark-all)
    (define-key map (kbd "t") #'tabularium-highlight-toggle-marks)
    (define-key map (kbd "x") #'tabularium-highlight-remove)
    (define-key map (kbd "RET") #'tabularium-highlight-modify)
    (define-key map (kbd "M-p") #'tabularium-highlight-move-up)
    (define-key map (kbd "M-n") #'tabularium-highlight-move-down)
    (define-key map (kbd "M-<up>") #'tabularium-highlight-move-up)
    (define-key map (kbd "M-<down>") #'tabularium-highlight-move-down)
    (define-key map (kbd ".") #'tabularium-highlight-save)
    (define-key map (kbd ">") #'tabularium-highlight-save-all)
    (define-key map (kbd "X") #'tabularium-highlight-expunge)
    (define-key map (kbd "g") #'tabularium-highlight-revert)
    (define-key map (kbd "=") #'tabularium-highlight-revert)
    (define-key map (kbd "n") #'tabularium-highlight-next)
    (define-key map (kbd "p") #'tabularium-highlight-prev)
    (define-key map (kbd "TAB") #'tabularium-highlight-next)
    (define-key map (kbd "<backtab>") #'tabularium-highlight-prev)
    (define-key map (kbd "<down>") #'tabularium-highlight-next)
    (define-key map (kbd "<up>") #'tabularium-highlight-prev)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `tabularium-highlight-mode'.")

(define-derived-mode tabularium-highlight-mode special-mode
  "Tabularium-Highlight"
  "Major mode for the interactive Highlight Rules List buffer.
Lists every highlight rule for a view — runtime (unsaved) rules
and schema-saved rules alike — numbered in evaluation order.
Rules can be marked and removed, new rules added, and the runtime
set saved to the schema, all without leaving the buffer."
  (setq-local revert-buffer-function
              (lambda (&rest _) (tabularium--highlight-refresh))))

;;;###autoload
(defun tabularium-view-highlight-buffer ()
  "Open the interactive Highlight Rules List buffer for the current view.
Lists every highlight rule numbered in evaluation order, with
keys to mark and remove rules, add new ones, and save the runtime
set to the schema."
  (interactive)
  (unless (derived-mode-p 'tabularium-view-mode)
    (user-error "Not in a Tabularium view"))
  (let ((view (current-buffer))
        (buf (get-buffer-create "*Highlight Rules List*")))
    (with-current-buffer buf
      (tabularium-highlight-mode)
      (setq tabularium--highlight-view view)
      (setq tabularium--highlight-marks nil)
      (tabularium--highlight-refresh))
    (pop-to-buffer buf)
    ;; Position the cursor on the first rule after display, so
    ;; redisplay does not reset window-point back to point-min.
    (with-current-buffer buf
      (goto-char (or tabularium--highlight-first-pos (point-min))))))

;;; * 5 View & Navigation

;;; ** 5.1 View Core Functions

(defvar-local tabularium--column-rule-hidden nil
  "Columns hidden by column-scoped filter rules in this buffer.
Recomputed on every refresh from the fetched rows, unlike
`tabularium--hidden-columns\=', which the user sets directly.")

(defun tabularium-view--field-visible-p (field)
  "Return non-nil if FIELD should be visible.
A field is hidden when the user hid it or when a column-scoped filter
rule rejected it on this refresh."
  (let ((name (plist-get field :id)))
    (and (not (plist-get field :hidden))
         (not (memq name tabularium--hidden-columns))
         (not (memq name tabularium--column-rule-hidden)))))

(defun tabularium-view--ordered-visible-fields ()
  "Return visible fields in display order."
  (let* ((schema-fields (tabularium--schema-fields))
         (ordered (if tabularium--column-order
                      (cl-remove-if
                       #'null
                       (mapcar (lambda (name)
                                 (cl-find-if (lambda (f) (eq (plist-get f :id) name))
                                             schema-fields))
                               tabularium--column-order))
                    schema-fields)))
    (cl-remove-if-not #'tabularium-view--field-visible-p ordered)))

(defun tabularium-view--setup-columns ()
  "Set up tabulated list columns from schema.
Active sort columns get a `↑'/`↓' indicator appended to their label,
faced with `tabularium-sort-indicator-face'."
  (let* ((visible-fields (tabularium-view--ordered-visible-fields))
         (sort-cols tabularium--sort-columns)
         (base-columns
          (mapcar (lambda (field)
                    (let* ((id (plist-get field :id))
                           (label (plist-get field :label))
                           (entry (assq id sort-cols))
                           (arrow (and entry
                                       (if (eq (cdr entry) 'asc) "↑" "↓")))
                           (decorated
                            (if arrow
                                (concat label " "
                                        (propertize
                                         arrow 'face
                                         'tabularium-sort-indicator-face))
                              label))
                           ;; Reserve space for the arrow if present, so
                           ;; the indicator doesn't push neighbors.
                           (base-width (or (plist-get field :width) 15))
                           (width (if arrow (+ base-width 2) base-width)))
                      ;; Sorter slot is nil: Tabularium drives sorting
                      ;; itself via `tabularium--sort-columns'.  Leaving
                      ;; it non-nil would make tabulated-list draw its
                      ;; own ▲/▼ indicator alongside our ↑/↓ and install
                      ;; a competing click handler.
                      (list decorated width nil)))
                  visible-fields))
         ;; Add freeze indicator column if there are frozen rows
         (format-spec
          (vconcat
           (if tabularium--frozen-ids
               (cons (list "∙" 1 nil) base-columns)
             base-columns))))
    (setq tabulated-list-format format-spec)
    (setq tabulated-list-sort-key nil)  ; We handle sorting ourselves
    (setq tabulated-list-padding 1)
    (tabulated-list-init-header)))

(defun tabularium--view-cell-descriptor (display face)
  "Return a tabulated-list cell descriptor for DISPLAY carrying FACE.
When FACE is non-nil the text is returned as a *propertized string*,
never a (LABEL . PROPS) list.  `tabulated-list-mode' renders any
non-string column descriptor as a clickable text button (via
`insert-text-button'); such a button carries the button keymap, and
because `tabulated-list-mode-map' inherits `button-buffer-map' the
button's `<backtab>' is `backward-button' — so backward-cell motion
over a highlighted (faced) cell jumps to the previous button instead
of the previous column, and the echo area shows the button's
\"mouse-2, RET: Push this button\" help.  A propertized string applies
the face without making the cell a button.  FACE may itself be a list
of faces (stacked highlights); `propertize' handles that directly."
  (if face (propertize display 'face face) display))

(defun tabularium-view--refresh ()
  "Refresh the list from database."
  (tabularium--ensure-db)
  ;; Column rules are judged over the values actually fetched, so every
  ;; candidate column is queried and the rejected ones are dropped from the
  ;; display below.  Clearing the set first keeps the previous refresh's
  ;; verdict from narrowing this one's evidence.
  (setq tabularium--column-rule-hidden nil)
  (tabularium-view--setup-columns)
  (let* ((visible-fields (tabularium-view--ordered-visible-fields))
         (field-names (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                              visible-fields))
         (primary-name (symbol-name (tabularium--primary-field-name)))
         ;; Build WHERE clause combining filter and ID range
         ;; When a filter rule or sort key names an elisp-computed field the
         ;; work happens in Emacs after the fetch.  The whole filter stack
         ;; then moves there — splitting it would be wrong for `OR' —
         ;; leaving only the row restriction in SQL.
         (post-fetch (tabularium--post-fetch-p))
         (where-parts (delq nil
                            (list
                             (unless post-fetch
                               (tabularium--build-filter-clause))
                             (tabularium--view-id-range-clause primary-name))))
         (where (if where-parts
                    (format "WHERE %s" (string-join where-parts " AND "))
                  ""))
         (order-clause (tabularium--build-order-clause))
         ;; Build SELECT with computed SQL expressions where applicable
         (computed-select (tabularium--build-select-with-computed visible-fields))
         ;; Always include primary key for row identification
         (select-fields (if (member primary-name computed-select)
                            computed-select
                          (cons primary-name computed-select)))
         ;; Identify elisp-computed fields for post-processing
         (elisp-computed (cl-remove-if-not
                          (lambda (f)
                            (and (tabularium--computed-field-p f)
                                 (not (tabularium--computed-sql-expression f))))
                          visible-fields))
         ;; Stored columns an elisp-computed field may depend on that the
         ;; user has hidden.  Gathered only when an elisp-computed field is
         ;; present, fetched as extra trailing SELECT items so the
         ;; computation can see them, then trimmed off each row before
         ;; display.  SQL-expression computed fields are unaffected: their
         ;; expression is evaluated by the database regardless of the
         ;; SELECT list.
         (context-fields
          (when elisp-computed
            (let ((primary (tabularium--primary-field-name))
                  (visible-ids (mapcar (lambda (f) (plist-get f :id))
                                       visible-fields)))
              (cl-remove-if
               (lambda (f)
                 (or (tabularium--computed-field-p f)
                     (memq (plist-get f :id) visible-ids)
                     (eq (plist-get f :id) primary)))
               (tabularium--schema-fields)))))
         (context-names (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                                context-fields))
         ;; Use custom limit or default page size
         (page-limit (or tabularium--view-limit tabularium-view-page-size))
         ;; Post-fetch work must see every candidate row, so the page limit
         ;; is applied afterwards and the fetch is bounded by the cap.
         (limit (if post-fetch tabularium-post-fetch-row-cap page-limit))
         (sql (format "SELECT %s FROM %s %s ORDER BY %s LIMIT %d"
                      (string-join (append select-fields context-names) ", ")
                      tabularium-table-name
                      where
                      order-clause
                      limit))
         (rows (tabularium-db-query tabularium--db sql))
         ;; If primary key was not in visible fields, strip it from display
         (display-offset (if (member primary-name field-names) 0 1))
         ;; Separate frozen and regular rows
         (frozen-rows '())
         (regular-rows '())
         ;; Build a set of long-field column indices for fast lookup
         (long-indices (let ((idx -1))
                         (delq nil (mapcar (lambda (f)
                                            (cl-incf idx)
                                            (when (plist-get f :long) idx))
                                          visible-fields))))
         ;; Resolve the active highlight rules once for this whole
         ;; refresh and memoize them, so the row/cell face resolvers do
         ;; not rebuild the identical list once per cell.  `cf-active'
         ;; is then just a non-nil check on the memoized list.
         (tabularium--cf-rules-cache (tabularium--compute-cf-rules))
         (cf-active (and tabularium--cf-rules-cache t)))
    ;; Reset row-face map for this refresh; populated below as rows are
    ;; partitioned.  Consumed by `tabularium-view--update-cf-display'.
    (setq tabularium--cf-row-faces
          (if cf-active (make-hash-table :test 'equal) nil))
    (when (and post-fetch (>= (length rows) tabularium-post-fetch-row-cap))
      (user-error
       "Filtering or sorting by a computed column needs more than %d rows; raise `tabularium-post-fetch-row-cap'"
       tabularium-post-fetch-row-cap))
    ;; Apply elisp computed fields if any
    (when elisp-computed
      (setq rows (tabularium--apply-elisp-computed rows visible-fields
                                                elisp-computed display-offset
                                                context-fields))
      ;; Drop the trailing context columns now that computation is done.
      (when context-fields
        (let ((keep (+ display-offset (length visible-fields))))
          (setq rows (mapcar (lambda (r) (cl-subseq r 0 keep)) rows)))))
    ;; Now that computed values exist, run the filter and sort here.
    (when post-fetch
      (setq rows (tabularium--post-fetch-process
                  rows visible-fields display-offset page-limit)))
    ;; Column-scoped rules select which columns survive, judged over the
    ;; rows that made it through.  Rejected columns are dropped from the
    ;; field list, from every row, and from the header.
    (when (tabularium--column-filter-rules)
      (let ((drop (tabularium--column-rules-drop
                   rows visible-fields display-offset)))
        (setq tabularium--column-rule-hidden drop)
        (when drop
          (let ((keep-idx (cl-loop for f in visible-fields
                                   for i from 0
                                   unless (memq (plist-get f :id) drop)
                                   collect i)))
            (setq visible-fields
                  (cl-remove-if (lambda (f) (memq (plist-get f :id) drop))
                                visible-fields))
            (setq rows
                  (mapcar (lambda (r)
                            (append (seq-take r display-offset)
                                    (mapcar (lambda (i)
                                              (nth (+ display-offset i) r))
                                            keep-idx)))
                          rows))
            (setq long-indices
                  (let ((i -1))
                    (delq nil (mapcar (lambda (f)
                                        (cl-incf i)
                                        (when (plist-get f :long) i))
                                      visible-fields))))
            (tabularium-view--setup-columns)))))
    ;; Resolve column-scoped highlight rules once for this refresh.
    (setq tabularium--highlight-column-faces
          (when cf-active
            (tabularium--highlight-column-face-alist
             (tabularium--cf-rules) rows visible-fields display-offset)))
    ;; Build the duplicate-value cache for any active `duplicates'
    ;; highlight rule.  One pass over the fetched rows per refresh; the
    ;; cell-face path then does an O(1) lookup.  Skipped entirely when
    ;; no duplicate rule is active.
    (setq tabularium--highlight-dup-cache
          (let ((dup-fields
                 (delq nil
                       (mapcar (lambda (r)
                                 (and (memq (plist-get r :builtin)
                                            '(duplicates unique))
                                      (eq (plist-get r :scope) 'cell)
                                      (plist-get r :field)))
                               (and cf-active (tabularium--cf-rules))))))
            ;; (tabularium--cf-rules here returns the per-refresh memo.)
            (when dup-fields
              (let ((cache (make-hash-table :test 'eq)))
                (dolist (field dup-fields)
                  (let ((counts (make-hash-table :test 'equal))
                        (col-idx (cl-position
                                  field visible-fields
                                  :key (lambda (f) (plist-get f :id)))))
                    (when col-idx
                      (dolist (row rows)
                        (let* ((v (nth (+ display-offset col-idx) row))
                               (s (if v (format "%s" v) "")))
                          (unless (string-empty-p (string-trim s))
                            (puthash s (1+ (or (gethash s counts) 0))
                                     counts)))))
                    (puthash field counts cache)))
                cache))))
    ;; Cell formatter: sanitize long fields for tabulated display and
    ;; apply cell-scoped highlight faces when active.
    (cl-flet ((format-cells (row)
               (let* ((values (nthcdr display-offset row))
                      (row-alist (and cf-active
                                      (tabularium--cf-row-alist
                                       row visible-fields display-offset)))
                      (idx -1))
                 (mapcar (lambda (v)
                           (cl-incf idx)
                           (let* ((s (format "%s" (or v "")))
                                  (display
                                   (if (memq idx long-indices)
                                       ;; Strip newlines, truncate
                                       (let ((clean (replace-regexp-in-string
                                                     "[\n\r]+" " " s)))
                                         (if (> (length clean) 60)
                                             (concat (substring clean 0 57) "...")
                                           clean))
                                     s))
                                  (cell-face
                                   (and cf-active
                                        (tabularium--cf-cell-face
                                         (plist-get (nth idx visible-fields) :id)
                                         v row-alist))))
                             (tabularium--view-cell-descriptor display cell-face)))
                         values))))
    ;; Partition rows into frozen and regular
    (dolist (row rows)
      (when cf-active
        (let* ((row-alist (tabularium--cf-row-alist
                           row visible-fields display-offset))
               (face (tabularium--cf-row-face row-alist)))
          (when face
            (puthash (car row) face tabularium--cf-row-faces))))
      (if (member (car row) tabularium--frozen-ids)
          (push row frozen-rows)
        (push row regular-rows)))
    ;; Fetch any frozen rows that were not in the query results
    (dolist (fid tabularium--frozen-ids)
      (unless (cl-find-if (lambda (r) (equal (car r) fid)) frozen-rows)
        (let* ((fsql (format "SELECT %s FROM %s WHERE %s = ?"
                             (string-join (append select-fields context-names) ", ")
                             tabularium-table-name primary-name))
               (frow (tabularium-db-query-single tabularium--db fsql (list fid))))
          (when frow
            ;; Apply elisp computed to frozen row too
            (when elisp-computed
              (setq frow (car (tabularium--apply-elisp-computed
                               (list frow) visible-fields
                               elisp-computed display-offset
                               context-fields)))
              (when context-fields
                (setq frow (cl-subseq
                            frow 0 (+ display-offset (length visible-fields))))))
            (when cf-active
              (let* ((row-alist (tabularium--cf-row-alist
                                 frow visible-fields display-offset))
                     (face (tabularium--cf-row-face row-alist)))
                (when face
                  (puthash (car frow) face tabularium--cf-row-faces))))
            (push frow frozen-rows)))))
    ;; Build entries with frozen rows first
    (setq tabulated-list-entries
          (append
           ;; Frozen rows with indicator
           (mapcar (lambda (row)
                     (list (car row)
                           (vconcat
                            (cons (propertize "∙" 'face 'tabularium-frozen-row-face)
                                  (format-cells row)))))
                   (nreverse frozen-rows))
           ;; Regular rows (with empty indicator column if there are frozen rows)
           (mapcar (lambda (row)
                     (let ((values (format-cells row)))
                       (list (car row)
                             (vconcat
                              (if tabularium--frozen-ids
                                  (cons "" values)
                                values)))))
                   (nreverse regular-rows)))))))

;;;###autoload
(defun tabularium-view ()
  "Open the record browser.
If a default view is defined in the schema, it will be applied automatically.

Re-opening the browser while the database is still open reuses the
existing buffer and keeps its current view — sort, filters, hidden
columns and rows — intact.  Only a first open, or a reopen after
the database has been closed (which discards the buffer), applies
the schema's default view."
  (interactive)
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (buf (get-buffer-create (format "*%s*" schema-name))))
    (with-current-buffer buf
      ;; A buffer already in `tabularium-view-mode' carries live view
      ;; state; initialise (which wipes buffer-locals via the mode's
      ;; `kill-all-local-variables') only on a genuinely fresh buffer,
      ;; so a quit/bury and reopen preserves sort/filter/hidden state.
      (when (not (derived-mode-p 'tabularium-view-mode))
        (tabularium-view-mode)
        (setq-local tabularium--buffer-schema-name schema-name)
        (tabularium--apply-default-view))
      (tabularium-view--refresh)
      (tabulated-list-print)
      (tabularium-view--update-cf-display)
      (tabularium-view--update-frozen-display))
    (switch-to-buffer buf)))

;;;###autoload
(defun tabularium-view-refresh ()
  "Refresh the view buffer and reload the schema from disk.
If a named view is active, re-applies it from the freshly-loaded
schema so that changes to view definitions take effect."
  (interactive)
  (let* ((schema-name (or tabularium--buffer-schema-name
                          tabularium--current-schema-name))
         (schema (assoc schema-name tabularium-schemas))
         (db-file (plist-get (cdr schema) :file))
         (schema-file (when db-file
                        (tabularium-registry--schema-file-for-db db-file)))
         (active-view-name tabularium--current-view))
    (when (and schema-file (file-exists-p schema-file))
      (load-file schema-file))
    (tabularium--invalidate-cache)
    ;; Re-apply the active view from the (possibly updated) schema
    (when active-view-name
      (let ((updated-view (cl-find-if
                           (lambda (v) (equal (plist-get v :name) active-view-name))
                           (tabularium--schema-views))))
        (if updated-view
            ;; Re-apply view (sets hidden-columns, filters, sort from new definition)
            (let ((columns (plist-get updated-view :columns))
                  (filter (plist-get updated-view :filter))
                  (sort-spec (plist-get updated-view :sort))
                  (rows (plist-get updated-view :rows)))
              (setq tabularium--filter-rules
                    (when filter
                      (list (list :raw t :sql filter :desc active-view-name :connective nil))))
              (when columns
                (let ((all-fields (mapcar (lambda (f) (plist-get f :id))
                                          (tabularium--schema-fields))))
                  (setq tabularium--hidden-columns
                        (cl-remove-if (lambda (col) (memq col columns)) all-fields)))
                (setq tabularium--column-order columns))
              (setq tabularium--view-id-range rows)
              (when rows
                (setq tabularium--view-limit most-positive-fixnum))
              (when sort-spec
                (setq tabularium--sort-columns
                      (if (and (consp (car sort-spec)) (symbolp (caar sort-spec)))
                          sort-spec
                        (list sort-spec)))))
          ;; View no longer exists in schema — clear it
          (setq tabularium--current-view nil)
          (setq mode-name "Tabularium"))))
    (revert-buffer)
    (message "View refreshed%s"
             (if schema-file
                 (format " (schema reloaded from %s)" (file-name-nondirectory schema-file))
               ""))))

(defun tabularium--id-at-point ()
  "Get record ID at point in list view."
  (when (derived-mode-p 'tabularium-view-mode)
    (tabulated-list-get-id)))

(defun tabularium-view-entry ()
  "View record at point."
  (interactive)
  (when-let ((id (tabularium--id-at-point)))
    (tabularium-new-entry id)))

(defun tabularium-view-edit (&optional use-alt-method)
  "Edit record at point using preferred entry method.
With prefix argument USE-ALT-METHOD, use the alternative entry method.
See `tabularium-entry-method' to set the default."
  (interactive "P")
  (when-let ((id (tabularium--id-at-point)))
    (tabularium--edit-with-method id use-alt-method)
    (unless (tabularium--use-form-p use-alt-method)
      (revert-buffer))))

;;; ** 5.2 Tabulated List View

(defface tabularium-list-header-face
  '((t :inherit header-line))
  "Face for the column-header line in `tabularium-view-mode'.
Applied via `face-remap-add-relative' on `header-line' when the
mode is entered, so it inherits from `header-line' by default and
can be customized without affecting unrelated buffers."
  :group 'tabularium-faces)

(defvar tabularium-view-mode-map
  (let ((map (make-sparse-keymap)))

    ;; === Navigation ===
    (define-key map (kbd "RET") #'tabularium-view-entry)
    (define-key map (kbd "g") #'tabularium-view-refresh)
    (define-key map (kbd "=") #'tabularium-view-refresh)
    (define-key map (kbd "/") #'tabularium-find)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    ;; First/last row
    (define-key map (kbd "{") #'tabularium-view-first-row)
    (define-key map (kbd "}") #'tabularium-view-last-row)
    (define-key map (kbd "M-<") #'tabularium-view-first-row)
    (define-key map (kbd "M->") #'tabularium-view-last-row)
    ;; Line beginning/end
    (define-key map (kbd "[") #'tabularium-view-beginning-of-line)
    (define-key map (kbd "]") #'tabularium-view-end-of-line)
    ;; Cell navigation
    (define-key map (kbd "TAB") #'tabularium-view-forward-cell)
    (define-key map (kbd "<backtab>") #'tabularium-view-backward-cell)
    (define-key map (kbd "M-f") #'tabularium-view-forward-cell)
    (define-key map (kbd "M-b") #'tabularium-view-backward-cell)
    ;; Cell-jump navigation
    (define-key map (kbd "M-n") #'tabularium-view-cell-jump-down)
    (define-key map (kbd "M-p") #'tabularium-view-cell-jump-up)
    (define-key map (kbd "M-]") #'tabularium-view-cell-jump-forward)
    (define-key map (kbd "M-[") #'tabularium-view-cell-jump-backward)
    (define-key map (kbd "M-}") #'tabularium-view-cell-jump-down)
    (define-key map (kbd "M-{") #'tabularium-view-cell-jump-up)
    (define-key map (kbd "M-<down>") #'tabularium-view-cell-jump-down)
    (define-key map (kbd "M-<up>") #'tabularium-view-cell-jump-up)
    (define-key map (kbd "M-<right>") #'tabularium-view-cell-jump-forward)
    (define-key map (kbd "M-<left>") #'tabularium-view-cell-jump-backward)
    (define-key map (kbd "C-<down>") #'tabularium-view-page-down)
    (define-key map (kbd "C-<up>") #'tabularium-view-page-up)
    (define-key map (kbd "C-<right>") #'tabularium-view-scroll-column-right)
    (define-key map (kbd "C-<left>") #'tabularium-view-scroll-column-left)
    ;; Filter
    (define-key map (kbd "f a") #'tabularium-view-filter-add)
    (define-key map (kbd "f f") #'tabularium-view-filter-at-point)
    (define-key map (kbd "f s") #'tabularium-view-filter-substring)
    (define-key map (kbd "f e") #'tabularium-view-filter-exact)
    (define-key map (kbd "f n") #'tabularium-view-filter-numeric)
    (define-key map (kbd "f t") #'tabularium-view-filter-datetime)
    (define-key map (kbd "f r") #'tabularium-view-filter-regexp)
    (define-key map (kbd "| /") #'tabularium-view-select-columns)
    (define-key map (kbd "f |") #'tabularium-view-filter-column)
    (define-key map (kbd "f d") #'tabularium-view-filter-duplicates)
    (define-key map (kbd "f u") #'tabularium-view-filter-unique)
    (define-key map (kbd "f l") #'tabularium-view-filter-buffer)
    (define-key map (kbd "f c") #'tabularium-view-filter-cycle-connective)
    (define-key map (kbd "f x") #'tabularium-view-filter-remove)
    (define-key map (kbd "f X") #'tabularium-view-filter-remove-all)
    ;; Fill operations
    (define-key map (kbd "F f") #'tabularium-view-fill-forward)
    (define-key map (kbd "F F") #'tabularium-view-fill-backward)
    (define-key map (kbd "F n") #'tabularium-view-fill-down)
    (define-key map (kbd "F p") #'tabularium-view-fill-up)
    (define-key map (kbd "F ,") #'tabularium-view-fill-up-to-point)
    (define-key map (kbd "F .") #'tabularium-view-fill-down-to-point)
    (define-key map (kbd "F s") #'tabularium-view-fill-series)
    (define-key map (kbd "F S") #'tabularium-view-fill-series-up)
    (define-key map (kbd "F d") #'tabularium-view-fill-delete)
    (define-key map (kbd "F D") #'tabularium-view-fill-delete-up)
    (define-key map (kbd "F r") #'tabularium-view-fill-replace)
    (define-key map (kbd "F R") #'tabularium-view-fill-replace-up)
    (define-key map (kbd "F x") #'tabularium-view-fill-clear-to-point)
    (define-key map (kbd "F X") #'tabularium-view-fill-clear)
    ;; Highlight (conditional formatting) — `h' prefix.  Each command
    ;; prompts for the target columns with a completing-read-multiple
    ;; selector (the `<<ALL>>' sentinel selects every visible column),
    ;; the same field-selection paradigm the filter and mark commands
    ;; use.  Key convention: `r' regexp, `x' remove, `X' expunge.
    (define-key map (kbd "h h") #'tabularium-view-highlight-rows)
    (define-key map (kbd "h \\") #'tabularium-view-highlight-column)
    (define-key map (kbd "h |") #'tabularium-view-highlight-columns)
    (define-key map (kbd "h a") #'tabularium-view-highlight-new)
    (define-key map (kbd "h n") #'tabularium-view-highlight-numeric)
    (define-key map (kbd "h d") #'tabularium-view-highlight-duplicates)
    (define-key map (kbd "h u") #'tabularium-view-highlight-unique)
    (define-key map (kbd "h r") #'tabularium-view-highlight-regexp)
    (define-key map (kbd "h s") #'tabularium-view-highlight-substring)
    (define-key map (kbd "h e") #'tabularium-view-highlight-exact)
    (define-key map (kbd "h t") #'tabularium-view-highlight-datetime)
    (define-key map (kbd "h l") #'tabularium-view-highlight-buffer)
    (define-key map (kbd "h x") #'tabularium-view-highlight-remove)
    (define-key map (kbd "h X") #'tabularium-view-highlight-expunge)
    (define-key map (kbd "h .") #'tabularium-view-highlight-save)
    (define-key map (kbd "h >") #'tabularium-view-highlight-save-all)
    ;; View management
    (define-key map (kbd "v v") #'tabularium-select-view)
    (define-key map (kbd "v .") #'tabularium-view-save)
    (define-key map (kbd "v 0") #'tabularium-view-0)
    (define-key map (kbd "v x") #'tabularium-view-clear)
    (define-key map (kbd "v 1") #'tabularium-view-1)
    (define-key map (kbd "v 2") #'tabularium-view-2)
    (define-key map (kbd "v 3") #'tabularium-view-3)
    (define-key map (kbd "v 4") #'tabularium-view-4)
    (define-key map (kbd "v 5") #'tabularium-view-5)
    (define-key map (kbd "v 6") #'tabularium-view-6)
    (define-key map (kbd "v 7") #'tabularium-view-7)
    (define-key map (kbd "v 8") #'tabularium-view-8)
    (define-key map (kbd "v 9") #'tabularium-view-9)
    ;; Marking
    (define-key map (kbd "m") #'tabularium-view-mark)
    (define-key map (kbd "u") #'tabularium-view-unmark)
    (define-key map (kbd "U") #'tabularium-view-unmark-all)
    (define-key map (kbd "t") #'tabularium-view-toggle-marks)
    (define-key map (kbd "x") #'tabularium-view-execute)
    (define-key map (kbd "* s") #'tabularium-view-mark-matching)
    (define-key map (kbd "* e") #'tabularium-view-mark-exact)
    (define-key map (kbd "* p") #'tabularium-view-mark-pattern)
    (define-key map (kbd "* r") #'tabularium-view-mark-regexp)
    (define-key map (kbd "* n") #'tabularium-view-mark-range)
    (define-key map (kbd "* #") #'tabularium-view-count-marked)
    ;; Freeze
    (define-key map (kbd "z z") #'tabularium-view-freeze)
    (define-key map (kbd "z u") #'tabularium-view-unfreeze)
    (define-key map (kbd "z x") #'tabularium-view-unfreeze)
    (define-key map (kbd "z U") #'tabularium-view-unfreeze-all)
    (define-key map (kbd "z X") #'tabularium-view-unfreeze-all)

    ;; === Constructive/Destructive ===
    ;; Create
    (define-key map (kbd "N") #'tabularium-new-entry)
    (define-key map (kbd "P") #'tabularium-prompt-entry)
    (define-key map (kbd "Q") #'tabularium-quick-entry)
    (define-key map (kbd "I") #'tabularium-view-insert)
    (define-key map (kbd "+") #'tabularium-view-duplicate)
    (define-key map (kbd "D") #'tabularium-view-delete)
    ;; Copy/Paste/Cut
    (define-key map (kbd "C") #'tabularium-view-copy)
    (define-key map (kbd "V") #'tabularium-view-paste)
    (define-key map (kbd "A") #'tabularium-view-paste-append)
    (define-key map (kbd "X") #'tabularium-view-cut)
    (define-key map (kbd "y") #'tabularium-kill-ring-view)
    ;; Edit
    (define-key map (kbd "E") #'tabularium-view-edit)
    ;; Move/Swap/Reindex
    (define-key map (kbd "M") #'tabularium-view-move)
    (define-key map (kbd "W") #'tabularium-view-swap)
    (define-key map (kbd "`") #'tabularium-reindex)
    ;; Replace (R prefix)
    (define-key map (kbd "R s") #'tabularium-replace-substring)
    (define-key map (kbd "R S") #'tabularium-replace-visible-substring)
    (define-key map (kbd "R e") #'tabularium-replace-exact)
    (define-key map (kbd "R E") #'tabularium-replace-visible-exact)
    (define-key map (kbd "R p") #'tabularium-replace-pattern)
    (define-key map (kbd "R r") #'tabularium-replace-regexp)
    (define-key map (kbd "R R") #'tabularium-replace-visible-regexp)
    (define-key map (kbd "R /") #'tabularium-replace-query)
    (define-key map (kbd "R ?") #'tabularium-replace-visible-query)
    (define-key map (kbd "R c") #'tabularium-toggle-case-sensitive)
    ;; Sort (s prefix) — mirrors the filter/highlight rule paradigm.
    (define-key map (kbd "s s") #'tabularium-view-sort-reverse)
    (define-key map (kbd "s `") #'tabularium-view-sort-index)
    (define-key map (kbd "s a") #'tabularium-view-sort-add)
    (define-key map (kbd "s c") #'tabularium-view-sort-cycle)
    (define-key map (kbd "s x") #'tabularium-view-sort-remove)
    (define-key map (kbd "s X") #'tabularium-view-sort-remove-all)
    (define-key map (kbd "s l") #'tabularium-view-sort-buffer)
    ;; Goto (' prefix)
    (define-key map (kbd "' c") #'tabularium-view-goto-column)
    (define-key map (kbd "' r") #'tabularium-view-goto-row)
    (define-key map (kbd "' '") #'tabularium-view-goto-entry)
    ;; === Undo/Redo ===
    (define-key map (kbd "C-/") #'tabularium-undo)
    (define-key map (kbd "C-_") #'tabularium-undo)
    (define-key map (kbd "C-x u") #'tabularium-undo)
    (define-key map (kbd "C-?") #'tabularium-redo)
    (define-key map (kbd "C-S-/") #'tabularium-redo)
    (define-key map (kbd "M-_") #'tabularium-redo)

    ;; === Prefix menus ===
    ;; Column operations
    (define-key map (kbd "| t") #'tabularium-view-toggle-column)
    (define-key map (kbd "| h") #'tabularium-view-hide-columns)
    (define-key map (kbd "| s") #'tabularium-view-show-columns)
    (define-key map (kbd "| o") #'tabularium-view-show-only-columns)
    (define-key map (kbd "| a") #'tabularium-view-show-all-columns)
    (define-key map (kbd "| r") #'tabularium-view-reorder-columns)
    (define-key map (kbd "| <") #'tabularium-view-move-column-left)
    (define-key map (kbd "| >") #'tabularium-view-move-column-right)
    (define-key map (kbd "| =") #'tabularium-view-reset-column-order)
    (define-key map (kbd "| N") #'tabularium-view-column-add)
    (define-key map (kbd "| D") #'tabularium-view-column-delete)
    (define-key map (kbd "| I") #'tabularium-view-column-insert)
    (define-key map (kbd "| E") #'tabularium-view-column-edit)
    (define-key map (kbd "| +") #'tabularium-view-column-duplicate)
    (define-key map (kbd "| M") #'tabularium-view-column-move)
    (define-key map (kbd "| W") #'tabularium-view-column-swap)
    (define-key map (kbd "| C") #'tabularium-view-column-copy)
    (define-key map (kbd "| X") #'tabularium-view-column-cut)
    (define-key map (kbd "| V") #'tabularium-view-column-paste)
    (define-key map (kbd "| A") #'tabularium-view-column-paste-append)
    ;; Schema operations
    (define-key map (kbd ". .") #'tabularium-schema-edit)
    (define-key map (kbd ". v") #'tabularium-schema-view)
    (define-key map (kbd ". =") #'tabularium-schema-reload)
    (define-key map (kbd ". w") #'tabularium-schema-switch)
    (define-key map (kbd ". $") #'tabularium-schema-rename-field)
    (define-key map (kbd ". +") #'tabularium-view-column-add)
    ;; Calculate operations
    (define-key map (kbd "# c") #'tabularium-aggregate-count)
    (define-key map (kbd "# C") #'tabularium-aggregate-visible-count)
    (define-key map (kbd "# *") #'tabularium-view-count-marked)
    (define-key map (kbd "# s") #'tabularium-aggregate-sum)
    (define-key map (kbd "# S") #'tabularium-aggregate-visible-sum)
    (define-key map (kbd "# m") #'tabularium-aggregate-min-max)
    (define-key map (kbd "# M") #'tabularium-aggregate-visible-min-max)
    (define-key map (kbd "# d") #'tabularium-aggregate-mean-sd)
    (define-key map (kbd "# D") #'tabularium-aggregate-visible-mean-sd)
    (define-key map (kbd "# i") #'tabularium-aggregate-median-iqr)
    (define-key map (kbd "# I") #'tabularium-aggregate-visible-median-iqr)
    (define-key map (kbd "# #") #'tabularium-aggregate-column-summary)
    ;; View expansion
    (define-key map (kbd "v >") #'tabularium-view-show-more)
    (define-key map (kbd "v a") #'tabularium-view-show-all)
    (define-key map (kbd "v +") #'tabularium-view-show-all-in-view)
    (define-key map (kbd "v r") #'tabularium-view-show-range)
    (define-key map (kbd "v =") #'tabularium-view-reset-limit)

    ;; === Import/Export/Help ===
    ;; Import comes first.  `i' is an import prefix: `i i' import a
    ;; file as a new database, `i a' append a file to the current
    ;; database.  `<' is an alternative prefix for the same commands.
    (define-key map (kbd "i i") #'tabularium-import)
    (define-key map (kbd "i a") #'tabularium-import-append)
    (define-key map (kbd "< i") #'tabularium-import)
    (define-key map (kbd "< a") #'tabularium-import-append)
    ;; `e' is an export prefix: `e e' marked-or-all, `e a' always all,
    ;; `e v' visible view, `e r' explicit id/column selection.  `>' is
    ;; an alternative prefix for the same commands.
    (define-key map (kbd "e e") #'tabularium-export)
    (define-key map (kbd "e a") #'tabularium-export-all)
    (define-key map (kbd "e v") #'tabularium-export-visible)
    (define-key map (kbd "e r") #'tabularium-export-range)
    (define-key map (kbd "> e") #'tabularium-export)
    (define-key map (kbd "> a") #'tabularium-export-all)
    (define-key map (kbd "> v") #'tabularium-export-visible)
    (define-key map (kbd "> r") #'tabularium-export-range)
    (define-key map (kbd "$") #'tabularium-rename-database)
    (define-key map (kbd "o") #'tabularium-open)
    (define-key map (kbd "O") #'tabularium-open-and-view)
    (define-key map (kbd "?") #'tabularium-describe-database)
    (define-key map (kbd "SPC") #'tabularium-view-menu)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `tabularium-view-mode'.")

(define-derived-mode tabularium-view-mode tabulated-list-mode "Tabularium"
  "Major mode for browsing records.

\\{tabularium-view-mode-map}"
  ;; Initialize sort order: schema default > global customization
  (setq-local tabularium--sort-ascending
              (if tabularium--current-schema-name
                  (eq (tabularium--schema-default-sort) 'asc)
                tabularium-view-sort-ascending))
  (setq-local tabularium--hidden-columns nil)
  (setq-local tabularium--marked-entries nil)
  (setq-local tabularium--frozen-ids nil)
  (setq-local tabularium--column-order nil)
  (setq-local tabularium--sort-columns nil)
  ;; Customizable header-line face for this buffer only
  (face-remap-add-relative 'header-line 'tabularium-list-header-face)
  (add-hook 'tabulated-list-revert-hook #'tabularium-view--refresh nil t)
  ;; Override revert so mark, frozen, and highlight
  ;; overlays are re-applied after `tabulated-list-print'.
  (setq-local revert-buffer-function #'tabularium-view--revert))

(defun tabularium-view--revert (_ignore-auto _noconfirm)
  "Revert the view buffer and re-apply mark, frozen, and CF overlays."
  (let ((saved-id (tabulated-list-get-id))
        (saved-col (tabularium--column-name-at-point))
        (saved-win-start (window-start)))
    (tabularium-view--refresh)
    (tabulated-list-print t)
    (tabularium-view--update-cf-display)
    (tabularium-view--update-frozen-display)
    (tabularium-view--update-mark-display)
    ;; Restore position: find saved row, then navigate to saved column
    (tabularium-view--goto-position saved-id saved-col)
    ;; Restore scroll position precisely
    (set-window-start (selected-window) saved-win-start t)))

(defun tabularium-view--goto-position (id column-name)
  "Navigate to the row with ID and the column COLUMN-NAME.
If ID is nil, stay on the current line.  If COLUMN-NAME is nil,
go to the beginning of the row."
  (when id
    (goto-char (point-min))
    (let ((found nil))
      (while (and (not found) (not (eobp)))
        (when (equal (tabulated-list-get-id) id)
          (setq found t))
        (unless found (forward-line 1)))
      (unless found
        (goto-char (point-min)))))
  (when column-name
    (tabularium-view--goto-column column-name)))

(defun tabularium-view--goto-column (column-name)
  "Move point to the beginning of COLUMN-NAME on the current row."
  (let* ((fields (tabularium--schema-fields))
         (order (or tabularium--column-order
                    (mapcar (lambda (f) (plist-get f :id)) fields)))
         (visible (cl-remove-if
                   (lambda (name)
                     (or (memq name tabularium--hidden-columns)
                         (let ((f (tabularium--field-by-name name)))
                           (plist-get f :hidden))))
                   order))
         (target-idx (cl-position column-name visible))
         ;; Account for freeze indicator column
         (actual-idx (if tabularium--frozen-ids
                         (when target-idx (1+ target-idx))
                       target-idx)))
    (when actual-idx
      (beginning-of-line)
      ;; +1 because beginning-of-line is before tabulated-list-padding;
      ;; the first tabulated-list-next-column call moves past padding
      ;; to column 0.
      (dotimes (_ (1+ actual-idx))
        (tabulated-list-next-column 1)))))

(defun tabularium-view-toggle-column (column-name)
  "Toggle visibility of COLUMN-NAME in the current view."
  (interactive
   (let* ((all-fields (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                              (tabularium--schema-fields)))
          (field (completing-read "Toggle column: " all-fields nil t)))
     (list (intern field))))
  (if (memq column-name tabularium--hidden-columns)
      (setq tabularium--hidden-columns (delq column-name tabularium--hidden-columns))
    (push column-name tabularium--hidden-columns))
  (revert-buffer)
  (message "Column %s %s" column-name
           (if (memq column-name tabularium--hidden-columns) "hidden" "shown")))

;;;###autoload
(defun tabularium-view-select-columns (pattern &optional match-on invert)
  "Select columns by title, hiding those whose name or label matches PATTERN.
This picks columns by what they are called, which is a way of choosing
columns rather than of filtering data — see
`tabularium-view-filter-column\=' for a rule that judges a column by the
values it holds.
PATTERN is literal text, matched case-insensitively.  MATCH-ON is
`name' (the column's code identifier), `label' (its display heading),
or `both' — the default, and what most schemas want, since the two
usually differ only in punctuation.  With INVERT non-nil
\(interactively, a prefix argument) the matching columns are the ones
kept and everything else is hidden, i.e. \"show only these\".

The column-oriented counterpart of the row filters: a row filter
selects rows, this selects columns, and selected columns are hidden.
It covers the common cases of `tabularium-view-hide-columns' without
naming each column; `| a' restores everything.

The primary-key column is never hidden by this command, since it
identifies the row; hide it explicitly with `| h' if wanted."
  (interactive
   (let* ((on (intern (completing-read "Match on: "
                                       '("both" "name" "label")
                                       nil t nil nil "both")))
          (pat (read-string
                (format "Hide columns whose %s contains%s: "
                        (pcase on
                          ('name "name")
                          ('label "label")
                          (_ "name or label"))
                        (if current-prefix-arg " (inverted)" "")))))
     (when (string-empty-p (string-trim pat))
       (user-error "Empty pattern"))
     (list pat on current-prefix-arg)))
  (let* ((fields (tabularium--schema-fields))
         (primary (tabularium--primary-field-name))
         (case-fold-search t)
         (quoted (regexp-quote pattern))
         (match-p
          (lambda (f)
            (let ((name (symbol-name (plist-get f :id)))
                  (label (or (plist-get f :label) "")))
              (pcase (or match-on 'both)
                ('name (string-match-p quoted name))
                ('label (string-match-p quoted label))
                (_ (or (string-match-p quoted name)
                       (string-match-p quoted label)))))))
         ;; Selecting keeps what matches, as a row filter does; the
         ;; columns hidden are therefore the ones that do NOT match.
         (targets (cl-remove-if
                   (lambda (f) (eq (plist-get f :id) primary))
                   (if invert
                       (cl-remove-if-not match-p fields)
                     (cl-remove-if match-p fields)))))
    (unless targets
      (user-error "Every column %s \"%s\"; nothing to hide"
                  (if invert "fails to match" "matches") pattern))
    (dolist (f targets)
      (cl-pushnew (plist-get f :id) tabularium--hidden-columns))
    (revert-buffer)
    (message "Kept columns %s \"%s\"; hid %d other%s (total hidden: %d)"
             (if invert "not matching" "matching") pattern
             (length targets) (if (= 1 (length targets)) "" "s")
             (length tabularium--hidden-columns))))

(defun tabularium-view-show-all-columns ()
  "Show all columns in the current view."
  (interactive)
  (setq tabularium--hidden-columns nil)
  (revert-buffer)
  (message "All columns visible"))

(defun tabularium-view-hide-columns (columns)
  "Hide multiple COLUMNS in the current view.
Adds to existing hidden columns rather than replacing."
  (interactive
   (let* ((all-fields (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                              (tabularium--schema-fields)))
          (visible-fields (cl-remove-if
                           (lambda (name)
                             (memq (intern name) tabularium--hidden-columns))
                           all-fields))
          (selected (completing-read-multiple "Hide columns: " visible-fields)))
     (list (mapcar #'intern selected))))
  (dolist (col columns)
    (cl-pushnew col tabularium--hidden-columns))
  (revert-buffer)
  (message "Hidden %d columns (total hidden: %d)"
           (length columns) (length tabularium--hidden-columns)))

(defun tabularium-view-show-columns (columns)
  "Show one or more hidden COLUMNS in the current view.
The direct inverse of `tabularium-view-hide-columns': prompts, with
completion over the currently hidden columns (in schema order), for
which to reveal.  With no hidden columns, says so and does nothing."
  (interactive
   (progn
     (unless tabularium--hidden-columns
       (user-error "No hidden columns to show"))
     (let* ((hidden-names
             (mapcar #'symbol-name
                     (cl-remove-if-not
                      (lambda (id) (memq id tabularium--hidden-columns))
                      (mapcar (lambda (f) (plist-get f :id))
                              (tabularium--schema-fields)))))
            (selected (completing-read-multiple "Show columns: " hidden-names)))
       (list (mapcar #'intern selected)))))
  (dolist (col columns)
    (setq tabularium--hidden-columns (delq col tabularium--hidden-columns)))
  (revert-buffer)
  (message "Shown %d column%s (total hidden: %d)"
           (length columns) (if (= 1 (length columns)) "" "s")
           (length tabularium--hidden-columns)))

(defun tabularium-view-show-only-columns (columns)
  "Show only the selected COLUMNS, hiding all others."
  (interactive
   (let* ((all-fields (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                              (tabularium--schema-fields)))
          (selected (completing-read-multiple "Show only columns: " all-fields)))
     (list (mapcar #'intern selected))))
  (when (null columns)
    (user-error "No columns selected"))
  (let ((all-names (mapcar (lambda (f) (plist-get f :id))
                           (tabularium--schema-fields))))
    ;; Hide all columns except selected
    (setq tabularium--hidden-columns
          (cl-remove-if (lambda (col) (memq col columns)) all-names)))
  (revert-buffer)
  (message "Showing %d columns" (length columns)))

;;; ** 5.3 Row/Column Navigation

(defun tabularium-view-goto-entry (id)
  "Go to entry with ID."
  (interactive "nGo to entry ID: ")
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (if (equal (tabulated-list-get-id) id)
          (setq found t)
        (forward-line 1)))
    (if found
        (message "Entry %d" id)
      (message "Entry %d not found in current view" id))))

(defun tabularium-view-goto-row (n)
  "Go to row N (1-indexed)."
  (interactive "nGo to row: ")
  (goto-char (point-min))
  (forward-line (1- n)))

(defun tabularium-view-goto-column (column-name)
  "Go to COLUMN-NAME on the current row, with completion."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (order (or tabularium--column-order
                     (mapcar (lambda (f) (plist-get f :id)) fields)))
          (visible (cl-remove-if
                    (lambda (name)
                      (or (memq name tabularium--hidden-columns)
                          (let ((f (tabularium--field-by-name name)))
                            (plist-get f :hidden))))
                    order))
          (candidates (mapcar #'symbol-name visible))
          (choice (completing-read "Go to column: " candidates nil t)))
     (list (intern choice))))
  (tabularium-view--goto-column column-name))

;;;###autoload
(defun tabularium-last (field pattern)
  "Find most recent record where FIELD matches PATTERN."
  (interactive
   (let* ((field-names (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                               (cl-remove-if #'tabularium--computed-field-p
                                             (tabularium--schema-fields))))
          (field (completing-read "Search field: " field-names nil t))
          (candidates (tabularium--get-historical-values field))
          (pattern (completing-read (format "Find last %s matching: " field) candidates)))
     (list field pattern)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (date-field (cl-find-if (lambda (f) (eq (plist-get f :type) 'date))
                                 (tabularium--schema-fields)))
         (order-by (if date-field
                       (symbol-name (plist-get date-field :id))
                     primary-name))
         (op (tabularium-db-like-op tabularium-case-sensitive))
         (wrapped (tabularium-db-like-pattern (format "%s" pattern)
                                              tabularium-case-sensitive))
         (escaped (replace-regexp-in-string "'" "''" wrapped))
         (sql (format "SELECT %s, %s FROM %s WHERE %s %s '%s' ORDER BY %s DESC LIMIT 1"
                      primary-name order-by tabularium-table-name
                      field op escaped order-by))
         (result (tabularium-db-query-single tabularium--db sql)))
    (if result
        (progn
          (message "Last '%s': ID %s on %s" pattern (car result) (cadr result))
          (when (y-or-n-p "View this record? ")
            (tabularium-new-entry (car result))))
      (message "No records found matching '%s'" pattern))))

;;; *** 5.3.1 Page Navigation

(defun tabularium-view-page-down ()
  "Move forward by `tabularium-view-page-size' rows."
  (interactive)
  (forward-line tabularium-view-page-size))

(defun tabularium-view-page-up ()
  "Move backward by `tabularium-view-page-size' rows."
  (interactive)
  (forward-line (- tabularium-view-page-size)))

;;; *** 5.3.2 Column Scroll

(defun tabularium-view--column-width (col-idx)
  "Return display width of column COL-IDX (including separator)."
  (when (< col-idx (length tabulated-list-format))
    (1+ (cadr (aref tabulated-list-format col-idx)))))

(defun tabularium-view-scroll-column-right ()
  "Scroll the view one column to the right.
Useful for wide tables where columns overflow the window."
  (interactive)
  (let* ((current (window-hscroll))
         (cumulative 0)
         (target nil))
    (catch 'found
      (dotimes (i (length tabulated-list-format))
        (let ((width (tabularium-view--column-width i)))
          (when (and width (> (+ cumulative width) current))
            (setq target (+ cumulative width))
            (throw 'found nil))
          (setq cumulative (+ cumulative (or width 0))))))
    (if target
        (set-window-hscroll (selected-window) target)
      (message "Already at last column"))))

(defun tabularium-view-scroll-column-left ()
  "Scroll the view one column to the left."
  (interactive)
  (let* ((current (window-hscroll))
         (cumulative 0)
         (prev 0))
    (if (zerop current)
        (message "Already at first column")
      (dotimes (i (length tabulated-list-format))
        (let ((width (tabularium-view--column-width i)))
          (when (and width (< cumulative current))
            (setq prev cumulative)
            (setq cumulative (+ cumulative width)))))
      (set-window-hscroll (selected-window) prev))))

;;; ** 5.4 Cell Navigation

;;; *** 5.4.1 Basic Movement

(defun tabularium-view-forward-cell (&optional n)
  "Move forward N cells in the current row, stopping at the last column.
Uses the package's own column-position logic rather than
`tabulated-list-next-column', so it advances exactly one column per
step even in tables with computed columns."
  (interactive "p")
  (let* ((ncols (length tabulated-list-format))
         (idx (or (tabularium--current-column-index) 0))
         (target (min (1- ncols) (+ idx (or n 1)))))
    (tabularium-view--move-to-column target)))

(defun tabularium-view-backward-cell (&optional n)
  "Move backward N cells in the current row, stopping at the first column.
Uses the package's own column-position logic rather than
`tabulated-list-previous-column', whose text-property scan can skip
two or three columns at a time in tables with computed columns."
  (interactive "p")
  (let* ((idx (or (tabularium--current-column-index) 0))
         (target (max 0 (- idx (or n 1)))))
    (tabularium-view--move-to-column target)))

(defun tabularium-view-beginning-of-line ()
  "Move to the first column of the current row.
If already at the beginning of the line, move to the top-left corner
\(first column of the first row)."
  (interactive)
  (let ((was-at-bol (= (point) (line-beginning-position))))
    (if was-at-bol
        ;; Already at BOL — go to first row, first column (top-left)
        (progn
          (goto-char (point-min))
          (while (and (not (eobp)) (not (tabulated-list-get-id)))
            (forward-line 1))
          (beginning-of-line)
          (message "Top-left"))
      ;; Not at BOL — just go to beginning of line
      (beginning-of-line))))

(defun tabularium-view-end-of-line ()
  "Move to the end of the current row.
If already at the end of the line, move to the bottom-right corner
\(end of the last row)."
  (interactive)
  (let ((was-at-eol (= (point) (line-end-position))))
    (if was-at-eol
        ;; Already at EOL — go to last row, end of line (bottom-right)
        (progn
          (goto-char (point-max))
          (forward-line -1)
          (while (and (not (bobp)) (not (tabulated-list-get-id)))
            (forward-line -1))
          (end-of-line)
          (message "Bottom-right"))
      ;; Not at EOL — just go to end of line
      (end-of-line))))

(defun tabularium-view-first-row ()
  "Move to the first data row in the view, staying in the same column.
If already at the first row, move to the beginning of the line (upper-left)."
  (interactive)
  (let* ((col-idx (tabularium--current-column-index))
         (current-id (tabulated-list-get-id))
         (first-id nil))
    ;; Find the first row's ID
    (save-excursion
      (goto-char (point-min))
      (while (and (not (eobp)) (not (tabulated-list-get-id)))
        (forward-line 1))
      (setq first-id (tabulated-list-get-id)))
    ;; Check if already at first row
    (if (equal current-id first-id)
        (progn
          (beginning-of-line)
          (message "Beginning of first row"))
      ;; Go to first row
      (goto-char (point-min))
      (while (and (not (eobp)) (not (tabulated-list-get-id)))
        (forward-line 1))
      ;; Move to the same column
      (tabularium-view--move-to-column col-idx)
      (message "First row"))))

(defun tabularium-view-last-row ()
  "Move to the last data row in the view, staying in the same column.
If already at the last row, move to the end of the line (bottom-right)."
  (interactive)
  (let* ((col-idx (tabularium--current-column-index))
         (current-id (tabulated-list-get-id))
         (last-id nil))
    ;; Find the last row's ID
    (save-excursion
      (goto-char (point-max))
      (forward-line -1)
      (while (and (not (bobp)) (not (tabulated-list-get-id)))
        (forward-line -1))
      (setq last-id (tabulated-list-get-id)))
    ;; Check if already at last row
    (if (equal current-id last-id)
        (progn
          (end-of-line)
          (message "End of last row"))
      ;; Go to last row
      (goto-char (point-max))
      (forward-line -1)
      (while (and (not (bobp)) (not (tabulated-list-get-id)))
        (forward-line -1))
      ;; Move to the same column
      (tabularium-view--move-to-column col-idx)
      (message "Last row"))))

;;; *** 5.4.2 Jump Navigation

(defun tabularium-view--get-cell-value-at-column (col-idx)
  "Get the cell value at column COL-IDX on the current line.
Returns the string value, handling both plain strings and
\(STRING . PROPS) cons cells used by `tabulated-list-mode'."
  (when-let ((entry (tabulated-list-get-entry)))
    (when (< col-idx (length entry))
      (let ((val (aref entry col-idx)))
        (if (stringp val) val (car val))))))

(defun tabularium-view--column-start-position (col-idx)
  "Return the character position (from BOL) where column COL-IDX starts.
COL-IDX is 0-based.  Each row begins with `tabulated-list-padding'
padding characters before the first column, so that offset is
included — without it every column would be reported one character
too far left, landing point on the trailing separator (and, for a
truncated neighbour, visually on its ellipsis)."
  (let ((pos (or tabulated-list-padding 0)))
    (dotimes (i col-idx)
      (setq pos (+ pos 1 (cadr (aref tabulated-list-format i)))))
    pos))

(defun tabularium-view--move-to-column (col-idx)
  "Move point to column COL-IDX on the current line.
COL-IDX is 0-based.  `tabulated-list-mode' trims trailing
whitespace, so a row whose rightmost cells are empty has a line
physically shorter than the full column layout.  Plain
`forward-char' would then stop at end-of-line and leave point in
the wrong column; using `move-to-column' keeps the target column
accurate (it reports the column it actually reached, and we do not
force-pad the buffer)."
  (beginning-of-line)
  (move-to-column (tabularium-view--column-start-position col-idx)))

(defun tabularium-view-cell-jump-down (&optional n)
  "Jump down to the next row where the current column value changes.
With prefix N, jump N value transitions."
  (interactive "p")
  (let* ((col-idx (tabularium--current-column-index))
         (transitions (or n 1))
         (jumped 0))
    (cl-block outer
      (dotimes (_ transitions)
        (let ((current-val (tabularium-view--get-cell-value-at-column col-idx))
              (found nil)
              (last-row nil))
          (save-excursion
            (while (not (eobp))
              (forward-line 1)
              (when (tabulated-list-get-id)
                (setq last-row (point))
                (let ((new-val (tabularium-view--get-cell-value-at-column col-idx)))
                  (when (and (not found) (not (string-equal new-val current-val)))
                    (setq found (point)))))))
          (cond
           (found
            (goto-char found)
            (tabularium-view--move-to-column col-idx)
            (cl-incf jumped))
           (last-row
            ;; No different value, but there are rows below - go to last row
            (goto-char last-row)
            (tabularium-view--move-to-column col-idx)
            (message "Reached last row")
            (cl-return-from outer))
           (t
            ;; Already at last row
            (message "Already at last row")
            (cl-return-from outer))))))
    (when (= jumped transitions)
      (message "Jumped %d transition%s" jumped (if (= jumped 1) "" "s")))))

(defun tabularium-view-cell-jump-up (&optional n)
  "Jump up to the next row where the current column value changes.
With prefix N, jump N value transitions."
  (interactive "p")
  (let* ((col-idx (tabularium--current-column-index))
         (transitions (or n 1))
         (jumped 0))
    (cl-block outer
      (dotimes (_ transitions)
        (let ((current-val (tabularium-view--get-cell-value-at-column col-idx))
              (found nil)
              (first-row nil))
          (save-excursion
            (while (not (bobp))
              (forward-line -1)
              (when (tabulated-list-get-id)
                (setq first-row (point))
                (let ((new-val (tabularium-view--get-cell-value-at-column col-idx)))
                  (when (and (not found) (not (string-equal new-val current-val)))
                    (setq found (point)))))))
          (cond
           (found
            (goto-char found)
            (tabularium-view--move-to-column col-idx)
            (cl-incf jumped))
           (first-row
            ;; No different value, but there are rows above - go to first row
            (goto-char first-row)
            (tabularium-view--move-to-column col-idx)
            (message "Reached first row")
            (cl-return-from outer))
           (t
            ;; Already at first row
            (message "Already at first row")
            (cl-return-from outer))))))
    (when (= jumped transitions)
      (message "Jumped %d transition%s" jumped (if (= jumped 1) "" "s")))))

(defun tabularium-view-cell-jump-forward ()
  "Move right to the next column with a different value on this row."
  (interactive)
  (let* ((start-col (tabularium--current-column-index))
         (entry (tabulated-list-get-entry))
         (current-val (tabularium-view--get-cell-value-at-column start-col))
         (num-cols (length tabulated-list-format))
         (found nil)
         (last-col (1- num-cols)))
    (when (and entry current-val)
      (let ((i (1+ start-col)))
        (while (and (not found) (< i num-cols))
          (let ((val (tabularium-view--get-cell-value-at-column i)))
            (when (and val (not (string-equal val current-val)))
              (setq found i)))
          (setq i (1+ i)))))
    (cond
     (found
      (tabularium-view--move-to-column found))
     ((< start-col last-col)
      ;; No different value, go to last column
      (tabularium-view--move-to-column last-col)
      (message "Reached last column"))
     (t
      (message "Already at last column")))))

(defun tabularium-view-cell-jump-backward ()
  "Move left to the next column with a different value on this row."
  (interactive)
  (let* ((start-col (tabularium--current-column-index))
         (entry (tabulated-list-get-entry))
         (current-val (tabularium-view--get-cell-value-at-column start-col))
         (found nil))
    (when (and entry current-val (> start-col 0))
      ;; Search from start-col-1 down to 0, stop at first match
      (let ((i (1- start-col)))
        (while (and (not found) (>= i 0))
          (let ((val (tabularium-view--get-cell-value-at-column i)))
            (when (and val (not (string-equal val current-val)))
              (setq found i)))
          (setq i (1- i)))))
    (cond
     (found
      (tabularium-view--move-to-column found))
     ((> start-col 0)
      ;; No different value, go to first column
      (tabularium-view--move-to-column 0)
      (message "Reached first column"))
     (t
      (message "Already at first column")))))

;;; ** 5.5 Fuzzy Search

(defun tabularium--format-for-search (row fields)
  "Format ROW using FIELDS for search display."
  (let ((parts '()))
    (cl-loop for field in fields
             for value in row
             for width = (or (plist-get field :width) 20)
             unless (plist-get field :hidden)
             do (push (truncate-string-to-width
                       (format "%s" (or value "")) width)
                      parts))
    (string-join (nreverse parts) " | ")))

(defun tabularium--search-candidates ()
  "Get all records formatted for fuzzy search."
  (tabularium--ensure-db)
  (let* ((fields (cl-remove-if (lambda (f)
                                 (or (plist-get f :hidden)
                                     (tabularium--computed-field-p f)))
                               (tabularium--schema-fields)))
         (field-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) fields))
         (primary-name (symbol-name (tabularium--primary-field-name)))
         (sql (format "SELECT %s FROM %s ORDER BY %s DESC"
                      (string-join field-names ", ")
                      tabularium-table-name
                      primary-name))
         (rows (tabularium-db-query tabularium--db sql)))
    (mapcar (lambda (row)
              (cons (tabularium--format-for-search row fields)
                    (car row)))
            rows)))

;;;###autoload
(defun tabularium-find ()
  "Fuzzy-find a record using `completing-read'."
  (interactive)
  (tabularium--ensure-db)
  (let* ((candidates (tabularium--search-candidates))
         (selection (completing-read
                     (format "Find %s: " (tabularium--schema-name))
                     candidates nil t))
         (id (cdr (assoc selection candidates))))
    (when id
      (tabularium-new-entry id))))

;;; ** 5.6 View Window Expansion

(defun tabularium-view-show-all ()
  "Show every row in the table.
Removes the page-size limit, ID-range filter, and any active filter,
sort spec, column hiding, and saved-view label.  This is the most
permissive view — useful when you want to see literally everything
in the database without any constraints.

For showing all rows that match the current filter/view constraints,
use `tabularium-view-show-all-in-view'."
  (interactive)
  ;; Clear all view constraints
  (setq tabularium--filter-rules nil)
  (setq tabularium--hidden-columns nil)
  (setq tabularium--sort-columns nil)
  (setq tabularium--sort-ascending
        (if tabularium--current-schema-name
            (eq (tabularium--schema-default-sort) 'asc)
          tabularium-view-sort-ascending))
  (setq tabularium--column-order nil)
  (setq tabularium--current-view nil)
  ;; Remove row limit and ID-range
  (setq tabularium--view-limit most-positive-fixnum)
  (setq tabularium--view-id-range nil)
  (setq mode-name "Tabularium")
  (revert-buffer)
  (message "Showing every row in the table (all constraints cleared)"))

(defun tabularium-view-show-all-in-view ()
  "Show all rows that match the current view constraints.
Removes only the page-size limit and any ID-range filter; the
active filter, sort spec, column hiding, and saved-view label are
preserved.

To clear constraints in addition to expanding the row count, use
`tabularium-view-show-all'."
  (interactive)
  (setq tabularium--view-limit most-positive-fixnum)
  (setq tabularium--view-id-range nil)
  (revert-buffer)
  (message "Showing all rows in current view"))

(defun tabularium-view-show-range (spec)
  "Restrict the view to the row IDs named by SPEC.
SPEC is the same comma-and-dash form `tabularium-export-range'
accepts — single IDs and inclusive ranges, e.g. =3-7,12,20-25=.
A spec that is one unbroken range is stored as a contiguous
range; a spec with gaps is stored as an explicit ID set.  Both
are honored by the view's row filter."
  (interactive
   (list (read-string "Show rows [comma-separated or range]: "
                      (when-let ((id (tabularium--id-at-point)))
                        (number-to-string id)))))
  (let ((ids (tabularium--parse-id-range-spec spec)))
    (unless ids
      (user-error "No valid row IDs in: %s" spec))
    (let* ((lo (car ids))
           (hi (car (last ids)))
           (contiguous (= (length ids) (1+ (- hi lo)))))
      ;; A gapless run is stored as a (MIN . MAX) cons; anything with
      ;; holes is stored as the explicit sorted ID list.
      (setq tabularium--view-id-range
            (if contiguous (cons lo hi) ids))
      (setq tabularium--view-limit most-positive-fixnum)
      (revert-buffer)
      (message "Showing %d row%s%s"
               (length ids) (if (= 1 (length ids)) "" "s")
               (if contiguous (format " (%d-%d)" lo hi) "")))))

(defun tabularium-view-show-more (&optional count)
  "Increase the number of visible entries by COUNT.
COUNT defaults to `tabularium-view-page-size'."
  (interactive "P")
  (let ((increase (or count tabularium-view-page-size)))
    (setq tabularium--view-limit
          (+ (or tabularium--view-limit tabularium-view-page-size) increase))
    (revert-buffer)
    (message "Showing up to %d entries" tabularium--view-limit)))

(defun tabularium-view-reset-limit ()
  "Reset view to default page size."
  (interactive)
  (setq tabularium--view-limit nil)
  (setq tabularium--view-id-range nil)
  (revert-buffer)
  (message "Reset to default limit (%d)" tabularium-view-page-size))

;;; ** 5.7 Saved View Windows

(defun tabularium-apply-view (view)
  "Apply saved VIEW preset to the current buffer.
VIEW is a plist with optional keys :filter, :columns, :sort, :rows,
and :frozen (pinned row IDs)."
  (let ((name (plist-get view :name))
        (filter (plist-get view :filter))
        (columns (plist-get view :columns))
        (sort-spec (plist-get view :sort))
        (rows (plist-get view :rows))
        (frozen (plist-get view :frozen)))
    ;; Apply filter
    (setq tabularium--filter-rules
          (when filter
            (list (list :raw t :sql filter :desc name :connective nil))))
    ;; Apply column visibility and ordering
    (when columns
      (let ((all-fields (mapcar (lambda (f) (plist-get f :id))
                                (tabularium--schema-fields))))
        (setq tabularium--hidden-columns
              (cl-remove-if (lambda (col) (memq col columns)) all-fields)))
      (setq tabularium--column-order columns))
    ;; Apply the row-ID restriction.  A view with no `:rows' key clears
    ;; any restriction so the full table shows; a saved restriction
    ;; lifts the page limit so every restricted row is visible.
    (setq tabularium--view-id-range rows)
    (when rows
      (setq tabularium--view-limit most-positive-fixnum))
    ;; Apply sort — sort-spec is either (col . dir) or ((col1 . dir1) (col2 . dir2) ...)
    (when sort-spec
      (setq tabularium--sort-columns
            (if (and (consp (car sort-spec)) (symbolp (caar sort-spec)))
                ;; List of cons cells: ((year . desc) (month . desc))
                sort-spec
              ;; Single cons cell: (year . desc)
              (list sort-spec))))
    ;; Apply frozen rows (pinned row IDs)
    (setq tabularium--frozen-ids frozen)
    ;; Track current view
    (setq tabularium--current-view name)
    ;; Update mode name to show view
    (setq mode-name (if name
                        (format "Tabularium[%s]" name)
                      "Tabularium"))
    ;; Refresh display
    (revert-buffer)
    (when name
      (message "Applied view: %s" name))))

(defun tabularium-select-view ()
  "Select and apply a saved view from the schema."
  (interactive)
  (let ((views (tabularium--schema-views)))
    (if (null views)
        (user-error "No saved views defined in schema")
      (let* ((names (mapcar (lambda (v) (plist-get v :name)) views))
             (current tabularium--current-view)
             (prompt (if current
                         (format "Select view (current: %s): " current)
                       "Select view: "))
             (selected (completing-read prompt names nil t))
             (view (cl-find-if (lambda (v) (string= (plist-get v :name) selected))
                               views)))
        (when view
          (tabularium-apply-view view))))))

(defun tabularium--capture-current-view ()
  "Return a view plist describing the buffer's current visible state.
Captures the active filter (as a SQL WHERE clause), the sort spec,
the visible-columns list (only when the user has customized column
visibility or order — otherwise `:columns' is omitted so the view
follows the schema default), and the row-ID restriction set by
`tabularium-view-show-range' (the `:rows' key)."
  (let* ((filter (tabularium--build-filter-clause))
         (sort-spec tabularium--sort-columns)
         (columns-customized (or tabularium--hidden-columns
                                 tabularium--column-order))
         (visible-cols
          (when columns-customized
            (mapcar (lambda (f) (plist-get f :id))
                    (tabularium-view--ordered-visible-fields)))))
    (append
     (when filter (list :filter filter))
     (when visible-cols (list :columns visible-cols))
     ;; Row restriction — the contiguous range or explicit ID set that
     ;; `tabularium-view-show-range' applied.  Stored verbatim; nil (no
     ;; restriction) is omitted so the view shows all rows.
     (when tabularium--view-id-range
       (list :rows tabularium--view-id-range))
     ;; Frozen rows — the pinned row IDs, so they re-pin when the view is
     ;; applied.  Omitted when nothing is frozen.
     (when tabularium--frozen-ids
       (list :frozen tabularium--frozen-ids))
     (when sort-spec
       ;; Normalize: single (col . dir) stored as cons, list stays list
       (list :sort (if (= 1 (length sort-spec))
                       (car sort-spec)
                     sort-spec))))))

(defun tabularium-view-save (slot &optional name)
  "Save the current visible state as preset view SLOT.
SLOT is 1..9 — the index into the schema's `:views' list.
NAME is the display name; when called interactively, prompts for
both.  Overwrites an existing view at SLOT after confirmation.

The captured view includes the active filter, current sort, any
frozen (pinned) rows, and the visible-columns list (only when the
user has hidden or reordered columns — otherwise the view tracks the
schema default).  The view is persisted to the schema file immediately
so it survives Emacs restarts."
  (interactive
   (progn
     (unless (derived-mode-p 'tabularium-view-mode)
       (user-error "Not in a Tabularium view buffer"))
     (let* ((views (tabularium--schema-views))
            (taken (mapcar (lambda (v) (plist-get v :name)) views))
            (slot-choices
             (mapcar (lambda (i)
                       (let ((existing (nth (1- i) views)))
                         (format "%d%s" i
                                 (if existing
                                     (format " (currently: %s)"
                                             (plist-get existing :name))
                                   ""))))
                     (number-sequence 1 9)))
            (slot-pick (completing-read "Save as view slot: "
                                        slot-choices nil t))
            (slot-num (string-to-number slot-pick))
            (existing (nth (1- slot-num) views))
            (default-name (or (and existing (plist-get existing :name))
                              tabularium--current-view))
            (name (read-string
                   (format "View name%s: "
                           (if default-name
                               (format " [%s]" default-name)
                             ""))
                   nil nil default-name)))
       (when (string-empty-p (string-trim name))
         (user-error "View name cannot be empty"))
       (when (and existing
                  (not (y-or-n-p (format "Slot %d already has view '%s'.  Overwrite? "
                                         slot-num (plist-get existing :name)))))
         (user-error "Canceled"))
       (when (and (member name taken)
                  (not (and existing (equal name (plist-get existing :name))))
                  (not (y-or-n-p (format "A view named '%s' already exists in another slot.  Continue? "
                                         name))))
         (user-error "Canceled"))
       (list slot-num name))))
  (unless (and (integerp slot) (<= 1 slot 9))
    (user-error "Slot must be an integer between 1 and 9"))
  (let* ((schema-name (tabularium--schema-name))
         (schema (assoc schema-name tabularium-schemas))
         (plist (cdr schema))
         (views (or (plist-get plist :views) '()))
         (captured (tabularium--capture-current-view))
         (new-view (append (list :name name) captured))
         ;; Pad views list to slot length
         (padded (append views (make-list (max 0 (- slot (length views))) nil)))
         (idx 0)
         (updated (mapcar (lambda (v)
                            (cl-incf idx)
                            (if (= idx slot) new-view v))
                          padded)))
    (setq plist (plist-put plist :views updated))
    (setf (cdr schema) plist)
    (tabularium--save-schema-to-file schema-name)
    (setq tabularium--current-view name)
    (setq mode-name (format "Tabularium[%s]" name))
    (force-mode-line-update)
    (message "Saved view #%d: %s" slot name)))

(defun tabularium-view-clear ()
  "Clear the current view: no filter, all columns, default sort.
Frozen (pinned) rows are released as well, so the buffer returns to a
completely unrestricted state."
  (interactive)
  (setq tabularium--filter-rules nil)
  (setq tabularium--hidden-columns nil)
  (setq tabularium--sort-columns nil)
  (setq tabularium--frozen-ids nil)
  ;; Reset sort direction to schema default or global default
  (setq tabularium--sort-ascending
        (if tabularium--current-schema-name
            (eq (tabularium--schema-default-sort) 'asc)
          tabularium-view-sort-ascending))
  (setq tabularium--column-order nil)
  (setq tabularium--current-view nil)
  (setq mode-name "Tabularium")
  (revert-buffer)
  (message "Cleared view - showing all data, all columns, default sort, no frozen rows"))

(defun tabularium--apply-view-by-index (index)
  "Apply the INDEXth view from the schema (1-indexed).
Returns t if view was applied, nil otherwise."
  (let* ((views (tabularium--schema-views))
         (view (nth (1- index) views)))
    (if view
        (progn
          (tabularium-apply-view view)
          t)
      (message "No view #%d defined (%d views available)" index (length views))
      nil)))

(defun tabularium-view-0 () "Clear view." (interactive) (tabularium-view-clear))
(defun tabularium-view-1 () "Apply view #1 from schema." (interactive) (tabularium--apply-view-by-index 1))
(defun tabularium-view-2 () "Apply view #2 from schema." (interactive) (tabularium--apply-view-by-index 2))
(defun tabularium-view-3 () "Apply view #3 from schema." (interactive) (tabularium--apply-view-by-index 3))
(defun tabularium-view-4 () "Apply view #4 from schema." (interactive) (tabularium--apply-view-by-index 4))
(defun tabularium-view-5 () "Apply view #5 from schema." (interactive) (tabularium--apply-view-by-index 5))
(defun tabularium-view-6 () "Apply view #6 from schema." (interactive) (tabularium--apply-view-by-index 6))
(defun tabularium-view-7 () "Apply view #7 from schema." (interactive) (tabularium--apply-view-by-index 7))
(defun tabularium-view-8 () "Apply view #8 from schema." (interactive) (tabularium--apply-view-by-index 8))
(defun tabularium-view-9 () "Apply view #9 from schema." (interactive) (tabularium--apply-view-by-index 9))

(defun tabularium--apply-default-view ()
  "Apply the default view if one is defined in the schema.
Called automatically when opening a database.
Set view parameters without calling `revert-buffer' (caller should refresh)."
  (when-let ((default-view (tabularium--schema-default-view)))
    (let ((name (plist-get default-view :name))
          (filter (plist-get default-view :filter))
          (columns (plist-get default-view :columns))
          (sort-spec (plist-get default-view :sort)))
      ;; Apply filter
      (setq tabularium--filter-rules
            (when filter
              (list (list :raw t :sql filter :desc name :connective nil))))
      ;; Apply column visibility and ordering
      (when columns
        (let ((all-fields (mapcar (lambda (f) (plist-get f :id))
                                  (tabularium--schema-fields))))
          (setq tabularium--hidden-columns
                (cl-remove-if (lambda (col) (memq col columns)) all-fields)))
        (setq tabularium--column-order columns))
      ;; Apply sort — sort-spec is either (col . dir) or ((col1 . dir1) ...)
      (when sort-spec
        (setq tabularium--sort-columns
              (if (and (consp (car sort-spec)) (symbolp (caar sort-spec)))
                  sort-spec
                (list sort-spec))))
      ;; Apply frozen rows (pinned row IDs)
      (setq tabularium--frozen-ids (plist-get default-view :frozen))
      ;; Track current view
      (setq tabularium--current-view name)
      ;; Update mode name to show view
      (setq mode-name (if name
                          (format "Tabularium[%s]" name)
                        "Tabularium")))))

(defun tabularium-aggregate-visible-count ()
  "Count entries currently visible (respecting filter)."
  (interactive)
  (let ((count (length tabulated-list-entries))
        (desc (tabularium--filter-description)))
    (if desc
        (message "Visible entries (%s): %d" desc count)
      (message "Total entries: %d" count))))

;;;###autoload
(defun tabularium-open-and-view (name)
  "Open database NAME and immediately show the view buffer.
If called from a view buffer, closes the current buffer first."
  (interactive
   (list (completing-read "Open database: "
                          (if (fboundp 'tabularium-registry--completion-table)
                              (tabularium-registry--completion-table)
                            (mapcar #'car tabularium-schemas))
                          nil nil nil nil tabularium--current-schema-name)))
  ;; Close current view buffer if currently in one
  (when (derived-mode-p 'tabularium-view-mode)
    (kill-buffer (current-buffer)))
  (tabularium-open name)
  (tabularium-view))

;;; ** 5.8 Marking Operations

(defface tabularium-marked-face
  '((((class color) (background dark))
     :background "#3a3a00" :foreground "#ffcc00" :weight bold :extend t)
    (((class color) (background light))
     :background "#ffffcc" :foreground "#8b6914" :weight bold :extend t)
    (t :weight bold :extend t))
  "Face for marked entries in Tabularium view."
  :group 'tabularium-faces)

(defface tabularium-registry-open-face
  '((t :inherit success :weight bold))
  "Face for the `+' indicator on the open database in the registry."
  :group 'tabularium-faces)

(defface tabularium-query-replace-face
  '((t :inherit isearch))
  "Face for highlighting matches during query-replace."
  :group 'tabularium-faces)

;; Highlight palette — ten hues, each available as a background fill
;; and as a foreground (text) color.  Every face is theme-aware: the
;; `dark' and `light' specs are independently tuned so the cell text
;; meets WCAG AAA contrast (>= 7:1) against its theme.  A single fixed
;; color cannot be AAA on both a near-white and a near-black
;; background at once, so the two specs differ deliberately.
;;
;; Background faces: dark theme = deep fill + white text; light theme
;; = pale fill + black text.  Foreground faces: dark theme = light
;; hue on the dark editor background; light theme = deep hue on white.

(defmacro tabularium--def-highlight-bg (name dark-bg light-bg doc)
  "Define a background highlight face NAME with DARK-BG and LIGHT-BG and docstring DOC."
  `(defface ,name
     '((((class color) (background dark))
        :background ,dark-bg :extend t)
       (((class color) (background light))
        :background ,light-bg :extend t)
       (t :inherit highlight))
     ,doc
     :group 'tabularium-faces))

(defmacro tabularium--def-highlight-fg (name dark-fg light-fg doc)
  "Define a foreground highlight face NAME with DARK-FG and LIGHT-FG and docstring DOC."
  `(defface ,name
     '((((class color) (background dark)) :foreground ,dark-fg)
       (((class color) (background light)) :foreground ,light-fg)
       (t :inherit default))
     ,doc
     :group 'tabularium-faces))

(tabularium--def-highlight-bg tabularium-highlight-bg-red
  "#7a1f1f" "#ffd4d4" "Red background highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-bg tabularium-highlight-bg-orange
  "#7a3d00" "#ffe0bf" "Orange background highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-bg tabularium-highlight-bg-amber
  "#6b4a00" "#ffeab0" "Amber background highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-bg tabularium-highlight-bg-yellow
  "#5c5200" "#fbf3a8" "Yellow background highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-bg tabularium-highlight-bg-green
  "#1f5223" "#c8f0c2" "Green background highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-bg tabularium-highlight-bg-teal
  "#0d4f4a" "#bdeee8" "Teal background highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-bg tabularium-highlight-bg-cyan
  "#0c4a57" "#bfeaf2" "Cyan background highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-bg tabularium-highlight-bg-blue
  "#1a3d70" "#cfddff" "Blue background highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-bg tabularium-highlight-bg-purple
  "#43306b" "#e0d4f7" "Purple background highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-bg tabularium-highlight-bg-magenta
  "#6b1f55" "#fbcdee" "Magenta background highlight face (WCAG AAA, theme-aware).")

(tabularium--def-highlight-fg tabularium-highlight-fg-red
  "#ff9d9d" "#a01010" "Red foreground highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-fg tabularium-highlight-fg-orange
  "#ffb870" "#9a4a00" "Orange foreground highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-fg tabularium-highlight-fg-amber
  "#e8c25a" "#7d5700" "Amber foreground highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-fg tabularium-highlight-fg-yellow
  "#dcd06a" "#6b6000" "Yellow foreground highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-fg tabularium-highlight-fg-green
  "#86d98a" "#1d6b22" "Green foreground highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-fg tabularium-highlight-fg-teal
  "#74d6cc" "#0a625b" "Teal foreground highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-fg tabularium-highlight-fg-cyan
  "#79cfe0" "#0a5c6b" "Cyan foreground highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-fg tabularium-highlight-fg-blue
  "#9db8ff" "#1a4499" "Blue foreground highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-fg tabularium-highlight-fg-purple
  "#c5a8f0" "#5a3a96" "Purple foreground highlight face (WCAG AAA, theme-aware).")
(tabularium--def-highlight-fg tabularium-highlight-fg-magenta
  "#f0a0d8" "#8a1f6f" "Magenta foreground highlight face (WCAG AAA, theme-aware).")

(defface tabularium-highlight-style-bold '((t :inherit bold))
  "Bold style highlight face."
  :group 'tabularium-faces)

(defface tabularium-highlight-style-italic '((t :inherit italic))
  "Italic style highlight face."
  :group 'tabularium-faces)

(defface tabularium-highlight-style-underline '((t :inherit underline))
  "Underline style highlight face."
  :group 'tabularium-faces)

(defface tabularium-highlight-style-strike '((t :strike-through t))
  "Strike-through style highlight face."
  :group 'tabularium-faces)

(defcustom tabularium-highlight-faces
  '(("bg: Red"     . tabularium-highlight-bg-red)
    ("bg: Orange"  . tabularium-highlight-bg-orange)
    ("bg: Amber"   . tabularium-highlight-bg-amber)
    ("bg: Yellow"  . tabularium-highlight-bg-yellow)
    ("bg: Green"   . tabularium-highlight-bg-green)
    ("bg: Teal"    . tabularium-highlight-bg-teal)
    ("bg: Cyan"    . tabularium-highlight-bg-cyan)
    ("bg: Blue"    . tabularium-highlight-bg-blue)
    ("bg: Purple"  . tabularium-highlight-bg-purple)
    ("bg: Magenta" . tabularium-highlight-bg-magenta)
    ("fg: Red"     . tabularium-highlight-fg-red)
    ("fg: Orange"  . tabularium-highlight-fg-orange)
    ("fg: Amber"   . tabularium-highlight-fg-amber)
    ("fg: Yellow"  . tabularium-highlight-fg-yellow)
    ("fg: Green"   . tabularium-highlight-fg-green)
    ("fg: Teal"    . tabularium-highlight-fg-teal)
    ("fg: Cyan"    . tabularium-highlight-fg-cyan)
    ("fg: Blue"    . tabularium-highlight-fg-blue)
    ("fg: Purple"  . tabularium-highlight-fg-purple)
    ("fg: Magenta" . tabularium-highlight-fg-magenta)
    ("style: Bold"      . tabularium-highlight-style-bold)
    ("style: Italic"    . tabularium-highlight-style-italic)
    ("style: Underline" . tabularium-highlight-style-underline)
    ("style: Strike"    . tabularium-highlight-style-strike))
  "Palette offered when adding a highlight rule.
An alist mapping a human-readable name (the string shown in the
`completing-read' face prompt of the highlight commands) to a face
symbol.  The defaults are grouped into three independent categories —
=bg:= background fills, =fg:= foreground text colors, and =style:=
attributes — so a cell can carry one of each at once when several
highlight rules stack.  The same ten hues are offered for both the
background and foreground groups.  Every default face is
theme-aware and tuned for WCAG AAA contrast on both dark and light
backgrounds.  Customize this to add your own faces or reorder the
choices.  The first entry is the default."
  :type '(alist :key-type string :value-type face)
  :group 'tabularium-faces)

(defun tabularium-view--update-mark-display ()
  "Update the display to show marks."
  (remove-overlays (point-min) (point-max) 'tabularium-mark t)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when-let ((id (tabulated-list-get-id)))
        (when (member id tabularium--marked-entries)
          (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
            (overlay-put ov 'tabularium-mark t)
            (overlay-put ov 'face 'tabularium-marked-face)
            (overlay-put ov 'priority 100)
            (overlay-put ov 'before-string (propertize "* " 'face 'tabularium-marked-face)))))
      (forward-line 1))))

(defun tabularium-view-mark ()
  "Mark entry at point, or all entries in the active region."
  (interactive)
  (if (use-region-p)
      ;; Mark all rows in region
      (let ((start (region-beginning))
            (end (region-end))
            (count 0))
        (save-excursion
          (goto-char start)
          (while (< (point) end)
            (when-let ((id (tabularium--id-at-point)))
              (unless (member id tabularium--marked-entries)
                (push id tabularium--marked-entries)
                (cl-incf count)))
            (forward-line 1)))
        (deactivate-mark)
        (tabularium-view--update-mark-display)
        (message "Unmarked region (%d still marked)" (length tabularium--marked-entries)))
    ;; Single row
    (when-let ((id (tabularium--id-at-point)))
      (unless (member id tabularium--marked-entries)
        (push id tabularium--marked-entries))
      (tabularium-view--update-mark-display)
      (forward-line 1)
      (message "Marked %d entries" (length tabularium--marked-entries)))))

(defun tabularium-view-unmark ()
  "Unmark entry at point, or all entries in the active region."
  (interactive)
  (if (use-region-p)
      (let ((start (region-beginning))
            (end (region-end)))
        (save-excursion
          (goto-char start)
          (while (< (point) end)
            (when-let ((id (tabularium--id-at-point)))
              (setq tabularium--marked-entries (delete id tabularium--marked-entries)))
            (forward-line 1)))
        (deactivate-mark)
        (tabularium-view--update-mark-display)
        (message "Marked %d entries" (length tabularium--marked-entries)))
    (when-let ((id (tabularium--id-at-point)))
      (let ((was-marked (member id tabularium--marked-entries)))
        (setq tabularium--marked-entries (delete id tabularium--marked-entries))
        (tabularium-view--update-mark-display)
        (forward-line 1)
        (message "%s (%d marked)"
                 (if was-marked "Unmarked" "Not marked")
                 (length tabularium--marked-entries))))))

(defun tabularium-view-unmark-all ()
  "Unmark all entries."
  (interactive)
  (setq tabularium--marked-entries nil)
  (tabularium-view--update-mark-display)
  (message "All marks cleared"))

(defun tabularium-view-toggle-marks ()
  "Toggle marks on all visible entries."
  (interactive)
  (let ((visible-ids (mapcar #'car tabulated-list-entries)))
    (dolist (id visible-ids)
      (if (member id tabularium--marked-entries)
          (setq tabularium--marked-entries (delete id tabularium--marked-entries))
        (push id tabularium--marked-entries))))
  (tabularium-view--update-mark-display)
  (message "Marked %d entries" (length tabularium--marked-entries)))

(defun tabularium-view-mark-range (spec)
  "Mark rows by position: SPEC names row ids, as in \"2,3,5-9\".
Marking can already select by value (`* s\=', `* e\=', `* p\=', `* r\='); this
selects by position, which is what a row range needs.  Marks add to any
already set, so several ranges can be combined; `U\=' clears them.

Marks are how a filter or highlight rule is limited to certain rows —
see `tabularium--read-row-restriction\=' — so this is the usual way to
build such a restriction."
  (interactive (list (read-string "Mark rows (comma-separated or range): ")))
  (let ((ids (tabularium--parse-id-range-spec spec)))
    (unless ids
      (user-error "No rows parsed from %S" spec))
    (let ((added 0))
      (dolist (id ids)
        (unless (member id tabularium--marked-entries)
          (push id tabularium--marked-entries)
          (cl-incf added)))
      (revert-buffer)
      (message "Marked %d row%s (total marked: %d)"
               added (if (= 1 added) "" "s")
               (length tabularium--marked-entries)))))

(defun tabularium-view-mark-matching (value &optional fields)
  "Mark all entries where VALUE appears as a substring in FIELDS.
FIELDS is a list of field name strings.  If nil, searches all fields."
  (interactive
   (let* ((value (read-string "Mark containing: " nil 'tabularium-search-history))
          (fields (tabularium--field-crm)))
     (list value fields)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (like-op (tabularium-db-like-op tabularium-case-sensitive))
         (search-fields (or fields (tabularium--stored-field-names)))
         (conditions (mapcar (lambda (f) (format "%s %s ?" f like-op)) search-fields))
         (where (string-join conditions " OR "))
         (params (mapcar (lambda (_) (tabularium-db-like-pattern value tabularium-case-sensitive)) search-fields))
         (sql (format "SELECT %s FROM %s WHERE %s"
                      primary-name tabularium-table-name where))
         (ids (mapcar #'car (tabularium-db-query tabularium--db sql params))))
    (setq tabularium--marked-entries (cl-union tabularium--marked-entries ids))
    (tabularium-view--update-mark-display)
    (message "Marked %d entries containing '%s' (total: %d)"
             (length ids) value (length tabularium--marked-entries))))

(defun tabularium-view-mark-exact (value &optional fields)
  "Mark all entries where VALUE equals a cell value exactly in FIELDS.
FIELDS is a list of field name strings.  If nil, searches all fields."
  (interactive
   (let* ((value (read-string "Mark equal to: " nil 'tabularium-search-history))
          (fields (tabularium--field-crm)))
     (list value fields)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (collate (tabularium-db-collate tabularium-case-sensitive))
         (search-fields (or fields (tabularium--stored-field-names)))
         (conditions (mapcar (lambda (f) (format "%s%s = ?" f collate)) search-fields))
         (where (string-join conditions " OR "))
         (params (mapcar (lambda (_) value) search-fields))
         (sql (format "SELECT %s FROM %s WHERE %s"
                      primary-name tabularium-table-name where))
         (ids (mapcar #'car (tabularium-db-query tabularium--db sql params))))
    (setq tabularium--marked-entries (cl-union tabularium--marked-entries ids))
    (tabularium-view--update-mark-display)
    (message "Marked %d entries equal to '%s' (total: %d)"
             (length ids) value (length tabularium--marked-entries))))

(defun tabularium-view-mark-pattern (pattern &optional fields)
  "Mark all entries where FIELDS match PATTERN.
When case-sensitive (default), uses GLOB with wildcards * and ?.
When case-insensitive, uses LIKE with wildcards %% and _.
FIELDS is a list of field name strings.  If nil, searches all fields."
  (interactive
   (let* ((pattern (read-string (format "Mark matching %s pattern: "
                                        (tabularium-db-like-op tabularium-case-sensitive))))
          (fields (tabularium--field-crm)))
     (list pattern fields)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (like-op (tabularium-db-like-op tabularium-case-sensitive))
         (search-fields (or fields (tabularium--stored-field-names)))
         (conditions (mapcar (lambda (f) (format "%s %s ?" f like-op)) search-fields))
         (where (string-join conditions " OR "))
         (params (mapcar (lambda (_) pattern) search-fields))
         (sql (format "SELECT %s FROM %s WHERE %s"
                      primary-name tabularium-table-name where))
         (ids (mapcar #'car (tabularium-db-query tabularium--db sql params))))
    (setq tabularium--marked-entries (cl-union tabularium--marked-entries ids))
    (tabularium-view--update-mark-display)
    (message "Marked %d entries matching '%s' (total: %d)"
             (length ids) pattern (length tabularium--marked-entries))))

(defun tabularium-view-mark-regexp (regexp &optional fields)
  "Mark all entries where FIELDS match Emacs REGEXP.
Uses Emacs regular expressions (not SQL patterns).
FIELDS is a list of field name strings.  If nil, searches all fields."
  (interactive
   (let* ((regexp (read-string "Mark matching regexp: " nil 'tabularium-regexp-history))
          (fields (tabularium--field-crm)))
     (list regexp fields)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (search-fields (or fields (tabularium--stored-field-names)))
         (case-fold (not tabularium-case-sensitive))
         (matching-ids '()))
    ;; Fetch all rows and filter in Emacs
    (dolist (field search-fields)
      (let* ((sql (format "SELECT %s, %s FROM %s"
                          primary-name field tabularium-table-name))
             (rows (tabularium-db-query tabularium--db sql nil)))
        (dolist (row rows)
          (let ((id (car row))
                (val (if (cadr row) (format "%s" (cadr row)) "")))
            (when (let ((case-fold-search case-fold))
                    (string-match-p regexp val))
              (push id matching-ids))))))
    (setq matching-ids (delete-dups matching-ids))
    (setq tabularium--marked-entries (cl-union tabularium--marked-entries matching-ids))
    (tabularium-view--update-mark-display)
    (message "Marked %d entries matching regexp '%s' (total: %d)"
             (length matching-ids) regexp (length tabularium--marked-entries))))

(defun tabularium-view-count-marked ()
  "Count marked entries."
  (interactive)
  (message "Marked: %d entries" (length tabularium--marked-entries)))

(defun tabularium-view-execute ()
  "Execute an action on marked entries or entry at point.
Presents a completion menu of available operations."
  (interactive)
  (let* ((has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0)))
         (count (if has-marks (length tabularium--marked-entries) 1))
         (target (if has-marks
                     (format "%d marked entries" count)
                   "entry at point"))
         (actions '(("copy"         . tabularium-view-copy)
                    ("cut"          . tabularium-view-cut)
                    ("delete"       . tabularium-view-delete)
                    ("duplicate"    . tabularium-view-duplicate)
                    ("edit"         . tabularium-view-edit)
                    ("export"       . tabularium-export)
                    ("fill"         . tabularium-view-fill-forward)
                    ("freeze"          . tabularium-view-freeze)
                    ("move"         . tabularium-view-move)
                    ("swap"         . tabularium-view-swap)))
         (choice (completing-read (format "Action on %s: " target)
                                  (mapcar #'car actions) nil t))
         (fn (alist-get choice actions nil nil #'string=)))
    (when fn
      (call-interactively fn))))

;;; * 6 Data Entry

;;; ** 6.1 Input Methods

;;; *** 6.1.1 Form-Based Entry

;;; *** 6.1.1.1 Mode & State

(defvar-local tabularium-entry--fields nil
  "List of field definitions for current form.")

(defvar-local tabularium-entry--values nil
  "Alist of current field values.")

(defvar-local tabularium-entry--original-values nil
  "Alist of original field values when form was opened.
Used to determine if changes have been made.")

(defvar-local tabularium-entry-editing-id nil
  "ID of record being edited, or nil for new entry.")

(defvar-local tabularium-entry--field-overlays nil
  "Alist of (field-name . overlay) for field value regions.")

(defvar-local tabularium-entry--current-field nil
  "Currently selected field name.")

(defvar-local tabularium-entry-schema-name nil
  "Schema name for this form buffer.")

(defvar-local tabularium-entry--source-buffer nil
  "Buffer from which the form was opened (e.g., view buffer).")

(defvar-local tabularium-entry--source-column nil
  "Column name at point in the source buffer when the form was opened.")

(defvar-local tabularium-entry--source-line-offset nil
  "Line offset from `window-start' in the source buffer when the form was opened.")

(defun tabularium--display-entry-buffer (buf)
  "Display entry buffer BUF according to `tabularium-entry-display'.
Reuses an existing window showing BUF if one is available."
  (if (eq tabularium-entry-display 'side)
      (pop-to-buffer buf
                     '((display-buffer-reuse-window
                        display-buffer-in-direction)
                       (direction . right)
                       (window-width . 0.4)))
    (switch-to-buffer buf)))

(defface tabularium-entry-current-field
  '((((class color) (background dark))
     :background "#3a3a5a" :extend t)
    (((class color) (background light))
     :background "#dce4f8" :extend t)
    (t :inherit highlight :extend t))
  "Face for the currently selected field in entry mode."
  :group 'tabularium-faces)

(defvar tabularium-entry-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Field navigation
    (define-key map (kbd "TAB") #'tabularium-entry-next-field)
    (define-key map (kbd "<backtab>") #'tabularium-entry-prev-field)
    (define-key map (kbd "<down>") #'tabularium-entry-next-field)
    (define-key map (kbd "<up>") #'tabularium-entry-prev-field)
    (define-key map (kbd "M-]") #'tabularium-entry-next-field)
    (define-key map (kbd "M-[") #'tabularium-entry-prev-field)
    (define-key map (kbd "C-c C-n") #'tabularium-entry-next-field)
    (define-key map (kbd "C-c C-p") #'tabularium-entry-prev-field)
    ;; Field editing
    (define-key map (kbd "RET") #'tabularium-entry-edit-field)
    (define-key map (kbd "C-c C-e") #'tabularium-entry-edit-field)
    (define-key map (kbd "C-c C-d") #'tabularium-entry-set-default)
    (define-key map (kbd "=") #'tabularium-entry-set-default)
    (define-key map (kbd "C-c C-r") #'tabularium-entry-reset-field)
    (define-key map (kbd "DEL") #'tabularium-entry-reset-field)
    (define-key map (kbd "<delete>") #'tabularium-entry-reset-field)
    (define-key map (kbd "<deletechar>") #'tabularium-entry-reset-field)
    (define-key map (kbd "x") #'tabularium-entry-reset-field)
    (define-key map (kbd "X") #'tabularium-entry-clear-and-edit)
    (define-key map (kbd "C-c C-x") #'tabularium-entry-clear-and-edit)
    ;; Submit/Cancel
    (define-key map (kbd "C-c C-c") #'tabularium-entry-submit)
    (define-key map (kbd "C-c C-k") #'tabularium-entry-cancel)
    (define-key map (kbd "C-c C-s") #'tabularium-entry-submit)
    (define-key map (kbd "C-<return>") #'tabularium-entry-submit)
    (define-key map (kbd ".") #'tabularium-entry-submit)
    ;; Entry operations (matching view-mode)
    (define-key map (kbd "N") #'tabularium-entry-new)
    (define-key map (kbd "I") #'tabularium-entry-insert)
    (define-key map (kbd "+") #'tabularium-entry-duplicate)
    (define-key map (kbd "D") #'tabularium-entry-delete)
    (define-key map (kbd "C-x C-s") #'tabularium-entry-submit)
    ;; Navigation
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "M-n") #'tabularium-entry-next-entry)
    (define-key map (kbd "M-p") #'tabularium-entry-prev-entry)
    (define-key map (kbd "'") #'tabularium-entry-goto-entry)
    ;; Undo/Redo
    (define-key map (kbd "C-/") #'tabularium-undo)
    (define-key map (kbd "C-_") #'tabularium-undo)
    (define-key map (kbd "C-?") #'tabularium-redo)
    (define-key map (kbd "C-S-/") #'tabularium-redo)
    (define-key map (kbd "M-_") #'tabularium-redo)
    ;; Return to view
    (define-key map (kbd "q") #'tabularium-entry-cancel)
    (define-key map (kbd "v") #'tabularium-entry-goto-view)
    map)
  "Keymap for `tabularium-entry-mode'.")

(define-derived-mode tabularium-entry-mode special-mode "Tabularium Entry"
  "Major mode for editing Tabularium entries in a form buffer.
Provides field navigation, completion, and entry operations.

\\{tabularium-entry-mode-map}"
  (setq buffer-read-only t)
  (setq-local truncate-lines t)
  ;; Field highlighting follows point — update on any cursor movement,
  ;; including mouse clicks and goto-char from outside our nav commands.
  (add-hook 'post-command-hook
            #'tabularium-entry--update-highlight-at-point nil t)
  ;; Confirm before killing a form buffer with unsaved edits (e.g. via
  ;; C-x k or window-deletion that triggers buffer cleanup).
  (add-hook 'kill-buffer-query-functions
            #'tabularium-entry--confirm-kill nil t))

(defun tabularium-entry--confirm-kill ()
  "Return non-nil unless the user wants to keep editing.
Used in `kill-buffer-query-functions' to safeguard unsaved form data."
  (or (not (tabularium-entry-edited-p))
      (yes-or-no-p
       (format "Form '%s' has unsaved changes.  Kill anyway? "
               (buffer-name)))))

(defvar tabularium-entry-render-hook nil
  "Hook run at the end of form buffer rendering.
Called inside the render function with `inhibit-read-only' bound
to t, after the standard hint lines but before cursor positioning.
Plugins can use this to inject additional content such as
cross-table data or schema-specific hint lines.")

(defvar tabularium-entry-pre-render-hook nil
  "Hook run at the start of form buffer rendering, before layout.
Called inside `tabularium-entry-render' with the form buffer current
but before the buffer is erased.  Plugins should use this to set
buffer-local variables consulted during render — most notably
`tabularium-entry-header-function' — that need to be in place
before the layout pass runs.")

(defvar tabularium-entry-new-hook nil
  "Hook run when a NEW entry form is rendered.
Called in the form buffer after the initial values have been set
but before `tabularium-entry-render' lays out the buffer.  Plugins
can mutate `tabularium-entry--values' to populate plugin-specific
defaults that are not expressible as simple `:default' values
\(e.g. cross-field logic, computed dates, counters).
Not called when editing an existing entry.")

(defvar tabularium-entry-pre-submit-hook nil
  "Hook run in the form buffer just before save.
Plugins can mutate `tabularium-entry--values' to update fields
\(e.g. a Date-modified field set to today on every save) before
the values are written to the database.  Runs for both new and
edited entries; check `tabularium-entry-editing-id' to distinguish
\(nil = new entry, integer = update).")

(defvar-local tabularium-entry-header-function nil
  "Function returning a header string to insert at the top of the form.
When non-nil, called by `tabularium-entry-render' with no arguments;
should return a string (with optional `\\n's) or nil for no header.
The header is inserted before the schema field list.

This variable is buffer-local; for schema-wide configuration, set
the schema's `:header-function' property instead.  When both are
set, the buffer-local value wins.")

(defvar tabularium-entry-required-field-functions nil
  "List of functions declaring dynamic required fields.
Each function is called during `tabularium-entry-render' with two
arguments — FIELD-NAME (a symbol) and VALUES (the current
`tabularium-entry--values' alist) — and should return non-nil if
FIELD-NAME is required given the entry's current state.

Used to express type-specific or otherwise contextual required
fields that cannot be captured by static `:required t' in the
schema.  A field marked dynamically required displays a `+'
indicator; statically required fields continue to display `*'
\(static wins when both apply).

Functions in this list compose by short-circuit: the first
non-nil return value marks the field as required.")

(defvar tabularium-entry-field-changed-functions nil
  "Abnormal hook run when a field value changes in the form buffer.
Each function is called with three arguments — FIELD-NAME (symbol),
OLD-VALUE, and NEW-VALUE — after the value has been committed to
`tabularium-entry--values' and before the buffer is re-rendered.

Fires for direct user edits (e.g. ~tabularium-entry-edit-field~),
default-setting, clearing, and autofill cascades — but not for
programmatic mutations from other hooks (e.g. ~pre-submit-hook~)
which set values via `setf' directly.

Plugin functions may further mutate `tabularium-entry--values' in
response (e.g. clearing dependent fields when a type changes).
Such mutations will themselves fire this hook, so plugins should
guard against unbounded recursion.")

(defun tabularium--compute-default (field)
  "Compute the default value for FIELD.
The symbols `today' and `now' are resolved based on the field's
`:type'.  Resolution rules:

  `today' → today's date in `tabularium-date-format'.
  `now' on a `time' field → current time in `tabularium-time-format'.
  `now' on a `date' field → today's date in `tabularium-date-format'.
  `now' on a `datetime' field → current timestamp in
                                `tabularium-datetime-format'.
  `now' on any other type → current timestamp in
                            `tabularium-datetime-format'.

Other values are returned as-is, with functions called with no
arguments."
  (let ((default (plist-get field :default))
        (type (plist-get field :type)))
    (pcase default
      ('today (format-time-string tabularium-date-format))
      ('now (pcase type
              ('time (format-time-string tabularium-time-format))
              ('date (format-time-string tabularium-date-format))
              ('datetime (format-time-string tabularium-datetime-format))
              (_ (format-time-string tabularium-datetime-format))))
      ((pred functionp) (funcall default))
      (_ default))))

(defun tabularium--next-id ()
  "Get the next ID for auto-increment primary key."
  (tabularium--ensure-db)
  (let* ((primary (symbol-name (tabularium--primary-field-name)))
         (sql (format "SELECT COALESCE(MAX(%s), 0) + 1 FROM %s"
                      primary tabularium-table-name)))
    (tabularium-db-query-scalar tabularium--db sql)))

(defun tabularium--get-record-by-id (id)
  "Get record with ID as an alist."
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (col-info (tabularium--get-table-columns))
         (col-names (mapcar (lambda (c) (plist-get c :id)) col-info))
         (sql (format "SELECT * FROM %s WHERE %s = ?"
                      tabularium-table-name primary-name))
         (row (tabularium-db-query-single tabularium--db sql (list id))))
    (when row
      (cl-mapcar #'cons col-names row))))

(defun tabularium--get-table-columns ()
  "Get column information for current table."
  (tabularium-db-table-columns tabularium--db tabularium-table-name))

(defun tabularium--use-form-p (use-alt-method)
  "Return non-nil if form method should be used.
USE-ALT-METHOD flips the default from `tabularium-entry-method'."
  (if use-alt-method
      (eq tabularium-entry-method 'minibuffer)
    (eq tabularium-entry-method 'form)))

(defun tabularium-entry--get-field-completions (field)
  "Get completion candidates for FIELD in form context.
Uses current form values for related field completion."
  (let* ((type (plist-get field :type))
         (choices (plist-get field :choice))
         (complete (plist-get field :complete))
         ;; Get current form values for context (enables related completion)
         (context (when (boundp 'tabularium-entry--values)
                    tabularium-entry--values)))
    (cond
     ;; Choice field with explicit choices (high priority)
     ((and (eq type 'choice) choices)
      choices)
     ;; Has :complete spec - use the enhanced dispatcher
     (complete
      (tabularium--get-completion-candidates field context))
     ;; Boolean type — restricted to a single canonical pair
     ((eq type 'boolean)
      (let ((pair (tabularium--boolean-pair-for field)))
        (if pair
            (list (car pair) (cadr pair))
          ;; No pair determined yet: fall back to the canonical list of
          ;; first-entries (the user's choice here will lock in the pair
          ;; for the column going forward).
          tabularium--boolean-pair-anchors)))
     ;; No completion
     (t nil))))

(defvar-local tabularium-entry-first-field-line nil
  "Line number of first field in form buffer.")

(defvar-local tabularium-entry-footer-start nil
  "Position where footer starts in form buffer.")

;;; *** 6.1.1.2 Rendering

(defun tabularium-entry-render ()
  "Render the form buffer."
  ;; Pre-render hook: plugins set buffer-local variables consulted during
  ;; layout (e.g. `tabularium-entry-header-function').
  (run-hooks 'tabularium-entry-pre-render-hook)
  (let ((inhibit-read-only t)
        (first-field-line nil)
        (footer-start nil))
    (erase-buffer)
    (setq tabularium-entry--field-overlays nil)
    ;; Header - double lines for edit mode emphasis
    (let ((title (format "%s: %s"
                         tabularium-entry-schema-name
                         (if tabularium-entry-editing-id
                             (format "Edit #%s" tabularium-entry-editing-id)
                           "New Entry"))))
      (insert (tabularium--make-box-header title 80 'double) "\n"))
    (insert "\n")
    ;; Plugin header — text inserted by the active header function appears
    ;; between the title bar and the field list.  The buffer-local
    ;; `tabularium-entry-header-function' takes precedence; otherwise the
    ;; render falls back to the schema's `:header-function' property.
    ;; Plugins can use either to render a citation, summary, or other
    ;; contextual content.
    (let ((header-fn (or tabularium-entry-header-function
                         (plist-get (cdr (tabularium--current-schema))
                                    :header-function))))
      (when header-fn
        (let ((header-text (funcall header-fn)))
          (when (and header-text (stringp header-text)
                     (not (string-empty-p header-text)))
            (insert header-text)
            (unless (eq (char-before) ?\n)
              (insert "\n"))
            (insert "\n")))))
    ;; Fields - use %-20s to align with entry mode
    (dolist (field tabularium-entry--fields)
      (let* ((name (plist-get field :id))
             (prompt (plist-get field :label))
             (required (plist-get field :required))
             (dyn-required
              (and (not required)
                   (run-hook-with-args-until-success
                    'tabularium-entry-required-field-functions
                    name tabularium-entry--values)))
             (type (plist-get field :type))
             (choices (plist-get field :choice))
             (complete (plist-get field :complete))
             (value (or (alist-get name tabularium-entry--values) ""))
             (value-str (format "%s" value)))
        ;; Track first field line
        (unless first-field-line
          (setq first-field-line (line-number-at-pos)))
        ;; Field label — required marker occupies the last padding character
        ;; so the colon aligns at the same column for all fields.
        ;; `*' for static :required t (always required)
        ;; `+' for dynamic-required (plugin-declared, contextual)
        ;;
        ;; A short type marker (`[I]', `[N]', `[D]', `[T]', `[DT]',
        ;; `[C]', `[B]') is appended to the label so the user knows at
        ;; a glance what kind of value is expected.  Text fields (the
        ;; default) get no marker, keeping plain text fields visually
        ;; uncluttered.  When the label + marker combination overflows
        ;; the 20-char budget the marker is dropped from the label area
        ;; (the right-side hint still conveys it for choice/boolean).
        (let* ((label-marker (and tabularium-entry-show-type-hints
                                  (tabularium--field-type-hint field 'label)))
               (label-budget (if (or required dyn-required) 19 20))
               ;; The marker is kept whenever there is one.  If the
               ;; label + " " + marker overflows the fixed label-area
               ;; width, the *label* is truncated with an ellipsis so
               ;; the marker survives — the type hint is more useful in
               ;; cramped space than the tail of a long field id, and
               ;; the required `*'/`+' marker still aligns either way.
               (marker-shown (and label-marker t))
               (marker-cost (if label-marker
                                (1+ (length label-marker)) ; " " + marker
                              0))
               (label-room (- label-budget marker-cost))
               (display-label
                (if (and label-marker
                         (> (+ (length prompt) marker-cost) label-budget)
                         (> label-room 1))
                    ;; Truncate the label, keep one char for the ellipsis.
                    (concat (substring prompt 0 (1- label-room)) "…")
                  prompt))
               ;; Visible width of the composed label area, for padding.
               (composed-width (+ (length display-label)
                                  (if marker-shown marker-cost 0)))
               ;; Compose with the label faced as a keyword and the type
               ;; marker faced `shadow' — the same faded face the
               ;; right-of-value choice/boolean hints use — so the
               ;; marker reads as a hint, not part of the label.
               (label-area
                (let ((s (if marker-shown
                             (concat
                              (propertize display-label
                                          'face 'font-lock-keyword-face)
                              " "
                              (propertize label-marker 'face 'shadow))
                           (propertize display-label
                                       'face 'font-lock-keyword-face))))
                  (if (< composed-width label-budget)
                      (concat s (make-string (- label-budget composed-width)
                                             ?\s))
                    s))))
          ;; The whole label area carries the navigation property.
          (add-text-properties 0 (length label-area)
                               (list 'tabularium-entry-label name)
                               label-area)
          (cond
           (required
            (insert "  " label-area (propertize "*" 'face 'error)))
           (dyn-required
            (insert "  " label-area (propertize "+" 'face 'warning)))
           (t
            (insert "  " label-area))))
        (insert ": ")
        ;; Field value with overlay for highlighting
        ;; Max value width: 80 - 2 (indent) - 20 (label) - 2 (": ") - 1 (*) - 2 (pad) = 53
        (let* ((max-val-width 53)
               (start (point))
               (display-value
                (if (string-empty-p value-str)
                    (propertize "<empty>" 'face 'shadow)
                  (if (plist-get field :long)
                      ;; Long fields: first line + metadata
                      (let* ((first-line (car (split-string value-str "\n")))
                             (total-len (length value-str))
                             (line-count (1+ (cl-count ?\n value-str)))
                             (meta (if (or (> line-count 1) (> total-len max-val-width))
                                       (propertize
                                        (format " [%d chars, %d lines]" total-len line-count)
                                        'face 'shadow)
                                     ""))
                             (avail (- max-val-width (length meta)))
                             (truncated (if (> (length first-line) avail)
                                            (concat (substring first-line 0 (max 0 (- avail 1))) "…")
                                          first-line)))
                        (concat truncated meta))
                    ;; Regular fields: truncate to box width
                    (let ((clean (replace-regexp-in-string "[\n\r]" " " value-str)))
                      (if (> (length clean) max-val-width)
                          (concat (substring clean 0 (- max-val-width 1)) "…")
                        clean))))))
          (insert display-value)
          (let ((ov (make-overlay start (point))))
            (overlay-put ov 'tabularium-field name)
            (overlay-put ov 'tabularium-value value)
            (push (cons name ov) tabularium-entry--field-overlays)))
        ;; Right-of-value annotation.  Choice fields show their
        ;; candidate list; boolean fields show the configured pair.
        ;; Plain typed fields (integer/number/date/time/datetime) no
        ;; longer get a right-side hint — their type marker now sits
        ;; in the label area (e.g. =LABEL [N]_____*: <empty>=).
        (let ((hint
               (cond
                ((and choices
                      (or (eq type 'choice)
                          (and (eq type 'text) (eq complete 'fixed))))
                 (let ((display-choices
                        (if (<= (length choices) 5)
                            (string-join choices ", ")
                          (concat (string-join (seq-take choices 4) ", ") ", …"))))
                   (format "  [%s]" display-choices)))
                ((eq type 'boolean)
                 (let ((pair (plist-get field :boolean-pair)))
                   (if (and (listp pair) (= (length pair) 2))
                       (format "  [%s/%s]" (car pair) (cadr pair))
                     "  [Yes/No]")))
                (t nil))))
          (when hint
            (let ((avail (- 78 (current-column))))
              (when (> (length hint) avail)
                (setq hint (if (> avail 6)
                               (concat (substring hint 0 (- avail 1)) "…")
                             "")))
              (unless (string-empty-p hint)
                (insert (propertize hint 'face 'shadow))))))
        (insert "\n")))
    ;; Footer - double lines to match header
    (insert "\n")
    (setq footer-start (point))
    (insert (tabularium--make-box-footer 80 'double) "\n")
    (insert "  "
            (propertize "TAB" 'face 'help-key-binding) "/"
            (propertize "S-TAB" 'face 'help-key-binding) " Nav  "
            (propertize "n" 'face 'help-key-binding) "/"
            (propertize "p" 'face 'help-key-binding) " Line ↓/↑  "
            (propertize "M-n" 'face 'help-key-binding) "/"
            (propertize "M-p" 'face 'help-key-binding) " Entry ↓/↑  "
            (propertize "'" 'face 'help-key-binding) " Goto\n")
    (insert "  "
            (propertize "RET" 'face 'help-key-binding) " Edit  "
            (propertize "x" 'face 'help-key-binding) " Clear  "
            (propertize "X" 'face 'help-key-binding) " Clear + Edit  "
            (propertize "=" 'face 'help-key-binding) " Default\n")
    (insert "  "
            (propertize "N" 'face 'help-key-binding) " New  "
            (propertize "I" 'face 'help-key-binding) " Insert  "
            (propertize "+" 'face 'help-key-binding) " Dup  "
            (propertize "D" 'face 'help-key-binding) " Del  "
            (propertize "v" 'face 'help-key-binding) " View\n")
    (insert "  "
            (propertize "q" 'face 'help-key-binding) " Cancel  "
            (propertize "." 'face 'help-key-binding) "/"
            (propertize "C-c C-c" 'face 'help-key-binding) "/"
            (propertize "C-RET" 'face 'help-key-binding) " Submit")
    ;; Store bounds — must happen before the hook so plugins can read them
    (setq tabularium-entry-first-field-line (or first-field-line 3))
    (setq tabularium-entry-footer-start footer-start)
    ;; Plugin hook — inject additional content after standard hints
    (run-hooks 'tabularium-entry-render-hook)
    ;; Position on current field if set, otherwise first editable field
    (goto-char (point-min))
    (let* ((fields (tabularium-entry--field-list))
           (primary-name (tabularium--primary-field-name))
           (target-field (or tabularium-entry--current-field
                             (cl-find-if (lambda (f) (not (eq f primary-name))) fields)
                             (car fields))))
      (tabularium-entry--goto-field target-field))))

;;; *** 6.1.1.3 Navigation

(defun tabularium-entry--goto-field (field-name)
  "Move cursor to FIELD-NAME and highlight it."
  (when-let ((ov (alist-get field-name tabularium-entry--field-overlays)))
    ;; Remove old highlighting
    (dolist (pair tabularium-entry--field-overlays)
      (overlay-put (cdr pair) 'face nil))
    ;; Highlight current
    (overlay-put ov 'face 'tabularium-entry-current-field)
    (goto-char (overlay-start ov))
    (setq tabularium-entry--current-field field-name)))

(defun tabularium-entry--update-highlight-at-point ()
  "Update field highlighting to follow point.
If point is over a field overlay different from the currently highlighted
one, move the highlight there (without moving point).  If point is not
over any field overlay, leave the highlighting unchanged."
  (let ((field (tabularium-entry--field-at-point)))
    (when (and field (not (eq field tabularium-entry--current-field)))
      (when-let ((ov (alist-get field tabularium-entry--field-overlays)))
        (dolist (pair tabularium-entry--field-overlays)
          (overlay-put (cdr pair) 'face nil))
        (overlay-put ov 'face 'tabularium-entry-current-field)
        (setq tabularium-entry--current-field field)))))

(defun tabularium-entry--field-list ()
  "Get ordered list of field names."
  (reverse (mapcar #'car tabularium-entry--field-overlays)))

(defun tabularium-entry-all-nav-positions ()
  "Return a sorted list of navigable positions in the form buffer.
Each element is (LINE-NUMBER POSITION . FIELD-NAME-OR-NIL).
Schema field overlays and lines with the `tabularium-navigable'
text property are both included, enabling plugin content to
participate in field navigation."
  (let ((positions '()))
    ;; Field overlays (position is mid-line; normalize to line number)
    (dolist (pair tabularium-entry--field-overlays)
      (let ((name (car pair))
            (ov (cdr pair)))
        (when (overlay-buffer ov)
          (let ((pos (overlay-start ov)))
            (push (list (line-number-at-pos pos) pos name) positions)))))
    ;; Extra navigable lines (text property set by plugins)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (when (get-text-property (point) 'tabularium-navigable)
          (let* ((pos (line-beginning-position))
                 (lnum (line-number-at-pos pos)))
            (unless (cl-some (lambda (p) (= (car p) lnum)) positions)
              (push (list lnum pos nil) positions))))
        (forward-line 1)))
    ;; Sort by line number
    (sort positions (lambda (a b) (< (car a) (car b))))))

(defun tabularium-entry--clear-field-highlight ()
  "Remove field highlighting from all overlays."
  (dolist (pair tabularium-entry--field-overlays)
    (overlay-put (cdr pair) 'face nil)))

(defun tabularium-entry--goto-nav (target)
  "Navigate to TARGET, a (LINE-NUMBER POSITION . FIELD-OR-NIL) entry."
  (let ((pos (nth 1 target))
        (field (nth 2 target)))
    (if field
        (tabularium-entry--goto-field field)
      (tabularium-entry--clear-field-highlight)
      (setq tabularium-entry--current-field nil)
      (goto-char pos))))

(defun tabularium-entry-next-field ()
  "Move to the next navigable position.
Wraps to the first position when past the last."
  (interactive)
  (let* ((nav (tabularium-entry-all-nav-positions))
         (cur-line (line-number-at-pos))
         (next (cl-find-if (lambda (p) (> (car p) cur-line)) nav))
         (target (or next (car nav))))
    (when target
      (tabularium-entry--goto-nav target))))

(defun tabularium-entry-prev-field ()
  "Move to the previous navigable position.
Wraps to the last position when before the first."
  (interactive)
  (let* ((nav (tabularium-entry-all-nav-positions))
         (cur-line (line-number-at-pos))
         (prev (car (last (cl-remove-if-not
                           (lambda (p) (< (car p) cur-line))
                           nav))))
         (target (or prev (car (last nav)))))
    (when target
      (tabularium-entry--goto-nav target))))

(defun tabularium-entry--filtered-ids ()
  "Return entry IDs in the current filtered/sorted order.
Reads filter and sort state from the source view buffer.
Falls back to primary-key order when no source buffer exists."
  (tabularium--ensure-db)
  (let* ((source tabularium-entry--source-buffer)
         (primary-name (symbol-name (tabularium--primary-field-name)))
         (filter-clause (when (and source (buffer-live-p source))
                          (with-current-buffer source
                            (tabularium--build-filter-clause))))
         (order-clause (if (and source (buffer-live-p source))
                           (with-current-buffer source
                             (tabularium--build-order-clause))
                         (format "%s DESC" primary-name)))
         (where (if filter-clause
                    (format "WHERE %s" filter-clause)
                  ""))
         (sql (format "SELECT %s FROM %s %s ORDER BY %s"
                      primary-name tabularium-table-name
                      where order-clause)))
    (mapcar #'car (tabularium-db-query tabularium--db sql))))

(defun tabularium-entry-next-entry ()
  "Save current entry and move to the next one in filtered order."
  (interactive)
  (if (not tabularium-entry-editing-id)
      (message "Cannot navigate: this is a new entry")
    (let* ((ids (tabularium-entry--filtered-ids))
           (pos (cl-position tabularium-entry-editing-id ids))
           (next-id (when pos (nth (1+ pos) ids)))
           (source tabularium-entry--source-buffer))
      (if next-id
          (progn
            (when (tabularium-entry-edited-p)
              (tabularium-entry-submit))
            (tabularium-new-entry next-id)
            ;; Preserve source buffer for subsequent navigation
            (when (and source (buffer-live-p source))
              (setq tabularium-entry--source-buffer source)))
        (message "No next entry")))))

(defun tabularium-entry-prev-entry ()
  "Save current entry and move to the previous one in filtered order."
  (interactive)
  (if (not tabularium-entry-editing-id)
      (message "Cannot navigate: this is a new entry")
    (let* ((ids (tabularium-entry--filtered-ids))
           (pos (cl-position tabularium-entry-editing-id ids))
           (prev-id (when (and pos (> pos 0)) (nth (1- pos) ids)))
           (source tabularium-entry--source-buffer))
      (if prev-id
          (progn
            (when (tabularium-entry-edited-p)
              (tabularium-entry-submit))
            (tabularium-new-entry prev-id)
            ;; Preserve source buffer for subsequent navigation
            (when (and source (buffer-live-p source))
              (setq tabularium-entry--source-buffer source)))
        (message "No previous entry")))))

;;; *** 6.1.1.4 Field Editing

(defun tabularium-entry--field-at-point ()
  "Return the field name at point, or nil if not on a field."
  (let ((overlays (overlays-at (point))))
    (cl-some (lambda (ov)
               (overlay-get ov 'tabularium-field))
             overlays)))

(defun tabularium-entry--field-empty-p (field-name)
  "Return non-nil if FIELD-NAME has an empty value."
  (let ((value (alist-get field-name tabularium-entry--values)))
    (or (null value)
        (and (stringp value) (string-empty-p value))
        (and (stringp value) (string= value "<empty>")))))

(defvar tabularium-entry--goto-prev-field nil
  "When non-nil, signals that the previous field was requested during input.")

(defvar tabularium-entry--submit-after-field nil
  "When non-nil, signals that form submission was requested during input.")

(defun tabularium-entry--abort-to-prev ()
  "Abort current minibuffer input and signal to go to previous field."
  (interactive)
  (setq tabularium-entry--goto-prev-field t)
  (abort-recursive-edit))

(defun tabularium-entry--exit-and-submit ()
  "Accept current minibuffer input and signal to submit form after."
  (interactive)
  (setq tabularium-entry--submit-after-field t)
  (exit-minibuffer))

(defun tabularium-entry--read-with-prev-field (prompt completions initial
                                                       &optional require-match
                                                       field)
  "Read input with PROMPT, COMPLETIONS, and INITIAL value.
When REQUIRE-MATCH is non-nil and COMPLETIONS is non-empty, the
user must select one of the completion candidates (no free text).

FIELD, when non-nil, is the schema field plist and enables the
full validation chain: type-based validity, `:pattern' regex, and
custom `:validate' function.  Empty input is always accepted (so
users can clear a field).  The prompt re-loops on invalid input
with a brief inline complaint.

Returns the new value, or nil if aborted to go to the previous field."
  (setq tabularium-entry--goto-prev-field nil)
  (setq tabularium-entry--submit-after-field nil)
  (let ((setup-fn (lambda ()
                    ;; Override in the actual minibuffer keymap to take
                    ;; precedence over minor-mode maps (e.g. outline)
                    (let ((map (current-local-map)))
                      (when map
                        (define-key map (kbd "<backtab>") #'tabularium-entry--abort-to-prev)
                        (define-key map (kbd "S-TAB") #'tabularium-entry--abort-to-prev)
                        (define-key map (kbd "<S-iso-lefttab>") #'tabularium-entry--abort-to-prev)
                        (define-key map (kbd "C-<return>") #'tabularium-entry--exit-and-submit)
                        (define-key map (kbd "<C-return>") #'tabularium-entry--exit-and-submit)
                        (define-key map (kbd "C-c C-c") #'tabularium-entry--exit-and-submit))))))
    (unwind-protect
        (progn
          (add-hook 'minibuffer-setup-hook setup-fn)
          (condition-case nil
              ;; Validation loop: keep prompting until a type-valid (or empty)
              ;; value is entered.  Abort-to-prev breaks out via the quit
              ;; handler below.
              (let ((value nil)
                    (current-initial initial)
                    (done nil))
                (while (not done)
                  (setq value
                        (if completions
                            (completing-read prompt completions nil
                                             require-match current-initial)
                          (read-string prompt current-initial)))
                  (let ((err (and field
                                  (tabularium--validate-field-input value field))))
                    (if (null err)
                        (setq done t)
                      (message "%s" err)
                      (sit-for 1.0)
                      (setq current-initial value))))
                value)
            (quit
             (if tabularium-entry--goto-prev-field
                 nil
               (signal 'quit nil)))))
      (remove-hook 'minibuffer-setup-hook setup-fn))))

(defun tabularium-entry--set-field-value (field-name new-value)
  "Set FIELD-NAME's value to NEW-VALUE in the form buffer.
Updates `tabularium-entry--values' and runs
`tabularium-entry-field-changed-functions' with the field name,
old value, and new value as arguments.  Used by all interactive
field-change paths (edit, clear, default, autofill).

Returns the new value."
  (let ((old-value (alist-get field-name tabularium-entry--values)))
    (setf (alist-get field-name tabularium-entry--values) new-value)
    (run-hook-with-args 'tabularium-entry-field-changed-functions
                        field-name old-value new-value)
    new-value))

(defun tabularium-entry-edit-field ()
  "Edit the field at point with completion.
Fields with `:long t' open a dedicated editing buffer instead of
the minibuffer."
  (interactive)
  ;; Use field at point if available, otherwise use highlighted field
  (let ((field-name (or (tabularium-entry--field-at-point)
                        tabularium-entry--current-field)))
    (when-let* ((field (cl-find-if (lambda (f) (eq (plist-get f :id) field-name))
                                   tabularium-entry--fields)))
      ;; Update current field to match what is being edited
      (setq tabularium-entry--current-field field-name)
      (if (plist-get field :long)
          ;; Long field: open dedicated editing buffer
          (let* ((current-value (or (alist-get field-name tabularium-entry--values) ""))
                 (initial (if (stringp current-value) current-value
                            (format "%s" current-value)))
                 (entry-buf (current-buffer)))
            (tabularium--edit-long-field
             (symbol-name field-name) initial
             (lambda (text)
               (with-current-buffer entry-buf
                 (tabularium-entry--set-field-value field-name text)
                 (tabularium-entry-render)
                 (tabularium-entry--goto-field field-name)
                 (message "Saved %s (%d chars)" (plist-get field :label)
                          (length text))))))
        ;; Normal field: minibuffer prompt
        (let* ((prompt (tabularium--field-prompt field))
               (current-value (or (alist-get field-name tabularium-entry--values) ""))
               ;; Track if field was empty before editing
               (was-empty (tabularium-entry--field-empty-p field-name))
               (completions (tabularium-entry--get-field-completions field))
               (field-type (plist-get field :type))
               (field-complete (plist-get field :complete))
               ;; Require strict completion for choice fields, boolean
               ;; fields (locked to a single canonical pair), and text
               ;; fields restricted to a fixed list of candidates.
               (strict (or (eq field-type 'choice)
                           (eq field-type 'boolean)
                           (and (eq field-type 'text) (eq field-complete 'fixed))))
               (initial (if (stringp current-value)
                            current-value
                          (format "%s" current-value)))
               (new-value (tabularium-entry--read-with-prev-field
                           prompt completions initial strict
                           field)))
          ;; Check if prior navigation to previous field
          (if (null new-value)
              (progn
                ;; Go to previous field
                (let* ((fields (tabularium-entry--field-list))
                       (idx (cl-position field-name fields))
                       (prev-field (nth (mod (1- (or idx 0)) (length fields)) fields)))
                  (setq tabularium-entry--current-field prev-field)
                  (tabularium-entry-render)
                  (message "Moved to previous field")))
            ;; Normal completion - save value and proceed
            (tabularium-entry--set-field-value field-name new-value)
            (when tabularium-debug
              (message "DEBUG edit-field: edited %s, new-value='%s', was-empty=%s"
                       field-name new-value was-empty))
            ;; Check if this field is a source for any paired field
            (tabularium-entry--maybe-fill-paired field-name new-value)
            (when tabularium-debug
              (message "DEBUG edit-field: after maybe-fill-paired, values=%S"
                       tabularium-entry--values))
            ;; Check if C-RET or C-c C-c was pressed to submit immediately
            (if tabularium-entry--submit-after-field
                (progn
                  (tabularium-entry-render)
                  (tabularium-entry-submit))
              ;; Compute next field and move there
              (let* ((fields (tabularium-entry--field-list))
                     (idx (cl-position field-name fields))
                     (next-field (nth (mod (1+ (or idx 0)) (length fields)) fields)))
                (setq tabularium-entry--current-field next-field)
                (tabularium-entry-render)
                ;; Only auto-enter next field if current field was empty (new data entry)
                ;; and next field is also empty. Skip if doing touch-up edits.
                (when (and was-empty (tabularium-entry--field-empty-p next-field))
                  (run-at-time 0 nil #'tabularium-entry-edit-field))))))))))

(defun tabularium-entry--maybe-fill-paired (source-field-name source-value)
  "If any fields have autofill from SOURCE-FIELD-NAME, fill them.
Only fills if the target field is currently empty and a historical
co-occurrence exists for SOURCE-VALUE."
  (let ((target-fields (tabularium--find-autofill-targets source-field-name)))
    (if (null target-fields)
        (when tabularium-debug
          (message "DEBUG: No autofill targets for %s" source-field-name))
      (dolist (target-field target-fields)
        (let* ((target-name (plist-get target-field :id))
               (current-target (alist-get target-name tabularium-entry--values)))
          (if (and current-target (stringp current-target) (not (string-empty-p current-target)))
              (when tabularium-debug
                (message "DEBUG: Target %s already has value: %s" target-name current-target))
            (let ((autofill-value (tabularium--get-autofill-value
                                   source-field-name source-value target-name)))
              (if (not autofill-value)
                  (when tabularium-debug
                    (message "DEBUG: No autofill value found for %s=%s -> %s"
                             source-field-name source-value target-name))
                (tabularium-entry--set-field-value target-name autofill-value)
                (message "Auto-filled %s: %s"
                         (plist-get target-field :label) autofill-value)))))))))

(defun tabularium-entry-set-default ()
  "Set current field to its default value."
  (interactive)
  (when-let* ((field-name tabularium-entry--current-field)
              (field (cl-find-if (lambda (f) (eq (plist-get f :id) field-name))
                                 tabularium-entry--fields))
              (default (tabularium--compute-default field)))
    (tabularium-entry--set-field-value field-name default)
    (tabularium-entry-render)
    (tabularium-entry--goto-field field-name)
    (message "Set %s to default: %s" (plist-get field :label) default)))

(defun tabularium-entry-reset-field ()
  "Reset current field to empty."
  (interactive)
  (let ((field-name (or (tabularium-entry--field-at-point)
                        tabularium-entry--current-field)))
    (when field-name
      (tabularium-entry--set-field-value field-name "")
      (setq tabularium-entry--current-field field-name)
      (tabularium-entry-render)
      (message "Cleared %s" field-name))))

(defun tabularium-entry-clear-and-edit ()
  "Clear the current field and immediately prompt for a new value.
Combines `tabularium-entry-reset-field' and
`tabularium-entry-edit-field' — useful when overwriting an
existing value with something unrelated."
  (interactive)
  (let ((field-name (or (tabularium-entry--field-at-point)
                        tabularium-entry--current-field)))
    (when field-name
      (tabularium-entry--set-field-value field-name "")
      (setq tabularium-entry--current-field field-name)
      (tabularium-entry-edit-field))))

;;; *** 6.1.1.5 Lifecycle

(defun tabularium-entry-submit ()
  "Submit the form and save the entry."
  (interactive)
  ;; Run pre-submit hook so plugins can mutate values (e.g. update a
  ;; date-modified field) before validation and save.
  (run-hooks 'tabularium-entry-pre-submit-hook)
  (let ((values tabularium-entry--values))
    ;; Validate required fields — both static (:required t) and dynamic
    ;; (declared by `tabularium-entry-required-field-functions').
    (dolist (field tabularium-entry--fields)
      (let* ((name (plist-get field :id))
             (static-req (plist-get field :required))
             (dyn-req (and (not static-req)
                           (run-hook-with-args-until-success
                            'tabularium-entry-required-field-functions
                            name values))))
        (when (or static-req dyn-req)
          (let ((value (alist-get name values)))
            (when (or (null value) (string-empty-p (format "%s" value)))
              (tabularium-entry--goto-field name)
              (user-error "%s field '%s' is empty"
                          (if static-req "Required" "Required for this entry type:")
                          (plist-get field :label)))))))
    ;; Save.  Computed fields have no physical column — drop them from
    ;; the value alist before any INSERT/UPDATE, otherwise SQLite
    ;; rejects the statement with "table has no column named ...".
    (let* ((schema-fields (tabularium--schema-fields))
           (computed-ids
            (delq nil (mapcar (lambda (f)
                                (and (tabularium--computed-field-p f)
                                     (plist-get f :id)))
                              schema-fields)))
           (values (cl-remove-if (lambda (pair)
                                   (memq (car pair) computed-ids))
                                 values)))
    (if tabularium-entry-editing-id
        ;; Update existing, and record old values for undo
        (let* ((primary-name (tabularium--primary-field-name))
               (old-data (tabularium--get-record-by-id tabularium-entry-editing-id))
               (changed-fields (cl-remove-if (lambda (x) (eq (car x) primary-name)) values))
               (update-ops '()))
          ;; Build undo ops for each changed field
          (dolist (pair changed-fields)
            (let ((field (car pair))
                  (new-val (cdr pair)))
              (unless (equal new-val (alist-get field old-data))
                (push (list :type 'update
                            :row tabularium-entry-editing-id
                            :field field
                            :old (alist-get field old-data)
                            :new new-val)
                      update-ops))))
          (when update-ops
            (tabularium--undo-push
             (if (= 1 (length update-ops))
                 (car update-ops)
               (list :type 'multi :ops update-ops))))
          (tabularium-db-update tabularium--db tabularium-table-name
                            changed-fields
                            primary-name tabularium-entry-editing-id)
          (tabularium--invalidate-cache)
          (message "Entry %s updated." tabularium-entry-editing-id))
      ;; Insert new
      (let ((new-id (alist-get (tabularium--primary-field-name) values)))
        (tabularium-db-insert tabularium--db tabularium-table-name values)
        (tabularium--undo-push (list :type 'insert :row new-id :data values))
        (tabularium--invalidate-cache)
        (message "Entry added"))))
    ;; Mark buffer clean — values now match what's on disk, so the
    ;; kill-buffer hook should not prompt about unsaved changes.
    (setq tabularium-entry--original-values
          (copy-alist tabularium-entry--values))
    ;; Store source buffer and edit info before quitting
    (let ((source-buf tabularium-entry--source-buffer)
          (source-col tabularium-entry--source-column)
          (line-offset tabularium-entry--source-line-offset)
          (schema-name tabularium-entry-schema-name)
          (edit-id tabularium-entry-editing-id)
          (new-id (unless tabularium-entry-editing-id
                    (alist-get (tabularium--primary-field-name) values))))
      (quit-window t)
      ;; Switch to and refresh view buffer
      (cond
       ;; If we have a specific source buffer, use it
       ((and source-buf (buffer-live-p source-buf))
        (switch-to-buffer source-buf)
        (revert-buffer)
        (tabularium-view--goto-position (or edit-id new-id) source-col)
        (recenter line-offset))
       ;; Otherwise try to find/refresh the view buffer
       ((when-let ((view-buf (get-buffer (format "*%s*" schema-name))))
          (switch-to-buffer view-buf)
          (revert-buffer)
          (tabularium-view--goto-position (or edit-id new-id) source-col)
          (recenter line-offset)
          t))
       ;; If no view buffer exists, open the view
       (t
        (tabularium-view))))))

(defun tabularium-entry-edited-p ()
  "Return non-nil if the entry buffer has unsaved changes.
Public predicate; safe for plugins to call."
  (not (equal tabularium-entry--values tabularium-entry--original-values)))

(defun tabularium-entry--maybe-discard (buf)
  "Prompt before BUF's form is overwritten if it has unsaved changes.
Return t if the buffer is safe to clobber (no changes, or user
confirmed discard); nil if the user canceled."
  (or (not (buffer-live-p buf))
      (with-current-buffer buf
        (or (not (derived-mode-p 'tabularium-entry-mode))
            (not (tabularium-entry-edited-p))
            (yes-or-no-p
             (format "Form '%s' has unsaved changes.  Discard? "
                     (buffer-name buf)))))))

(defun tabularium-entry-cancel ()
  "Cancel the form without saving.
Only prompts for confirmation if changes have been made."
  (interactive)
  (if (not (tabularium-entry-edited-p))
      ;; No changes, just quit
      (quit-window t)
    ;; Has changes, ask for confirmation
    (when (yes-or-no-p "Discard changes? ")
      ;; User has confirmed — bypass the kill-buffer-query hook.
      (let ((kill-buffer-query-functions
             (remq #'tabularium-entry--confirm-kill
                   kill-buffer-query-functions)))
        (quit-window t)))))

(defun tabularium-entry-new ()
  "Save current entry and open a new blank form."
  (interactive)
  (when (yes-or-no-p "Save current entry and create new? ")
    (tabularium-entry-submit)
    (tabularium-new-entry)))

(defun tabularium-entry-duplicate ()
  "Save current entry and open a duplicate for editing."
  (interactive)
  (let* ((values tabularium-entry--values)
         (primary-name (tabularium--primary-field-name))
         ;; Copy all values except primary key
         (new-values (cl-remove-if (lambda (pair) (eq (car pair) primary-name))
                                   values)))
    ;; Submit current if editing
    (when tabularium-entry-editing-id
      (tabularium-entry-submit))
    ;; Create duplicate
    (tabularium--ensure-db)
    (let* ((schema-name (tabularium--schema-name))
           (fields (tabularium--schema-fields))
           (buf (get-buffer-create (format "*%s Form*" schema-name)))
           (new-id (tabularium--next-id)))
      ;; Add new primary key
      (push (cons primary-name new-id) new-values)
      (unless (tabularium-entry--maybe-discard buf)
        (user-error "Canceled"))
      (with-current-buffer buf
        (tabularium-entry-mode)
        (setq tabularium-entry-schema-name schema-name)
        (setq tabularium-entry--fields fields)
        (setq tabularium-entry--values new-values)
        (setq tabularium-entry--original-values (copy-alist new-values))
        (setq tabularium-entry-editing-id nil)  ; new entry
        (setq tabularium-entry--source-buffer nil)
        (run-hooks 'tabularium-entry-new-hook)
        (tabularium-entry-render))
      (tabularium--display-entry-buffer buf)
      (message "Duplicated entry - edit and submit to save as new"))))

(defun tabularium-entry-delete ()
  "Delete the current entry being edited."
  (interactive)
  (if (not tabularium-entry-editing-id)
      (message "Cannot delete: this is a new entry (not yet saved)")
    (when (yes-or-no-p (format "Delete entry %s? " tabularium-entry-editing-id))
      (let ((id tabularium-entry-editing-id)
            (schema-name tabularium-entry-schema-name))
        (tabularium--ensure-db)
        ;; Record for undo
        (let ((old-data (tabularium--get-record-by-id id)))
          (tabularium--undo-push (list :type 'delete :row id :data old-data)))
        ;; Delete
        (tabularium-db-delete tabularium--db tabularium-table-name
                          (tabularium--primary-field-name) id)
        (tabularium--invalidate-cache)
        (message "Entry %s deleted" id)
        ;; Close form and refresh view
        (quit-window t)
        (when-let ((view-buf (get-buffer (format "*%s*" schema-name))))
          (with-current-buffer view-buf
            (revert-buffer)))))))

(defun tabularium-entry-insert ()
  "Insert a new entry at the current entry's position.
Shifts the current entry and all subsequent entries up by 1.
Only works when editing an existing entry (not a new one)."
  (interactive)
  (if (not tabularium-entry-editing-id)
      (message "Cannot insert: this is a new entry")
    (let ((position tabularium-entry-editing-id)
          (schema-name tabularium-entry-schema-name))
      ;; Submit current entry if there are changes
      (when (tabularium-entry-edited-p)
        (tabularium-entry-submit))
      ;; Shift all entries from position onwards up by 1
      (tabularium--ensure-db)
      (let* ((primary-name (tabularium--primary-field-name))
             (primary-name-str (symbol-name primary-name))
             (ids-to-shift (mapcar #'car
                                   (tabularium-db-query
                                    tabularium--db
                                    (format "SELECT %s FROM %s WHERE %s >= ? ORDER BY %s DESC"
                                            primary-name-str tabularium-table-name
                                            primary-name-str primary-name-str)
                                    (list position)))))
        (tabularium-db-with-transaction tabularium--db
          (dolist (old-id ids-to-shift)
            (tabularium-db-execute
             tabularium--db
             (format "UPDATE %s SET %s = ? WHERE %s = ?"
                     tabularium-table-name primary-name-str primary-name-str)
             (list (1+ old-id) old-id))))
        (tabularium--invalidate-cache)
        ;; Open new entry form with the position as ID (not editing existing)
        (let* ((fields (tabularium--schema-fields))
               (buf (get-buffer-create (format "*%s Form*" schema-name)))
               (initial-values
                (mapcar (lambda (f)
                          (let ((name (plist-get f :id)))
                            (cons name
                                  (if (eq name primary-name)
                                      position  ; Use the insert position as ID
                                    (or (tabularium--compute-default f) "")))))
                        fields)))
          (unless (tabularium-entry--maybe-discard buf)
            (user-error "Canceled"))
          (with-current-buffer buf
            (tabularium-entry-mode)
            (setq tabularium-entry-schema-name schema-name)
            (setq tabularium-entry--fields fields)
            (setq tabularium-entry--values initial-values)
            (setq tabularium-entry--original-values (copy-alist initial-values))
            (setq tabularium-entry-editing-id nil)  ; This is a NEW entry
            (run-hooks 'tabularium-entry-new-hook)
            (tabularium-entry-render))
          (tabularium--display-entry-buffer buf)
          (message "Inserted new entry at position %s (shifted %d entries)"
                   position (length ids-to-shift)))))))

(defun tabularium-entry-goto-view ()
  "Save and switch to the view buffer, centering on current entry."
  (interactive)
  (let ((schema-name tabularium-entry-schema-name)
        (editing-id tabularium-entry-editing-id))
    ;; Submit if there are changes
    (when (and tabularium-entry-editing-id
               (tabularium-entry-edited-p))
      (tabularium-entry-submit))
    ;; Switch to view
    (quit-window)
    (if-let ((view-buf (get-buffer (format "*%s*" schema-name))))
        (progn
          (switch-to-buffer view-buf)
          (revert-buffer)
          ;; Position on the entry we were editing and center
          (when editing-id
            (goto-char (point-min))
            (tabularium-view-goto-entry editing-id)
            (recenter)))
      (tabularium-view))))

(defun tabularium-entry-goto-entry ()
  "Center the view buffer on the entry currently open in this form.
Selects the source view buffer and moves point to the row for the
record being edited, recentering it.  Unlike `tabularium-entry-goto-view'
this neither submits nor closes the form.  Signals an error for a new,
unsaved entry (which has no row yet)."
  (interactive)
  (let ((editing-id tabularium-entry-editing-id)
        (schema-name tabularium-entry-schema-name))
    (unless editing-id
      (user-error "No saved entry to go to (new, unsaved entry)"))
    (if-let ((view-buf (get-buffer (format "*%s*" schema-name))))
        (progn
          (pop-to-buffer view-buf)
          (goto-char (point-min))
          (tabularium-view-goto-entry editing-id)
          (recenter))
      (user-error "No view buffer for '%s'" schema-name))))

;;;###autoload
(defun tabularium-new-entry (&optional id)
  "Open a form for entering a new entry, or edit entry ID if provided.
With prefix argument, prompts for ID to edit."
  (interactive
   (list (when current-prefix-arg
           (or (tabularium--id-at-point)
               (read-number "Edit entry ID: ")))))
  (tabularium--ensure-db)
  (let* ((source-buffer (when (derived-mode-p 'tabularium-view-mode)
                          (current-buffer)))
         (source-column (when (derived-mode-p 'tabularium-view-mode)
                          (tabularium--column-name-at-point)))
         (source-line-offset (when (derived-mode-p 'tabularium-view-mode)
                               (count-lines (window-start) (point))))
         (schema-name (tabularium--schema-name))
         ;; Exclude computed fields from the form
         (fields (cl-remove-if #'tabularium--computed-field-p
                               (tabularium--schema-fields)))
         (primary-name (tabularium--primary-field-name))
         (buf (get-buffer-create (format "*%s Form*" schema-name)))
         (initial-values
          (if id
              (tabularium--get-record-by-id id)
            ;; New entry: compute defaults
            (mapcar (lambda (f)
                      (let ((name (plist-get f :id)))
                        (cons name
                              (if (eq name primary-name)
                                  (tabularium--next-id)
                                (or (tabularium--compute-default f) "")))))
                    fields))))
    (unless (tabularium-entry--maybe-discard buf)
      (user-error "Canceled"))
    (with-current-buffer buf
      (tabularium-entry-mode)
      (setq tabularium-entry-schema-name schema-name)
      (setq tabularium-entry--fields fields)
      (setq tabularium-entry--values initial-values)
      (setq tabularium-entry--original-values (copy-alist initial-values))
      (setq tabularium-entry-editing-id id)
      ;; Track where we came from (captured in outer let*)
      (setq tabularium-entry--source-buffer source-buffer)
      (setq tabularium-entry--source-column source-column)
      (setq tabularium-entry--source-line-offset source-line-offset)
      (unless id
        (run-hooks 'tabularium-entry-new-hook))
      (tabularium-entry-render))
    (tabularium--display-entry-buffer buf)))

;;; *** 6.1.1.6 Long Field Editing

(defvar-local tabularium-long--callback nil
  "Function to call with the edited text when the long-field buffer is saved.")

(defvar-local tabularium-long--field-name nil
  "Field name being edited in this long-field buffer.")

(defvar tabularium-long-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'tabularium-long-save)
    (define-key map (kbd "C-c C-k") #'tabularium-long-cancel)
    map)
  "Keymap for `tabularium-long-edit-mode'.")

(define-derived-mode tabularium-long-edit-mode text-mode "Tabularium-Long"
  "Major mode for editing long-form Tabularium fields.
Derived from `text-mode' with `visual-line-mode' and outline support.
\\{tabularium-long-edit-mode-map}"
  (visual-line-mode 1)
  (setq-local outline-regexp "[#*]+ ")
  (outline-minor-mode 1))

(defun tabularium-long-save ()
  "Save the long-field buffer contents and close."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties
                            (point-min) (point-max))))
        (callback tabularium-long--callback))
    (quit-window t)
    (when callback
      (funcall callback text))))

(defun tabularium-long-cancel ()
  "Cancel long-field editing without saving."
  (interactive)
  (let ((in-recursive (> (recursion-depth) 0)))
    (quit-window t)
    (when in-recursive
      (abort-recursive-edit))))

(defun tabularium--edit-long-field (field-name initial callback)
  "Open a buffer for editing long-form text for FIELD-NAME.
INITIAL is the current value.  CALLBACK is called with the new text
when the user saves via `tabularium-long-save'."
  (let ((buf (get-buffer-create (format "*Tabularium: %s*" field-name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (eq tabularium-long-field-mode 'text-mode)
            (tabularium-long-edit-mode)
          (funcall tabularium-long-field-mode)
          ;; Add our keybindings as minor mode overlay
          (local-set-key (kbd "C-c C-c") #'tabularium-long-save)
          (local-set-key (kbd "C-c C-k") #'tabularium-long-cancel))
        (setq tabularium-long--callback callback)
        (setq tabularium-long--field-name field-name)
        (when (and initial (not (string-empty-p initial)))
          (insert initial))
        (setq-local header-line-format
                    (list " Editing: " (propertize field-name 'face 'bold)
                          "  "
                          (propertize "C-c C-c" 'face 'help-key-binding)
                          " Save  "
                          (propertize "C-c C-k" 'face 'help-key-binding)
                          " Cancel"))
        (goto-char (point-min))))
    (select-window
     (display-buffer-in-side-window
      buf (if (eq tabularium-long-field-display 'side)
              '((side . right) (window-width . 0.4))
            '((side . bottom) (window-height . 0.4)))))))

;;; *** 6.1.2 Prompt Entry

(defun tabularium--field-type-hint (field &optional style)
  "Return a short bracketed hint for FIELD's expected input format, or nil.
STYLE controls verbosity and use site:
  `short' (default) — single-letter abbreviations for compact display
                      to the right of a form-buffer field value:
                      =[I]=, =[N]=, =[D]=, =[T]=, =[DT]=.  Returns nil
                      for text, choice, and boolean (which show
                      their candidates to the right instead).
  `label'            — like `short' but also returns markers for
                      choice (=[C]=), boolean (=[B]=), and text (nil
                      \\— text is the default and needs no marker).
                      Used in the label column of the form buffer.
  `long'             — full type names for use in minibuffer prompts:
                      =[integer]=, =[number]=, =[date]=, =[time]=,
                      =[datetime]=, =[choice]=, =[boolean]=.

Boolean fields use the configured `:boolean-pair' (e.g. =[Yes/No]=,
=[True/False]=) in `short' style only when the type-marker form
isn't returned — otherwise `[B]' (label) or `[boolean]' (long)."
  (let ((style (or style 'short))
        (type (plist-get field :type)))
    (pcase type
      ('integer (pcase style ('long "[integer]") (_ "[I]")))
      ('number (pcase style ('long "[number]") (_ "[N]")))
      ('date (pcase style ('long "[date]") (_ "[D]")))
      ('time (pcase style ('long "[time]") (_ "[T]")))
      ('datetime (pcase style ('long "[datetime]") (_ "[DT]")))
      ('choice (pcase style
                 ('long "[choice]")
                 ('label "[C]")
                 (_ nil)))
      ('boolean
       (pcase style
         ('long "[boolean]")
         ('label "[B]")
         (_ (let ((pair (plist-get field :boolean-pair)))
              (if (and (listp pair) (= (length pair) 2))
                  (format "[%s/%s]" (car pair) (cadr pair))
                "[Yes/No]")))))
      (_ nil))))

(defun tabularium--field-prompt (field &optional default)
  "Build the minibuffer prompt string for FIELD.
Combines the label, a `*' marker for required fields, and a
bracketed annotation.  The annotation is DEFAULT when non-nil and
non-empty; otherwise a type hint — the long-form word for typed
fields (=[integer]=, =[date]=, …) but the boolean pair (=[Yes/No]=,
=[True/False]=) for boolean fields, since the pair tells the user
exactly what to type.  Returns a string ending in `: ' suitable
for direct use with `read-string'/`completing-read'."
  (let* ((label (plist-get field :label))
         (required (plist-get field :required))
         (default-str (and default
                           (not (and (stringp default)
                                     (string-empty-p default)))
                           (format "%s" default)))
         ;; Boolean prompts show the pair, not the word `[boolean]'.
         (type-hint (if (eq (plist-get field :type) 'boolean)
                        (tabularium--field-type-hint field 'short)
                      (tabularium--field-type-hint field 'long)))
         (annotation (cond
                      (default-str (format " [%s]" default-str))
                      (type-hint (format " %s" type-hint))
                      (t ""))))
    (format "%s%s%s: " label (if required "*" "") annotation)))

(defun tabularium--read-field (field &optional initial context)
  "Read a value for FIELD with appropriate completion.
INITIAL provides pre-filled value for editing.
CONTEXT is an alist of current field values for related completion.
Fields with `:long t' open a dedicated editing buffer."
  (if (plist-get field :long)
      ;; Long field: open buffer, use recursive-edit to block
      (let* ((field-name (symbol-name (plist-get field :id)))
             (initial-str (if (and initial (not (string-empty-p (format "%s" initial))))
                              (format "%s" initial) ""))
             (result nil)
             (buf (get-buffer-create (format "*Tabularium: %s*" field-name))))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (if (eq tabularium-long-field-mode 'text-mode)
                (tabularium-long-edit-mode)
              (funcall tabularium-long-field-mode)
              (local-set-key (kbd "C-c C-c") #'tabularium-long-save)
              (local-set-key (kbd "C-c C-k") #'tabularium-long-cancel))
            (setq tabularium-long--field-name field-name)
            (setq tabularium-long--callback
                  (lambda (text)
                    (setq result text)
                    (exit-recursive-edit)))
            (unless (string-empty-p initial-str)
              (insert initial-str))
            (setq-local header-line-format
                        (list " Editing: " (propertize field-name 'face 'bold)
                              "  "
                              (propertize "C-c C-c" 'face 'help-key-binding)
                              " Save  "
                              (propertize "C-c C-k" 'face 'help-key-binding)
                              " Cancel"))
            (goto-char (point-min))))
        (select-window
         (display-buffer-in-side-window
          buf (if (eq tabularium-long-field-display 'side)
                  '((side . right) (window-width . 0.4))
                '((side . bottom) (window-height . 0.4)))))
        (condition-case nil
            (recursive-edit)
          (error nil))
        (or result initial-str))
    ;; Normal field: minibuffer prompt
    (let* ((prompt-base (plist-get field :label))
           (field-type (plist-get field :type))
           (required (plist-get field :required))
           (default (or initial (tabularium--compute-default field)))
           (prompt (tabularium--field-prompt field default))
           (choices (plist-get field :choice))
           value)
      ;; Read, validate, and re-prompt until the input is acceptable —
      ;; the same type and pattern checks the form buffer applies, so
      ;; prompt/quick entry cannot store a malformed date, number, etc.
      (catch 'done
        (while t
          (let* ((raw
                  (pcase field-type
                    ('choice
                     (completing-read prompt (append choices '(""))
                                      nil nil nil nil (or initial default)))
                    ('text
                     (if (plist-get field :complete)
                         (let ((candidates (tabularium--get-completion-candidates
                                            field context)))
                           (completing-read prompt candidates nil nil nil nil
                                            (or initial default)))
                       (read-string prompt (or initial default))))
                    (_
                     (read-string prompt
                                  (when (or initial default)
                                    (format "%s" (or initial default)))))))
                 ;; An empty answer means "take the default".
                 (input (if (and (stringp raw) (string-empty-p raw))
                            (and default (format "%s" default))
                          raw))
                 ;; Validate the string form against the field type and
                 ;; any :pattern.  Empty input is allowed here; the
                 ;; required-field check below catches truly empty
                 ;; required fields.
                 (type-err (and input
                                (tabularium--validate-field-value
                                 input field-type)))
                 (pat-err (and input (not type-err)
                               (tabularium--validate-pattern input field))))
            (cond
             ((or type-err pat-err)
              (message "%s" (or type-err pat-err))
              (sit-for 1.5))
             (t
              ;; Accepted — coerce numeric types to numbers, leave the
              ;; rest as strings; an empty answer yields the default.
              (setq value
                    (cond
                     ((null input) default)
                     ((memq field-type '(integer number))
                      (string-to-number input))
                     (t input)))
              (throw 'done nil))))))
      ;; Validate required
      (when (and required (or (null value)
                              (and (stringp value) (string-empty-p value))))
        (user-error "Field '%s' is required" prompt-base))
      value)))

;;;###autoload
(defun tabularium-prompt-entry ()
  "Create a new entry via sequential minibuffer prompts.
For form-based entry, use `tabularium-new-entry' instead."
  (interactive)
  (tabularium--ensure-db)
  (let ((values '())
        (primary-name (tabularium--primary-field-name)))
    ;; Collect all field values, passing accumulated values as context
    (dolist (field (cl-remove-if #'tabularium--computed-field-p
                                 (tabularium--schema-fields)))
      (let* ((name (plist-get field :id))
             (default (if (and (eq name primary-name)
                               (eq (plist-get field :type) 'integer))
                          (tabularium--next-id)
                        nil))
             ;; Pass current values as context for related completion
             (value (tabularium--read-field field default values)))
        (push (cons name value) values)))
    ;; Insert
    (let ((data (nreverse values)))
      (tabularium-db-insert tabularium--db tabularium-table-name data)
      (tabularium--invalidate-cache)
      (when (derived-mode-p 'tabularium-view-mode)
        (revert-buffer))
      (message "Entry added: %s" (alist-get primary-name data)))))

;;; *** 6.1.3 Quick Entry

(defun tabularium--get-recent-record ()
  "Get the most recent record as an alist."
  (tabularium--ensure-db)
  (let* ((col-info (tabularium--get-table-columns))
         (col-names (mapcar (lambda (c) (plist-get c :id)) col-info))
         (sql (format "SELECT * FROM %s ORDER BY rowid DESC LIMIT 1"
                      tabularium-table-name))
         (row (tabularium-db-query-single tabularium--db sql)))
    (when row
      (cl-mapcar #'cons col-names row))))

;;;###autoload
(defun tabularium-quick-entry ()
  "Streamlined entry using only quick-entry fields."
  (interactive)
  (tabularium--ensure-db)
  (let ((values '())
        (quick-fields (tabularium--schema-quick-fields))
        (all-fields (cl-remove-if #'tabularium--computed-field-p
                                  (tabularium--schema-fields)))
        (primary-name (tabularium--primary-field-name))
        (recent-alist (tabularium--get-recent-record)))
    ;; Process each field, passing accumulated values as context
    (dolist (field all-fields)
      (let* ((name (plist-get field :id))
             (in-quick (memq name quick-fields))
             (recent-val (alist-get name recent-alist))
             (default-val (tabularium--compute-default field)))
        (cond
         ;; Primary key: auto-increment
         ((eq name primary-name)
          (push (cons name (tabularium--next-id)) values))
         ;; Quick field: prompt with smart default, pass context
         (in-quick
          (let ((smart-default (or recent-val default-val)))
            (push (cons name (tabularium--read-field field smart-default values)) values)))
         ;; Non-quick field: use default or empty
         (t
          (push (cons name (or default-val "")) values)))))
    (tabularium-db-insert tabularium--db tabularium-table-name (nreverse values))
    (tabularium--invalidate-cache)
    (when (derived-mode-p 'tabularium-view-mode)
      (revert-buffer))
    (message "Entry added")))

;;; ** 6.2 Edit Entry

(defun tabularium--edit-with-method (id &optional use-alt-method)
  "Edit entry ID using preferred or alternative method.
With USE-ALT-METHOD non-nil, use the alternative entry method."
  (if (tabularium--use-form-p use-alt-method)
      (tabularium-new-entry id)
    (tabularium--edit id)))

(defun tabularium--edit (id)
  "Edit record ID, prompting for each field."
  (interactive
   (list (or (tabularium--id-at-point)
             (read-number "Edit ID: "))))
  (tabularium--ensure-db)
  (let* ((primary-name (tabularium--primary-field-name))
         (record-data (tabularium--get-record-by-id id)))
    (unless record-data
      (user-error "Record %s not found" id))
    (let ((updates '()))
      ;; Prompt for each field (skip computed fields)
      (dolist (field (cl-remove-if #'tabularium--computed-field-p
                                   (tabularium--schema-fields)))
        (let* ((name (plist-get field :id))
               (current (alist-get name record-data))
               (new-value (tabularium--read-field field current)))
          (unless (equal new-value current)
            (push (cons name new-value) updates))))
      ;; Apply updates
      (when updates
        (tabularium-db-update tabularium--db tabularium-table-name
                              (nreverse updates) primary-name id)
        (tabularium--invalidate-cache)
        (message "Record %s updated." id)))))

;;; ** 6.3 Duplicate Entry

(defun tabularium--duplicate-with-method (id &optional use-alt-method)
  "Duplicate entry ID using preferred or alternative method.
With USE-ALT-METHOD non-nil, use the alternative entry method."
  (if (tabularium--use-form-p use-alt-method)
      (tabularium--duplicate-form id)
    (tabularium--duplicate-prompt id)))

(defun tabularium--duplicate-form (id)
  "Duplicate entry ID using form mode."
  (tabularium--ensure-db)
  (let* ((primary-name (tabularium--primary-field-name))
         (record-data (tabularium--get-record-by-id id))
         (schema-name (tabularium--schema-name))
         ;; Exclude computed fields from the form
         (fields (cl-remove-if #'tabularium--computed-field-p
                               (tabularium--schema-fields)))
         (buf (get-buffer-create (format "*%s Form*" schema-name))))
    (unless record-data
      (user-error "Record %s not found" id))
    ;; Remove internal fields and primary key
    (setq record-data (cl-remove-if (lambda (x)
                                      (memq (car x) (list primary-name 'created_at 'updated_at)))
                                    record-data))
    ;; Add new primary key
    (push (cons primary-name (tabularium--next-id)) record-data)
    (unless (tabularium-entry--maybe-discard buf)
      (user-error "Canceled"))
    (with-current-buffer buf
      (tabularium-entry-mode)
      (setq tabularium-entry-schema-name schema-name)
      (setq tabularium-entry--fields fields)
      (setq tabularium-entry--values record-data)
      (setq tabularium-entry--original-values (copy-alist record-data))
      (setq tabularium-entry-editing-id nil)  ; new entry
      (setq tabularium-entry--source-buffer nil)
      (run-hooks 'tabularium-entry-new-hook)
      (tabularium-entry-render))
    (tabularium--display-entry-buffer buf)
    (message "Duplicated from %s - edit and submit to save" id)))

(defun tabularium--duplicate-prompt (id)
  "Duplicate record with ID via minibuffer prompts.
Internal helper; users should invoke `tabularium-view-duplicate'
or `tabularium-entry-duplicate' instead.  Selected by
`tabularium--duplicate-with-method' when the entry method is
`prompt' (rather than `form')."
  (tabularium--ensure-db)
  (let* ((primary-name (tabularium--primary-field-name))
         (record-data (tabularium--get-record-by-id id)))
    (unless record-data
      (user-error "Record %s not found" id))
    ;; Remove internal fields
    (setq record-data (cl-remove-if (lambda (x)
                                      (memq (car x) '(created_at updated_at)))
                                    record-data))
    (let ((new-values '()))
      ;; Prompt for each field (skip computed fields)
      (dolist (field (cl-remove-if #'tabularium--computed-field-p
                                   (tabularium--schema-fields)))
        (let* ((name (plist-get field :id))
               (current (alist-get name record-data))
               ;; For primary key, suggest new ID
               (initial (if (eq name primary-name)
                            (tabularium--next-id)
                          current))
               (value (tabularium--read-field field initial)))
          (push (cons name value) new-values)))
      (tabularium-db-insert tabularium--db tabularium-table-name (nreverse new-values))
      (tabularium--invalidate-cache)
      (message "Duplicated from %s" id))))

;;; * 7 Data Manipulation

;;; ** 7.1 Row Operations

;;; *** 7.1.1 Index Management

(defcustom tabularium-auto-reindex nil
  "If non-nil, automatically reindex after operations that modify row count.
This ensures IDs stay sequential without gaps.
WARNING: Enabling this breaks undo/redo functionality for those operations.
Consider leaving this nil and using `tabularium-reindex' manually when needed."
  :type 'boolean
  :group 'tabularium-database
  :safe #'booleanp)

(defun tabularium--reindex-silent ()
  "Reindex all entries sequentially without prompts or messages."
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         ;; Use ROWID to uniquely identify each row, sort by current ID then ROWID
         (rows (tabularium-db-query
                tabularium--db
                (format "SELECT ROWID FROM %s ORDER BY %s ASC, ROWID ASC"
                        tabularium-table-name primary-name)))
         (_count (length rows)))
    (when rows
      (tabularium-db-with-transaction tabularium--db
        ;; First pass: assign unique negative temp IDs to avoid any conflicts
        (let ((temp-id -1))
          (dolist (row rows)
            (let ((rowid (car row)))
              (tabularium-db-execute
               tabularium--db
               (format "UPDATE %s SET %s = ? WHERE ROWID = ?"
                       tabularium-table-name primary-name)
               (list temp-id rowid))
              (cl-decf temp-id))))
        ;; Second pass: assign final sequential IDs (1, 2, 3, ...)
        ;; Re-fetch ROWIDs in the new order (by temp ID, which preserved original order)
        (let ((final-rows (tabularium-db-query
                           tabularium--db
                           (format "SELECT ROWID FROM %s ORDER BY %s DESC"
                                   tabularium-table-name primary-name)))
              (final-id 1))
          (dolist (row final-rows)
            (let ((rowid (car row)))
              (tabularium-db-execute
               tabularium--db
               (format "UPDATE %s SET %s = ? WHERE ROWID = ?"
                       tabularium-table-name primary-name)
               (list final-id rowid))
              (cl-incf final-id)))))
      (tabularium--invalidate-cache))))

(defun tabularium-reindex ()
  "Renumber all entries sequentially starting from 1.
Fixes gaps and duplicates in the primary key column."
  (interactive)
  (tabularium--ensure-db)
  (when (yes-or-no-p "This will renumber all IDs starting from 1.  Reindex all entries? ")
    (let ((count (caar (tabularium-db-query
                        tabularium--db
                        (format "SELECT COUNT(*) FROM %s" tabularium-table-name)))))
      (tabularium--reindex-silent)
      (when (derived-mode-p 'tabularium-view-mode)
        (revert-buffer))
      (message "Reindexed %d entries (1 to %d)" count count))))

;;; *** 7.1.2 Multi-Column Sort

(defface tabularium-sort-indicator-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the sort-direction indicator (`↑'/`↓') in column headers.
Appended to a column's label in `tabularium-view--setup-columns'
when the column appears in `tabularium--sort-columns'."
  :group 'tabularium-faces)

(defun tabularium--sortable-column-at-point ()
  "Return the column at point for sorting, or nil.
A stored column, or a computed column backed by a SQL expression (which
orders by that expression), is returned.  A column computed in Emacs
Lisp has no SQL form, so it is not returned and callers fall back to
the index column."
  (and (derived-mode-p 'tabularium-view-mode)
       (tabularium--column-name-at-point)))

(defun tabularium--sort-by-column-toggle (col start-desc)
  "Make COL the sole sort key, toggling direction when repeated.
A fresh application sorts ascending, or descending when START-DESC
is non-nil; re-applying while COL is already the only key flips its
direction.  Replaces any current sort (build multi-key sorts with
`tabularium-view-sort-add')."
  (let* ((only (and (= 1 (length tabularium--sort-columns))
                    (eq (caar tabularium--sort-columns) col)))
         (new-dir (cond
                   (only (if (eq (cdar tabularium--sort-columns) 'asc)
                             'desc 'asc))
                   (start-desc 'desc)
                   (t 'asc))))
    (tabularium--sort-push-undo)
    (setq tabularium--sort-columns (list (cons col new-dir)))
    (revert-buffer)
    (tabularium--sort-sync)
    (message "Sort: %s" (tabularium--sort-description))))

(defun tabularium-view-sort-reverse ()
  "Reverse-sort by the column at point.
Makes the column at point the sole sort key, descending first and
toggling to ascending when repeated on the same column — the
keyboard equivalent of clicking a column header to sort by it.
Falls back to the primary-key (index) column when point is not on a
sortable column (computed columns cannot be sorted).  Build
multi-key sorts with `tabularium-view-sort-add'."
  (interactive)
  (tabularium--sort-by-column-toggle
   (or (tabularium--sortable-column-at-point)
       (tabularium--primary-field-name))
   t))

(defun tabularium-view-sort-index ()
  "Sort by the primary-key (index) column.
Sorts ascending first and toggles to descending when repeated.
This is the explicit \"sort by index\" command, distinct from
`tabularium-view-sort-reverse', which sorts by the column at point."
  (interactive)
  (tabularium--sort-by-column-toggle (tabularium--primary-field-name) nil))

(defun tabularium-view-sort-add (column direction)
  "Add COLUMN as additional sort key with DIRECTION."
  (interactive
   (let* ((existing (mapcar #'car tabularium--sort-columns))
          (fields (cl-remove-if
                   (lambda (name) (memq (intern name) existing))
                   ;; Computed fields are offered too; an elisp-computed
                   ;; key is sorted in Emacs after the fetch.
                   (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                           (tabularium--schema-fields))))
          (prompt (if tabularium--sort-columns
                      (format "Sort [%s] + add: " (tabularium--sort-description))
                    "Sort by: "))
          (col (completing-read prompt fields nil t))
          (dir-choice (completing-read
                      (format "Direction for '%s': " col)
                      '("ascending" "descending") nil t nil nil "ascending"))
          (dir (if (string= dir-choice "ascending") 'asc 'desc)))
     (list (intern col) dir)))
  (tabularium--sort-push-undo)
  (setq tabularium--sort-columns
        (append tabularium--sort-columns
                (list (cons column direction))))
  (revert-buffer)
  (tabularium--sort-sync)
  (message "Sort: %s" (tabularium--sort-description)))

(defun tabularium-view-sort-cycle (column)
  "Flip the sort direction of COLUMN in the current sort.
Interactively the active sort columns are offered; the chosen
column's direction toggles between ascending and descending.  The
view-level counterpart of the rules-list buffer's `c' command."
  (interactive
   (if (null tabularium--sort-columns)
       (user-error "No sort columns to cycle")
     (let* ((current (mapcar (lambda (x)
                               (format "%s %s" (car x)
                                       (if (eq (cdr x) 'asc) "↑" "↓")))
                             tabularium--sort-columns))
            (choice (completing-read "Cycle order on column: " current nil t))
            (col-name (car (split-string choice " "))))
       (list (intern col-name)))))
  (let ((cell (assq column tabularium--sort-columns)))
    (unless cell (user-error "Column %s is not a sort key" column))
    (setcdr cell (if (eq (cdr cell) 'asc) 'desc 'asc))
    (revert-buffer)
    (tabularium--sort-sync)
    (message "Sort: %s" (tabularium--sort-description))))

(defun tabularium-view-sort-remove (target)
  "Remove sort column(s) from the current view.
TARGET is a column symbol to drop, or the symbol `all' to clear
the whole custom sort and return to the default primary-key order.

Interactively every active sort column is listed alongside the
`<<ALL>>' sentinel (the default).  This single command replaces
the former separate \"delete sort\" and \"clear sort\" commands,
mirroring `tabularium-view-filter-remove'."
  (interactive
   (if (null tabularium--sort-columns)
       (user-error "No sort columns to remove")
     (let* ((labels (mapcar (lambda (x)
                              (format "%s %s" (car x)
                                      (if (eq (cdr x) 'asc) "↑" "↓")))
                            tabularium--sort-columns))
            (choice (completing-read
                     "Remove sort [<<ALL>>]: "
                     (cons "<<ALL>>" labels) nil t nil nil "<<ALL>>")))
       (list (if (equal choice "<<ALL>>")
                 'all
               (intern (car (split-string choice " "))))))))
  (cond
   ((eq target 'all)
    (setq tabularium--sort-columns nil)
    (revert-buffer)
    (tabularium--sort-sync)
    (message "Sort cleared (default order)"))
   ((null target)
    (message "No sort column selected"))
   (t
    (setq tabularium--sort-columns
          (cl-remove-if (lambda (x) (eq (car x) target))
                        tabularium--sort-columns))
    (revert-buffer)
    (tabularium--sort-sync)
    (if tabularium--sort-columns
        (message "Sort: %s" (tabularium--sort-description))
      (message "Sort cleared (default order)")))))

(defun tabularium-view-sort-remove-all ()
  "Remove every sort rule, returning to the default index order.
A direct equivalent of choosing `<<ALL>>' in
`tabularium-view-sort-remove'."
  (interactive)
  (if (null tabularium--sort-columns)
      (user-error "No sort rules to remove")
    (tabularium-view-sort-remove 'all)))

(defun tabularium--sort-description ()
  "Return human-readable sort description."
  (if tabularium--sort-columns
      (mapconcat (lambda (x)
                   (format "%s %s" (car x) (if (eq (cdr x) 'asc) "↑" "↓")))
                 tabularium--sort-columns " ∧ ")
    "default"))

(defun tabularium--filter-push-undo ()
  "Record the current filter stack so the next change can be undone.
Call before mutating `tabularium--filter-rules'."
  (tabularium--undo-push
   (list :type 'filter-change
         :old-filter (copy-sequence tabularium--filter-rules))))

(defun tabularium--sort-push-undo ()
  "Record the current sort keys so the next sort change can be undone.
Call before mutating `tabularium--sort-columns'."
  (tabularium--undo-push
   (list :type 'sort-change
         :old-sort (copy-sequence tabularium--sort-columns))))

(defun tabularium--build-order-clause ()
  "Build ORDER BY clause from `tabularium--sort-columns'.
Each key is resolved with `tabularium--field-sql-ref', so a computed
field backed by a SQL expression sorts by that expression.  A key with
no SQL form (an elisp-computed field) is skipped rather than ordering
by its NULL placeholder, which would silently do nothing."
  (let ((parts (delq nil
                     (mapcar
                      (lambda (x)
                        (when-let ((ref (tabularium--field-sql-ref (car x))))
                          (format "%s %s" ref (upcase (symbol-name (cdr x))))))
                      tabularium--sort-columns))))
    (if parts
        (string-join parts ", ")
      ;; Default sort
      (format "%s %s"
              (tabularium--primary-field-name)
              (if tabularium--sort-ascending "ASC" "DESC")))))

;;; *** 7.1.2.1 Sort Rules List Buffer

(defvar-local tabularium--sort-view nil
  "The view buffer whose sort rules a Sort Rules List buffer edits.")

(defvar-local tabularium--sort-marks nil
  "List of 1-based sort-rule indices marked for removal in the buffer.")

(defvar-local tabularium--sort-first-pos nil
  "Buffer position of the first sort rule, for cursor placement.")

(defvar-local tabularium--sort-first-line nil
  "Line number of the first sort rule, for bounded cursor motion.")

(defvar-local tabularium--sort-last-line nil
  "Line number of the last sort rule, for bounded cursor motion.")

(defun tabularium--sort-refresh ()
  "Redraw the Sort Rules List buffer from the owning view's sort keys.
Lists every sort column in priority order with its direction in a
dedicated column, key hints faced like the registry, and the
cursor left on the first rule.  Sort keys apply in sequence — each
tie broken by the next — conceptually conjoined (∧)."
  (let ((inhibit-read-only t)
        (rules (with-current-buffer tabularium--sort-view
                 tabularium--sort-columns))
        (marks tabularium--sort-marks)
        (first-pos nil)
        (first-line nil)
        (last-line nil))
    (erase-buffer)
    (insert (tabularium--make-box-header "Sort Rules List" 80 'single)
            "\n\n")
    (insert (format "  %-3s %-5s %s\n" "#" "Order" "Column"))
    (insert (propertize (concat "  " (make-string 76 ?─) "\n")
                        'face 'shadow))
    (if (null rules)
        (insert (propertize "  No sort rules (default order).\n" 'face 'shadow))
      (let ((n 0))
        (dolist (rule rules)
          (cl-incf n)
          (let* ((dir (cdr rule))
                 (dir-str (if (eq dir 'asc) "↑" "↓"))
                 (marked (memq n marks))
                 (start (point))
                 (line (line-number-at-pos start)))
            (unless first-pos
              (setq first-pos start first-line line))
            (setq last-line line)
            (insert (propertize
                     (format "%s %-3d %-5s %s\n"
                             (if marked
                                 (propertize "*" 'face 'tabularium-marked-face)
                               " ")
                             n dir-str
                             (symbol-name (car rule)))
                     'tabularium-sort-n n
                     'face (and marked 'tabularium-marked-face)))))))
    (insert "\n")
    (insert (tabularium--make-box-footer 80 'single) "\n")
    (insert (format "  Total: %d rule%s\n\n"
                    (length rules)
                    (if (= 1 (length rules)) "" "s")))
    (insert "  " (propertize "m" 'face 'help-key-binding) " Mark   "
            (propertize "u" 'face 'help-key-binding) " Unmark   "
            (propertize "U" 'face 'help-key-binding) " Unmark all   "
            (propertize "t" 'face 'help-key-binding) " Toggle   "
            (propertize "x" 'face 'help-key-binding) " Remove\n")
    (insert "  " (propertize "TAB" 'face 'help-key-binding) "/"
            (propertize "S-TAB" 'face 'help-key-binding) " Nav   "
            (propertize "M-p" 'face 'help-key-binding) "/"
            (propertize "M-n" 'face 'help-key-binding) " Move   "
            (propertize "c" 'face 'help-key-binding) " Cycle order\n")
    (insert "  " (propertize "I" 'face 'help-key-binding) " Insert   "
            (propertize "A" 'face 'help-key-binding) " Add   "
            (propertize "RET" 'face 'help-key-binding) " Modify\n")
    (insert "  " (propertize "q" 'face 'help-key-binding) " Quit   "
            (propertize "g" 'face 'help-key-binding) "/"
            (propertize "=" 'face 'help-key-binding) " Refresh\n")
    (setq tabularium--sort-first-pos (or first-pos (point-min)))
    (setq tabularium--sort-first-line (or first-line 5))
    (setq tabularium--sort-last-line (or last-line 5))
    (goto-char tabularium--sort-first-pos)))

(defun tabularium--sort-sync ()
  "Refresh an open Sort Rules List buffer, if any.
Called after the sort keys change so the list buffer stays in step
with the view without a manual `g'."
  (let ((buf (get-buffer "*Sort Rules List*")))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (derived-mode-p 'tabularium-sort-mode)
          (let ((saved-n (tabularium--sort-n-at-point)))
            (tabularium--sort-refresh)
            (when saved-n
              (tabularium--sort-goto-n saved-n))))))))

(defun tabularium--sort-n-at-point ()
  "Return the sort-rule index on the current line, or nil."
  (get-text-property (line-beginning-position) 'tabularium-sort-n))

(defun tabularium--sort-goto-n (n)
  "Move point to the line of sort-rule index N, if present.
Point is only moved when N is found; return the position, or nil."
  (let ((pos (save-excursion
               (goto-char (point-min))
               (let (found)
                 (while (and (not found) (not (eobp)))
                   (when (eql n (get-text-property (line-beginning-position)
                                                   'tabularium-sort-n))
                     (setq found (line-beginning-position)))
                   (forward-line 1))
                 found))))
    (when pos (goto-char pos) pos)))

(defun tabularium-sort-mark ()
  "Mark the sort rule at point for removal, then advance.
At the last rule, point stays on it rather than leaving the list."
  (interactive)
  (let ((n (tabularium--sort-n-at-point)))
    (unless n (user-error "No sort rule at point"))
    (cl-pushnew n tabularium--sort-marks)
    (tabularium--sort-refresh)
    (or (tabularium--sort-goto-n (1+ n))
        (tabularium--sort-goto-n n))))

(defun tabularium-sort-unmark ()
  "Unmark the sort rule at point, then advance.
At the last rule, point stays on it rather than leaving the list."
  (interactive)
  (let ((n (tabularium--sort-n-at-point)))
    (unless n (user-error "No sort rule at point"))
    (setq tabularium--sort-marks (delq n tabularium--sort-marks))
    (tabularium--sort-refresh)
    (or (tabularium--sort-goto-n (1+ n))
        (tabularium--sort-goto-n n))))

(defun tabularium-sort-unmark-all ()
  "Clear all marks in the Sort Rules List buffer."
  (interactive)
  (setq tabularium--sort-marks nil)
  (tabularium--sort-refresh))

(defun tabularium-sort-next ()
  "Move to the next sort rule, respecting bounds."
  (interactive)
  (if (< (line-number-at-pos) (or tabularium--sort-last-line 5))
      (forward-line 1)
    (message "Last rule")))

(defun tabularium-sort-prev ()
  "Move to the previous sort rule, respecting bounds."
  (interactive)
  (if (> (line-number-at-pos) (or tabularium--sort-first-line 5))
      (forward-line -1)
    (message "First rule")))

(defun tabularium-sort-remove ()
  "Remove the marked sort rules, or the rule at point if none marked."
  (interactive)
  (let* ((nums (or tabularium--sort-marks
                   (when-let ((n (tabularium--sort-n-at-point)))
                     (list n))))
         (view tabularium--sort-view))
    (unless nums (user-error "No sort rule marked or at point"))
    (with-current-buffer view
      (let ((i 0))
        (tabularium--sort-push-undo)
        (setq tabularium--sort-columns
              (cl-remove-if (lambda (_) (memq (cl-incf i) nums))
                            tabularium--sort-columns)))
      (revert-buffer))
    (setq tabularium--sort-marks nil)
    (tabularium--sort-refresh)
    (message "Removed %d sort rule%s"
             (length nums) (if (= 1 (length nums)) "" "s"))))

(defun tabularium-sort-remove-all ()
  "Remove every sort rule, returning to the default index order."
  (interactive)
  (with-current-buffer tabularium--sort-view
    (tabularium--sort-push-undo)
    (setq tabularium--sort-columns nil)
    (revert-buffer))
  (setq tabularium--sort-marks nil)
  (tabularium--sort-refresh)
  (message "Removed all sort rules"))

(defun tabularium-sort-toggle-marks ()
  "Toggle every mark in the Sort Rules List buffer."
  (interactive)
  (let* ((rules (with-current-buffer tabularium--sort-view
                  tabularium--sort-columns))
         (all (number-sequence 1 (length rules)))
         (n-at (tabularium--sort-n-at-point)))
    (setq tabularium--sort-marks
          (cl-set-difference all tabularium--sort-marks))
    (tabularium--sort-refresh)
    (when n-at (tabularium--sort-goto-n n-at))))

(defun tabularium-sort-cycle-order ()
  "Flip the sort direction of the rule at point (ascending ↔ descending)."
  (interactive)
  (let ((n (tabularium--sort-n-at-point))
        (view tabularium--sort-view))
    (unless n (user-error "No sort rule at point"))
    (with-current-buffer view
      (let ((cell (nth (1- n) tabularium--sort-columns)))
        (setcdr cell (if (eq (cdr cell) 'asc) 'desc 'asc)))
      (revert-buffer))
    (tabularium--sort-refresh)
    (tabularium--sort-goto-n n)))

(defun tabularium-sort-revert ()
  "Refresh the Sort Rules List buffer."
  (interactive)
  (tabularium--sort-refresh))

(defun tabularium--sort-move (direction)
  "Move the sort rule at point one step in DIRECTION (`up' or `down').
Reorders `tabularium--sort-columns' in the owning view, changing
sort priority.  Unlike filter rules, sort keys carry no connective,
so nothing needs repairing after the swap."
  (let ((n (tabularium--sort-n-at-point))
        (view tabularium--sort-view))
    (unless n (user-error "No sort rule at point"))
    (with-current-buffer view
      (let* ((rules (copy-sequence tabularium--sort-columns))
             (len (length rules))
             (i (1- n))
             (j (if (eq direction 'up) (1- i) (1+ i))))
        (when (or (< j 0) (>= j len))
          (user-error "Cannot move %s any further" direction))
        (let ((tmp (nth i rules)))
          (setf (nth i rules) (nth j rules))
          (setf (nth j rules) tmp))
        (tabularium--sort-push-undo)
        (setq tabularium--sort-columns rules)
        (revert-buffer)))
    (tabularium--sort-refresh)
    (tabularium--sort-goto-n (if (eq direction 'up) (1- n) (1+ n)))))

(defun tabularium-sort-move-up ()
  "Move the sort rule at point one position earlier (higher priority)."
  (interactive)
  (tabularium--sort-move 'up))

(defun tabularium-sort-move-down ()
  "Move the sort rule at point one position later (lower priority)."
  (interactive)
  (tabularium--sort-move 'down))

(defun tabularium-sort-modify ()
  "Re-enter the sort rule at point.
Removes the rule and re-prompts for a column and direction via
`tabularium-view-sort-add', so it can be re-specified.  The new
rule is added at the end (lowest priority)."
  (interactive)
  (let ((n (tabularium--sort-n-at-point))
        (view tabularium--sort-view))
    (unless n (user-error "No sort rule at point"))
    (with-current-buffer view
      (tabularium--sort-push-undo)
      (setq tabularium--sort-columns
            (cl-remove-if (let ((i 0))
                            (lambda (_) (= (cl-incf i) n)))
                          tabularium--sort-columns))
      (call-interactively #'tabularium-view-sort-add))
    (tabularium--sort-refresh)))

(defun tabularium-sort-add ()
  "Add a new sort key at the end (lowest priority).
Runs `tabularium-view-sort-add' in the owning view."
  (interactive)
  (with-current-buffer tabularium--sort-view
    (call-interactively #'tabularium-view-sort-add))
  (tabularium--sort-refresh))

(defun tabularium-sort-insert ()
  "Insert a new sort key before the key at point.
Prompts as `tabularium-sort-add' does, then moves the new key to the
current line.  With no key at point (empty list) it simply adds."
  (interactive)
  (let* ((n (tabularium--sort-n-at-point))
         (view tabularium--sort-view)
         (before (with-current-buffer view (length tabularium--sort-columns))))
    (with-current-buffer view
      (call-interactively #'tabularium-view-sort-add))
    (let ((after (with-current-buffer view (length tabularium--sort-columns))))
      (when (and n (> after before))
        (with-current-buffer view
          (let* ((cols (copy-sequence tabularium--sort-columns))
                 (new-col (car (last cols)))
                 (without (butlast cols))
                 (idx (1- n)))
            (tabularium--sort-push-undo)
            (setq tabularium--sort-columns
                  (append (seq-take without idx)
                          (list new-col)
                          (seq-drop without idx)))
            (revert-buffer))))
      (tabularium--sort-refresh)
      (when n (tabularium--sort-goto-n n)))))

(defvar tabularium-sort-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "m") #'tabularium-sort-mark)
    (define-key map (kbd "u") #'tabularium-sort-unmark)
    (define-key map (kbd "U") #'tabularium-sort-unmark-all)
    (define-key map (kbd "t") #'tabularium-sort-toggle-marks)
    (define-key map (kbd "x") #'tabularium-sort-remove)
    (define-key map (kbd "X") #'tabularium-sort-remove-all)
    (define-key map (kbd "c") #'tabularium-sort-cycle-order)
    (define-key map (kbd "M-p") #'tabularium-sort-move-up)
    (define-key map (kbd "M-n") #'tabularium-sort-move-down)
    (define-key map (kbd "M-<up>") #'tabularium-sort-move-up)
    (define-key map (kbd "M-<down>") #'tabularium-sort-move-down)
    (define-key map (kbd "RET") #'tabularium-sort-modify)
    (define-key map (kbd "g") #'tabularium-sort-revert)
    (define-key map (kbd "=") #'tabularium-sort-revert)
    (define-key map (kbd "n") #'tabularium-sort-next)
    (define-key map (kbd "p") #'tabularium-sort-prev)
    (define-key map (kbd "TAB") #'tabularium-sort-next)
    (define-key map (kbd "<backtab>") #'tabularium-sort-prev)
    (define-key map (kbd "I") #'tabularium-sort-insert)
    (define-key map (kbd "A") #'tabularium-sort-add)
    (define-key map (kbd "<down>") #'tabularium-sort-next)
    (define-key map (kbd "<up>") #'tabularium-sort-prev)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `tabularium-sort-mode'.")

(define-derived-mode tabularium-sort-mode special-mode
  "Tabularium-Sort"
  "Major mode for the interactive Sort Rules List buffer.
Lists every sort key of a view in priority order, with its
direction shown in a dedicated column.  Rules can be marked and
removed, their direction cycled, and their priority reordered,
without leaving the buffer.  A companion to the single-line sort
description shown in the modeline."
  (setq-local revert-buffer-function
              (lambda (&rest _) (tabularium--sort-refresh))))

;;;###autoload
(defun tabularium-view-sort-buffer ()
  "Open the interactive Sort Rules List buffer for the current view.
Lists every sort key numbered in priority order, with keys to mark
and remove rules, cycle their direction, and reorder them."
  (interactive)
  (unless (derived-mode-p 'tabularium-view-mode)
    (user-error "Not in a Tabularium view"))
  (let ((view (current-buffer))
        (buf (get-buffer-create "*Sort Rules List*")))
    (with-current-buffer buf
      (tabularium-sort-mode)
      (setq tabularium--sort-view view)
      (setq tabularium--sort-marks nil)
      (tabularium--sort-refresh))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (goto-char (or tabularium--sort-first-pos (point-min))))))

;;; *** 7.1.3 Creative/Destructive Operations

(defun tabularium-view-copy ()
  "Copy entry at point, or all marked entries as a batch.
Clears marks after copying."
  (interactive)
  (let ((ids (or (and tabularium--marked-entries
                      (sort (copy-sequence tabularium--marked-entries) #'<))
                 (when-let ((id (tabularium--id-at-point))) (list id)))))
    (unless ids
      (user-error "No entry at point"))
    (let ((schema (tabularium--schema-name))
          (entries '()))
      ;; Collect data for all entries (in ID order)
      (dolist (id ids)
        (when-let ((data (tabularium--get-record-by-id id)))
          (push data entries)))
      (setq entries (nreverse entries))
      ;; Add as a batch to kill ring
      (tabularium--add-to-kill-ring schema entries)
      ;; Clear marks
      (when tabularium--marked-entries
        (setq tabularium--marked-entries nil)
        (tabularium-view--update-mark-display))
      (message "Copied %d %s" (length entries)
               (if (= 1 (length entries)) "entry" "entries")))))

(defun tabularium-view-cut ()
  "Cut entry at point, or all marked entries as a batch.
Clears marks after cutting.  Undoable."
  (interactive)
  (let ((ids (or (and tabularium--marked-entries
                      (sort (copy-sequence tabularium--marked-entries) #'<))
                 (when-let ((id (tabularium--id-at-point))) (list id)))))
    (unless ids
      (user-error "No entry at point"))
    (let ((schema (tabularium--schema-name))
          (entries '())
          (ops '()))
      (tabularium-db-with-transaction tabularium--db
        ;; Collect data and delete
        (dolist (id ids)
          (when-let ((data (tabularium--get-record-by-id id)))
            (push data entries)
            (push (list :type 'delete :row id :data data) ops)
            (tabularium-db-delete tabularium--db tabularium-table-name
                              (tabularium--primary-field-name) id)))
        (setq entries (nreverse entries))
        ;; Add as batch to kill ring
        (tabularium--add-to-kill-ring schema entries)
        ;; Record undo
        (tabularium--undo-push (if (= 1 (length ops))
                               (car ops)
                             (list :type 'multi :ops (nreverse ops))))
        ;; Clear marks
        (setq tabularium--marked-entries nil)
        ;; Auto-reindex if enabled (nested transaction is a no-op here)
        (when tabularium-auto-reindex
          (tabularium--reindex-silent)))
      (tabularium--invalidate-cache)
      (let ((line (line-number-at-pos)))
        (revert-buffer)
        (goto-char (point-min))
        (forward-line (1- (min line (count-lines (point-min) (point-max))))))
      (tabularium-view--update-mark-display)
      (message "Cut %d %s" (length entries)
               (if (= 1 (length entries)) "entry" "entries")))))

(defun tabularium-view-paste (&optional consume)
  "Paste the most recent kill ring batch at point.
With prefix arg CONSUME, remove the batch from the kill ring."
  (interactive "P")
  (unless tabularium--kill-ring
    (user-error "Kill ring is empty"))
  (let* ((batch (if consume
                    (tabularium--pop-kill-ring)
                  (tabularium--peek-kill-ring)))
         (batch-type (tabularium--kill-ring-batch-type batch)))
    (if (eq batch-type 'columns)
        ;; Paste columns at point: insert before the column at point
        ;; (mirroring row paste at point), or append when point is not on
        ;; a column.
        (tabularium--paste-column-batch
         batch consume
         (or (and (derived-mode-p 'tabularium-view-mode)
                  (tabularium--column-name-at-point))
             'last))
      ;; Row paste
      (if consume
          (tabularium--paste-batch batch nil nil t)
        (tabularium--paste-batch batch nil nil nil)))))

(defun tabularium--paste-batch (batch &optional at-end position consumed)
  "Paste BATCH of entries.
If AT-END, append; else insert at POSITION or point.
CONSUMED indicates whether batch was removed from kill ring (affects undo)."
  (tabularium--ensure-db)
  (let* ((schema (plist-get batch :schema))
         (entries (plist-get batch :entries))
         (current-schema (tabularium--schema-name))
         (primary-name (tabularium--primary-field-name))
         (primary-name-str (symbol-name primary-name)))
    ;; Warn if different schema
    (when (and (not (equal schema current-schema))
               (not (yes-or-no-p
                     (format "Paste %d entries from '%s' into '%s'? "
                             (length entries) schema current-schema))))
      ;; Put batch back if it was consumed and user cancels
      (when consumed
        (push batch tabularium--kill-ring))
      (user-error "Paste canceled"))
    (let* ((insert-position (cond
                             (at-end
                              (1+ (or (caar (tabularium-db-query
                                             tabularium--db
                                             (format "SELECT MAX(%s) FROM %s"
                                                     primary-name-str tabularium-table-name)))
                                      0)))
                             (position position)
                             (t (or (tabularium--id-at-point)
                                    (tabularium--next-id)))))
           (max-id (or (caar (tabularium-db-query
                              tabularium--db
                              (format "SELECT MAX(%s) FROM %s"
                                      primary-name-str tabularium-table-name)))
                       0))
           (num-to-paste (length entries))
           (ops '()))
      (tabularium-db-with-transaction tabularium--db
        ;; Shift entries at and after insert position (if not appending at end)
        (when (and (not at-end) (<= insert-position max-id))
          (let ((ids-to-shift (mapcar #'car
                                      (tabularium-db-query
                                       tabularium--db
                                       (format "SELECT %s FROM %s WHERE %s >= ? ORDER BY %s DESC"
                                               primary-name-str tabularium-table-name
                                               primary-name-str primary-name-str)
                                       (list insert-position)))))
            (dolist (old-id ids-to-shift)
              (tabularium-db-execute
               tabularium--db
               (format "UPDATE %s SET %s = ? WHERE %s = ?"
                       tabularium-table-name primary-name-str primary-name-str)
               (list (+ old-id num-to-paste) old-id)))))
        ;; Insert pasted entries
        (let ((new-id insert-position))
          (dolist (entry entries)
            (let ((data (copy-alist entry)))
              (setf (alist-get primary-name data) new-id)
              (tabularium-db-insert tabularium--db tabularium-table-name data)
              (push (list :type 'insert :row new-id :data data) ops)
              (cl-incf new-id))))
        ;; Record undo - type depends on whether batch was consumed
        (if consumed
            ;; Consumed: undo should restore batch to kill ring
            (tabularium--undo-push (list :type 'paste
                                     :ops (nreverse ops)
                                     :batch batch))
          ;; Not consumed: undo just deletes, does not touch kill ring
          (tabularium--undo-push (list :type 'yank :ops (nreverse ops))))
        ;; Auto-reindex if enabled (nested transaction is a no-op here)
        (when tabularium-auto-reindex
          (tabularium--reindex-silent)))
      (tabularium--invalidate-cache)
      (when (derived-mode-p 'tabularium-view-mode)
        (revert-buffer)
        (tabularium-view-goto-entry insert-position))
      (message "%s %d %s at #%d"
               (if consumed "Pasted" "Yanked")
               num-to-paste
               (if (= 1 num-to-paste) "entry" "entries")
               insert-position))))

(defun tabularium-view-paste-append (&optional consume)
  "Paste the most recent kill ring batch at end of table.
With prefix arg CONSUME, remove the batch from the kill ring."
  (interactive "P")
  (unless tabularium--kill-ring
    (user-error "Kill ring is empty"))
  (let* ((batch (if consume
                    (tabularium--pop-kill-ring)
                  (tabularium--peek-kill-ring)))
         (batch-type (tabularium--kill-ring-batch-type batch)))
    (if (eq batch-type 'columns)
        (tabularium--paste-column-batch batch consume 'last)
      (if consume
          (tabularium--paste-batch batch t nil t)
        (tabularium--paste-batch batch t nil nil)))))

(defun tabularium-view-move (to-position)
  "Move entry at point or all marked entries to TO-POSITION.
Clears marks after moving.  Undoable."
  (interactive
   (let* ((count (if tabularium--marked-entries
                     (length tabularium--marked-entries)
                   1))
          (prompt (if (> count 1)
                      (format "Move %d marked entries to position: " count)
                    "Move entry to position: ")))
     (list (read-number prompt))))
  (tabularium--ensure-db)
  (let* ((ids (or (and tabularium--marked-entries
                       (sort (copy-sequence tabularium--marked-entries) #'<))
                  (when-let ((id (tabularium--id-at-point))) (list id))))
         (primary-name (symbol-name (tabularium--primary-field-name))))
    (unless ids
      (user-error "No entry at point"))
    ;; Snapshot all (rowid, primary-key) BEFORE move
    (let* ((before-map (tabularium-db-query
                        tabularium--db
                        (format "SELECT rowid, %s FROM %s"
                                primary-name tabularium-table-name)
                        nil))
           (num-entries (length ids))
           (temp-base -1000))
      (tabularium-db-with-transaction tabularium--db
        ;; Move all entries to temporary negative IDs
        (cl-loop for id in ids
                 for temp-id from temp-base
                 do (tabularium-db-execute
                     tabularium--db
                     (format "UPDATE %s SET %s = ? WHERE %s = ?"
                             tabularium-table-name primary-name primary-name)
                     (list temp-id id)))
        ;; Shift entries to make room at destination
        (let ((ids-to-shift (mapcar #'car
                                    (tabularium-db-query
                                     tabularium--db
                                     (format "SELECT %s FROM %s WHERE %s >= ? AND %s > 0 ORDER BY %s DESC"
                                             primary-name tabularium-table-name
                                             primary-name primary-name primary-name)
                                     (list to-position)))))
          (dolist (old-id ids-to-shift)
            (tabularium-db-execute
             tabularium--db
             (format "UPDATE %s SET %s = ? WHERE %s = ?"
                     tabularium-table-name primary-name primary-name)
             (list (+ old-id num-entries) old-id))))
        ;; Move temp entries to their final positions
        (cl-loop for temp-id from temp-base
                 for new-id from to-position
                 repeat num-entries
                 do (tabularium-db-execute
                     tabularium--db
                     (format "UPDATE %s SET %s = ? WHERE %s = ?"
                             tabularium-table-name primary-name primary-name)
                     (list new-id temp-id))))
      ;; Record undo: save the before-map so we can restore exactly
      (tabularium--undo-push
       (list :type 'move :before-map before-map :count num-entries))
      ;; Clear marks
      (when tabularium--marked-entries
        (setq tabularium--marked-entries nil))
      (tabularium--invalidate-cache)
      (revert-buffer)
      (tabularium-view--update-mark-display)
      (tabularium-view-goto-entry to-position)
      (message "Moved %d %s to position %d"
               num-entries
               (if (= 1 num-entries) "entry" "entries")
               to-position))))

(defun tabularium-view-duplicate (&optional use-alt-method)
  "Duplicate entry at point or all marked entries.
With prefix argument USE-ALT-METHOD, use the alternative entry method.
Clears marks after duplicating.  Undoable."
  (interactive "P")
  (let ((ids (or (and tabularium--marked-entries
                      (sort (copy-sequence tabularium--marked-entries) #'<))
                 (when-let ((id (tabularium--id-at-point))) (list id)))))
    (unless ids
      (user-error "No entry at point"))
    (if (= 1 (length ids))
        ;; Single entry: use form/minibuffer method
        (progn
          (tabularium--duplicate-with-method (car ids) use-alt-method)
          (setq tabularium--marked-entries nil)
          (tabularium-view--update-mark-display))
      ;; Multiple entries: duplicate all immediately
      (when (yes-or-no-p (format "Duplicate %d entries? " (length ids)))
        (let ((primary-name (tabularium--primary-field-name))
              (ops '()))
          (tabularium-db-with-transaction tabularium--db
            (dolist (id ids)
              (let* ((data (tabularium--get-record-by-id id))
                     (new-id (tabularium--next-id)))
                (when data
                  (setf (alist-get primary-name data) new-id)
                  (tabularium-db-insert tabularium--db tabularium-table-name data)
                  (push (list :type 'insert :row new-id :data data) ops)))))
          (tabularium--undo-push (list :type 'multi :ops (nreverse ops)))
          (setq tabularium--marked-entries nil)
          (tabularium--invalidate-cache)
          (revert-buffer)
          (tabularium-view--update-mark-display)
          (message "Duplicated %d entries" (length ids)))))))

(defun tabularium-view-delete ()
  "Delete entry at point or all marked entries.
Clears marks after deleting.  Undoable."
  (interactive)
  (let ((ids (or (and tabularium--marked-entries
                      (sort (copy-sequence tabularium--marked-entries) #'<))
                 (when-let ((id (tabularium--id-at-point))) (list id)))))
    (unless ids
      (user-error "No entry at point"))
    (when (y-or-n-p (format "Delete %d %s? "
                            (length ids)
                            (if (= 1 (length ids)) "entry" "entries")))
      (let ((ops '()))
        (tabularium-db-with-transaction tabularium--db
          (dolist (id ids)
            (let ((data (tabularium--get-record-by-id id)))
              (push (list :type 'delete :row id :data data) ops)
              (tabularium-db-delete tabularium--db
                                tabularium-table-name
                                (tabularium--primary-field-name)
                                id)))
          (tabularium--undo-push (if (= 1 (length ops))
                                 (car ops)
                               (list :type 'multi :ops (nreverse ops))))
          (setq tabularium--marked-entries nil)
          ;; Auto-reindex if enabled (nested transaction is a no-op here)
          (when tabularium-auto-reindex
            (tabularium--reindex-silent)))
        (tabularium--invalidate-cache)
        ;; Keep point on the same visual row after the revert.
        ;; `revert-buffer' would otherwise reset point to the top; we
        ;; save the line number and the column, then restore both —
        ;; clamping the line to the last data row since deleting rows
        ;; shrinks the buffer.  Landing on the same line number means
        ;; the cursor sits on what was the next row, the familiar
        ;; dired-style "stay put" behavior.
        (let ((saved-line (line-number-at-pos))
              (saved-col (tabularium--column-name-at-point)))
          (revert-buffer)
          (goto-char (point-min))
          (forward-line (1- saved-line))
          ;; If the saved line is now past the end (deleted the last
          ;; row, or a marked batch), fall back to the last data row.
          (when (or (eobp)
                    (null (tabulated-list-get-id)))
            (goto-char (point-max))
            (forward-line -1)
            (beginning-of-line))
          (when saved-col
            (tabularium-view--goto-column saved-col)))
        (tabularium-view--update-mark-display)
        (message "Deleted %d %s"
                 (length ids)
                 (if (= 1 (length ids)) "entry" "entries"))))))

(defun tabularium-view-insert (&optional position)
  "Insert a new entry, shifting subsequent entries.
By default, inserts at point.  With prefix arg, prompts for POSITION.
Opens form for data entry."
  (interactive
   (list (if current-prefix-arg
             (read-number "Insert new entry at position: ")
           (or (tabularium--id-at-point)
               (read-number "Insert new entry at position: ")))))
  (tabularium--ensure-db)
  (let* ((primary-name (tabularium--primary-field-name))
         (primary-name-str (symbol-name primary-name))
         (max-id (or (caar (tabularium-db-query
                            tabularium--db
                            (format "SELECT MAX(%s) FROM %s" primary-name-str tabularium-table-name)))
                     0)))
    (when (< position 1)
      (user-error "Position must be >= 1"))
    (when (> position (1+ max-id))
      (user-error "Position %d is beyond current max (%d); use new-entry instead" position max-id))
    ;; Shift all entries from position onwards up by 1
    (let ((ids-to-shift (mapcar #'car
                                (tabularium-db-query
                                 tabularium--db
                                 (format "SELECT %s FROM %s WHERE %s >= ? ORDER BY %s DESC"
                                         primary-name-str tabularium-table-name
                                         primary-name-str primary-name-str)
                                 (list position)))))
      (dolist (old-id ids-to-shift)
        (tabularium-db-execute
         tabularium--db
         (format "UPDATE %s SET %s = ? WHERE %s = ?"
                 tabularium-table-name primary-name-str primary-name-str)
         (list (1+ old-id) old-id))))
    ;; Open form with the specified position as ID
    (let* ((source-buffer (current-buffer))
           (schema-name (tabularium--schema-name))
           (fields (tabularium--schema-fields))
           (buf (get-buffer-create (format "*%s Form*" schema-name)))
           (initial-values
            (mapcar (lambda (f)
                      (let ((name (plist-get f :id)))
                        (cons name
                              (if (eq name primary-name)
                                  position
                                (or (tabularium--compute-default f) "")))))
                    fields)))
      (unless (tabularium-entry--maybe-discard buf)
        (user-error "Canceled"))
      (with-current-buffer buf
        (tabularium-entry-mode)
        (setq tabularium-entry-schema-name schema-name)
        (setq tabularium-entry--fields fields)
        (setq tabularium-entry--values initial-values)
        (setq tabularium-entry--original-values (copy-alist initial-values))
        (setq tabularium-entry-editing-id nil)
        (setq tabularium-entry--source-buffer
              (when (derived-mode-p 'tabularium-view-mode) source-buffer))
        (run-hooks 'tabularium-entry-new-hook)
        (tabularium-entry-render))
      (tabularium--display-entry-buffer buf)
      (message "Inserting new entry at position %d" position))))

(defun tabularium-view-swap (id1 id2)
  "Swap the positions of two entries, ID1 and ID2.
If exactly 2 entries are marked, swap them.
If >2 entries are marked, suggest using move instead.
Otherwise swap the entry at point with another.  Undoable.
When called non-interactively, swap the entries ID1 and ID2."
  (interactive
   (cond
    ((and tabularium--marked-entries
          (> (length tabularium--marked-entries) 2))
     (user-error "Cannot swap >2 entries.  Use `tabularium-view-move' (M) to reorder multiple entries"))
    ((and tabularium--marked-entries
          (= (length tabularium--marked-entries) 2))
     (let ((sorted (sort (copy-sequence tabularium--marked-entries) #'<)))
       (list (car sorted) (cadr sorted))))
    (t
     (let* ((first (or (tabularium--id-at-point)
                       (read-number "First entry ID: ")))
            (second (read-number (format "Swap entry %d with ID: " first))))
       (list first second)))))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (temp-id -1))
    (when (= id1 id2)
      (user-error "Cannot swap entry with itself"))
    ;; Three-way swap using temp
    (tabularium-db-execute
     tabularium--db
     (format "UPDATE %s SET %s = ? WHERE %s = ?" tabularium-table-name primary-name primary-name)
     (list temp-id id1))
    (tabularium-db-execute
     tabularium--db
     (format "UPDATE %s SET %s = ? WHERE %s = ?" tabularium-table-name primary-name primary-name)
     (list id1 id2))
    (tabularium-db-execute
     tabularium--db
     (format "UPDATE %s SET %s = ? WHERE %s = ?" tabularium-table-name primary-name primary-name)
     (list id2 temp-id))
    ;; Record undo (swap is its own inverse)
    (tabularium--undo-push (list :type 'swap :row1 id1 :row2 id2))
    ;; Clear marks
    (when tabularium--marked-entries
      (setq tabularium--marked-entries nil)
      (tabularium-view--update-mark-display))
    (tabularium--invalidate-cache)
    (revert-buffer)
    (message "Swapped entries %d and %d" id1 id2)))

;;; *** 7.1.4 Freeze Rows

(defface tabularium-frozen-row-face
  '((((class color) (background dark))
     :background "#1e2a3a" :extend t)
    (((class color) (background light))
     :background "#eaf2ff" :extend t)
    (t :inherit highlight :extend t))
  "Face for frozen rows in `tabularium-view-mode'.
Applied as an overlay over the entire row line; priority is lower
than `tabularium-marked-face' so a frozen row that is also marked
is shown in the marked face."
  :group 'tabularium-faces)

(defun tabularium-view--update-frozen-display ()
  "Update the display to show frozen-row highlighting.
Adds an overlay over each frozen row with `tabularium-frozen-row-face',
priority 50 (lower than marks at 100)."
  (remove-overlays (point-min) (point-max) 'tabularium-frozen t)
  (when tabularium--frozen-ids
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let ((id (tabulated-list-get-id)))
          (when (member id tabularium--frozen-ids)
            (let ((ov (make-overlay (line-beginning-position)
                                    (line-end-position))))
              (overlay-put ov 'tabularium-frozen t)
              (overlay-put ov 'face 'tabularium-frozen-row-face)
              (overlay-put ov 'priority 50))))
        (forward-line 1)))))

(defun tabularium-view--update-cf-display ()
  "Update display to show row-scoped highlight faces.
Reads `tabularium--cf-row-faces' (populated by
`tabularium-view--refresh') and overlays each matched row.
Priority 25 keeps marks (100) and frozen highlight (50) on top."
  (remove-overlays (point-min) (point-max) 'tabularium-cf t)
  (when (and tabularium--cf-row-faces
             (> (hash-table-count tabularium--cf-row-faces) 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((id (tabulated-list-get-id))
                    (face (gethash id tabularium--cf-row-faces)))
          (let ((ov (make-overlay (line-beginning-position)
                                  (line-end-position))))
            (overlay-put ov 'tabularium-cf t)
            (overlay-put ov 'face face)
            (overlay-put ov 'priority 25)))
        (forward-line 1)))))

(defun tabularium-view-freeze ()
  "Freeze rows to the top of the view.
With rows marked, freezes all marked rows and clears the marks;
otherwise freezes the row at point.  Mirrors the marked-or-at-point
behaviour of the registry's action commands."
  (interactive)
  (if tabularium--marked-entries
      (let ((count 0))
        (dolist (id tabularium--marked-entries)
          (unless (member id tabularium--frozen-ids)
            (push id tabularium--frozen-ids)
            (cl-incf count)))
        (setq tabularium--marked-entries nil)
        (tabularium-view--update-mark-display)
        (revert-buffer)
        (message "Frozen %d marked %s (%d total frozen)"
                 count (if (= count 1) "row" "rows")
                 (length tabularium--frozen-ids)))
    (when-let ((id (tabularium--id-at-point)))
      (if (member id tabularium--frozen-ids)
          (message "Entry #%s is already frozen" id)
        (push id tabularium--frozen-ids)
        (revert-buffer)
        (message "Frozen entry #%s (%d frozen)"
                 id (length tabularium--frozen-ids))))))

(defun tabularium-view-unfreeze ()
  "Unfreeze rows.
With rows marked, unfreezes all marked rows and clears the marks;
otherwise unfreezes the row at point.  Mirrors the marked-or-at-point
behaviour of the registry's action commands.  Use
`tabularium-view-unfreeze-all' to clear every frozen row at once."
  (interactive)
  (if tabularium--marked-entries
      (let ((count 0))
        (dolist (id tabularium--marked-entries)
          (when (member id tabularium--frozen-ids)
            (setq tabularium--frozen-ids (delete id tabularium--frozen-ids))
            (cl-incf count)))
        (setq tabularium--marked-entries nil)
        (tabularium-view--update-mark-display)
        (revert-buffer)
        (message "Unfroze %d marked %s (%d still frozen)"
                 count (if (= count 1) "row" "rows")
                 (length tabularium--frozen-ids)))
    (when-let ((id (tabularium--id-at-point)))
      (if (member id tabularium--frozen-ids)
          (progn
            (setq tabularium--frozen-ids (delete id tabularium--frozen-ids))
            (revert-buffer)
            (message "Unfroze entry #%s (%d still frozen)"
                     id (length tabularium--frozen-ids)))
        (message "Entry #%s is not frozen" id)))))

(defun tabularium-view-unfreeze-all ()
  "Unfreeze all frozen entries."
  (interactive)
  (if (null tabularium--frozen-ids)
      (message "No frozen entries")
    (let ((count (length tabularium--frozen-ids)))
      (setq tabularium--frozen-ids nil)
      (revert-buffer)
      (message "Unfroze all %d entries" count))))

;;; ** 7.2 Column Operations

;;; *** 7.2.1 Column Reordering

(defun tabularium-view-reorder-columns ()
  "Interactively reorder columns."
  (interactive)
  (let* ((fields (tabularium--schema-fields))
         (current-order (or tabularium--column-order
                            (mapcar (lambda (f) (plist-get f :id)) fields)))
         (new-order '())
         (remaining (copy-sequence current-order)))
    ;; Build new order by repeated selection
    (while remaining
      (let* ((choices (mapcar #'symbol-name remaining))
             (choice (completing-read
                      (format "Column %d (of %d): "
                              (1+ (length new-order))
                              (length current-order))
                      choices nil t nil nil (car choices))))
        (push (intern choice) new-order)
        (setq remaining (delete (intern choice) remaining))))
    (setq tabularium--column-order (nreverse new-order))
    (revert-buffer)
    (message "Columns reordered")))

(defun tabularium-view-move-column-left ()
  "Move the current column one position left.
This reorders the buffer's display only (not the schema) and is
undoable."
  (interactive)
  (let* ((col-idx (tabularium--current-column-index))
         (fields (tabularium--schema-fields))
         (prev-order tabularium--column-order)
         (saved-id (tabulated-list-get-id))
         (order (or tabularium--column-order
                    (mapcar (lambda (f) (plist-get f :id)) fields))))
    (when (and col-idx (> col-idx 0))
      (let ((col (nth col-idx order)))
        (setq order (delete col order))
        (setq order (append (seq-take order (1- col-idx))
                            (list col)
                            (seq-drop order (1- col-idx))))
        (setq tabularium--column-order order)
        (tabularium--undo-push (list :type 'view-reorder :old-order prev-order))
        (revert-buffer)
        ;; Follow the column so repeated moves keep working on it.
        (tabularium-view--goto-position saved-id col)))))

(defun tabularium-view-move-column-right ()
  "Move the current column one position right.
This reorders the buffer's display only (not the schema) and is
undoable."
  (interactive)
  (let* ((col-idx (tabularium--current-column-index))
         (fields (tabularium--schema-fields))
         (prev-order tabularium--column-order)
         (saved-id (tabulated-list-get-id))
         (order (or tabularium--column-order
                    (mapcar (lambda (f) (plist-get f :id)) fields)))
         (max-idx (1- (length order))))
    (when (and col-idx (< col-idx max-idx))
      (let ((col (nth col-idx order)))
        (setq order (delete col order))
        (setq order (append (seq-take order (1+ col-idx))
                            (list col)
                            (seq-drop order (1+ col-idx))))
        (setq tabularium--column-order order)
        (tabularium--undo-push (list :type 'view-reorder :old-order prev-order))
        (revert-buffer)
        ;; Follow the column so repeated moves keep working on it.
        (tabularium-view--goto-position saved-id col)))))

(defun tabularium-view-reset-column-order ()
  "Reset columns to schema-defined order."
  (interactive)
  (setq tabularium--column-order nil)
  (revert-buffer)
  (message "Column order reset to default"))

(defun tabularium--current-column-index ()
  "Get the index of the column at point.
Column boundaries are computed from `tabularium-view--column-start-position'
so that this and `tabularium-view--move-to-column' agree exactly:
column I owns the half-open span from its own start position up to
the next column's start position (its content plus the trailing
separator), and the final column owns everything from its start
onward.  Point sitting on a column's start position therefore
always reads back as that column — not the previous one."
  (when (derived-mode-p 'tabularium-view-mode)
    (let* ((col (current-column))
           (ncols (length tabulated-list-format))
           (idx (1- ncols)))           ; default: last column
      (cl-block scan
        (cl-loop for i from 0 below ncols
                 for start = (tabularium-view--column-start-position i)
                 for next = (if (< (1+ i) ncols)
                                (tabularium-view--column-start-position (1+ i))
                              most-positive-fixnum)
                 when (and (>= col start) (< col next))
                 do (setq idx i) (cl-return-from scan)))
      ;; Point before the first column's start (rare) → column 0.
      (when (< col (tabularium-view--column-start-position 0))
        (setq idx 0))
      idx)))

;;; *** 7.2.2 Creative/Destructive Operations

(defun tabularium--column-name-at-point ()
  "Return the column name (symbol) at point in view mode, or nil."
  (when (derived-mode-p 'tabularium-view-mode)
    (when-let ((idx (tabularium--current-column-index)))
      (let* ((fields (tabularium--schema-fields))
             (order (or tabularium--column-order
                        (mapcar (lambda (f) (plist-get f :id)) fields)))
             ;; Filter to visible columns only
             (visible (cl-remove-if
                       (lambda (name)
                         (or (memq name tabularium--hidden-columns)
                             (let ((f (tabularium--field-by-name name)))
                               (plist-get f :hidden))))
                       order))
             ;; Account for freeze indicator column offset
             (adjusted-idx (if tabularium--frozen-ids (1- idx) idx)))
        (when (and (>= adjusted-idx 0) (< adjusted-idx (length visible)))
          (nth adjusted-idx visible))))))

(defun tabularium-view-column-add (name type prompt &optional default after-column field-plist)
  "Add a new column NAME with TYPE and PROMPT to the current table.
TYPE should be one of: text, integer, number, date, time, datetime,
choice, boolean.  DEFAULT, if given, is the column's default value.
AFTER-COLUMN is the column name (symbol) to insert after; the symbol
\\='__first__ means insert after the primary key column; nil means append.
FIELD-PLIST, when non-nil, is a complete field definition (as produced
by the schema wizard) and supersedes NAME/TYPE/PROMPT/DEFAULT; it may
carry :choice, :boolean-pair, :complete, :required, :width, :long, and
a computed placeholder, all of which are persisted to the schema.

Interactively this always appends the new column at the end of the
table (use `tabularium-view-column-insert' to place a column at a
chosen position) and walks the schema wizard's full field-definition
decision tree, validating any default against the column type.
This modifies both the database and the schema.  Undoable."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (fp (tabularium-wizard--read-field (1+ (length fields)) fields)))
     (unless fp (user-error "Canceled"))
     (list (plist-get fp :id) (plist-get fp :type) (plist-get fp :label)
           (plist-get fp :default) nil fp)))
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (primary (tabularium--primary-field-name))
         ;; A full wizard plist supersedes the scalar args; otherwise
         ;; synthesize the historical minimal field (backward-compatible).
         (new-field (if field-plist
                        (copy-sequence field-plist)
                      (let ((f (list :id name :type type :label prompt
                                     :complete (if (eq type 'text) 'historical nil))))
                        (when default (setq f (plist-put f :default default)))
                        f)))
         (col-name (plist-get new-field :id))
         (col-type (plist-get new-field :type))
         (col-default (plist-get new-field :default))
         (col-label (or (plist-get new-field :label) prompt ""))
         (sql-type (pcase col-type
                     ('integer "INTEGER")
                     ('number "REAL")
                     (_ "TEXT")))
         ;; Only literal (string/number) defaults become a SQL DEFAULT, which
         ;; also back-fills existing rows.  Symbolic defaults (today/now) are
         ;; applied by the entry layer, so the column is added plain.
         (sql-default-p (and col-default (not (symbolp col-default))))
         (default-clause (if sql-default-p
                             (format " DEFAULT '%s'" col-default)
                           ""))
         (width (or (plist-get new-field :width)
                    (max (length col-label)
                         (if sql-default-p (length (format "%s" col-default)) 10)
                         10))))
    (setq new-field (plist-put new-field :width width))
    ;; Add column to database
    (tabularium-db-execute tabularium--db
                           (format "ALTER TABLE %s ADD COLUMN %s %s%s"
                                   tabularium-table-name col-name sql-type default-clause)
                           nil)
    ;; Update schema in memory
    (let* ((schema (assoc schema-name tabularium-schemas))
           (plist (cdr schema))
           (fields (plist-get plist :fields)))
      ;; Insert at the right position
      (cond
       ((eq after-column '__first__)
        ;; After primary key column
        (let ((pk-pos (or (cl-position-if
                           (lambda (f) (eq (plist-get f :id) primary))
                           fields)
                          0)))
          (setq fields (append (seq-take fields (1+ pk-pos))
                               (list new-field)
                               (seq-drop fields (1+ pk-pos))))))
       (after-column
        (let ((pos (cl-position-if
                    (lambda (f) (eq (plist-get f :id) after-column))
                    fields)))
          (if pos
              (setq fields (append (seq-take fields (1+ pos))
                                   (list new-field)
                                   (seq-drop fields (1+ pos))))
            (setq fields (append fields (list new-field))))))
       (t
        (setq fields (append fields (list new-field)))))
      (setf (cdr schema) (plist-put plist :fields fields))
      ;; Save updated schema to file
      (tabularium--save-schema-to-file schema-name)
      ;; Push undo
      (tabularium--undo-push
       (list :type 'add-column :column col-name :field-plist new-field)))
    (tabularium--invalidate-cache)
    (when (derived-mode-p 'tabularium-view-mode)
      (let ((saved-id (tabulated-list-get-id)))
        (revert-buffer)
        (tabularium-view--goto-position saved-id col-name)))
    (message "Added column '%s' (%s)%s" col-name col-type
             (cond ((eq after-column '__first__)
                    (format " after '%s'" primary))
                   (after-column (format " after '%s'" after-column))
                   (t " at end")))))

(defun tabularium-view-column-delete (names)
  "Delete one or more columns NAMES from the current table.
NAMES is a list of column name symbols.
This removes the columns and all their data from the database.
The primary key column cannot be deleted.  Undoable."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (primary (tabularium--primary-field-name))
          (deletable (cl-remove-if
                      (lambda (f) (eq (plist-get f :id) primary))
                      fields))
          (choices (mapcar (lambda (f) (symbol-name (plist-get f :id))) deletable))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (let ((col (tabularium--column-name-at-point)))
                             (when (and col (not (eq col primary)))
                               col))))
          (candidates (append (when at-point-name
                                (list (format "<<POINT>> %s"
                                              (symbol-name at-point-name))))
                              choices))
          (selected (completing-read-multiple
                     "Delete column(s): " candidates nil t nil nil
                     (when at-point-name
                       (format "<<POINT>> %s" (symbol-name at-point-name)))))
          (resolved (mapcar (lambda (s)
                              (if (string-prefix-p "<<POINT>> " s)
                                  at-point-name
                                (intern s)))
                            selected)))
     (list (delete-dups resolved))))
  (tabularium--ensure-db)
  (let* ((primary-name (tabularium--primary-field-name))
         ;; Save visible column order before deletion for cursor fallback
         (pre-visible
          (when (derived-mode-p 'tabularium-view-mode)
            (mapcar (lambda (f) (plist-get f :id))
                    (cl-remove-if-not #'tabularium-view--field-visible-p
                                      (tabularium--schema-fields))))))
    (dolist (name names)
      (when (eq name primary-name)
        (user-error "Cannot delete primary key column")))
    (unless (yes-or-no-p (format "Delete %d column%s and all %s data? "
                                 (length names)
                                 (if (= 1 (length names)) "" "s")
                                 (if (= 1 (length names)) "its" "their")))
      (user-error "Canceled"))
    (let ((ops '()))
      (dolist (name names)
        (let* ((schema-name (tabularium--schema-name))
               (fields (tabularium--schema-fields))
               (name-str (symbol-name name))
               (field-plist (cl-find-if (lambda (f) (eq (plist-get f :id) name)) fields))
               (position (cl-position field-plist fields :test #'equal))
               (computed-p (tabularium--computed-field-p field-plist))
               (primary-str (symbol-name primary-name))
               (rows (unless computed-p
                       (tabularium-db-query
                        tabularium--db
                        (format "SELECT %s, %s FROM %s WHERE %s IS NOT NULL AND %s != ''"
                                primary-str name-str tabularium-table-name
                                name-str name-str)
                        nil)))
               (col-data (mapcar (lambda (row) (cons (car row) (cadr row))) rows)))
          ;; Recreate the table without this column (physical columns only).
          (unless computed-p
            (tabularium--rebuild-table-dropping name))
          ;; Update schema in memory
          (let* ((schema (assoc schema-name tabularium-schemas))
                 (plist (cdr schema))
                 (new-fields (cl-remove-if (lambda (f) (eq (plist-get f :id) name))
                                           (plist-get plist :fields))))
            (setf (cdr schema) (plist-put plist :fields new-fields))
            (tabularium--save-schema-to-file schema-name))
          (push (list :type 'delete-column :column name
                      :field-plist field-plist :position position
                      :data col-data)
                ops)))
      ;; Push undo
      (tabularium--undo-push
       (if (= 1 (length ops))
           (car ops)
         (list :type 'multi :ops (nreverse ops)))))
    (tabularium--invalidate-cache)
    (when (derived-mode-p 'tabularium-view-mode)
      (let* ((saved-id (tabulated-list-get-id))
             (saved-col (tabularium--column-name-at-point))
             ;; Find fallback column from pre-deletion order
             (fallback-col
              (when (and pre-visible (member saved-col names))
                (let ((found-deleted nil)
                      (result nil))
                  ;; Find column after the last deleted one
                  (dolist (col pre-visible)
                    (if (member col names)
                        (setq found-deleted t)
                      (when (and found-deleted (not result))
                        (setq result col))))
                  ;; If no column after, try column before
                  (unless result
                    (let ((prev nil))
                      (dolist (col pre-visible)
                        (if (member col names)
                            (unless result (setq result prev))
                          (setq prev col)))))
                  result))))
        (revert-buffer)
        (tabularium-view--goto-position saved-id
                                        (if (member saved-col names)
                                            fallback-col
                                          saved-col))))
    (message "Deleted %d column%s" (length names)
             (if (= 1 (length names)) "" "s"))))

(defun tabularium-view-column-move (columns target)
  "Move COLUMNS (list of symbols) to be before TARGET column.
TARGET nil means move to the end.  TARGET \\='__first__ means move
to the beginning (after the primary key column).
This reorders the schema and saves.  Undoable."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (primary (tabularium--primary-field-name))
          (all-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) fields))
          (movable (cl-remove-if
                    (lambda (f) (eq (plist-get f :id) primary))
                    fields))
          (movable-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) movable))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (let ((col (tabularium--column-name-at-point)))
                             (when (and col (not (eq col primary)))
                               col))))
          (sel-candidates (append (when at-point-name
                                    (list (format "<<POINT>> %s"
                                                  (symbol-name at-point-name))))
                                  movable-names))
          (selected (completing-read-multiple
                     "Move columns: " sel-candidates nil t nil nil
                     (when at-point-name
                       (format "<<POINT>> %s" (symbol-name at-point-name)))))
          (sel-syms (mapcar (lambda (s)
                              (if (string-prefix-p "<<POINT>> " s)
                                  at-point-name
                                (intern s)))
                            selected))
          (sel-syms (delete-dups sel-syms))
          (sel-names (mapcar #'symbol-name sel-syms))
          ;; Build target candidates (exclude selected columns)
          (remaining (cl-remove-if (lambda (n) (member n sel-names)) all-names))
          (tgt-at-point (when (and at-point-name
                                   (not (memq at-point-name sel-syms))
                                   (member (symbol-name at-point-name) remaining))
                          at-point-name))
          (tgt-candidates (append (when tgt-at-point
                                    (list (format "<<POINT>> %s"
                                                  (symbol-name tgt-at-point))))
                                  (list "<<FIRST>>" "<<LAST>>")
                                  remaining))
          (tgt-default (if tgt-at-point
                           (format "<<POINT>> %s" (symbol-name tgt-at-point))
                         "<<FIRST>>"))
          (target-choice (completing-read "Move before: " tgt-candidates nil t
                                          nil nil tgt-default))
          (before-col (cond
                       ((string= target-choice "<<FIRST>>") '__first__)
                       ((string= target-choice "<<LAST>>") nil)
                       ((string-prefix-p "<<POINT>> " target-choice) tgt-at-point)
                       (t (intern target-choice)))))
     (list sel-syms before-col)))
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (schema (assoc schema-name tabularium-schemas))
         (plist (cdr schema))
         (fields (plist-get plist :fields))
         (old-order (mapcar (lambda (f) (plist-get f :id)) fields))
         (primary (tabularium--primary-field-name))
         ;; Ensure columns is a proper list of symbols
         (columns (if (listp columns) columns (list columns)))
         ;; Remove selected columns from the list
         (remaining (cl-remove-if (lambda (f)
                                    (member (plist-get f :id) columns))
                                  fields))
         (moved-fields (cl-remove-if-not (lambda (f)
                                           (member (plist-get f :id) columns))
                                         fields))
         ;; Convert before-column to insertion position
         (pos (cond
               ;; __first__: after primary key
               ((eq target '__first__)
                (1+ (or (cl-position-if
                         (lambda (f) (eq (plist-get f :id) primary))
                         remaining)
                        0)))
               ;; nil: at end
               ((null target) (length remaining))
               ;; Named column: before it (find its position in remaining)
               (t (or (cl-position-if
                       (lambda (f) (eq (plist-get f :id) target))
                       remaining)
                      (length remaining)))))
         (new-fields (append (seq-take remaining pos)
                             moved-fields
                             (seq-drop remaining pos))))
    (setf (cdr schema) (plist-put plist :fields new-fields))
    (tabularium--save-schema-to-file schema-name)
    (tabularium--undo-push
     (list :type 'reorder-columns :old-order old-order))
    (tabularium--invalidate-cache)
    (setq tabularium--column-order nil)
    (when (derived-mode-p 'tabularium-view-mode)
      (let ((saved-id (tabulated-list-get-id)))
        (revert-buffer)
        (tabularium-view--goto-position saved-id (car columns))))
    (message "Moved %d column%s" (length columns)
             (if (= 1 (length columns)) "" "s"))))

(defun tabularium-view-column-swap (col-a col-b)
  "Swap positions of columns COL-A and COL-B in the schema.
Undoable."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (all-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) fields))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (tabularium--column-name-at-point)))
          (first-candidates (append (when at-point-name
                                     (list (format "<<POINT>> %s" (symbol-name at-point-name))))
                                   all-names))
          (first-choice (completing-read "Swap column: " first-candidates nil t))
          (first (if (string-prefix-p "<<POINT>> " first-choice)
                     at-point-name
                   (intern first-choice)))
          (rest (cl-remove (symbol-name first) all-names :test #'string=))
          (second (intern (completing-read
                           (format "Swap '%s' with: " first) rest nil t))))
     (list first second)))
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (schema (assoc schema-name tabularium-schemas))
         (plist (cdr schema))
         (fields (plist-get plist :fields))
         (old-order (mapcar (lambda (f) (plist-get f :id)) fields))
         (idx-a (cl-position-if (lambda (f) (eq (plist-get f :id) col-a)) fields))
         (idx-b (cl-position-if (lambda (f) (eq (plist-get f :id) col-b)) fields)))
    (unless (and idx-a idx-b)
      (user-error "Column not found"))
    (let ((field-a (nth idx-a fields))
          (new-fields (copy-sequence fields)))
      (setf (nth idx-a new-fields) (nth idx-b fields))
      (setf (nth idx-b new-fields) field-a)
      (setf (cdr schema) (plist-put plist :fields new-fields))
      (tabularium--save-schema-to-file schema-name)
      (tabularium--undo-push
       (list :type 'reorder-columns :old-order old-order))
      (tabularium--invalidate-cache)
      (setq tabularium--column-order nil)
      (when (derived-mode-p 'tabularium-view-mode)
        (let ((saved-id (tabulated-list-get-id)))
          (revert-buffer)
          (tabularium-view--goto-position saved-id col-a)))
      (message "Swapped columns '%s' and '%s'" col-a col-b))))

(defun tabularium-view-column-copy (columns)
  "Copy COLUMNS to the kill ring.
Stores schema and data for each column as a column batch."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (all-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) fields))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (tabularium--column-name-at-point)))
          (candidates (append (when at-point-name
                                (list (format "<<POINT>> %s"
                                              (symbol-name at-point-name))))
                              all-names))
          (selected (completing-read-multiple
                     "Copy columns: " candidates nil t nil nil
                     (when at-point-name
                       (format "<<POINT>> %s" (symbol-name at-point-name)))))
          (resolved (mapcar (lambda (s)
                              (if (string-prefix-p "<<POINT>> " s)
                                  at-point-name
                                (intern s)))
                            selected)))
     (list (delete-dups resolved))))
  (tabularium--ensure-db)
  (let ((entries '()))
    (dolist (col columns)
      (let* ((field-plist (tabularium--field-by-name col))
             (name-str (symbol-name col))
             (primary-str (symbol-name (tabularium--primary-field-name)))
             (rows (tabularium-db-query
                    tabularium--db
                    (format "SELECT %s, %s FROM %s WHERE %s IS NOT NULL AND %s != ''"
                            primary-str name-str tabularium-table-name
                            name-str name-str)
                    nil))
             (col-data (mapcar (lambda (row) (cons (car row) (cadr row))) rows)))
        (push (list :column col :field-plist (copy-sequence field-plist) :data col-data)
              entries)))
    (tabularium--add-to-kill-ring (tabularium--schema-name)
                                   (nreverse entries) 'columns)
    (message "Copied %d column%s to kill ring"
             (length columns) (if (= 1 (length columns)) "" "s"))))

(defun tabularium-view-column-duplicate (source-col &optional new-name)
  "Duplicate column SOURCE-COL, creating a new column with NEW-NAME.
Copies the column schema and all data.  The new column is placed
immediately after the source column.  Undoable."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (col-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) fields))
          (at-point (when (derived-mode-p 'tabularium-view-mode)
                      (tabularium--column-name-at-point)))
          (candidates (append (when at-point
                                (list (format "<<POINT>> %s" (symbol-name at-point))))
                              col-names))
          (default (if at-point
                       (format "<<POINT>> %s" (symbol-name at-point))
                     (car col-names)))
          (choice (completing-read "Duplicate column: " candidates nil t nil nil default))
          (source (if (string-prefix-p "<<POINT>> " choice)
                      at-point
                    (intern choice)))
          (new (intern (read-string (format "New column name (copy of %s): " source)
                                    (format "%s_copy" source)))))
     (list source new)))
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (field-plist (tabularium--field-by-name source-col))
         (source-str (symbol-name source-col))
         (new-str (symbol-name new-name))
         (type (plist-get field-plist :type))
         (sql-type (pcase type
                     ('integer "INTEGER")
                     ('number "REAL")
                     (_ "TEXT")))
         ;; Build new field plist from source
         (new-field (copy-sequence field-plist)))
    (setq new-field (plist-put new-field :id new-name))
    (setq new-field (plist-put new-field :label
                               (or (read-string
                                    (format "Prompt for %s: " new-name)
                                    (plist-get field-plist :label))
                                   (capitalize new-str))))
    ;; Add column to database
    (tabularium-db-execute tabularium--db
                           (format "ALTER TABLE %s ADD COLUMN %s %s"
                                   tabularium-table-name new-str sql-type)
                           nil)
    ;; Copy data from source to new column
    (tabularium-db-execute tabularium--db
                           (format "UPDATE %s SET %s = %s"
                                   tabularium-table-name new-str source-str)
                           nil)
    ;; Update schema in memory - insert after source column
    (let* ((schema (assoc schema-name tabularium-schemas))
           (plist (cdr schema))
           (fields (plist-get plist :fields))
           (pos (cl-position-if
                 (lambda (f) (eq (plist-get f :id) source-col))
                 fields)))
      (if pos
          (setq fields (append (seq-take fields (1+ pos))
                               (list new-field)
                               (seq-drop fields (1+ pos))))
        (setq fields (append fields (list new-field))))
      (setf (cdr schema) (plist-put plist :fields fields))
      ;; Save updated schema to file
      (tabularium--save-schema-to-file schema-name)
      ;; Push undo
      (tabularium--undo-push
       (list :type 'add-column :column new-name :field-plist new-field)))
    (tabularium--invalidate-cache)
    (when (derived-mode-p 'tabularium-view-mode)
      (let ((saved-id (tabulated-list-get-id)))
        (revert-buffer)
        (tabularium-view--goto-position saved-id new-name)))
    (message "Duplicated column '%s' → '%s'" source-col new-name)))

(defun tabularium-view-column-cut (columns)
  "Cut COLUMNS: copy to kill ring then delete from schema/database.
The primary key column cannot be cut.  Undoable."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (primary (tabularium--primary-field-name))
          (deletable (cl-remove-if
                      (lambda (f) (eq (plist-get f :id) primary))
                      fields))
          (choices (mapcar (lambda (f) (symbol-name (plist-get f :id))) deletable))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (let ((col (tabularium--column-name-at-point)))
                             (when (and col (not (eq col primary)))
                               col))))
          (candidates (append (when at-point-name
                               (list (format "<<POINT>> %s"
                                             (symbol-name at-point-name))))
                             choices))
          (selected (completing-read-multiple
                     "Cut columns: " candidates nil t nil nil
                     (when at-point-name
                       (format "<<POINT>> %s" (symbol-name at-point-name)))))
          (resolved (mapcar (lambda (s)
                              (if (string-prefix-p "<<POINT>> " s)
                                  at-point-name
                                (intern s)))
                            selected)))
     (list (delete-dups resolved))))
  (tabularium--ensure-db)
  ;; Save the visible order and point's position BEFORE the cut: once the
  ;; columns are gone from the schema, the column-at-point lookup no longer
  ;; matches what is still on screen and would report nothing.
  (let ((pre-visible
         (when (derived-mode-p 'tabularium-view-mode)
           (mapcar (lambda (f) (plist-get f :id))
                   (cl-remove-if-not #'tabularium-view--field-visible-p
                                     (tabularium--schema-fields)))))
        (pre-id (when (derived-mode-p 'tabularium-view-mode)
                  (tabulated-list-get-id)))
        (pre-col (when (derived-mode-p 'tabularium-view-mode)
                   (tabularium--column-name-at-point))))
    ;; First copy to kill ring
    (tabularium-view-column-copy columns)
    ;; Then delete each column
    (let ((ops '()))
    (dolist (col columns)
      (let* ((schema-name (tabularium--schema-name))
             (fields (tabularium--schema-fields))
             (field-plist (cl-find-if (lambda (f) (eq (plist-get f :id) col)) fields))
             (position (cl-position field-plist fields :test #'equal))
             (name-str (symbol-name col))
             (computed-p (tabularium--computed-field-p field-plist))
             (primary-str (symbol-name (tabularium--primary-field-name)))
             (rows (unless computed-p
                     (tabularium-db-query
                      tabularium--db
                      (format "SELECT %s, %s FROM %s WHERE %s IS NOT NULL AND %s != ''"
                              primary-str name-str tabularium-table-name
                              name-str name-str)
                      nil)))
             (col-data (mapcar (lambda (row) (cons (car row) (cadr row))) rows)))
        ;; Recreate the table without this column (physical columns only).
        (unless computed-p
          (tabularium--rebuild-table-dropping col))
        ;; Update schema
        (let* ((schema (assoc schema-name tabularium-schemas))
               (plist (cdr schema))
               (new-fields (cl-remove-if (lambda (f) (eq (plist-get f :id) col))
                                          (plist-get plist :fields))))
          (setf (cdr schema) (plist-put plist :fields new-fields))
          (tabularium--save-schema-to-file schema-name))
        (push (list :type 'delete-column :column col
                    :field-plist field-plist :position position
                    :data col-data)
              ops)))
    ;; Push undo
    (tabularium--undo-push
     (if (= 1 (length ops))
         (car ops)
       (list :type 'multi :ops (nreverse ops))))
    (tabularium--invalidate-cache)
    (when (derived-mode-p 'tabularium-view-mode)
      (let* ((cut-at-point (and pre-col (member pre-col columns)))
             (pos (and cut-at-point (cl-position pre-col pre-visible)))
             ;; Prefer the nearest surviving column to the left; fall back to
             ;; the nearest one to the right when the cut reached the start.
             (fallback-col
              (when pos
                (or (cl-find-if (lambda (c) (not (member c columns)))
                                (reverse (seq-take pre-visible pos)))
                    (cl-find-if (lambda (c) (not (member c columns)))
                                (seq-drop pre-visible (1+ pos)))))))
        (revert-buffer)
        (tabularium-view--goto-position pre-id
                                        (if cut-at-point fallback-col pre-col))))
    (message "Cut %d column%s" (length columns)
             (if (= 1 (length columns)) "" "s")))))

(defun tabularium--unique-column-name (base-name)
  "Return a unique column name symbol based on BASE-NAME.
If BASE-NAME already exists, append _copy1, _copy2, etc."
  (if (not (tabularium--field-by-name base-name))
      base-name
    (let ((base-str (symbol-name base-name))
          (n 1)
          candidate)
      (while (progn
               (setq candidate (intern (format "%s_copy%d" base-str n)))
               (tabularium--field-by-name candidate))
        (cl-incf n))
      candidate)))

(defun tabularium--paste-column-batch (batch &optional _consumed position)
  "Paste a column BATCH from the kill ring.
_CONSUMED indicates whether batch was already removed from kill ring.
POSITION may be a column name symbol (paste before that column), the
symbol \\='__first__ (paste after the primary key), or \\='last / nil
\(append at the end)."
  (tabularium--ensure-db)
  (let* ((columns (plist-get batch :columns))
         (schema-name (tabularium--schema-name))
         (primary (tabularium--primary-field-name))
         (fields (tabularium--schema-fields))
         (before-column
          (cond
           ((eq position 'last) nil)
           ((eq position '__first__) '__first__)
           (t position)))
         ;; Convert before-column to after-column
         (after-column
          (cond
           ;; <LAST>: append at end
           ((null before-column) nil)
           ;; <FIRST>: after primary key
           ((eq before-column '__first__) '__first__)
           ;; Named column: find the column before it
           (t (let ((pos (cl-position-if
                          (lambda (f) (eq (plist-get f :id) before-column))
                          fields)))
                (if (or (null pos) (<= pos 0))
                    '__first__  ; before first data column = after PK
                  (plist-get (nth (1- pos) fields) :id))))))
         (ops '())
         (renamed '()))
    (dolist (entry columns)
      (let* ((orig-name (plist-get entry :column))
             (name (tabularium--unique-column-name orig-name))
             (field-plist (copy-sequence (plist-get entry :field-plist)))
             (col-data (plist-get entry :data))
             (name-str (symbol-name name))
             (col-type (plist-get field-plist :type))
             (sql-type (pcase col-type
                         ('integer "INTEGER")
                         ('number "REAL")
                         (_ "TEXT")))
             (primary-str (symbol-name primary)))
        ;; Track renames
        (unless (eq orig-name name)
          (push (cons orig-name name) renamed))
        ;; Update field-plist with the (possibly new) name
        (setq field-plist (plist-put field-plist :id name))
        ;; Add column to DB
        (tabularium-db-execute tabularium--db
                               (format "ALTER TABLE %s ADD COLUMN %s %s"
                                       tabularium-table-name name-str sql-type)
                               nil)
        ;; Restore data (batched: one commit for the whole column)
        (tabularium-db-with-transaction tabularium--db
          (dolist (pair col-data)
            (tabularium-db-execute
             tabularium--db
             (format "UPDATE %s SET %s = ? WHERE %s = ?"
                     tabularium-table-name name-str primary-str)
             (list (cdr pair) (car pair)))))
        ;; Insert field into schema
        (let* ((schema (assoc schema-name tabularium-schemas))
               (plist (cdr schema))
               (cur-fields (plist-get plist :fields))
               (pos (cond
                     ((eq after-column '__first__)
                      (1+ (or (cl-position-if
                               (lambda (f) (eq (plist-get f :id) primary))
                               cur-fields)
                              0)))
                     (after-column
                      (1+ (or (cl-position-if
                               (lambda (f) (eq (plist-get f :id) after-column))
                               cur-fields)
                              (length cur-fields))))
                     (t (length cur-fields))))
               (new-fields (append (seq-take cur-fields pos)
                                   (list field-plist)
                                   (seq-drop cur-fields pos))))
          (setf (cdr schema) (plist-put plist :fields new-fields))
          ;; Update after-column for the next pasted column to go after this one
          (setq after-column name))
        (push (list :type 'add-column :column name :field-plist field-plist) ops)))
    (tabularium--save-schema-to-file schema-name)
    ;; Push undo
    (tabularium--undo-push
     (if (= 1 (length ops))
         (car ops)
       (list :type 'multi :ops (nreverse ops))))
    (tabularium--invalidate-cache)
    ;; Navigate to the first pasted column
    (let ((first-name (when ops (plist-get (car (last ops)) :name))))
      (when (derived-mode-p 'tabularium-view-mode)
        (let ((saved-id (tabulated-list-get-id)))
          (revert-buffer)
          (when first-name
            (tabularium-view--goto-position saved-id first-name)))))
    (let ((msg (format "Pasted %d column%s"
                       (length columns)
                       (if (= 1 (length columns)) "" "s"))))
      (when renamed
        (setq msg (concat msg " ("
                          (mapconcat (lambda (pair)
                                      (format "%s → %s" (car pair) (cdr pair)))
                                    (nreverse renamed) ", ")
                          ")")))
      (message "%s" msg))))

(defun tabularium-view-column-paste ()
  "Paste column(s) from the kill ring before a chosen column.
The target defaults to the column at point; \\='__first__' (shown as
=<<FIRST>>=) places the column(s) after the primary key and
=<<LAST>>= appends.  Errors unless the most recent kill-ring batch
is a set of columns.  The column-oriented counterpart to
`tabularium-view-paste'.  Undoable."
  (interactive)
  (let ((batch (tabularium--peek-kill-ring)))
    (unless batch
      (user-error "Kill ring is empty"))
    (unless (eq (tabularium--kill-ring-batch-type batch) 'columns)
      (user-error "The most recent kill-ring batch is rows, not columns"))
    (let* ((fields (tabularium--schema-fields))
           (col-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) fields))
           (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                            (tabularium--column-name-at-point)))
           (candidates (append (when at-point-name
                                 (list (format "<<POINT>> %s"
                                               (symbol-name at-point-name))))
                               (list "<<FIRST>>" "<<LAST>>")
                               col-names))
           (pos-default (if at-point-name
                            (format "<<POINT>> %s" (symbol-name at-point-name))
                          "<<LAST>>"))
           (choice (completing-read "Paste column(s) before: "
                                    candidates nil t nil nil pos-default))
           (before (cond
                    ((string= choice "<<FIRST>>") '__first__)
                    ((string= choice "<<LAST>>") 'last)
                    ((string-prefix-p "<<POINT>> " choice) at-point-name)
                    (t (intern choice)))))
      (tabularium--paste-column-batch batch nil before))))

(defun tabularium-view-column-paste-append ()
  "Append column(s) from the kill ring at the end of the table.
Errors unless the most recent kill-ring batch is a set of columns.
The column-oriented counterpart to `tabularium-view-paste-append'.
Undoable."
  (interactive)
  (let ((batch (tabularium--peek-kill-ring)))
    (unless batch
      (user-error "Kill ring is empty"))
    (unless (eq (tabularium--kill-ring-batch-type batch) 'columns)
      (user-error "The most recent kill-ring batch is rows, not columns"))
    (tabularium--paste-column-batch batch nil 'last)))

(defun tabularium-view-column-edit (edits)
  "Edit properties of one or more columns.
EDITS is a list of plists, each with :old-name (the current column
symbol) and :new-field (a complete replacement field plist as produced
by the schema wizard in edit mode).  Interactively, each selected
column is walked through the wizard's full field-definition decision
tree with its current values pre-filled.  Modifies the columns in both
the database and the schema.  Undoable."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (primary (tabularium--primary-field-name))
          (editable (cl-remove-if
                     (lambda (f) (eq (plist-get f :id) primary))
                     fields))
          (choices (mapcar (lambda (f) (symbol-name (plist-get f :id))) editable))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (let ((col (tabularium--column-name-at-point)))
                             (when (and col (not (eq col primary)))
                               col))))
          (candidates (append (when at-point-name
                                (list (format "<<POINT>> %s"
                                              (symbol-name at-point-name))))
                              choices))
          (selected (completing-read-multiple
                     "Edit column(s): " candidates nil t nil nil
                     (when at-point-name
                       (format "<<POINT>> %s" (symbol-name at-point-name)))))
          (sel-syms (delete-dups
                     (mapcar (lambda (s)
                               (if (string-prefix-p "<<POINT>> " s)
                                   at-point-name
                                 (intern s)))
                             selected)))
          ;; Walk each selected column through the wizard in edit mode; the
          ;; current field pre-fills every prompt.  A nil result (label
          ;; cleared) leaves that column unchanged.
          (edit-list
           (delq nil
                 (mapcar
                  (lambda (old-sym)
                    (let* ((field (tabularium--field-by-name old-sym))
                           (idx (1+ (or (cl-position-if
                                         (lambda (f) (eq (plist-get f :id) old-sym))
                                         fields)
                                        0)))
                           (siblings (cl-remove-if
                                      (lambda (f) (eq (plist-get f :id) old-sym))
                                      fields))
                           (new-field (tabularium-wizard--read-field
                                       idx siblings field)))
                      (and new-field
                           (list :old-name old-sym :new-field new-field))))
                  sel-syms))))
     (list edit-list)))
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (ops '())
         (changes '()))
    (dolist (edit edits)
      (let* ((old-name (plist-get edit :old-name))
             (new-field (copy-sequence (plist-get edit :new-field)))
             (new-name (plist-get new-field :id))
             (schema (assoc schema-name tabularium-schemas))
             (plist (cdr schema))
             (cur-fields (plist-get plist :fields))
             (field (cl-find-if (lambda (f) (eq (plist-get f :id) old-name))
                                cur-fields))
             ;; Save old state for undo
             (old-field-plist (copy-sequence field))
             (old-default (and field (plist-get field :default)))
             (new-default (plist-get new-field :default))
             (changed nil)
             (filled-ids nil))
        (unless field
          (user-error "Column '%s' not found" old-name))
        ;; Rename in database if the identifier changed
        (unless (eq old-name new-name)
          (when (cl-find-if (lambda (f) (eq (plist-get f :id) new-name))
                            cur-fields)
            (user-error "Column '%s' already exists" new-name))
          (tabularium-db-execute
           tabularium--db
           (format "ALTER TABLE %s RENAME COLUMN %s TO %s"
                   tabularium-table-name
                   (symbol-name old-name) (symbol-name new-name))
           nil)
          (push (format "%s → %s" old-name new-name) changed))
        ;; Note other notable changes for the summary message
        (unless (equal (plist-get field :label) (plist-get new-field :label))
          (push (format "label='%s'" (plist-get new-field :label)) changed))
        (unless (eq (plist-get field :type) (plist-get new-field :type))
          (push (format "type=%s" (plist-get new-field :type)) changed))
        ;; Ensure a width if the wizard did not set one
        (unless (plist-get new-field :width)
          (setq new-field
                (plist-put new-field :width
                           (max (length (or (plist-get new-field :label) ""))
                                (if (and new-default (not (symbolp new-default)))
                                    (length (format "%s" new-default))
                                  10)
                                10))))
        ;; Fill blank cells when a new literal default was set
        (unless (equal new-default old-default)
          (cond
           ((and new-default (not (symbolp new-default)))
            (let* ((col-name-str (symbol-name new-name))
                   (primary-str (symbol-name (tabularium--primary-field-name)))
                   ;; Record which rows are blank BEFORE filling
                   (blank-rows (tabularium-db-query
                                tabularium--db
                                (format "SELECT %s FROM %s WHERE %s IS NULL OR %s = ''"
                                        primary-str tabularium-table-name
                                        col-name-str col-name-str)
                                nil)))
              (setq filled-ids (mapcar #'car blank-rows))
              (when filled-ids
                (tabularium-db-execute
                 tabularium--db
                 (format "UPDATE %s SET %s = ? WHERE %s IS NULL OR %s = ''"
                         tabularium-table-name col-name-str
                         col-name-str col-name-str)
                 (list (format "%s" new-default))))
              (push (if filled-ids
                        (format "default='%s' (filled %d blanks)"
                                new-default (length filled-ids))
                      (format "default='%s'" new-default))
                    changed)))
           (new-default
            (push (format "default=%s" new-default) changed))
           (t
            (push "default=''" changed))))
        ;; Replace the field's plist wholesale with the new definition
        (setq cur-fields
              (mapcar (lambda (f)
                        (if (eq (plist-get f :id) old-name) new-field f))
                      cur-fields))
        (setf (cdr schema) (plist-put plist :fields cur-fields))
        (push (list :type 'edit-column
                    :old-field-plist old-field-plist
                    :new-name new-name
                    :filled-ids filled-ids)
              ops)
        (when changed
          (push (format "%s: %s" old-name (string-join (nreverse changed) ", "))
                changes))))
    ;; Save schema
    (tabularium--save-schema-to-file schema-name)
    ;; Push undo
    (tabularium--undo-push
     (if (= 1 (length ops))
         (car ops)
       (list :type 'multi :ops (nreverse ops))))
    (tabularium--invalidate-cache)
    (when (derived-mode-p 'tabularium-view-mode)
      (let ((saved-id (tabulated-list-get-id))
            (first-new (plist-get (car edits) :new-field)))
        (revert-buffer)
        (tabularium-view--goto-position
         saved-id (or (plist-get first-new :id)
                      (plist-get (car edits) :old-name)))))
    (if changes
        (message "Edited: %s" (string-join (nreverse changes) "; "))
      (message "No changes made"))))

(defun tabularium-view-column-insert (name type prompt &optional default before-column field-plist)
  "Insert a new empty column NAME with TYPE and PROMPT before BEFORE-COLUMN.
DEFAULT, if given, is the column's default value.  FIELD-PLIST, when
non-nil, is a complete field definition (as from the schema wizard) and
supersedes NAME/TYPE/PROMPT/DEFAULT.
Like `tabularium-view-column-add' but inserts before rather than after,
walking the same full field-definition wizard interactively."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (fp (or (tabularium-wizard--read-field (1+ (length fields)) fields)
                  (user-error "Canceled")))
          (col-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) fields))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (tabularium--column-name-at-point)))
          (candidates (append (when at-point-name
                                (list (format "<<POINT>> %s"
                                              (symbol-name at-point-name))))
                              (list "<<FIRST>>" "<<LAST>>")
                              col-names))
          (pos-default (if at-point-name
                           (format "<<POINT>> %s" (symbol-name at-point-name))
                         "<<FIRST>>"))
          (choice (completing-read "Insert before: " candidates nil t nil nil pos-default))
          (before (cond
                   ((string= choice "<<FIRST>>") '__first__)
                   ((string= choice "<<LAST>>") nil)
                   ((string-prefix-p "<<POINT>> " choice) at-point-name)
                   (t (intern choice)))))
     (list (plist-get fp :id) (plist-get fp :type) (plist-get fp :label)
           (plist-get fp :default) before fp)))
  (cond
   ;; <<LAST>>: append at end
   ((null before-column)
    (tabularium-view-column-add name type prompt default nil field-plist))
   ;; <<FIRST>>: after primary key
   ((eq before-column '__first__)
    (tabularium-view-column-add name type prompt default '__first__ field-plist))
   ;; Named column: find the column before it and delegate
   (t
    (let* ((fields (tabularium--schema-fields))
           (pos (cl-position-if
                 (lambda (f) (eq (plist-get f :id) before-column))
                 fields))
           (after (when (and pos (> pos 0))
                    (plist-get (nth (1- pos) fields) :id))))
      (if (or (null pos) (= pos 0))
          ;; Before the first column, after primary key
          (tabularium-view-column-add name type prompt default '__first__ field-plist)
        (tabularium-view-column-add name type prompt default after field-plist))))))

;;; ** 7.3 Filter

(defun tabularium--filter-field-condition (field op value &optional value2)
  "Return the SQL condition for one FIELD, OP, and VALUE.
OP is nil (substring LIKE), `= ', a numeric comparison
\(`> ' `>= ' `< ' `<= ' `!= '), or one of the chronological
comparisons `before', `after', and `between'.  VALUE is coerced to a
string; VALUE2 is the upper bound of a `between' range.

The chronological operators compare as text rather than casting to a
number, because ISO date, time, and datetime strings already order
chronologically."
  (let ((vstr (format "%s" value))
        (field (or (tabularium--field-sql-ref field)
                   (user-error
                    "Field '%s' is computed in Emacs Lisp and has no SQL form"
                    field))))
    (pcase op
      ('= (format "%s = %s" field (tabularium-db-sql-quote vstr)))
      ('!= (format "%s <> %s" field (tabularium-db-sql-quote vstr)))
      ('> (format "CAST(%s AS REAL) > %s" field
                  (tabularium-db-sql-quote vstr)))
      ('>= (format "CAST(%s AS REAL) >= %s" field
                   (tabularium-db-sql-quote vstr)))
      ('< (format "CAST(%s AS REAL) < %s" field
                  (tabularium-db-sql-quote vstr)))
      ('<= (format "CAST(%s AS REAL) <= %s" field
                   (tabularium-db-sql-quote vstr)))
      ;; Chronological comparisons: plain text ordering, no CAST.
      ('before (format "%s < %s" field (tabularium-db-sql-quote vstr)))
      ('after (format "%s > %s" field (tabularium-db-sql-quote vstr)))
      ('duplicate
       (format "%s IN (SELECT %s FROM %s GROUP BY %s HAVING COUNT(*) > 1)"
               field field tabularium-table-name field))
      ('unique
       (format "%s IN (SELECT %s FROM %s GROUP BY %s HAVING COUNT(*) = 1)"
               field field tabularium-table-name field))
      ('regexp (tabularium-db-regexp-clause
                tabularium--db field vstr tabularium-case-sensitive))
      ('between (format "%s BETWEEN %s AND %s" field
                        (tabularium-db-sql-quote vstr)
                        (tabularium-db-sql-quote (format "%s" value2))))
      (_ (tabularium-db-build-like-clause
          field vstr tabularium-case-sensitive)))))

(defun tabularium--filter-rule-sql (rule)
  "Return the SQL condition for a single filter RULE.
A RULE carries `:fields' (a list of column-name strings) and an
optional `:op'.  The same VALUE is tested against every field with
OP and the per-field conditions are OR'd, so a one-field rule and
a multi-field rule are handled by the same path.  A `:raw' rule
\(from a saved view) supplies its SQL directly."
  (cond
   ((plist-get rule :raw)
    (plist-get rule :sql))
   (t
    (let* ((op (plist-get rule :op))
           (value (plist-get rule :value))
           (fields (or (plist-get rule :fields)
                       ;; Back-compat with any single-field rule shape.
                       (and (plist-get rule :field)
                            (list (plist-get rule :field)))))
           (value2 (plist-get rule :value2))
           (conditions (mapcar (lambda (f)
                                 (tabularium--filter-field-condition
                                  f op value value2))
                               fields)))
      ;; A rule carrying :rows applies only within those row ids, which is
      ;; what lets two rules cover different ranges in one stack.
      (let ((sql (if (cdr conditions)
                     (format "(%s)" (string-join conditions " OR "))
                   (car conditions)))
            (rows (plist-get rule :rows)))
        (if rows
            (format "(%s AND %s IN (%s))"
                    sql
                    (tabularium--primary-field-name)
                    (mapconcat #'number-to-string rows ", "))
          sql))))))

(defcustom tabularium-post-fetch-row-cap 20000
  "Maximum rows fetched when a filter or sort runs in Emacs Lisp.
Filtering or sorting by an elisp `:computed\\=' field cannot be pushed
into SQL, so the rows must be fetched first and processed here.  That
means the page limit can only be applied afterwards; this cap bounds
the intermediate fetch.  Exceeding it signals an error rather than
silently truncating, which would show a wrong answer."
  :type 'integer
  :group 'tabularium)

(defun tabularium--field-elisp-computed-p (field)
  "Return non-nil if FIELD (a name string or symbol) is elisp-computed.
Such a field has no SQL form, so filtering or sorting by it has to
happen in Emacs after the rows are fetched."
  (let* ((sym (if (stringp field) (intern field) field))
         (plist (ignore-errors (tabularium--field-by-name sym))))
    (and plist
         (tabularium--computed-field-p plist)
         (not (tabularium--computed-sql-expression plist)))))

(defun tabularium--filter-post-fetch-p ()
  "Return non-nil if any row filter rule names an elisp-computed field."
  (cl-some (lambda (rule)
             (cl-some #'tabularium--field-elisp-computed-p
                      (or (plist-get rule :fields)
                          (and (plist-get rule :field)
                               (list (plist-get rule :field))))))
           (tabularium--row-filter-rules)))

(defun tabularium--sort-post-fetch-p ()
  "Return non-nil if any active sort key is an elisp-computed field."
  (cl-some (lambda (k) (tabularium--field-elisp-computed-p (car k)))
           tabularium--sort-columns))

(defun tabularium--post-fetch-p ()
  "Return non-nil when filtering or sorting must happen in Emacs."
  (or (tabularium--filter-post-fetch-p) (tabularium--sort-post-fetch-p)))

(defun tabularium--filter-value-matches-p (value op target &optional target2)
  "Return non-nil if VALUE satisfies OP against TARGET (and TARGET2).
The Emacs-side twin of `tabularium--filter-field-condition\\=', used when a
rule cannot be expressed in SQL.  Comparison follows the same rules:
numeric operators compare numerically, chronological ones compare ISO
text, and the default is a substring test honoring
`tabularium-case-sensitive\\='."
  (let ((v (if value (format "%s" value) ""))
        (tv (format "%s" target)))
    (pcase op
      ('= (string= v tv))
      ('!= (not (string= v tv)))
      ('> (> (string-to-number v) (string-to-number tv)))
      ('>= (>= (string-to-number v) (string-to-number tv)))
      ('< (< (string-to-number v) (string-to-number tv)))
      ('<= (<= (string-to-number v) (string-to-number tv)))
      ('before (string< v tv))
      ('after (string> v tv))
      ('between (and (not (string< v tv))
                     (not (string> v (format "%s" target2)))))
      ('regexp (let ((case-fold-search (not tabularium-case-sensitive)))
                (and (string-match-p tv v) t)))
      (_ (let ((case-fold-search (not tabularium-case-sensitive)))
           (and (string-match-p (regexp-quote tv) v) t))))))

(defun tabularium--filter-rule-matches-p (rule alist)
  "Return non-nil if ALIST satisfies RULE.
ALIST maps field ids to values for one row.  As in SQL, the rule\\='s
value is tested against every field in `:fields\\=' and the results are
OR\\='d together."
  (let ((op (plist-get rule :op))
        (value (plist-get rule :value))
        (value2 (plist-get rule :value2))
        (fields (or (plist-get rule :fields)
                    (and (plist-get rule :field)
                         (list (plist-get rule :field))))))
    ;; A rule limited to certain rows never applies outside them.
    (when (and (plist-get rule :rows)
               (not (member (cdr (assq (tabularium--primary-field-name) alist))
                            (plist-get rule :rows))))
      (setq fields nil))
    (cl-some (lambda (f)
               (let ((sym (if (stringp f) (intern f) f)))
                 (tabularium--filter-value-matches-p
                  (cdr (assq sym alist)) op value value2)))
             fields)))

(defun tabularium--row-matches-filter-stack-p (alist)
  "Return non-nil if ALIST satisfies the whole filter stack.
Rules combine left to right with their connectives, exactly as
`tabularium--build-filter-clause\\=' composes the SQL."
  (let ((result t)
        (first t))
    (dolist (rule (tabularium--row-filter-rules))
      (let ((v (tabularium--filter-rule-matches-p rule alist))
            (conn (plist-get rule :connective)))
        (cond
         (first (setq result v))
         ((eq conn 'or) (setq result (or result v)))
         ((eq conn 'and-not) (setq result (and result (not v))))
         ((eq conn 'or-not) (setq result (or result (not v))))
         (t (setq result (and result v)))))
      (setq first nil))
    result))

(defun tabularium--compare-values (a b)
  "Compare A and B, numerically when both look numeric, else as text.
Returns a negative number, zero, or a positive number."
  (let ((sa (if a (format "%s" a) ""))
        (sb (if b (format "%s" b) "")))
    (if (and (string-match-p "\\`[-+]?[0-9.]+\\'" sa)
             (string-match-p "\\`[-+]?[0-9.]+\\'" sb))
        (let ((na (string-to-number sa)) (nb (string-to-number sb)))
          (cond ((< na nb) -1) ((> na nb) 1) (t 0)))
      (cond ((string< sa sb) -1) ((string< sb sa) 1) (t 0)))))

(defun tabularium--post-fetch-process (rows visible-fields display-offset limit)
  "Filter, sort, and truncate ROWS in Emacs.
Used when a filter rule or sort key names an elisp-computed field, whose
value exists only after `tabularium--apply-elisp-computed\\=' has run.  The
whole filter stack is evaluated here (splitting it would be wrong for
`OR\\=' connectives), then every sort key is applied, then LIMIT.

Signals an error when a referenced computed column is not visible, since
its value is not present in the fetched rows."
  (let ((names (mapcar (lambda (f) (plist-get f :id)) visible-fields)))
    ;; Every elisp-computed field a rule or sort key names must be on screen.
    (dolist (field (append
                    (cl-mapcan (lambda (r)
                                 (copy-sequence
                                  (or (plist-get r :fields)
                                      (and (plist-get r :field)
                                           (list (plist-get r :field))))))
                               tabularium--filter-rules)
                    (mapcar #'car tabularium--sort-columns)))
      (let ((sym (if (stringp field) (intern field) field)))
        (when (and (tabularium--field-elisp-computed-p sym)
                   (not (memq sym names)))
          (user-error
           "Column `%s' is computed in Emacs Lisp; show it with `| s' to filter or sort by it"
           sym))))
    (let* ((alist-of (lambda (row)
                       (tabularium--cf-row-alist row visible-fields
                                                 display-offset)))
           (kept (if tabularium--filter-rules
                     (cl-remove-if-not
                      (lambda (row)
                        (tabularium--row-matches-filter-stack-p
                         (funcall alist-of row)))
                      rows)
                   rows))
           (sorted
            (if (null tabularium--sort-columns)
                kept
              (sort (copy-sequence kept)
                    (lambda (a b)
                      (let ((res nil) (done nil))
                        (dolist (k tabularium--sort-columns)
                          (unless done
                            (let* ((pos (cl-position (car k) names))
                                   (va (and pos (nth (+ display-offset pos) a)))
                                   (vb (and pos (nth (+ display-offset pos) b)))
                                   (cmp (tabularium--compare-values va vb)))
                              (unless (zerop cmp)
                                (setq res (if (eq (cdr k) 'desc)
                                              (> cmp 0)
                                            (< cmp 0))
                                      done t)))))
                        res))))))
      (if (> (length sorted) limit)
          (seq-take sorted limit)
        sorted))))

(defun tabularium--row-filter-rules ()
  "Return the row-scoped rules of the filter stack.
A rule with no `:scope\=' is a row rule, so existing stacks and saved
views keep their meaning."
  (cl-remove-if (lambda (r) (eq (plist-get r :scope) 'column))
                tabularium--filter-rules))

(defun tabularium--column-filter-rules ()
  "Return the column-scoped rules of the filter stack.
These select which columns stay on screen, judged over the values in
each column rather than over each row."
  (cl-remove-if-not (lambda (r) (eq (plist-get r :scope) 'column))
                    tabularium--filter-rules))

(defun tabularium--read-row-restriction (prompt)
  "Return the row ids a rule should be limited to, or nil for every row.
PROMPT always offers =<<ALL>>= (every row) and =<<RANGE>>= (a custom
id/range restriction).  When rows are marked it also offers =<<MARKED>>=,
which becomes the default and shows the marked count; otherwise the
default is =<<ALL>>=, so the common every-row case is a single =RET=.

Prompting every time — rather than only when rows happen to be marked —
keeps the restriction discoverable and puts =<<RANGE>>= within reach even
with nothing marked.  It is the row analogue of
`tabularium--read-column-restriction\='; marks are the spreadsheet-style
way to gather rows first, offered as =<<MARKED>>= rather than applied
silently, since rows are often marked for something else entirely.

Choosing =<<RANGE>>= asks for row ids or ranges (=1,3,5-9=), parsed by
`tabularium--parse-id-range-spec\='; an empty answer, like =<<ALL>>=,
means every row.

Mark rows with `m\=', by value (`* s\=', `* e\=', `* p\=', `* r\='), or by
position with `* n\=' (`tabularium-view-mark-range\=')."
  (let* ((marked tabularium--marked-entries)
         (candidates (if marked
                         '("<<MARKED>>" "<<RANGE>>" "<<ALL>>")
                       '("<<ALL>>" "<<RANGE>>")))
         (default (if marked "<<MARKED>>" "<<ALL>>"))
         (choice (completing-read
                  (if marked
                      (format "%s (%d marked): " prompt (length marked))
                    (format "%s: " prompt))
                  candidates nil t nil nil default)))
    (cond
     ((equal choice "<<ALL>>") nil)
     ((equal choice "<<RANGE>>")
      (tabularium--parse-id-range-spec
       (read-string "Rows [comma-separated or range]: ")))
     (t (copy-sequence marked)))))

(defun tabularium--read-column-restriction (prompt)
  "Return the column ids a column rule may act on, or nil for every column.
PROMPT offers =<<ALL>>= (every column, the default and a single =RET=) or
a comma-separated list of the visible columns.  A column rule so
restricted hides — or, for a highlight, tints — only the chosen columns
and leaves the rest untouched, which is the column analogue of
`tabularium--read-row-restriction\='.  There is no way to mark columns, so
this prompt is the only way to scope a column rule to particular columns.
Returns a list of column-id symbols, or nil meaning every column."
  (let* ((fields (tabularium-view--ordered-visible-fields))
         (names (mapcar (lambda (f) (symbol-name (plist-get f :id))) fields)))
    (when names
      (let ((chosen (completing-read-multiple
                     (format "%s [<<ALL>>, or comma-separated]: " prompt)
                     (cons "<<ALL>>" names) nil t nil nil "<<ALL>>")))
        (unless (or (null chosen) (member "<<ALL>>" chosen))
          (mapcar #'intern chosen))))))

(defun tabularium--column-rule-values (rule rows idx display-offset)
  "Return the values RULE should judge for the column at IDX.
A rule carrying `:rows\=' is judged only over those row ids, so a column
rule can ask about one row or a range rather than the whole column."
  (let ((ids (plist-get rule :rows)))
    (mapcar (lambda (r) (nth (+ display-offset idx) r))
            (if ids
                (cl-remove-if-not (lambda (r) (member (car r) ids)) rows)
              rows))))

(defun tabularium--column-rule-matches-p (rule values)
  "Return non-nil if VALUES, one column's cells, satisfy RULE.
A column matches when any of its cells does — the column analogue of a
row matching when the tested field does.  The `nonempty\=' operator is
the exception: it asks only whether the column holds any value at all,
which is what hides columns that are empty in the current view."
  (let ((op (plist-get rule :op))
        (value (plist-get rule :value))
        (value2 (plist-get rule :value2)))
    (if (eq op 'nonempty)
        (cl-some (lambda (v)
                   (and v (not (string-empty-p (string-trim (format "%s" v))))))
                 values)
      (cl-some (lambda (v)
                 (tabularium--filter-value-matches-p v op value value2))
               values))))

(defun tabularium--column-matches-rules-p (id rows idx display-offset)
  "Return non-nil if the column named ID (at IDX) satisfies the column-rule stack.
Each rule is judged over the rows it names, so rules restricted to
different rows can share one stack.  A rule carrying `:columns\=' applies
only to those columns: for any other column it is skipped entirely, so
the column passes through untouched rather than being judged — and
possibly hidden — by a rule that was never meant for it.  The first
applicable rule is the base; a column no rule applies to is kept."
  (let ((result t)
        (first t))
    (dolist (rule (tabularium--column-filter-rules))
      (let ((cols (plist-get rule :columns)))
        (when (or (null cols) (memq id cols))
          (let ((m (tabularium--column-rule-matches-p
                    rule (tabularium--column-rule-values
                          rule rows idx display-offset)))
                (conn (plist-get rule :connective)))
            (cond
             (first (setq result m))
             ((eq conn 'or) (setq result (or result m)))
             ((eq conn 'and-not) (setq result (and result (not m))))
             ((eq conn 'or-not) (setq result (or result (not m))))
             (t (setq result (and result m))))
            (setq first nil)))))
    result))

(defun tabularium--column-rules-drop (rows visible-fields display-offset)
  "Return the ids of VISIBLE-FIELDS that the column rules reject.
ROWS are the fetched rows and DISPLAY-OFFSET the leading primary-key
slot.  The primary key is never dropped, since it identifies the row."
  (let ((primary (tabularium--primary-field-name))
        (drop '())
        (idx -1))
    (dolist (f visible-fields)
      (cl-incf idx)
      (let ((id (plist-get f :id)))
        (unless (eq id primary)
          (unless (tabularium--column-matches-rules-p id rows idx display-offset)
            (push id drop)))))
    (nreverse drop)))

(defun tabularium--build-filter-clause ()
  "Build a SQL WHERE clause fragment from `tabularium--filter-rules'.
Returns nil if no filters are set.  Only the first rule may omit
a connective; a non-first rule with a nil `:connective' is joined
with an implicit AND, so a malformed stack can never produce two
adjacent parenthesised clauses with nothing between them."
  (when (tabularium--row-filter-rules)
    (let ((parts '())
          (first t))
      (dolist (rule (tabularium--row-filter-rules))
        (let* ((sql (tabularium--filter-rule-sql rule))
               (conn (plist-get rule :connective)))
          (cond
           (first
            (push (format "(%s)" sql) parts))
           ((eq conn 'or)
            (push (format "OR (%s)" sql) parts))
           ((eq conn 'and-not)
            (push (format "AND NOT (%s)" sql) parts))
           ((eq conn 'or-not)
            (push (format "OR NOT (%s)" sql) parts))
           ;; `and' and nil (defensive) both join with AND.
           (t
            (push (format "AND (%s)" sql) parts))))
        (setq first nil))
      (string-join (nreverse parts) " "))))

(defun tabularium--filter-quote-value (value)
  "Return VALUE for display, quoted unless it reads as a number.
Quoting keeps a text operand visually distinct from a numeric one, so
={name} ≈ \"2023\"= is plainly a substring test rather than arithmetic."
  (let ((str (format "%s" value)))
    (if (string-match-p "\\`-?[0-9.]+\\'" str)
        str
      (format "\"%s\"" str))))

(defun tabularium--filter-rule-desc (rule)
  "Return a human-readable description for a single filter RULE.
Scope is shown by the brackets: =[…]= for a rule that selects rows and
={…}= for one that selects columns, matching the bracket/brace pairs
used by the cell-motion keys."
  (cond
   ((eq (plist-get rule :scope) 'column)
    (let* ((op (plist-get rule :op))
           (rows (plist-get rule :rows))
           (cols (plist-get rule :columns))
           ;; A column rule acts on columns (the ={…}= scope, `*' meaning
           ;; every column) and is judged over rows (the =[…]= search set,
           ;; shown only when narrowed to a subset).
           (target (if rows
                       (format "[%s]{%s}"
                               (tabularium--format-row-ids rows)
                               (tabularium--format-column-ids cols))
                     (format "{%s}" (tabularium--format-column-ids cols)))))
      (if (eq op 'nonempty)
          (format "%s non-empty" target)
        (format "%s %s %s" target
                (pcase op
                  ('= "=") ('!= "≠") ('> ">") ('>= "≥") ('< "<") ('<= "≤")
                  ('before "<") ('after ">") ('between "∈") ('regexp "~")
                  (_ "≈"))
                (if (eq op 'between)
                    (format "%s..%s"
                            (tabularium--filter-quote-value (plist-get rule :value))
                            (tabularium--filter-quote-value (plist-get rule :value2)))
                  (tabularium--filter-quote-value (plist-get rule :value)))))))
   ((plist-get rule :raw)
    (or (plist-get rule :desc) "view"))
   (t
    (let* ((op (plist-get rule :op))
           (value (plist-get rule :value))
           (fields (or (plist-get rule :fields)
                       (and (plist-get rule :field)
                            (list (plist-get rule :field)))))
           (field-str (if (> (length fields) 3)
                          (format "%d fields" (length fields))
                        (string-join fields ",")))
           (rows-str (if (plist-get rule :rows)
                         (format "[%s]"
                                 (tabularium--format-row-ids
                                  (plist-get rule :rows)))
                       ""))
           (op-str (pcase op
                     ('= "=") ('!= "≠") ('> ">") ('>= "≥")
                     ('< "<") ('<= "≤")
                     ('before "<") ('after ">") ('between "∈")
                     ('regexp "~") ('duplicate "∈ dups") ('unique "∉ dups")
                     (_ "≈"))))
      (if (eq op 'between)
          (format "%s{%s} %s %s..%s" rows-str field-str op-str
                  (tabularium--filter-quote-value value)
                  (tabularium--filter-quote-value (plist-get rule :value2)))
        (format "%s{%s} %s %s" rows-str field-str op-str
                (tabularium--filter-quote-value value)))))))

(defconst tabularium--filter-connective-symbols
  '((nil . "") (and . " ∧ ") (or . " ∨ ") (and-not . " ∧¬ ") (or-not . " ∨¬ "))
  "Alist mapping logical connectives to display symbols.
A filter rule's connective combines it with the rules above:
conjunction (∧, AND), disjunction (∨, OR), and their negated
forms (∧¬, ∨¬).  The first rule has no connective (nil).")

(defun tabularium--filter-description (&optional full)
  "Return a human-readable description of all filter rules.
When more than three rules are active the middle rules are
elided as `…' to keep the modeline compact — e.g.
=(a) ∧ … ∧ (d)=.  With FULL non-nil every rule is shown in full,
for contexts (prompts, the rules buffer) where space is ample."
  (when tabularium--filter-rules
    (let ((parts '()))
      (dolist (rule tabularium--filter-rules)
        (let ((connective-sym (alist-get (plist-get rule :connective)
                                         tabularium--filter-connective-symbols))
              (desc (tabularium--filter-rule-desc rule)))
          (push (concat connective-sym "(" desc ")") parts)))
      (setq parts (nreverse parts))
      (if (and (not full) (> (length parts) 3))
          ;; Keep the first and last rule, elide the middle with `…'.
          ;; Each part after the first already carries its own
          ;; connective glyph, so the last part slots in directly
          ;; after the ellipsis.
          (concat (car parts) " …" (car (last parts)))
        (string-join parts)))))

(defun tabularium--filter-update-modeline ()
  "Update the `mode-name' to reflect current filter state.
The filter description is propertized with
`tabularium-modeline-filter-face'."
  (let ((desc (tabularium--filter-description)))
    (setq mode-name (if desc
                        (concat "Tabularium["
                                (propertize desc 'face
                                            'tabularium-modeline-filter-face)
                                "]")
                      "Tabularium"))))

(defun tabularium--filter-prompt-connective ()
  "Prompt for a logical connective if filter rules already exist.
Returns a connective symbol (`and', `or', `and-not', `or-not') or
nil for the first rule, which has no connective."
  (when tabularium--filter-rules
    (let ((choice (completing-read "Logical connective: "
                                   '("AND" "OR" "AND NOT" "OR NOT")
                                   nil t nil nil "AND")))
      (cdr (assoc choice '(("AND" . and) ("OR" . or)
                           ("AND NOT" . and-not)
                           ("OR NOT" . or-not)))))))

(defun tabularium--filter-add-rule (rule)
  "Add RULE to the filter stack, prompting for a connective if needed.
The change is recorded for undo before it is made.  If applying the new
rule makes the view query fail, the rule is removed again and the error
re-signalled, so one malformed rule cannot leave the whole filter stack
stuck and needing a full reset."
  (let ((connective (tabularium--filter-prompt-connective))
        (previous tabularium--filter-rules))
    (tabularium--filter-push-undo)
    (setq tabularium--filter-rules
          (append tabularium--filter-rules
                  (list (plist-put rule :connective connective))))
    (tabularium--filter-update-modeline)
    (condition-case err
        (revert-buffer)
      (error
       ;; Roll back the offending rule and restore a consistent view.
       (setq tabularium--filter-rules previous)
       (tabularium--filter-update-modeline)
       (ignore-errors (revert-buffer))
       (tabularium--filter-sync)
       (user-error "Filter rule not applied: %s"
                   (error-message-string err))))
    (tabularium--filter-sync)))

(defun tabularium-view-filter-substring (fields value)
  "Add a substring filter rule: VALUE appears in any of FIELDS.
FIELDS is a list of column-name strings; nil means every stored
field.  The same VALUE is tested against each field and the
per-field conditions are OR'd.  When filters already exist,
prompts for a logical connective (AND, OR, AND NOT, OR NOT).

Interactively the columns are chosen with `completing-read-multiple'
\(the `<<ALL>>' sentinel, or an empty answer, means every field) —
the same selector the mark and highlight commands use."
  (interactive
   (let* ((fields (tabularium--field-crm 'sql))
          (value (read-string
                  (if tabularium--filter-rules
                      (format "Filter [%s] + contains: "
                              (tabularium--filter-description))
                    "Filter contains: ")
                  nil 'tabularium-search-history)))
     (list fields value)))
  (tabularium--ensure-db)
  (let ((search-fields (or fields (tabularium--filterable-field-names))))
    (tabularium--filter-add-rule
     (list :fields search-fields :value value))))

(defconst tabularium--rule-types
  '("substring" "exact" "regexp" "numeric" "datetime" "unique" "duplicates")
  "Rule types shared by the filter and highlight stacks.
The same word means the same test on either side, so one vocabulary
describes both.")

(defun tabularium--rule-type-field-types (rule-type)
  "Return the field types RULE-TYPE can sensibly search, or nil for any.
Asking for the rule type before the columns lets the column prompt offer
only the columns the test can actually apply to."
  (pcase rule-type
    ("numeric" '(integer number))
    ("datetime" '(date time datetime))
    (_ nil)))

(defun tabularium--read-search-columns (field-types)
  "Prompt for the columns to search, restricted to FIELD-TYPES when given.
The `<<ALL>>' sentinel (or an empty answer) searches every eligible
column.  Returns a list of column-name strings."
  (let* ((fields (tabularium--schema-fields))
         (eligible (if field-types
                       (cl-remove-if-not
                        (lambda (f) (memq (plist-get f :type) field-types))
                        fields)
                     fields))
         (names (mapcar (lambda (f) (symbol-name (plist-get f :id))) eligible)))
    (unless names
      (user-error "No columns of the required type for this rule"))
    (let ((chosen (completing-read-multiple
                   "Search columns [<<ALL>>, or comma-separated]: "
                   (cons "<<ALL>>" names) nil t nil nil "<<ALL>>")))
      (if (or (null chosen) (member "<<ALL>>" chosen)) names chosen))))

(defun tabularium--read-rule-operand (rule-type dt-type)
  "Prompt for the operand of RULE-TYPE, naming the prompt after the operator.
DT-TYPE is the date/time type of the searched columns, used for the
format hint.  Returns the list (OP VALUE VALUE2); a rule type that takes
no operand returns nil for both values."
  (pcase rule-type
    ("substring" (list nil (read-string "Contains: ") nil))
    ("exact" (list '= (read-string "Equals: ") nil))
    ("regexp" (list 'regexp (read-regexp "Matches regexp: ") nil))
    ("unique" (list 'unique nil nil))
    ("duplicates" (list 'duplicate nil nil))
    ("numeric"
     (let ((op (intern (completing-read "Comparison: "
                                        '(">" ">=" "<" "<=" "=" "!=") nil t))))
       (list op (read-string (pcase op
                               ('> "Greater than: ")
                               ('>= "At least: ")
                               ('< "Less than: ")
                               ('<= "At most: ")
                               ('= "Equals: ")
                               (_ "Not equal to: ")))
             nil)))
    ("datetime"
     (let* ((type (or dt-type 'datetime))
            (hint (tabularium--datetime-format-hint type))
            (choice (completing-read "Comparison: "
                                     '("before" "after" "exact" "range")
                                     nil t)))
       (pcase choice
         ("before" (list 'before (tabularium-wizard--read-validated
                                  (format "Before [%s]: " hint) type) nil))
         ("after" (list 'after (tabularium-wizard--read-validated
                                (format "After [%s]: " hint) type) nil))
         ("exact" (list '= (tabularium-wizard--read-validated
                            (format "Equals [%s]: " hint) type) nil))
         (_ (list 'between
                  (tabularium-wizard--read-validated
                   (format "From [%s]: " hint) type)
                  (tabularium-wizard--read-validated
                   (format "To [%s]: " hint) type))))))))

(defun tabularium--read-rule (feature)
  "Walk the shared rule-creation prompts for FEATURE, `filter' or `highlight'.
The order is fixed by what each step needs from the one before it:

  target -> rule type -> search set -> operand (-> face)

The rule type narrows which columns can be searched, and the searched
columns decide the operand's format and validation.  The target names
what the rule acts on; the search set names the axis it looks at, which
is the opposite axis for a column rule.

Returns a plist with :target, :rule-type, :op, :value, :value2, :fields,
:rows, :columns, and (for highlight) :face."
  (let* ((label (if (eq feature 'highlight) "Highlight" "Filter"))
         ;; The most common target leads and is the default: value(s) for
         ;; highlight (tint the matching cells), row(s) for filter (keep the
         ;; matching rows).
         (targets (if (eq feature 'highlight)
                      '("value(s)" "row(s)" "column(s)")
                    '("row(s)" "column(s)")))
         (target (completing-read (format "%s target: " label)
                                  targets nil t nil nil (car targets)))
         (rule-type (completing-read
                     (format "%s %s rule type: " label target)
                     tabularium--rule-types nil t))
         (ftypes (tabularium--rule-type-field-types rule-type))
         ;; A column rule searches rows; everything else searches columns.
         ;; A value rule searches both: which columns to test, and which
         ;; rows the highlight may land on.
         (columns (unless (equal target "column(s)")
                    (tabularium--read-search-columns ftypes)))
         ;; Every target takes a row restriction: a column rule is judged
         ;; over these rows; a row or value rule applies only within them.
         (rows (tabularium--read-row-restriction "Search rows"))
         ;; A column rule may also be scoped to particular columns — which
         ;; ones it can hide or tint, the opposite axis from its row search
         ;; set.  Row and value rules test columns instead, so the columns
         ;; they name are already the search set, not a restriction.
         (col-restriction (when (equal target "column(s)")
                            (tabularium--read-column-restriction
                             "Restrict to columns")))
         (dt-type (when (equal rule-type "datetime")
                    (and columns (tabularium--datetime-field-type columns))))
         (operand (tabularium--read-rule-operand rule-type dt-type)))
    (list :target target :rule-type rule-type
          :op (nth 0 operand) :value (nth 1 operand) :value2 (nth 2 operand)
          :fields columns :rows rows :columns col-restriction
          :face (when (eq feature 'highlight)
                  (tabularium--highlight-read-face)))))

;;;###autoload
(defun tabularium-view-filter-add ()
  "Add a filter rule, walking the shared rule-creation prompts.
Asks for the target (rows or columns), then the rule type, then the set
to search, then the operand — see `tabularium--read-rule'.  A row rule
keeps rows whose searched columns satisfy the test; a column rule keeps
columns in which some searched row does.  The direct keys (`f s', `f n',
and so on) skip the first two steps by naming the rule type themselves."
  (interactive)
  (tabularium--ensure-db)
  (let* ((spec (tabularium--read-rule 'filter))
         (op (plist-get spec :op))
         (value (plist-get spec :value))
         (value2 (plist-get spec :value2)))
    (if (equal (plist-get spec :target) "column(s)")
        (tabularium--filter-add-rule
         (append (list :scope 'column :op op :value value)
                 (when value2 (list :value2 value2))
                 (when (plist-get spec :rows)
                   (list :rows (plist-get spec :rows)))
                 (when (plist-get spec :columns)
                   (list :columns (plist-get spec :columns)))))
      (tabularium--filter-add-rule
       (append (list :fields (or (plist-get spec :fields)
                                 (tabularium--filterable-field-names))
                     :op op :value value)
               (when value2 (list :value2 value2))
               (when (plist-get spec :rows)
                 (list :rows (plist-get spec :rows))))))))

(defun tabularium--datetime-field-type (fields)
  "Return the shared date/time type of FIELDS, or `datetime' when mixed.
FIELDS is a list of column-name strings.  The type selects the input
format and validation for the chronological prompts."
  (let ((types (delete-dups
                (delq nil
                      (mapcar (lambda (n)
                                (plist-get (tabularium--field-by-name
                                            (if (stringp n) (intern n) n))
                                           :type))
                              fields)))))
    (if (= 1 (length types)) (car types) 'datetime)))

(defun tabularium--datetime-format-hint (type)
  "Return the input-format hint string for a date/time TYPE."
  (pcase type
    ('date "YYYY-MM-DD")
    ('time "HH:MM[:SS]")
    (_ "YYYY-MM-DD HH:MM[:SS]")))

;;;###autoload
(defun tabularium-view-filter-exact (fields value)
  "Add an exact-match filter rule: VALUE equals a cell in any of FIELDS.
FIELDS is a list of column-name strings; nil means every stored
field.  Unlike `tabularium-view-filter-substring', matches the
complete cell value rather than a substring.

Interactively the columns are chosen with `completing-read-multiple'
\(the `<<ALL>>' sentinel means every field)."
  (interactive
   (let* ((fields (tabularium--field-crm 'sql))
          (value (read-string
                  (if tabularium--filter-rules
                      (format "Filter [%s] + exact: "
                              (tabularium--filter-description))
                    "Filter exact: ")
                  nil 'tabularium-search-history)))
     (list fields value)))
  (tabularium--ensure-db)
  (let ((search-fields (or fields (tabularium--filterable-field-names))))
    (tabularium--filter-add-rule
     (list :fields search-fields :value value :op '=))))

;;;###autoload
(defun tabularium-view-filter-numeric (fields op value)
  "Add a numeric comparison filter: FIELDS OP VALUE.
FIELDS is a list of column-name strings; nil means every numeric
field.  OP is one of the comparison symbols `> ', `>= ', `< ',
`<= ', `= ', `!= '.  The comparison is applied to every field and
the per-field conditions are OR'd.

Interactively only numeric (`integer'/`number') fields are offered
in the `completing-read-multiple' selector (the `<<ALL>>' sentinel
means every numeric field)."
  (interactive
   (let* ((numeric-names
           (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                   (cl-remove-if-not
                    (lambda (f)
                      (memq (plist-get f :type) '(integer number)))
                    (tabularium--schema-fields))))
          (selected (completing-read-multiple
                     "Numeric fields [<<ALL>>, or comma-separated]: "
                     (cons "<<ALL>>" numeric-names) nil t nil nil "<<ALL>>"))
          (fields (if (or (null selected) (member "<<ALL>>" selected))
                      numeric-names
                    selected))
          (op-choice (completing-read "Operator: "
                                      '(">" ">=" "<" "<=" "=" "!=") nil t))
          (value (read-string (format "Value %s " op-choice))))
     (list fields (intern op-choice) value)))
  (tabularium--ensure-db)
  (let ((search-fields (or fields
                           (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                                   (cl-remove-if-not
                                    (lambda (f)
                                      (memq (plist-get f :type)
                                            '(integer number)))
                                    (tabularium--schema-fields))))))
    (tabularium--filter-add-rule
     (list :fields search-fields :value value :op op))))

;;;###autoload
(defun tabularium-view-filter-at-point ()
  "Add an exact-match filter on the cell at point.
Filters the current view to rows whose value in the column at
point equals the value of the cell at point — the table analogue
of \"filter by this value\".  Operates on the actual stored value,
so a long field truncated in the display still matches in full.
Computed columns have no stored value and are rejected."
  (interactive)
  (unless (derived-mode-p 'tabularium-view-mode)
    (user-error "Not in a Tabularium view"))
  (let ((field (tabularium--column-name-at-point))
        (id (tabularium--id-at-point)))
    (unless field (user-error "No column at point"))
    (unless id (user-error "No row at point"))
    (when (tabularium--computed-field-p (tabularium--field-by-name field))
      (user-error "Cannot filter at point on a computed column"))
    (tabularium--ensure-db)
    (let* ((col (symbol-name field))
           (primary (symbol-name (tabularium--primary-field-name)))
           (value (tabularium-db-query-scalar
                   tabularium--db
                   (format "SELECT %s FROM %s WHERE %s = ?"
                           col tabularium-table-name primary)
                   (list id))))
      (tabularium--filter-add-rule
       (list :fields (list col) :value (if value (format "%s" value) "") :op '=)))))

;;;###autoload
(defun tabularium-view-filter-datetime (fields op value &optional value2)
  "Add a chronological filter: FIELDS OP VALUE.
FIELDS is a list of column-name strings.  OP is `before', `after',
`= ' (exact), or `between'; VALUE is an ISO date/time string and
VALUE2 the upper bound of a `between' range.  The comparison is
applied to every field and the per-field conditions are OR'd.

One command covers date, time, and datetime columns: ISO strings
\(=YYYY-MM-DD=, =HH:MM=, =YYYY-MM-DD HH:MM=) order chronologically as
text, so the same comparison expresses \"earlier/later than\" for all
three.  The prompts adapt their format hint and validation to the type
of the chosen columns.

Interactively only date, time, and datetime columns are offered (the
`<<ALL>>' sentinel means every such column); computed columns backed
by a SQL expression are included."
  (interactive
   (let* ((dt-names
           (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                   (cl-remove-if-not
                    (lambda (f)
                      (memq (plist-get f :type) '(date time datetime)))
                    (tabularium--schema-fields))))
          (_ (unless dt-names
               (user-error "No date, time, or datetime columns in this table")))
          (selected (completing-read-multiple
                     "Date/time fields [<<ALL>>, or comma-separated]: "
                     (cons "<<ALL>>" dt-names) nil t nil nil "<<ALL>>"))
          (fields (if (or (null selected) (member "<<ALL>>" selected))
                      dt-names
                    selected))
          (type (tabularium--datetime-field-type fields))
          (hint (tabularium--datetime-format-hint type))
          (op-name (completing-read
                    "Comparison: "
                    '("before" "after" "exact" "range") nil t))
          (op (pcase op-name
                ("before" 'before)
                ("after" 'after)
                ("exact" '=)
                ("range" 'between)))
          (v1 (tabularium-wizard--read-validated
               (format "%s [%s]: " (if (eq op 'between) "From" "Value") hint)
               type))
          (v2 (when (eq op 'between)
                (tabularium-wizard--read-validated
                 (format "To [%s]: " hint) type))))
     (list fields op v1 v2)))
  (tabularium--ensure-db)
  (tabularium--filter-add-rule
   (append (list :fields fields :value value :op op)
           (when value2 (list :value2 value2)))))

;;;###autoload
(defun tabularium-view-filter-column (op value &optional value2 rows)
  "Add a column-scoped filter rule: keep columns whose values satisfy it.
OP is a comparison operator as used by the row filters, or `nonempty\='.
VALUE (and VALUE2 for a range) are the operands.

This is the column transpose of a row filter.  Where a row rule keeps
rows whose field satisfies a test, a column rule keeps columns in which
some cell does; columns that fail are hidden.  The rule joins the same
stack as the row rules and combines with the same connectives, so the
filter list shows both kinds together, column rules marked `col:\='.

Because the test is over values rather than names, it is judged on the
rows actually fetched.  To choose columns by what they are called
instead, use `tabularium-view-select-columns\=' (=| /=)."
  (interactive
   (let* ((type (completing-read
                 "Column criterion: "
                 '("non-empty" "substring" "exact" "regexp"
                   "numeric" "datetime")
                 nil t))
          (op (pcase type
                ("non-empty" 'nonempty)
                ("substring" nil)
                ("exact" '=)
                ("regexp" 'regexp)
                ("numeric" (intern (completing-read
                                    "Comparison: "
                                    '(">" ">=" "<" "<=" "=" "!=") nil t)))
                ("datetime" (pcase (completing-read
                                    "Comparison: "
                                    '("before" "after" "exact" "range") nil t)
                              ("before" 'before)
                              ("after" 'after)
                              ("exact" '=)
                              ("range" 'between)))))
          (value (unless (eq op 'nonempty)
                   (read-string (format "Keep columns with a value %s: "
                                        (or op "containing")))))
          (v2 (when (eq op 'between)
                (read-string "Upper bound: "))))
     (list op value v2)))
  (tabularium--ensure-db)
  (tabularium--filter-add-rule
   (append (list :scope 'column :op op :value value)
           (when value2 (list :value2 value2))
           (when rows (list :rows rows)))))

;;;###autoload
(defun tabularium-view-filter-duplicates (fields)
  "Keep rows whose value in FIELDS is shared with another row.
FIELDS is a list of column-name strings.  The row-filter counterpart of
the duplicates highlight rule: where that tints repeated values, this
narrows the view to them, which is how duplicate records are found.

Only stored and SQL-expression columns are offered, since the test is a
grouped count evaluated by the database."
  (interactive
   (list (or (tabularium--field-crm
              nil "Duplicate in fields [<<ALL>>, or comma-separated]: ")
             (tabularium--filterable-field-names))))
  (tabularium--ensure-db)
  (tabularium--filter-add-rule (list :fields fields :op 'duplicate)))

;;;###autoload
(defun tabularium-view-filter-unique (fields)
  "Keep rows whose value in FIELDS appears exactly once.
The complement of `tabularium-view-filter-duplicates\=', for isolating
the records that stand alone."
  (interactive
   (list (or (tabularium--field-crm
              nil "Unique in fields [<<ALL>>, or comma-separated]: ")
             (tabularium--filterable-field-names))))
  (tabularium--ensure-db)
  (tabularium--filter-add-rule (list :fields fields :op 'unique)))

;;;###autoload
(defun tabularium-view-filter-regexp (fields regexp)
  "Add a regexp filter: rows where any of FIELDS matches REGEXP.
FIELDS is a list of column-name strings; nil means every filterable
field.  The pattern is a POSIX regexp evaluated by the database, so it
requires a backend with a regexp operator.

The built-in SQLite backend has none — SQLite parses the REGEXP
operator but ships no implementation, and Emacs' SQLite support cannot
register one — so this command signals an error there.  On SQLite, use
`tabularium-view-highlight-regexp', which matches in Emacs, or the
substring filter for literal text."
  (interactive
   (let* ((fields (tabularium--field-crm
                   'sql "Regexp fields [<<ALL>>, or comma-separated]: "))
          (regexp (read-regexp "Filter matching regexp: ")))
     (when (string-empty-p regexp)
       (user-error "Empty regexp"))
     (list fields regexp)))
  (tabularium--ensure-db)
  ;; Fail before the rule is added when the backend cannot match regexps,
  ;; so the filter stack is never left holding an unusable rule.
  (tabularium-db-regexp-clause tabularium--db
                               (car (or fields
                                        (tabularium--filterable-field-names)))
                               regexp tabularium-case-sensitive)
  (tabularium--filter-add-rule
   (list :fields (or fields (tabularium--filterable-field-names))
         :value regexp :op 'regexp)))

(defun tabularium--filter-rule-label (index rule)
  "Return a numbered `completing-read' label for filter RULE at INDEX."
  (format "%d. %s%s" index
          (let ((sym (alist-get (plist-get rule :connective)
                                tabularium--filter-connective-symbols)))
            ;; SYM is padded (e.g. \" ∨ \"); trim the leading pad but
            ;; keep one trailing space so it does not abut the text.
            (if (string-empty-p sym) ""
              (concat (string-trim sym) " ")))
          (tabularium--filter-rule-desc rule)))

(defun tabularium-view-filter-remove (target)
  "Remove filter rule(s) from the current view.
TARGET is a 1-based rule index, or the symbol `all' to remove
every rule.

Interactively every rule is listed, each numbered in evaluation
order, alongside the `<<ALL>>' sentinel (the default).  Selecting
`<<ALL>>' clears the whole filter stack; selecting one rule
removes just that rule, and the connective of whatever rule
becomes first is cleared.  This single command replaces the
former separate \"delete rule\" and \"clear all\" commands,
mirroring `tabularium-view-highlight-remove'."
  (interactive
   (if (null tabularium--filter-rules)
       (user-error "No filter rules to remove")
     (let* ((labels (cl-loop for rule in tabularium--filter-rules
                             for i from 1
                             collect (cons (tabularium--filter-rule-label
                                            i rule)
                                           i)))
            (choice (completing-read
                     "Remove filter [<<ALL>>]: "
                     (cons "<<ALL>>" (mapcar #'car labels))
                     nil t nil nil "<<ALL>>")))
       (list (if (equal choice "<<ALL>>")
                 'all
               (cdr (assoc choice labels)))))))
  (cond
   ((eq target 'all)
    (let ((n (length tabularium--filter-rules)))
      (tabularium--filter-push-undo)
      (setq tabularium--filter-rules nil)
      (setq mode-name "Tabularium")
      (tabularium--filter-update-modeline)
      (revert-buffer)
      (tabularium--filter-sync)
      (message "Removed %d filter rule%s" n (if (= n 1) "" "s"))))
   ((null target)
    (message "No filter rule selected"))
   (t
    (let ((index (1- target)))
      (setq tabularium--filter-rules
            (cl-remove-if (let ((i -1))
                            (lambda (_) (= (cl-incf i) index)))
                          tabularium--filter-rules))
      ;; The rule that is now first must carry no connective.
      (when (and tabularium--filter-rules
                 (plist-get (car tabularium--filter-rules) :connective))
        (setq tabularium--filter-rules
              (cons (plist-put (copy-sequence
                                (car tabularium--filter-rules))
                               :connective nil)
                    (cdr tabularium--filter-rules))))
      (tabularium--filter-update-modeline)
      (revert-buffer)
      (tabularium--filter-sync)
      (if tabularium--filter-rules
          (message "Filter: %s" (tabularium--filter-description))
        (message "All filters removed"))))))

(defun tabularium-view-filter-remove-all ()
  "Remove every filter rule.
A direct equivalent of choosing `<<ALL>>' in
`tabularium-view-filter-remove'."
  (interactive)
  (if (null tabularium--filter-rules)
      (user-error "No filter rules to remove")
    (tabularium-view-filter-remove 'all)))

(defun tabularium-view-filter-cycle-connective ()
  "Cycle the logical connective of a filter rule.
A rule's connective combines it with the rules above; cycles
through conjunction → disjunction → negated conjunction → negated
disjunction (and → or → and-not → or-not → and)."
  (interactive)
  (when (< (length tabularium--filter-rules) 2)
    (user-error "Need at least 2 filter rules to cycle a connective"))
  (let* ((non-first (cdr tabularium--filter-rules))
         (descs (cl-loop for rule in non-first
                         for i from 2
                         collect (format "%d: %s%s" i
                                         (let ((sym (alist-get (plist-get rule :connective)
                                                               tabularium--filter-connective-symbols)))
                                           (if (string-empty-p sym) "" sym))
                                         (tabularium--filter-rule-desc rule))))
         (choice (completing-read "Cycle connective on rule: " descs nil t))
         (idx (1- (string-to-number (car (split-string choice ":")))))
         (rule (nth idx tabularium--filter-rules))
         (cycle '(and or and-not or-not))
         (current (plist-get rule :connective))
         (next (or (cadr (memq current cycle)) 'and))
         (new-rule (plist-put (copy-sequence rule) :connective next)))
    (setf (nth idx tabularium--filter-rules) new-rule)
    (tabularium--filter-update-modeline)
    (revert-buffer)
    (tabularium--filter-sync)
    (message "Filter: %s" (tabularium--filter-description))))

;;; *** 7.3.1 Filter Rules List Buffer

(defvar-local tabularium--filter-view nil
  "The view buffer whose filter rules a Filter Rules List buffer edits.")

(defvar-local tabularium--filter-marks nil
  "List of 1-based rule indices marked for removal in the buffer.")

(defvar-local tabularium--filter-first-pos nil
  "Buffer position of the first rule entry, for cursor placement.")

(defvar-local tabularium--filter-first-line nil
  "Line number of the first rule entry, for bounded cursor motion.")

(defvar-local tabularium--filter-last-line nil
  "Line number of the last rule entry, for bounded cursor motion.")

(defun tabularium--filter-refresh ()
  "Redraw the Filter Rules List buffer from the owning view's rules.
Uses the single-line box ornament — a lightweight view-mode side
`view-mode' buffer — listing every filter rule in evaluation order with its
connective in a dedicated column, key hints faced like the
registry, and the cursor left on the first rule."
  (let ((inhibit-read-only t)
        (rules (with-current-buffer tabularium--filter-view
                  tabularium--filter-rules))
        (marks tabularium--filter-marks)
        (first-pos nil)
        (first-line nil)
        (last-line nil))
    (erase-buffer)
    (insert (tabularium--make-box-header "Filter Rules List" 80 'single)
            "\n\n")
    (insert (format "  %-3s %-5s %s\n" "#" "Op" "Filter"))
    (insert (propertize (concat "  " (make-string 76 ?─) "\n")
                        'face 'shadow))
    (if (null rules)
        (insert (propertize "  No filter rules.\n" 'face 'shadow))
      (let ((n 0))
        (dolist (rule rules)
          (cl-incf n)
          (let* ((connective (plist-get rule :connective))
                 (connective-str (pcase connective
                                   ('and "∧") ('or "∨")
                                   ('and-not "∧¬") ('or-not "∨¬")
                                   (_ "")))
                 (marked (memq n marks))
                 (start (point))
                 (line (line-number-at-pos start)))
            (unless first-pos
              (setq first-pos start first-line line))
            (setq last-line line)
            (insert (propertize
                     (format "%s %-3d %-5s %s\n"
                             (if marked
                                 (propertize "*" 'face 'tabularium-marked-face)
                               " ")
                             n connective-str
                             (tabularium--filter-rule-desc rule))
                     'tabularium-filter-n n
                     'face (and marked 'tabularium-marked-face)))))))
    (insert "\n")
    (insert (tabularium--make-box-footer 80 'single) "\n")
    (insert (format "  Total: %d rule%s\n\n"
                    (length rules)
                    (if (= 1 (length rules)) "" "s")))
    (insert "  " (propertize "TAB" 'face 'help-key-binding) "/"
            (propertize "S-TAB" 'face 'help-key-binding) " Nav   "
            (propertize "M-p" 'face 'help-key-binding) "/"
            (propertize "M-n" 'face 'help-key-binding) " Move   "
            (propertize "c" 'face 'help-key-binding) " Cycle connective\n")
    (insert "  " (propertize "m" 'face 'help-key-binding) " Mark   "
            (propertize "u" 'face 'help-key-binding) " Unmark   "
            (propertize "U" 'face 'help-key-binding) " Unmark all   "
            (propertize "t" 'face 'help-key-binding) " Toggle   "
            (propertize "x" 'face 'help-key-binding) " Remove   "
            (propertize "X" 'face 'help-key-binding) " Remove all\n")
    (insert "  " (propertize "I" 'face 'help-key-binding) " Insert   "
            (propertize "A" 'face 'help-key-binding) " Add   "
            (propertize "RET" 'face 'help-key-binding) " Modify\n")
    (insert "  " (propertize "q" 'face 'help-key-binding) " Quit   "
            (propertize "g" 'face 'help-key-binding) "/"
            (propertize "=" 'face 'help-key-binding) " Refresh\n")
    (setq tabularium--filter-first-pos (or first-pos (point-min)))
    (setq tabularium--filter-first-line (or first-line 5))
    (setq tabularium--filter-last-line (or last-line 5))
    (goto-char tabularium--filter-first-pos)))

(defun tabularium--filter-sync ()
  "Refresh an open Filter Rules List buffer, if any.
Called after the filter stack changes so the list buffer stays in
step with the view without a manual `g'."
  (let ((buf (get-buffer "*Filter Rules List*")))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (derived-mode-p 'tabularium-filter-mode)
          (let ((saved-n (tabularium--filter-n-at-point)))
            (tabularium--filter-refresh)
            (when saved-n
              (tabularium--filter-goto-n saved-n))))))))

(defun tabularium--filter-n-at-point ()
  "Return the rule index on the current line, or nil."
  (get-text-property (line-beginning-position) 'tabularium-filter-n))

(defun tabularium--filter-goto-n (n)
  "Move point to the line of rule index N, if present.
Point is only moved when N is found; return the position, or nil."
  (let ((pos (save-excursion
               (goto-char (point-min))
               (let (found)
                 (while (and (not found) (not (eobp)))
                   (when (eql n (get-text-property (line-beginning-position)
                                                   'tabularium-filter-n))
                     (setq found (line-beginning-position)))
                   (forward-line 1))
                 found))))
    (when pos (goto-char pos) pos)))

(defun tabularium-filter-mark ()
  "Mark the filter rule at point for removal, then advance.
At the last rule, point stays on it rather than leaving the list."
  (interactive)
  (let ((n (tabularium--filter-n-at-point)))
    (unless n (user-error "No filter rule at point"))
    (cl-pushnew n tabularium--filter-marks)
    (tabularium--filter-refresh)
    (or (tabularium--filter-goto-n (1+ n))
        (tabularium--filter-goto-n n))))

(defun tabularium-filter-unmark ()
  "Unmark the filter rule at point, then advance.
At the last rule, point stays on it rather than leaving the list."
  (interactive)
  (let ((n (tabularium--filter-n-at-point)))
    (unless n (user-error "No filter rule at point"))
    (setq tabularium--filter-marks
          (delq n tabularium--filter-marks))
    (tabularium--filter-refresh)
    (or (tabularium--filter-goto-n (1+ n))
        (tabularium--filter-goto-n n))))

(defun tabularium-filter-unmark-all ()
  "Clear all marks in the Filter Rules List buffer."
  (interactive)
  (setq tabularium--filter-marks nil)
  (tabularium--filter-refresh))

(defun tabularium-filter-next ()
  "Move to the next filter rule, respecting bounds."
  (interactive)
  (if (< (line-number-at-pos)
         (or tabularium--filter-last-line 5))
      (forward-line 1)
    (message "Last rule")))

(defun tabularium-filter-prev ()
  "Move to the previous filter rule, respecting bounds."
  (interactive)
  (if (> (line-number-at-pos)
         (or tabularium--filter-first-line 5))
      (forward-line -1)
    (message "First rule")))

(defun tabularium-filter-remove ()
  "Remove the marked filter rules, or the rule at point if none marked."
  (interactive)
  (let* ((nums (or tabularium--filter-marks
                   (when-let ((n (tabularium--filter-n-at-point)))
                     (list n))))
         (view tabularium--filter-view))
    (unless nums (user-error "No filter rule marked or at point"))
    (with-current-buffer view
      ;; Drop the indexed rules (1-based), then repair the connective
      ;; on a new first rule so it carries none.
      (let ((i 0))
        (setq tabularium--filter-rules
              (cl-remove-if (lambda (_)
                              (memq (cl-incf i) nums))
                            tabularium--filter-rules)))
      (when (and tabularium--filter-rules
                 (plist-get (car tabularium--filter-rules) :connective))
        (tabularium--filter-push-undo)
        (setq tabularium--filter-rules
              (cons (plist-put (copy-sequence
                                (car tabularium--filter-rules))
                               :connective nil)
                    (cdr tabularium--filter-rules))))
      (tabularium--filter-update-modeline)
      (revert-buffer))
    (setq tabularium--filter-marks nil)
    (tabularium--filter-refresh)
    (message "Removed %d filter rule%s"
             (length nums) (if (= 1 (length nums)) "" "s"))))

(defun tabularium-filter-remove-all ()
  "Remove every filter rule from the owning view."
  (interactive)
  (with-current-buffer tabularium--filter-view
    (tabularium--filter-push-undo)
    (setq tabularium--filter-rules nil)
    (setq mode-name "Tabularium")
    (tabularium--filter-update-modeline)
    (revert-buffer))
  (setq tabularium--filter-marks nil)
  (tabularium--filter-refresh)
  (message "Removed all filter rules"))

(defun tabularium-filter-toggle-marks ()
  "Toggle every mark in the Filter Rules List buffer."
  (interactive)
  (let* ((rules (with-current-buffer tabularium--filter-view
                   tabularium--filter-rules))
         (all (number-sequence 1 (length rules)))
         (n-at (tabularium--filter-n-at-point)))
    (setq tabularium--filter-marks
          (cl-set-difference all tabularium--filter-marks))
    (tabularium--filter-refresh)
    (when n-at (tabularium--filter-goto-n n-at))))

(defun tabularium-filter-cycle-connective ()
  "Cycle the logical connective of the filter rule at point.
Cycles conjunction → disjunction → negated conjunction → negated
disjunction (and → or → and-not → or-not → and).  The first rule
has no connective and cannot be cycled."
  (interactive)
  (let ((n (tabularium--filter-n-at-point))
        (view tabularium--filter-view))
    (unless n (user-error "No filter rule at point"))
    (when (= n 1)
      (user-error "The first filter rule has no connective"))
    (with-current-buffer view
      (let* ((idx (1- n))
             (rule (nth idx tabularium--filter-rules))
             (cycle '(and or and-not or-not))
             (current (plist-get rule :connective))
             (next (or (cadr (memq current cycle)) 'and)))
        (setf (nth idx tabularium--filter-rules)
              (plist-put (copy-sequence rule) :connective next))
        (tabularium--filter-update-modeline)
        (revert-buffer)))
    (tabularium--filter-refresh)
    (tabularium--filter-goto-n n)))

(defun tabularium-filter-revert ()
  "Refresh the Filter Rules List buffer."
  (interactive)
  (tabularium--filter-refresh))

(defun tabularium--filter-move (direction)
  "Move the filter rule at point one step in DIRECTION (`up' or `down').
Reorders `tabularium--filter-rules' in the owning view.  The logical
connective belongs to the line, not the rule, so each position keeps
its connective across the move (the first line always carries none);
only the rule data is reordered."
  (let ((n (tabularium--filter-n-at-point))
        (view tabularium--filter-view))
    (unless n (user-error "No filter rule at point"))
    (with-current-buffer view
      (let* ((rules (copy-sequence tabularium--filter-rules))
             (len (length rules))
             (i (1- n))
             (j (if (eq direction 'up) (1- i) (1+ i)))
             ;; Connectives belong to the line/position, not the rule, so
             ;; capture them by position and re-apply after moving the data.
             (conns (mapcar (lambda (r) (plist-get r :connective)) rules)))
        (when (or (< j 0) (>= j len))
          (user-error "Cannot move %s any further" direction))
        (let ((tmp (nth i rules)))
          (setf (nth i rules) (nth j rules))
          (setf (nth j rules) tmp))
        ;; Re-apply the per-position connectives; the first line carries none.
        (setq rules
              (cl-loop for rule in rules
                       for idx from 0
                       collect (plist-put (copy-sequence rule)
                                          :connective
                                          (if (= idx 0) nil (nth idx conns)))))
        (tabularium--filter-push-undo)
        (setq tabularium--filter-rules rules)
        (tabularium--filter-update-modeline)
        (revert-buffer)))
    (tabularium--filter-refresh)
    (tabularium--filter-goto-n (if (eq direction 'up) (1- n) (1+ n)))))

(defun tabularium-filter-move-up ()
  "Move the filter rule at point one position earlier."
  (interactive)
  (tabularium--filter-move 'up))

(defun tabularium-filter-move-down ()
  "Move the filter rule at point one position later."
  (interactive)
  (tabularium--filter-move 'down))

(defun tabularium-filter-modify ()
  "Re-enter the filter rule at point.
Removes the rule and restarts `tabularium-view-filter-add' from the
top, so the scope — row(s) or column(s) — is asked again along with
the rule type and its operands.  The replacement is added at the end
of the stack."
  (interactive)
  (let ((n (tabularium--filter-n-at-point))
        (view tabularium--filter-view))
    (unless n (user-error "No filter rule at point"))
    (with-current-buffer view
      (tabularium--filter-push-undo)
      (let ((rules (copy-sequence tabularium--filter-rules))
            (i 0))
        (setq tabularium--filter-rules
              (cl-remove-if (lambda (_) (= (cl-incf i) n)) rules))
        ;; The first rule never carries a connective.
        (when tabularium--filter-rules
          (setf (car tabularium--filter-rules)
                (plist-put (copy-sequence (car tabularium--filter-rules))
                           :connective nil)))
        (tabularium--filter-update-modeline)
        (call-interactively #'tabularium-view-filter-add)))
    (tabularium--filter-refresh)))

(defun tabularium-filter-add ()
  "Add a new filter rule at the end of the stack.
Runs the same dispatcher as `tabularium-view-filter-add' in the owning
view; the list buffer refreshes automatically."
  (interactive)
  (with-current-buffer tabularium--filter-view
    (call-interactively #'tabularium-view-filter-add)))

(defun tabularium-filter-insert ()
  "Insert a new filter rule before the rule at point.
Prompts for a rule as `tabularium-filter-add' does, then moves it to
the current line.  With no rule at point (empty list) it simply adds."
  (interactive)
  (let* ((n (tabularium--filter-n-at-point))
         (view tabularium--filter-view)
         (before (with-current-buffer view (length tabularium--filter-rules))))
    (with-current-buffer view
      (call-interactively #'tabularium-view-filter-add))
    (let ((after (with-current-buffer view (length tabularium--filter-rules))))
      (when (and n (> after before))
        (with-current-buffer view
          (let* ((rules (copy-sequence tabularium--filter-rules))
                 (new-rule (car (last rules)))
                 (without (butlast rules))
                 (idx (1- n))
                 (spliced (append (seq-take without idx)
                                  (list new-rule)
                                  (seq-drop without idx))))
            ;; Repair the connective invariant: the first line carries none,
            ;; and any later rule left without one defaults to AND.
            (setq spliced
                  (cl-loop for rule in spliced
                           for i from 0
                           collect
                           (cond
                            ((and (= i 0) (plist-get rule :connective))
                             (plist-put (copy-sequence rule) :connective nil))
                            ((and (> i 0) (null (plist-get rule :connective)))
                             (plist-put (copy-sequence rule) :connective 'and))
                            (t rule))))
            (tabularium--filter-push-undo)
            (setq tabularium--filter-rules spliced)
            (tabularium--filter-update-modeline)
            (revert-buffer)))
        (tabularium--filter-refresh)
        (tabularium--filter-goto-n n)))))

(defvar tabularium-filter-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "m") #'tabularium-filter-mark)
    (define-key map (kbd "u") #'tabularium-filter-unmark)
    (define-key map (kbd "U") #'tabularium-filter-unmark-all)
    (define-key map (kbd "t") #'tabularium-filter-toggle-marks)
    (define-key map (kbd "x") #'tabularium-filter-remove)
    (define-key map (kbd "X") #'tabularium-filter-remove-all)
    (define-key map (kbd "c") #'tabularium-filter-cycle-connective)
    (define-key map (kbd "M-p") #'tabularium-filter-move-up)
    (define-key map (kbd "M-n") #'tabularium-filter-move-down)
    (define-key map (kbd "M-<up>") #'tabularium-filter-move-up)
    (define-key map (kbd "M-<down>") #'tabularium-filter-move-down)
    (define-key map (kbd "RET") #'tabularium-filter-modify)
    (define-key map (kbd "g") #'tabularium-filter-revert)
    (define-key map (kbd "=") #'tabularium-filter-revert)
    (define-key map (kbd "n") #'tabularium-filter-next)
    (define-key map (kbd "p") #'tabularium-filter-prev)
    (define-key map (kbd "TAB") #'tabularium-filter-next)
    (define-key map (kbd "<backtab>") #'tabularium-filter-prev)
    (define-key map (kbd "I") #'tabularium-filter-insert)
    (define-key map (kbd "A") #'tabularium-filter-add)
    (define-key map (kbd "<down>") #'tabularium-filter-next)
    (define-key map (kbd "<up>") #'tabularium-filter-prev)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `tabularium-filter-mode'.")

(define-derived-mode tabularium-filter-mode special-mode
  "Tabularium-Filter"
  "Major mode for the interactive Filter Rules List buffer.
Lists every filter rule of a view in evaluation order, with its
connective shown in a dedicated column.  Rules can be marked
and removed and their connective cycled, without leaving the
buffer.  A companion to the single-line filter description shown
in the modeline."
  (setq-local revert-buffer-function
              (lambda (&rest _) (tabularium--filter-refresh))))

;;;###autoload
(defun tabularium-view-filter-buffer ()
  "Open the interactive Filter Rules List buffer for the current view.
Lists every filter rule numbered in evaluation order, with keys
to mark and remove rules and cycle their connectives."
  (interactive)
  (unless (derived-mode-p 'tabularium-view-mode)
    (user-error "Not in a Tabularium view"))
  (let ((view (current-buffer))
        (buf (get-buffer-create "*Filter Rules List*")))
    (with-current-buffer buf
      (tabularium-filter-mode)
      (setq tabularium--filter-view view)
      (setq tabularium--filter-marks nil)
      (tabularium--filter-refresh))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (goto-char (or tabularium--filter-first-pos (point-min))))))

;;; ** 7.4 Find/Replace

;;; *** 7.4.1 Standard

(defvar tabularium--replace-scope nil
  "Scope description for replace messages: nil, \"marked\", or \"visible\".")

(defvar tabularium-search-history nil
  "Minibuffer history for tabularium search and substring-match prompts.
Shared across `tabularium-replace-substring', `tabularium-replace-exact',
`tabularium-replace-query', the `tabularium-view-mark-*' family, the
~tabularium-aggregate-count~ value prompt, and their visible-scope
variants.  Press \\[previous-history-element] in any of these prompts
to recall a previous search term.")

(defvar tabularium-replace-history nil
  "Minibuffer history for tabularium replacement-value prompts.
Used for the `with:' prompt in every replace command and visible-scope
variant.  Distinct from `tabularium-search-history' so search terms and
replacement terms can be recalled independently.")

(defvar tabularium-regexp-history nil
  "Minibuffer history for tabularium regexp prompts.
Shared across `tabularium-replace-regexp', `tabularium-view-mark-regexp',
and their visible-scope variants.")

(defun tabularium-toggle-case-sensitive ()
  "Toggle case sensitivity for replace and mark operations."
  (interactive)
  (setq tabularium-case-sensitive (not tabularium-case-sensitive))
  (message "Case-sensitive matching: %s" (if tabularium-case-sensitive "ON" "OFF")))

(defun tabularium-replace-substring (old-value new-value &optional fields)
  "Replace substring OLD-VALUE with NEW-VALUE across FIELDS.
FIELDS is a list of field name strings.  If nil, searches all fields.
If rows are marked, only operates on marked rows; marks are cleared after."
  (interactive
   (let* ((old-value (read-string "Replace value: " nil 'tabularium-search-history))
          (new-value (read-string (format "Replace '%s' with: " old-value) nil 'tabularium-replace-history))
          (fields (tabularium--field-crm)))
     (list old-value new-value fields)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (marked-ids tabularium--marked-entries)
         (id-constraint (when marked-ids
                          (format " AND %s IN (%s)"
                                  primary-name
                                  (mapconcat #'number-to-string marked-ids ","))))
         (requested-fields (or fields (tabularium--stored-field-names)))
         (acc-rej (tabularium--fields-accepting-value requested-fields new-value))
         (search-fields (car acc-rej))
         (protected-fields (cdr acc-rej))
         (like-op (tabularium-db-like-op tabularium-case-sensitive))
         (case-fold (not tabularium-case-sensitive))
         (all-undo-ops '())
         (skipped 0)
         (skipped-fields '())
         (total-replaced 0))
    (when (and (null search-fields) requested-fields)
      (user-error "Cannot replace in selected fields: choice columns only accept their defined values"))
    ;; Count total matches first
    (dolist (field search-fields)
      (let* ((count-sql (format "SELECT COUNT(*) FROM %s WHERE %s %s ?%s"
                                tabularium-table-name field like-op
                                (or id-constraint "")))
             (count (caar (tabularium-db-query tabularium--db count-sql
                                               (list (tabularium-db-like-pattern old-value tabularium-case-sensitive))))))
        (when (> count 0)
          (setq total-replaced (+ total-replaced count)))))
    (if (zerop total-replaced)
        (message "No records found containing '%s'%s%s" old-value
                 (if marked-ids (format " (%s rows)" (or tabularium--replace-scope "marked")) "")
                 (if protected-fields
                     (format " (%d protected)" (length protected-fields))
                   ""))
      (when (yes-or-no-p (format "Replace '%s' → '%s' in %d %s%s? "
                                 old-value new-value total-replaced
                                 (if (= 1 total-replaced) "cell" "cells")
                                 (if marked-ids (format " (%d %s)" (length marked-ids) (or tabularium--replace-scope "marked")) "")))
        ;; Process each field with undo tracking, batched in one
        ;; transaction so a bulk replace is one commit, not one per cell.
        (tabularium-db-with-transaction tabularium--db
          (dolist (field search-fields)
            (let* ((select-sql (format "SELECT %s, %s FROM %s WHERE %s %s ?%s"
                                       primary-name field tabularium-table-name field
                                       like-op (or id-constraint "")))
                   (records (tabularium-db-query tabularium--db select-sql
                                                 (list (tabularium-db-like-pattern old-value tabularium-case-sensitive)))))
              (dolist (record records)
                (let* ((id (car record))
                       (current-val (format "%s" (cadr record)))
                       (case-fold-search case-fold)
                       (updated-val (replace-regexp-in-string
                                     (regexp-quote old-value) new-value current-val t t)))
                  (unless (string= current-val updated-val)
                    (condition-case err
                        (progn
                          (tabularium-db-update tabularium--db tabularium-table-name
                                            (list (cons (intern field) updated-val))
                                            (tabularium--primary-field-name) id)
                          (push (list :type 'update :row id :field (intern field)
                                      :old current-val :new updated-val)
                                all-undo-ops))
                      (error
                       (cl-incf skipped)
                       (cl-pushnew field skipped-fields :test #'string=)
                       (message "Skipped row %s (%s): %s" id field (error-message-string err))))))))))
        (let ((num-replaced (length all-undo-ops)))
          (when all-undo-ops
            (tabularium--undo-push
             (if (= 1 num-replaced)
                 (car all-undo-ops)
               (list :type 'multi :ops (nreverse all-undo-ops)))))
          (tabularium--invalidate-cache)
          (when marked-ids
            (setq tabularium--marked-entries nil))
          (when (derived-mode-p 'tabularium-view-mode)
            (let ((inhibit-message t))
              (revert-buffer)))
          (message "Replaced %d%s%s" num-replaced
                   (if (> skipped 0)
                       (format ", skipped %d (%s constraint)"
                       skipped (string-join (nreverse skipped-fields) ", "))
                     "")
                   (if protected-fields
                       (format " (%d protected)" (length protected-fields))
                     "")))))))

(defun tabularium-replace-exact (old-value new-value &optional fields)
  "Replace exact OLD-VALUE with NEW-VALUE across FIELDS.
Unlike `tabularium-replace-substring', matches the entire cell value.
FIELDS is a list of field name strings.  If nil, searches all fields.
If rows are marked, only operates on marked rows; marks are cleared after."
  (interactive
   (let* ((old-value (read-string "Replace exact value: " nil 'tabularium-search-history))
          (new-value (read-string (format "Replace '%s' with: " old-value) nil 'tabularium-replace-history))
          (fields (tabularium--field-crm)))
     (list old-value new-value fields)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (marked-ids tabularium--marked-entries)
         (id-constraint (when marked-ids
                          (format " AND %s IN (%s)"
                                  primary-name
                                  (mapconcat #'number-to-string marked-ids ","))))
         (requested-fields (or fields (tabularium--stored-field-names)))
         (acc-rej (tabularium--fields-accepting-value requested-fields new-value))
         (search-fields (car acc-rej))
         (protected-fields (cdr acc-rej))
         (collate (tabularium-db-collate tabularium-case-sensitive))
         (all-undo-ops '())
         (skipped 0)
         (skipped-fields '())
         (total-replaced 0))
    (when (and (null search-fields) requested-fields)
      (user-error "Cannot replace in selected fields: choice columns only accept their defined values"))
    ;; Count total matches first
    (dolist (field search-fields)
      (let* ((count-sql (format "SELECT COUNT(*) FROM %s WHERE %s%s = ?%s"
                                tabularium-table-name field collate
                                (or id-constraint "")))
             (count (caar (tabularium-db-query tabularium--db count-sql
                                               (list old-value)))))
        (when (> count 0)
          (setq total-replaced (+ total-replaced count)))))
    (if (zerop total-replaced)
        (message "No records found with exact value '%s'%s%s" old-value
                 (if marked-ids (format " (%s rows)" (or tabularium--replace-scope "marked")) "")
                 (if protected-fields
                     (format " (%d protected)" (length protected-fields))
                   ""))
      (when (yes-or-no-p (format "Replace '%s' → '%s' in %d %s%s? "
                                 old-value new-value total-replaced
                                 (if (= 1 total-replaced) "cell" "cells")
                                 (if marked-ids (format " (%d %s)" (length marked-ids) (or tabularium--replace-scope "marked")) "")))
        (tabularium-db-with-transaction tabularium--db
          (dolist (field search-fields)
            (let* ((select-sql (format "SELECT %s FROM %s WHERE %s%s = ?%s"
                                       primary-name tabularium-table-name field
                                       collate (or id-constraint "")))
                   (records (tabularium-db-query tabularium--db select-sql
                                                 (list old-value))))
              (dolist (record records)
                (let ((id (car record)))
                  (condition-case err
                      (progn
                        (tabularium-db-update tabularium--db tabularium-table-name
                                          (list (cons (intern field) new-value))
                                          (tabularium--primary-field-name) id)
                        (push (list :type 'update :row id :field (intern field)
                                    :old old-value :new new-value)
                              all-undo-ops))
                    (error
                     (cl-incf skipped)
                     (cl-pushnew field skipped-fields :test #'string=)
                     (message "Skipped row %s (%s): %s" id field (error-message-string err)))))))))
        (let ((num-replaced (length all-undo-ops)))
          (when all-undo-ops
            (tabularium--undo-push
             (if (= 1 num-replaced)
                 (car all-undo-ops)
               (list :type 'multi :ops (nreverse all-undo-ops)))))
          (tabularium--invalidate-cache)
          (when marked-ids
            (setq tabularium--marked-entries nil))
          (when (derived-mode-p 'tabularium-view-mode)
            (let ((inhibit-message t))
              (revert-buffer)))
          (message "Replaced %d%s%s" num-replaced
                   (if (> skipped 0)
                       (format ", skipped %d (%s constraint)"
                       skipped (string-join (nreverse skipped-fields) ", "))
                     "")
                   (if protected-fields
                       (format " (%d protected)" (length protected-fields))
                     "")))))))

(defun tabularium-replace-pattern (pattern replacement &optional fields)
  "Replace cells matching SQL PATTERN with REPLACEMENT across FIELDS.
Uses GLOB or LIKE per `tabularium-case-sensitive'.  Nil FIELDS means all."
  (interactive
   (let* ((pattern (read-string (format "SQL %s pattern: " (tabularium-db-like-op tabularium-case-sensitive))))
          (replacement (read-string (format "Replace matches of '%s' with: " pattern) nil 'tabularium-replace-history))
          (fields (tabularium--field-crm)))
     (list pattern replacement fields)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (marked-ids tabularium--marked-entries)
         (id-constraint (when marked-ids
                          (format " AND %s IN (%s)"
                                  primary-name
                                  (mapconcat #'number-to-string marked-ids ","))))
         (requested-fields (or fields (tabularium--stored-field-names)))
         (acc-rej (tabularium--fields-accepting-value requested-fields replacement))
         (search-fields (car acc-rej))
         (protected-fields (cdr acc-rej))
         (like-op (tabularium-db-like-op tabularium-case-sensitive))
         (all-undo-ops '())
         (skipped 0)
         (skipped-fields '())
         (total-replaced 0))
    (when (and (null search-fields) requested-fields)
      (user-error "Cannot replace in selected fields: choice columns only accept their defined values"))
    ;; Count total matches first
    (dolist (field search-fields)
      (let* ((count-sql (format "SELECT COUNT(*) FROM %s WHERE %s %s ?%s"
                                tabularium-table-name field like-op
                                (or id-constraint "")))
             (count (caar (tabularium-db-query tabularium--db count-sql
                                               (list pattern)))))
        (when (> count 0)
          (setq total-replaced (+ total-replaced count)))))
    (if (zerop total-replaced)
        (message "No records match pattern '%s'%s%s" pattern
                 (if marked-ids (format " (%s rows)" (or tabularium--replace-scope "marked")) "")
                 (if protected-fields
                     (format " (%d protected)" (length protected-fields))
                   ""))
      (when (yes-or-no-p (format "Replace %d %s matching '%s' → '%s'%s? "
                                 total-replaced
                                 (if (= 1 total-replaced) "cell" "cells")
                                 pattern replacement
                                 (if marked-ids (format " (%d %s)" (length marked-ids) (or tabularium--replace-scope "marked")) "")))
        (tabularium-db-with-transaction tabularium--db
          (dolist (field search-fields)
            (let* ((select-sql (format "SELECT %s, %s FROM %s WHERE %s %s ?%s"
                                       primary-name field tabularium-table-name field
                                       like-op (or id-constraint "")))
                   (records (tabularium-db-query tabularium--db select-sql
                                                 (list pattern))))
              (dolist (record records)
                (let ((id (car record))
                      (old-val (cadr record)))
                  (condition-case err
                      (progn
                        (tabularium-db-update tabularium--db tabularium-table-name
                                          (list (cons (intern field) replacement))
                                          (tabularium--primary-field-name) id)
                        (push (list :type 'update :row id :field (intern field)
                                    :old old-val :new replacement)
                              all-undo-ops))
                    (error
                     (cl-incf skipped)
                     (cl-pushnew field skipped-fields :test #'string=)
                     (message "Skipped row %s (%s): %s" id field (error-message-string err)))))))))
        (let ((num-replaced (length all-undo-ops)))
          (when all-undo-ops
            (tabularium--undo-push
             (if (= 1 num-replaced)
                 (car all-undo-ops)
               (list :type 'multi :ops (nreverse all-undo-ops)))))
          (tabularium--invalidate-cache)
          (when marked-ids
            (setq tabularium--marked-entries nil))
          (when (derived-mode-p 'tabularium-view-mode)
            (let ((inhibit-message t))
              (revert-buffer)))
          (message "Replaced %d%s%s" num-replaced
                   (if (> skipped 0)
                       (format ", skipped %d (%s constraint)"
                       skipped (string-join (nreverse skipped-fields) ", "))
                     "")
                   (if protected-fields
                       (format " (%d protected)" (length protected-fields))
                     "")))))))

(defun tabularium-replace-regexp (regexp replacement &optional fields)
  "Replace cells matching Emacs REGEXP with REPLACEMENT across FIELDS.
REPLACEMENT can include \\\\& and \\\\N.  Nil FIELDS means all."
  (interactive
   (let* ((regexp (read-string "Replace regexp: " nil 'tabularium-regexp-history))
          (replacement (read-string (format "Replace matches of '%s' with: " regexp) nil 'tabularium-replace-history))
          (fields (tabularium--field-crm)))
     (list regexp replacement fields)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (marked-ids tabularium--marked-entries)
         (requested-fields (or fields (tabularium--stored-field-names)))
         (acc-rej (tabularium--fields-accepting-value requested-fields replacement))
         (search-fields (car acc-rej))
         (protected-fields (cdr acc-rej))
         (case-fold (not tabularium-case-sensitive))
         (all-undo-ops '())
         (skipped 0)
         (skipped-fields '())
         (total-replaced 0))
    (when (and (null search-fields) requested-fields)
      (user-error "Cannot replace in selected fields: choice columns only accept their defined values"))
    ;; Fetch all rows and filter in Emacs; batch writes in one transaction.
    (tabularium-db-with-transaction tabularium--db
      (dolist (field search-fields)
        (let* ((id-constraint (when marked-ids
                                (format " WHERE %s IN (%s)"
                                        primary-name
                                        (mapconcat #'number-to-string marked-ids ","))))
               (sql (format "SELECT %s, %s FROM %s%s"
                            primary-name field tabularium-table-name
                            (or id-constraint "")))
               (rows (tabularium-db-query tabularium--db sql nil)))
          (dolist (row rows)
            (let* ((id (car row))
                   (val (cadr row))
                   (val-str (if val (format "%s" val) "")))
              (when (let ((case-fold-search case-fold))
                      (string-match regexp val-str))
                (let ((new-val (replace-regexp-in-string regexp replacement val-str
                                                         nil nil)))
                  (unless (string= val-str new-val)
                    (condition-case err
                        (progn
                          (tabularium-db-update tabularium--db tabularium-table-name
                                            (list (cons (intern field) new-val))
                                            (tabularium--primary-field-name) id)
                          (cl-incf total-replaced)
                          (push (list :type 'update :row id :field (intern field)
                                      :old val :new new-val)
                                all-undo-ops))
                      (error
                       (cl-incf skipped)
                       (cl-pushnew field skipped-fields :test #'string=)
                       (message "Skipped row %s (%s): %s" id field (error-message-string err))))))))))))
    (if (and (zerop total-replaced) (zerop skipped))
        (message "No cells match regexp '%s'%s%s" regexp
                 (if marked-ids (format " (%s rows)" (or tabularium--replace-scope "marked")) "")
                 (if protected-fields
                     (format " (%d protected)" (length protected-fields))
                   ""))
      (when all-undo-ops
        (tabularium--undo-push
         (if (= 1 total-replaced)
             (car all-undo-ops)
           (list :type 'multi :ops (nreverse all-undo-ops)))))
      (tabularium--invalidate-cache)
      (when marked-ids
        (setq tabularium--marked-entries nil))
      (when (derived-mode-p 'tabularium-view-mode)
        (let ((inhibit-message t))
          (revert-buffer)))
      (message "Replaced %d%s%s" total-replaced
               (if (> skipped 0)
                   (format ", skipped %d (%s constraint)"
                       skipped (string-join (nreverse skipped-fields) ", "))
                 "")
               (if protected-fields
                   (format " (%d protected)" (length protected-fields))
                 "")))))

(defun tabularium-replace-query (old-value new-value &optional fields)
  "Interactive query-replace OLD-VALUE with NEW-VALUE across FIELDS.
Prompt y/n/!/q at each match, like `query-replace'.  Nil FIELDS means all."
  (interactive
   (let* ((old-value (read-string "Query replace: " nil 'tabularium-search-history))
          (new-value (read-string (format "Replace '%s' with: " old-value) nil 'tabularium-replace-history))
          (fields (tabularium--field-crm)))
     (list old-value new-value fields)))
  (tabularium--ensure-db)
  (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
         (marked-ids tabularium--marked-entries)
         (id-constraint (when marked-ids
                          (format " AND %s IN (%s)"
                                  primary-name
                                  (mapconcat #'number-to-string marked-ids ","))))
         (requested-fields (or fields (tabularium--stored-field-names)))
         (acc-rej (tabularium--fields-accepting-value requested-fields new-value))
         (search-fields (car acc-rej))
         (protected-fields (cdr acc-rej))
         (replaced 0)
         (skipped 0)
         (replace-all nil)
         (undo-ops '())
         (like-op (tabularium-db-like-op tabularium-case-sensitive))
         (case-fold (not tabularium-case-sensitive))
         (in-view-mode (derived-mode-p 'tabularium-view-mode)))
    (when (and (null search-fields) requested-fields)
      (user-error "Cannot replace in selected fields: choice columns only accept their defined values"))
    ;; Gather all matches across fields
    (let ((all-matches '())
          ;; Build field position map for sort order (schema column order)
          (field-positions (let ((pos 0))
                            (mapcar (lambda (f)
                                      (prog1 (cons (symbol-name (plist-get f :id)) pos)
                                        (cl-incf pos)))
                                    (tabularium--schema-fields)))))
      (dolist (field search-fields)
        (let* ((select-sql (format "SELECT %s, %s FROM %s WHERE %s %s ?%s ORDER BY %s ASC"
                                   primary-name field tabularium-table-name field
                                   like-op (or id-constraint "")
                                   primary-name))
               (records (tabularium-db-query tabularium--db select-sql
                                             (list (tabularium-db-like-pattern old-value tabularium-case-sensitive)))))
          (dolist (record records)
            (push (list :id (car record) :field field :value (format "%s" (cadr record)))
                  all-matches))))
      ;; Sort: by row ID ascending, then by field position (left to right)
      (setq all-matches
            (sort all-matches
                  (lambda (a b)
                    (let ((id-a (plist-get a :id))
                          (id-b (plist-get b :id)))
                      (if (/= id-a id-b)
                          (< id-a id-b)
                        (< (or (cdr (assoc (plist-get a :field) field-positions)) 999)
                           (or (cdr (assoc (plist-get b :field) field-positions)) 999)))))))
      (if (null all-matches)
          (message "No matches found for '%s'%s" old-value
                   (if marked-ids (format " (%s rows)" (or tabularium--replace-scope "marked")) ""))
        (unwind-protect
            (catch 'quit
              (dolist (match all-matches)
                (let* ((id (plist-get match :id))
                       (field (plist-get match :field))
                       (current-value (plist-get match :value))
                       (case-fold-search case-fold)
                       (preview (replace-regexp-in-string
                                 (regexp-quote old-value) new-value current-value t t)))
                  ;; Highlight the match in view mode
                  (when in-view-mode
                    (tabularium--remove-qr-overlays)
                    (tabularium--highlight-match id field old-value)
                    (recenter))
                  (let ((do-replace replace-all))
                    (unless replace-all
                      (let ((response (read-char-choice
                                       (format "[%s] '%s' → '%s'? (y/n/!/q) [ID %s] "
                                               field current-value preview id)
                                       '(?y ?n ?! ?q))))
                        (pcase response
                          (?q (throw 'quit nil))
                          (?! (setq replace-all t do-replace t))
                          (?n (cl-incf skipped))
                          (?y (setq do-replace t)))))
                    (when do-replace
                      (let* ((case-fold-search case-fold)
                             (updated-value (replace-regexp-in-string
                                             (regexp-quote old-value) new-value current-value t t)))
                        (if (string= current-value updated-value)
                            (cl-incf skipped)
                          (condition-case err
                              (progn
                                (tabularium-db-update tabularium--db tabularium-table-name
                                                  (list (cons (intern field) updated-value))
                                                  (tabularium--primary-field-name) id)
                                (push (list :type 'update :row id :field (intern field)
                                            :old current-value :new updated-value)
                                      undo-ops)
                                (cl-incf replaced)
                                ;; Live update: refresh buffer to show the change
                                (when (and in-view-mode (not replace-all))
                                  (tabularium--invalidate-cache)
                                  (let ((inhibit-message t))
                                    (revert-buffer))))
                            (error
                             (cl-incf skipped)
                             (message "Skipped row %s (%s): %s" id field (error-message-string err)))))))))))
          ;; Always clean up overlays
          (when in-view-mode
            (tabularium--remove-qr-overlays)))
        (when undo-ops
          (tabularium--undo-push
           (if (= 1 (length undo-ops))
               (car undo-ops)
             (list :type 'multi :ops (nreverse undo-ops)))))
        (tabularium--invalidate-cache)
        (when marked-ids
          (setq tabularium--marked-entries nil))
        (when in-view-mode
          (let ((inhibit-message t))
            (revert-buffer)))
        (message "Replaced %d, skipped %d%s" replaced skipped
                 (if protected-fields
                     (format " (%d protected)" (length protected-fields))
                   ""))))))

(defun tabularium--goto-id (id)
  "Move point to the row with ID in the current view buffer."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (when (equal (tabulated-list-get-id) id)
        (setq found t))
      (unless found
        (forward-line 1)))
    found))

(defun tabularium--highlight-match (id field-name search-str)
  "Highlight SEARCH-STR in FIELD-NAME column of row ID.
Returns the overlay, or nil if not in view mode or not found."
  (when (and (derived-mode-p 'tabularium-view-mode)
             (tabularium--goto-id id))
    ;; Find column index for this field
    (let* ((schema-fields (tabularium--schema-fields))
           (field-prompt
            (let ((f (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :id)) field-name))
                                 schema-fields)))
              (when f (plist-get f :label))))
           (col-idx nil)
           (col-start 0))
      ;; Map prompt to column index
      (when field-prompt
        (dotimes (i (length tabulated-list-format))
          (when (string= (car (aref tabulated-list-format i)) field-prompt)
            (setq col-idx i)))
        ;; Compute character offset to column start
        (when col-idx
          (setq col-start tabulated-list-padding)
          (dotimes (i col-idx)
            (setq col-start (+ col-start 1 (cadr (aref tabulated-list-format i)))))
          ;; Search within the column for the substring
          (let* ((line-start (line-beginning-position))
                 (col-width (cadr (aref tabulated-list-format col-idx)))
                 (cell-start (+ line-start col-start))
                 (cell-end (+ cell-start col-width))
                 (case-fold-search (not tabularium-case-sensitive))
                 (ov nil))
            ;; Search in the cell region for the match
            (save-excursion
              (goto-char cell-start)
              (when (search-forward search-str cell-end t)
                (setq ov (make-overlay (match-beginning 0) (match-end 0)))
                (overlay-put ov 'tabularium-qr t)
                (overlay-put ov 'face 'tabularium-query-replace-face)
                (overlay-put ov 'priority 100)
                (goto-char (match-beginning 0))))
            ov))))))

(defun tabularium--remove-qr-overlays ()
  "Remove all query-replace highlight overlays."
  (remove-overlays (point-min) (point-max) 'tabularium-qr t))

;;; *** 7.4.2 Visible

(defun tabularium--visible-row-ids ()
  "Return list of row IDs currently visible in the tabulated list."
  (mapcar #'car tabulated-list-entries))

(defun tabularium-replace-visible-substring (old-value new-value &optional fields)
  "Replace substring OLD-VALUE with NEW-VALUE in FIELDS of visible rows.
Like `tabularium-replace-substring' but scoped to the current view
\(respecting filters and range limits).  Nil FIELDS means all fields."
  (interactive
   (let* ((old-value (read-string "Replace (visible): " nil 'tabularium-search-history))
          (new-value (read-string (format "Replace '%s' with: " old-value) nil 'tabularium-replace-history))
          (fields (tabularium--field-crm)))
     (list old-value new-value fields)))
  (let ((tabularium--marked-entries (tabularium--visible-row-ids))
        (tabularium--replace-scope "visible"))
    (tabularium-replace-substring old-value new-value fields)))

(defun tabularium-replace-visible-exact (old-value new-value &optional fields)
  "Replace exact OLD-VALUE with NEW-VALUE in FIELDS of visible rows.
Like `tabularium-replace-exact' but scoped to the current view.  Nil FIELDS means all."
  (interactive
   (let* ((old-value (read-string "Replace exact (visible): " nil 'tabularium-search-history))
          (new-value (read-string (format "Replace '%s' with: " old-value) nil 'tabularium-replace-history))
          (fields (tabularium--field-crm)))
     (list old-value new-value fields)))
  (let ((tabularium--marked-entries (tabularium--visible-row-ids))
        (tabularium--replace-scope "visible"))
    (tabularium-replace-exact old-value new-value fields)))

(defun tabularium-replace-visible-regexp (regexp replacement &optional fields)
  "Replace REGEXP with REPLACEMENT in FIELDS of visible rows.
Like `tabularium-replace-regexp' but scoped to the current view.  Nil FIELDS means all."
  (interactive
   (let* ((regexp (read-string "Replace regexp (visible): " nil 'tabularium-regexp-history))
          (replacement (read-string (format "Replace '%s' with: " regexp) nil 'tabularium-replace-history))
          (fields (tabularium--field-crm)))
     (list regexp replacement fields)))
  (let ((tabularium--marked-entries (tabularium--visible-row-ids))
        (tabularium--replace-scope "visible"))
    (tabularium-replace-regexp regexp replacement fields)))

(defun tabularium-replace-visible-query (old-value new-value &optional fields)
  "Interactive query-replace OLD-VALUE with NEW-VALUE in FIELDS of visible rows.
Like `tabularium-replace-query' (a `query-replace'-style loop) but scoped to the current view.  Nil FIELDS means all."
  (interactive
   (let* ((old-value (read-string "Query replace (visible): " nil 'tabularium-search-history))
          (new-value (read-string (format "Replace '%s' with: " old-value) nil 'tabularium-replace-history))
          (fields (tabularium--field-crm)))
     (list old-value new-value fields)))
  (let ((tabularium--marked-entries (tabularium--visible-row-ids))
        (tabularium--replace-scope "visible"))
    (tabularium-replace-query old-value new-value fields)))

;;; ** 7.5 Aggregate Operations

;;; *** 7.5.1 Count

(defun tabularium-aggregate-count (value &rest fields)
  "Count records where VALUE appears in FIELDS.
Interactively prompts for the value, then a `completing-read-multiple'
list of columns offering an `<<ALL>>' sentinel: choosing one column
counts matches in that column, choosing several counts rows matching
in any of them, and `<<ALL>>' (or an empty answer) counts across every
stored column.  Matching honours `tabularium-case-sensitive'.

This folds in the former \"count across\" command; from Lisp, VALUE is
the search pattern and FIELDS are field name strings (nil or empty
means all stored fields).  Returns the count."
  (interactive
   (let* ((value (read-string "Count value: " nil 'tabularium-search-history))
          (fields (tabularium--field-crm)))
     (if fields (cons value fields) (list value))))
  (tabularium--ensure-db)
  (let* ((search-fields (or fields (tabularium--stored-field-names)))
         (op (tabularium-db-like-op tabularium-case-sensitive))
         (pattern (tabularium-db-like-pattern (format "%s" value)
                                              tabularium-case-sensitive))
         (escaped (replace-regexp-in-string "'" "''" pattern))
         (conditions (mapcar (lambda (f)
                               (format "%s %s '%s'" f op escaped))
                             search-fields))
         (where-clause (string-join conditions " OR "))
         (sql (format "SELECT COUNT(*) FROM %s WHERE %s"
                      tabularium-table-name where-clause))
         (count (caar (tabularium-db-query tabularium--db sql))))
    (message "Records containing '%s' in %s: %d"
             value
             (cond
              ((= 1 (length search-fields)) (car search-fields))
              ((> (length search-fields) 3)
               (format "%d fields" (length search-fields)))
              (t (string-join search-fields ", ")))
             count)
    count))

;;; *** 7.5.2 Basic Statistics

(defun tabularium-aggregate-sum (field &optional filter-field filter-value)
  "Calculate sum of FIELD values.
Optionally filter by FILTER-FIELD matching FILTER-VALUE."
  (interactive
   (let* ((numeric-fields (cl-remove-if-not
                           (lambda (f)
                             (and (memq (plist-get f :type) '(integer number))
                                  (not (tabularium--computed-field-p f))))
                           (tabularium--schema-fields)))
          (field-names (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                               numeric-fields))
          (field (completing-read "Sum field: " field-names nil t)))
     (if current-prefix-arg
         (let* ((all-fields (tabularium--stored-field-names))
                (filter-field (completing-read "Filter by field: " all-fields nil t))
                (candidates (tabularium--get-historical-values filter-field))
                (filter-value (completing-read "Filter value: " candidates)))
           (list field filter-field filter-value))
       (list field nil nil))))
  (tabularium--ensure-db)
  (let* ((where (if (and filter-field filter-value (not (string-empty-p filter-value)))
                    (format "WHERE %s" (tabularium-db-build-like-clause filter-field filter-value tabularium-case-sensitive))
                  ""))
         (sql (format "SELECT SUM(%s) FROM %s %s" field tabularium-table-name where))
         (result (caar (tabularium-db-query tabularium--db sql))))
    (if (and filter-field filter-value (not (string-empty-p filter-value)))
        (message "Sum of %s (where %s ≈ %s): %s" field filter-field filter-value (or result 0))
      (message "Sum of %s: %s" field (or result 0)))))

(defun tabularium-aggregate-min-max (field &optional filter-field filter-value)
  "Show minimum and maximum values of FIELD.
Optionally filter by FILTER-FIELD matching FILTER-VALUE."
  (interactive
   (let* ((numeric-fields (cl-remove-if-not
                           (lambda (f)
                             (and (memq (plist-get f :type) '(integer number))
                                  (not (tabularium--computed-field-p f))))
                           (tabularium--schema-fields)))
          (field-names (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                               numeric-fields))
          (field (completing-read "Min/Max field: " field-names nil t)))
     (if current-prefix-arg
         (let* ((all-fields (tabularium--stored-field-names))
                (filter-field (completing-read "Filter by field: " all-fields nil t))
                (candidates (tabularium--get-historical-values filter-field))
                (filter-value (completing-read "Filter value: " candidates)))
           (list field filter-field filter-value))
       (list field nil nil))))
  (tabularium--ensure-db)
  (let* ((where (if (and filter-field filter-value (not (string-empty-p filter-value)))
                    (format "WHERE %s" (tabularium-db-build-like-clause filter-field filter-value tabularium-case-sensitive))
                  ""))
         (sql (format "SELECT MIN(%s), MAX(%s) FROM %s %s"
                      field field tabularium-table-name where))
         (result (car (tabularium-db-query tabularium--db sql)))
         (min-val (car result))
         (max-val (cadr result)))
    (if (and filter-field filter-value (not (string-empty-p filter-value)))
        (message "%s (where %s ≈ %s): min = %s, max = %s" field filter-field filter-value
                 (or min-val "N/A") (or max-val "N/A"))
      (message "%s: min = %s, max = %s" field (or min-val "N/A") (or max-val "N/A")))))

(defun tabularium--get-numeric-values (field &optional filter-field filter-value)
  "Get all numeric values for FIELD as a sorted list.
Optionally filter by FILTER-FIELD matching FILTER-VALUE.
Returns nil values removed and list sorted ascending."
  (tabularium--ensure-db)
  (let* ((where (if (and filter-field filter-value (not (string-empty-p filter-value)))
                    (format "WHERE %s AND %s IS NOT NULL"
                            (tabularium-db-build-like-clause filter-field filter-value tabularium-case-sensitive)
                            field)
                  (format "WHERE %s IS NOT NULL" field)))
         (sql (format "SELECT %s FROM %s %s ORDER BY %s ASC"
                      field tabularium-table-name where field))
         (results (tabularium-db-query tabularium--db sql)))
    (mapcar #'car results)))

(defun tabularium--calculate-percentile (sorted-values percentile)
  "Calculate PERCENTILE (0-100) from SORTED-VALUES list."
  (when sorted-values
    (let* ((n (length sorted-values))
           (rank (/ (* percentile (1- n)) 100.0))
           (lower-idx (floor rank))
           (upper-idx (ceiling rank))
           (fraction (- rank lower-idx)))
      (if (= lower-idx upper-idx)
          (float (nth lower-idx sorted-values))
        ;; Linear interpolation
        (+ (* (- 1 fraction) (nth lower-idx sorted-values))
           (* fraction (nth upper-idx sorted-values)))))))

(defun tabularium--calculate-std-dev (values mean)
  "Calculate standard deviation of VALUES given MEAN."
  (when (> (length values) 1)
    (let* ((n (length values))
           (sum-sq-diff (cl-reduce #'+
                                   (mapcar (lambda (v)
                                             (expt (- v mean) 2))
                                           values))))
      (sqrt (/ sum-sq-diff (1- n))))))  ; Sample std dev (n-1)

(defun tabularium-aggregate-mean-sd (field &optional filter-field filter-value)
  "Show mean ± standard deviation for FIELD.
Optionally filter by FILTER-FIELD matching FILTER-VALUE."
  (interactive
   (let* ((numeric-fields (cl-remove-if-not
                           (lambda (f)
                             (and (memq (plist-get f :type) '(integer number))
                                  (not (tabularium--computed-field-p f))))
                           (tabularium--schema-fields)))
          (field-names (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                               numeric-fields))
          (field (completing-read "Mean ± SD field: " field-names nil t)))
     (if current-prefix-arg
         (let* ((all-fields (tabularium--stored-field-names))
                (filter-field (completing-read "Filter by field: " all-fields nil t))
                (candidates (tabularium--get-historical-values filter-field))
                (filter-value (completing-read "Filter value: " candidates)))
           (list field filter-field filter-value))
       (list field nil nil))))
  (let* ((values (tabularium--get-numeric-values field filter-field filter-value))
         (n (length values)))
    (if (< n 2)
        (message "Need at least 2 values to calculate mean ± SD (got %d)" n)
      (let* ((mean (/ (cl-reduce #'+ values) (float n)))
             (sd (tabularium--calculate-std-dev values mean))
             (filter-info (if (and filter-field filter-value (not (string-empty-p filter-value)))
                              (format " (where %s ≈ %s)" filter-field filter-value)
                            "")))
        (message "%s%s: %.2f ± %.2f (n = %d)" field filter-info mean sd n)))))

(defun tabularium-aggregate-median-iqr (field &optional filter-field filter-value)
  "Show median [Q1, Q3] (interquartile range) for FIELD.
Optionally filter by FILTER-FIELD matching FILTER-VALUE."
  (interactive
   (let* ((numeric-fields (cl-remove-if-not
                           (lambda (f)
                             (and (memq (plist-get f :type) '(integer number))
                                  (not (tabularium--computed-field-p f))))
                           (tabularium--schema-fields)))
          (field-names (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                               numeric-fields))
          (field (completing-read "Median [Q1, Q3] field: " field-names nil t)))
     (if current-prefix-arg
         (let* ((all-fields (tabularium--stored-field-names))
                (filter-field (completing-read "Filter by field: " all-fields nil t))
                (candidates (tabularium--get-historical-values filter-field))
                (filter-value (completing-read "Filter value: " candidates)))
           (list field filter-field filter-value))
       (list field nil nil))))
  (let* ((values (tabularium--get-numeric-values field filter-field filter-value))
         (n (length values)))
    (if (< n 1)
        (message "No values found for %s" field)
      (let* ((q1 (tabularium--calculate-percentile values 25))
             (median (tabularium--calculate-percentile values 50))
             (q3 (tabularium--calculate-percentile values 75))
             (filter-info (if (and filter-field filter-value (not (string-empty-p filter-value)))
                              (format " (where %s ≈ %s)" filter-field filter-value)
                            "")))
        (message "%s%s: %.2f [%.2f - %.2f] (n = %d)" field filter-info median q1 q3 n)))))

;;; *** 7.5.3 Visible Statistics

(defun tabularium-aggregate-visible-sum ()
  "Calculate sum of a numeric field for currently visible entries."
  (interactive)
  (unless (derived-mode-p 'tabularium-view-mode)
    (user-error "Not in tabularium-view-mode"))
  (let* ((numeric-fields (cl-remove-if-not
                          (lambda (f)
                            (and (memq (plist-get f :type) '(integer number))
                                 (not (plist-get f :hidden))))
                          (tabularium--schema-fields)))
         (field-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) numeric-fields))
         (prompt (completing-read "Sum field: " field-names nil t))
         (field (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :id)) prompt))
                            numeric-fields))
         (field-idx (cl-position field
                                 (cl-remove-if (lambda (f) (plist-get f :hidden))
                                               (tabularium--schema-fields))))
         (sum 0)
         (max-decimals 0))
    (dolist (entry tabulated-list-entries)
      (let* ((row (cadr entry))
             (val-str (aref row field-idx))
             (val (string-to-number val-str))
             (dot-pos (string-match "\\." val-str))
             (decimals (if dot-pos (- (length val-str) dot-pos 1) 0)))
        (setq max-decimals (max max-decimals decimals))
        (setq sum (+ sum val))))
    (message "Sum of %s (visible): %s" prompt
             (if (> max-decimals 0)
                 (format (format "%%.%df" max-decimals) sum)
               (format "%d" (round sum))))))

(defun tabularium--visible-numeric-field ()
  "Prompt for a visible numeric field.
Returns (PROMPT FIELD-IDX FIELD-TYPE)."
  (unless (derived-mode-p 'tabularium-view-mode)
    (user-error "Not in tabularium-view-mode"))
  (let* ((numeric-fields (cl-remove-if-not
                          (lambda (f)
                            (and (memq (plist-get f :type) '(integer number))
                                 (not (plist-get f :hidden))))
                          (tabularium--schema-fields)))
         (field-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) numeric-fields))
         (prompt (completing-read "Field: " field-names nil t))
         (field (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :id)) prompt))
                            numeric-fields))
         (field-idx (cl-position field
                                 (cl-remove-if (lambda (f) (plist-get f :hidden))
                                               (tabularium--schema-fields)))))
    (list prompt field-idx (plist-get field :type))))

(defun tabularium--visible-field-values (field-idx)
  "Extract numeric values from visible rows at FIELD-IDX."
  (let ((vals '()))
    (dolist (entry tabulated-list-entries)
      (let* ((val-str (aref (cadr entry) field-idx))
             (val (and (not (string-empty-p val-str))
                       (string-to-number val-str))))
        (when (and val (not (zerop val))
                   (not (string-empty-p val-str)))
          (push val vals))
        ;; Include actual zero if the string is "0" or "0.0" etc
        (when (and (not (string-empty-p val-str))
                   (zerop (string-to-number val-str))
                   (string-match-p "^0" val-str))
          (push 0 vals))))
    (sort vals #'<)))

(defun tabularium-aggregate-visible-min-max ()
  "Show min and max of a numeric field for visible entries."
  (interactive)
  (pcase-let ((`(,name ,idx ,_type) (tabularium--visible-numeric-field)))
    (let ((vals (tabularium--visible-field-values idx)))
      (if vals
          (message "%s (visible): min = %s, max = %s"
                   name (car vals) (car (last vals)))
        (message "%s (visible): no numeric values" name)))))

(defun tabularium-aggregate-visible-mean-sd ()
  "Show mean ± SD of a numeric field for visible entries."
  (interactive)
  (pcase-let ((`(,name ,idx ,_type) (tabularium--visible-numeric-field)))
    (let ((vals (tabularium--visible-field-values idx)))
      (if (< (length vals) 2)
          (message "%s (visible): need at least 2 values" name)
        (let* ((n (length vals))
               (mean (/ (apply #'+ vals) (float n)))
               (sq-diffs (mapcar (lambda (v) (expt (- v mean) 2)) vals))
               (sd (sqrt (/ (apply #'+ sq-diffs) (float (1- n))))))
          (message "%s (visible): %.2f ± %.2f (n = %d)" name mean sd n))))))

(defun tabularium-aggregate-visible-median-iqr ()
  "Show median [Q1–Q3] of a numeric field for visible entries."
  (interactive)
  (pcase-let ((`(,name ,idx ,_type) (tabularium--visible-numeric-field)))
    (let ((vals (tabularium--visible-field-values idx)))
      (if (null vals)
          (message "%s (visible): no numeric values" name)
        (let* ((n (length vals))
               (median (tabularium--calculate-percentile vals 50))
               (q1 (tabularium--calculate-percentile vals 25))
               (q3 (tabularium--calculate-percentile vals 75)))
          (message "%s (visible): %.2f [%.2f – %.2f] (n = %d)"
                   name median q1 q3 n))))))

;;; *** 7.5.4 Column Summary

(defun tabularium-aggregate-column-summary (field)
  "Show comprehensive column summary for FIELD.
Adapts output based on column type: numeric columns get
descriptive statistics (mean, median, SD, IQR, range) while
all columns get metadata, null counts, unique value counts,
and a frequency table (all values if ≤20 unique, otherwise
top 10 and bottom 5)."
  (interactive
   (let ((field-names (tabularium--stored-field-names)))
     (list (completing-read "Column summary: " field-names nil t))))
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (field-spec (cl-find field (tabularium--schema-fields)
                              :key (lambda (f) (symbol-name (plist-get f :id)))
                              :test #'string=))
         (field-type (or (and field-spec (plist-get field-spec :type)) 'text))
         (numericp (memq field-type '(integer number)))
         ;; Basic counts
         (total-rows (caar (tabularium-db-query
                            tabularium--db
                            (format "SELECT COUNT(*) FROM %s" tabularium-table-name))))
         (non-null (caar (tabularium-db-query
                          tabularium--db
                          (format "SELECT COUNT(%s) FROM %s WHERE %s IS NOT NULL AND %s != ''"
                                  field tabularium-table-name field field))))
         (null-count (- total-rows non-null))
         (unique-count (caar (tabularium-db-query
                              tabularium--db
                              (format "SELECT COUNT(DISTINCT %s) FROM %s WHERE %s IS NOT NULL AND %s != ''"
                                      field tabularium-table-name field field))))
         ;; Frequency table
         (freq-results (tabularium-db-query
                        tabularium--db
                        (format "SELECT %s, COUNT(*) as cnt FROM %s WHERE %s IS NOT NULL AND %s != '' GROUP BY %s ORDER BY cnt DESC"
                                field tabularium-table-name field field field)))
         (box-width 80)
         (buf (get-buffer-create (format "*%s: %s*" schema-name field))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Header
        (insert (propertize (tabularium--make-box-header
                             (format "%s: %s" schema-name field) box-width 'single)
                            'face 'font-lock-keyword-face)
                "\n\n")
        ;; Column info
        (insert (propertize "  ─── Column Info ───\n" 'face 'bold))
        (insert (format "  Type:       %s\n" field-type))
        (insert (format "  Total:      %d\n" total-rows))
        (insert (format "  Non-null:   %d\n" non-null))
        (insert (format "  Null/empty: %d (%.1f%%)\n"
                        null-count
                        (if (> total-rows 0)
                            (* 100.0 (/ null-count (float total-rows)))
                          0.0)))
        (insert (format "  Unique:     %d\n" unique-count))
        ;; Numeric descriptive statistics
        (when numericp
          (let* ((values (tabularium--get-numeric-values field))
                 (n (length values)))
            (when (> n 0)
              (let* ((sum (cl-reduce #'+ values))
                     (mean (/ sum (float n)))
                     (sd (if (> n 1) (tabularium--calculate-std-dev values mean) 0))
                     (min-val (car values))
                     (max-val (car (last values)))
                     (q1 (tabularium--calculate-percentile values 25))
                     (med (tabularium--calculate-percentile values 50))
                     (q3 (tabularium--calculate-percentile values 75)))
                (insert "\n")
                (insert (propertize "  ─── Descriptive Statistics ───\n" 'face 'bold))
                (insert (format "  N:              %d\n" n))
                (insert (format "  Sum:            %.2f\n" sum))
                (insert (format "  Mean ± SD:      %.2f ± %.2f\n" mean sd))
                (insert (format "  Median [IQR]:   %.2f [%.2f, %.2f]\n" med q1 q3))
                (insert (format "  Range:          %.2f – %.2f\n" min-val max-val))))))
        ;; Frequency table
        (when freq-results
          (let* ((n-results (length freq-results))
                 (show-all (<= n-results 20))
                 (freq-total (cl-reduce #'+ (mapcar #'cadr freq-results)))
                 (most (if show-all freq-results (seq-take freq-results 10)))
                 (least (unless show-all (seq-take (reverse freq-results) 5)))
                 ;; Size the value/count columns across every row that will be
                 ;; displayed (most- and least-common together), so long names
                 ;; in the least-common block stay aligned.  Values are capped
                 ;; at 30 columns; counts at their widest rendering.
                 (displayed (append most least))
                 (valw (apply #'max 5
                              (mapcar (lambda (r)
                                        (min 30 (length (format "%s" (or (car r) "(empty)")))))
                                      displayed)))
                 (cntw (apply #'max 5
                              (mapcar (lambda (r)
                                        (length (number-to-string (cadr r))))
                                      displayed)))
                 (hdr (format (format "  %%-%ds  %%%ds  %%6s\n" valw cntw)
                              "Value" "Count" "%"))
                 (sep (concat "  " (make-string (+ valw cntw 10) ?─) "\n"))
                 (rowfmt (format "  %%-%ds  %%%dd  %%5.1f%%%%\n" valw cntw)))
            (cl-flet ((emit-row
                       (row)
                       (let* ((raw (format "%s" (or (car row) "(empty)")))
                              (val (if (> (length raw) 30)
                                       (concat (substring raw 0 27) "...")
                                     raw))
                              (cnt (cadr row)))
                         (insert (format rowfmt val cnt
                                         (* 100.0 (/ cnt (float freq-total))))))))
              (insert "\n")
              (insert (propertize (format "  ─── Values (%d unique) ───\n" n-results)
                                  'face 'bold))
              (insert "\n")
              (if show-all
                  (progn
                    (insert hdr sep)
                    (dolist (row freq-results) (emit-row row)))
                ;; Most common
                (insert (propertize "  Most common\n" 'face 'bold))
                (insert "\n" hdr sep)
                (dolist (row most) (emit-row row))
                (when (> n-results 15)
                  (insert (format "\n  ... %d more ...\n\n" (- n-results 15))))
                ;; Least common
                (insert (propertize "  Least common\n" 'face 'bold))
                (insert "\n" hdr sep)
                (dolist (row least) (emit-row row))))))
        ;; Footer
        (insert "\n")
        (insert (propertize (tabularium--make-box-footer box-width 'single) 'face 'font-lock-keyword-face) "\n")
        (insert "  " (propertize "q" 'face 'help-key-binding) " Quit   "
                (propertize "g" 'face 'help-key-binding) "/"
                (propertize "=" 'face 'help-key-binding) " Refresh\n"))
      (tabularium-summary-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defvar tabularium-summary-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'revert-buffer)
    (define-key map (kbd "=") #'revert-buffer)
    map)
  "Keymap for `tabularium-summary-mode'.")

(define-derived-mode tabularium-summary-mode special-mode "Tabularium Summary"
  "Mode for displaying Tabularium column summaries."
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (when-let ((field (save-excursion
                                    (goto-char (point-min))
                                    (when (re-search-forward "\\]: \\([^ ]+\\)" nil t)
                                      (match-string 1)))))
                  (tabularium-aggregate-column-summary field)))))

;;; ** 7.6 Fill Operations

(defun tabularium--find-blank-range-down (field-name)
  "Find consecutive blank row IDs downward from point for FIELD-NAME.
Returns a list of row IDs where FIELD-NAME is blank (nil or empty),
starting from the current row and stopping at the first filled row."
  (let ((ids '())
        (field-sym (intern field-name)))
    (save-excursion
      (while (and (not (eobp))
                  (when-let ((id (tabulated-list-get-id)))
                    (let* ((record (tabularium--get-record-by-id id))
                           (val (alist-get field-sym record)))
                      (when (or (null val) (string-empty-p (format "%s" val)))
                        (push id ids)
                        t))))
        (forward-line 1)))
    (nreverse ids)))

(defun tabularium--find-blank-range-up (field-name)
  "Find consecutive blank row IDs upward from point for FIELD-NAME.
Returns a list of row IDs (in top-to-bottom order) where FIELD-NAME
is blank, starting from the current row and stopping at the first
filled row."
  (let ((ids '())
        (field-sym (intern field-name)))
    (save-excursion
      (while (and (not (bobp))
                  (when-let ((id (tabulated-list-get-id)))
                    (let* ((record (tabularium--get-record-by-id id))
                           (val (alist-get field-sym record)))
                      (when (or (null val) (string-empty-p (format "%s" val)))
                        (push id ids)
                        t))))
        (forward-line -1)))
    ids))

(defun tabularium--fill-source-choice (field-name)
  "Prompt for fill source: copy from a row or type a value directly.
FIELD-NAME is the field being filled.  Returns the chosen value.
Select <<ROW>> to copy from a specific row; select an existing value
from the list; or type any new value directly.
For `:choice' fields, the candidate list is restricted to the
field's allowed choices and selection is enforced."
  (let* ((choices (tabularium--field-choices field-name))
         (existing (if choices choices
                     (tabularium--get-historical-values field-name 20)))
         (candidates (cons "<<ROW>>" existing))
         (require-match (if choices t nil))
         (choice (completing-read (format "Fill '%s' with: " field-name)
                                  candidates nil require-match nil nil "<<ROW>>")))
    (cond
     ((string= choice "<<ROW>>")
      (let* ((default-id (tabularium--id-at-point))
             (source-id (read-number "Source row ID: " default-id))
             (record (tabularium--get-record-by-id source-id)))
        (alist-get (intern field-name) record)))
     (t choice))))

(defun tabularium--fill-execute (field source-value &optional direction)
  "Execute fill: set FIELD to SOURCE-VALUE.
When marks are set, fills marked rows (prompting to overwrite non-blank cells).
When no marks are set, fills blank cells from point in DIRECTION
\(\\='down or \\='up, default \\='down).  Undoable.
Errors with a clear message when FIELD is a `:choice' field and
SOURCE-VALUE is not among the allowed choices."
  (unless (tabularium--field-accepts-value-p field source-value)
    (let ((choices (tabularium--field-choices field)))
      (user-error "Cannot fill '%s' with '%s': allowed choices are %s"
                  field source-value
                  (mapconcat (lambda (c) (format "'%s'" c)) choices ", "))))
  (let* ((has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0)))
         (field-sym (intern field))
         (ids (if has-marks
                  (copy-sequence tabularium--marked-entries)
                (if (eq direction 'up)
                    (tabularium--find-blank-range-up field)
                  (tabularium--find-blank-range-down field)))))
    (unless ids
      (user-error "No blank cells to fill from point"))
    (let ((ops '())
          (filled 0))
      ;; Check for non-blank cells in marked set
      (when has-marks
        (let* ((non-blank (cl-remove-if
                           (lambda (id)
                             (let* ((rec (tabularium--get-record-by-id id))
                                    (val (alist-get field-sym rec)))
                               (or (null val) (string-empty-p (format "%s" val)))))
                           ids))
               (overwrite (and non-blank
                               (yes-or-no-p
                                (format "%d of %d marked rows have values.  Overwrite? "
                                        (length non-blank) (length ids))))))
          (unless overwrite
            ;; Only fill blanks among the marked rows
            (setq ids (cl-remove-if
                       (lambda (id)
                         (let* ((rec (tabularium--get-record-by-id id))
                                (val (alist-get field-sym rec)))
                           (and val (not (string-empty-p (format "%s" val))))))
                       ids)))))
      (tabularium-db-with-transaction tabularium--db
        (dolist (id ids)
          (let* ((record (tabularium--get-record-by-id id))
                 (old-value (alist-get field-sym record)))
            (unless (equal old-value source-value)
              (push (list :type 'update :row id :field field-sym
                          :old old-value :new source-value)
                    ops)
              (tabularium-db-update tabularium--db tabularium-table-name
                                    (list (cons field-sym source-value))
                                    (tabularium--primary-field-name) id)
              (cl-incf filled)))))
      (when ops
        (tabularium--undo-push (if (= 1 (length ops))
                                   (car ops)
                                 (list :type 'multi :ops (nreverse ops)))))
      (tabularium--invalidate-cache)
      (when has-marks
        (setq tabularium--marked-entries nil)
        (tabularium-view--update-mark-display))
      (revert-buffer)
      (message "Filled %d row%s" filled (if (= filled 1) "" "s")))))

(defun tabularium-view-fill-backward ()
  "Fill backward from point: propagate a value into blank cells above.
Uses the current column.  If the cell at point is non-blank, fills
consecutive blank cells above with its value.  If the cell at point
is blank, finds the nearest non-blank value below and fills from
point upward.  With marks, fills the marked rows instead.  The
mirror of `tabularium-view-fill-forward'.  Undoable."
  (interactive)
  (let* ((col-name (or (tabularium--column-name-at-point)
                       (user-error "No column at point")))
         (field (symbol-name col-name))
         (id (tabularium--id-at-point))
         (record (when id (tabularium--get-record-by-id id)))
         (cell-val (when record (alist-get col-name record)))
         (cell-blank (or (null cell-val)
                         (string-empty-p (format "%s" cell-val))))
         ;; Determine fill value
         (fill-value
          (if (not cell-blank)
              (format "%s" cell-val)
            ;; Scan downward for nearest non-blank value in this column
            (save-excursion
              (let ((found nil))
                (while (and (not found) (zerop (forward-line 1)))
                  (when-let ((rid (tabulated-list-get-id)))
                    (let* ((rec (tabularium--get-record-by-id rid))
                           (val (alist-get col-name rec)))
                      (when (and val (not (string-empty-p (format "%s" val))))
                        (setq found (format "%s" val))))))
                found)))))
    (unless fill-value
      (user-error "No value found below to fill from"))
    ;; When cell is non-blank, start filling from the previous row
    (unless cell-blank
      (forward-line -1))
    (tabularium--fill-execute field fill-value 'up)))

(defun tabularium-view-fill-forward ()
  "Fill forward from point: propagate a value into blank cells below.
Uses the current column.  If the cell at point is non-blank, fills
consecutive blank cells below with its value.  If the cell at point
is blank, finds the nearest non-blank value above and fills from
point downward.  With marks, fills the marked rows instead.
Undoable."
  (interactive)
  (let* ((col-name (or (tabularium--column-name-at-point)
                       (user-error "No column at point")))
         (field (symbol-name col-name))
         (id (tabularium--id-at-point))
         (record (when id (tabularium--get-record-by-id id)))
         (cell-val (when record (alist-get col-name record)))
         (cell-blank (or (null cell-val)
                         (string-empty-p (format "%s" cell-val))))
         ;; Determine fill value
         (fill-value
          (if (not cell-blank)
              (format "%s" cell-val)
            ;; Scan upward for nearest non-blank value in this column
            (save-excursion
              (let ((found nil))
                (while (and (not found) (zerop (forward-line -1)))
                  (when-let ((rid (tabulated-list-get-id)))
                    (let* ((rec (tabularium--get-record-by-id rid))
                           (val (alist-get col-name rec)))
                      (when (and val (not (string-empty-p (format "%s" val))))
                        (setq found (format "%s" val))))))
                found)))))
    (unless fill-value
      (user-error "No value found above to fill from"))
    ;; When cell is non-blank, start filling from the next row
    (unless cell-blank
      (forward-line 1))
    (tabularium--fill-execute field fill-value 'down)))

(defun tabularium-view-fill-down (field source-value)
  "Fill FIELD downward with SOURCE-VALUE from point.
Undoable.  When called interactively, offers choice of copying
from a row, entering manually, or picking from existing values."
  (interactive
   (let* ((field (completing-read "Fill down field: "
                                  (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                                          (tabularium--schema-fields))
                                  nil t))
          (value (tabularium--fill-source-choice field)))
     (list field value)))
  (tabularium--fill-execute field source-value 'down))

(defun tabularium-view-fill-up (field source-value)
  "Fill FIELD upward with SOURCE-VALUE from point.
Undoable.  When called interactively, offers choice of copying
from a row, entering manually, or picking from existing values."
  (interactive
   (let* ((field (completing-read "Fill up field: "
                                  (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                                          (tabularium--schema-fields))
                                  nil t))
          (value (tabularium--fill-source-choice field)))
     (list field value)))
  (tabularium--fill-execute field source-value 'up))

(defun tabularium-view-fill-down-to-point ()
  "Fill the blank gap that ends at point, downward from a source above.
Scans upward to find the nearest non-blank cell in the current column,
then fills every blank cell from that source down to point (inclusive)
with that value.  The fill direction is downward; point is the bottom
of the filled range.  Undoable."
  (interactive)
  (let* ((col-name (or (tabularium--column-name-at-point)
                       (user-error "No column at point")))
         (field (symbol-name col-name))
         (fill-value
          (save-excursion
            (let ((found nil))
              (while (and (not found) (zerop (forward-line -1)))
                (when-let ((rid (tabulated-list-get-id)))
                  (let* ((rec (tabularium--get-record-by-id rid))
                         (val (alist-get col-name rec)))
                    (when (and val (not (string-empty-p (format "%s" val))))
                      (setq found (format "%s" val))))))
              found))))
    (unless fill-value
      (user-error "No value found above to fill from"))
    (tabularium--fill-execute field fill-value 'up)))

(defun tabularium-view-fill-up-to-point ()
  "Fill the blank gap that starts at point, upward from a source below.
Scans downward to find the nearest non-blank cell in the current column,
then fills every blank cell from that source up to point (inclusive)
with that value.  The fill direction is upward; point is the top of
the filled range.  Undoable."
  (interactive)
  (let* ((col-name (or (tabularium--column-name-at-point)
                       (user-error "No column at point")))
         (field (symbol-name col-name))
         (fill-value
          (save-excursion
            (let ((found nil))
              (while (and (not found) (zerop (forward-line 1)))
                (when-let ((rid (tabulated-list-get-id)))
                  (let* ((rec (tabularium--get-record-by-id rid))
                         (val (alist-get col-name rec)))
                    (when (and val (not (string-empty-p (format "%s" val))))
                      (setq found (format "%s" val))))))
              found))))
    (unless fill-value
      (user-error "No value found below to fill from"))
    (tabularium--fill-execute field fill-value 'down)))

(defun tabularium--fill-series-read-args ()
  "Read FIELD, START, and INCREMENT for a fill-series command.
Returns a list (FIELD START INCREMENT) for the interactive spec of
the fill-series commands.  START may be copied from a row, picked
from existing values, or entered directly."
  (let* ((fillable-types '(integer number date))
         (field (completing-read "Fill series in field: "
                                 (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                                         (cl-remove-if-not
                                          (lambda (f) (memq (plist-get f :type) fillable-types))
                                          (tabularium--schema-fields)))
                                 nil t))
         (field-def (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :id)) field))
                                (tabularium--schema-fields)))
         (field-type (plist-get field-def :type))
         (existing (tabularium--get-historical-values field 20))
         (has-data (and existing (car existing)
                        (not (string-empty-p (format "%s" (car existing)))))))
    (if (eq field-type 'date)
        ;; Date field: smart source selection
        (let* ((today (format-time-string tabularium-date-format))
               (source-choices (append (when has-data '("<<ROW>>"))
                                       (mapcar (lambda (v) (format "%s" v)) existing)))
               (choice (completing-read (format "Start date for '%s': " field)
                                        source-choices nil nil nil nil
                                        (if has-data "<<ROW>>" today)))
               (start (cond
                       ((string= choice "<<ROW>>")
                        (let* ((default-id (tabularium--id-at-point))
                               (source-id (read-number "Source row ID: " default-id))
                               (record (tabularium--get-record-by-id source-id)))
                          (format "%s" (alist-get (intern field) record))))
                       (t (if (string-empty-p choice) today choice))))
               (increment (read-number "Increment (days): " 1)))
          (list field start increment))
      ;; Numeric field: smart source selection
      (let* ((source-choices (append (when has-data '("<<ROW>>"))
                                     (mapcar (lambda (v) (format "%s" v)) existing)))
             (choice (completing-read (format "Start value for '%s': " field)
                                      source-choices nil nil nil nil nil))
             (start (cond
                     ((string= choice "<<ROW>>")
                      (let* ((default-id (tabularium--id-at-point))
                             (source-id (read-number "Source row ID: " default-id))
                             (record (tabularium--get-record-by-id source-id))
                             (val (alist-get (intern field) record)))
                        (if (numberp val) val
                          (string-to-number (format "%s" val)))))
                     ((or (null choice) (string-empty-p choice))
                      (read-number "Start value: " 1))
                     (t (string-to-number choice))))
             (increment (read-number "Increment: " 1)))
        (list field start increment)))))

(defun tabularium--fill-series-fill (field start increment direction)
  "Fill FIELD with a series from point in DIRECTION (\\='down or \\='up).
START is the value at point; successive cells away from point in
DIRECTION step by INCREMENT.  For date fields START is a date string
and INCREMENT a number of days.  With marks, fills the marked rows in
ascending ID order.  Undoable."
  (let* ((has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0)))
         (field-def (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :id)) field))
                                (tabularium--schema-fields)))
         (field-type (plist-get field-def :type))
         (is-date (eq field-type 'date))
         (field-sym (intern field))
         (ids (cond
               (has-marks
                (cl-sort (copy-sequence tabularium--marked-entries) #'<))
               ((eq direction 'up)
                (reverse (tabularium--find-blank-range-up field)))
               (t
                (tabularium--find-blank-range-down field))))
         ;; For dates, parse the start date to a time value for incrementing
         (date-time (when is-date
                      (let ((parsed (parse-time-string start)))
                        (encode-time (or (nth 0 parsed) 0)
                                     (or (nth 1 parsed) 0)
                                     (or (nth 2 parsed) 0)
                                     (or (nth 3 parsed) 1)
                                     (or (nth 4 parsed) 1)
                                     (or (nth 5 parsed) 2000))))))
    (unless ids
      (user-error "No blank cells to fill from point"))
    ;; When marks are set, check for non-blank cells
    (when has-marks
      (let* ((non-blank (cl-remove-if
                         (lambda (id)
                           (let* ((rec (tabularium--get-record-by-id id))
                                  (val (alist-get field-sym rec)))
                             (or (null val) (string-empty-p (format "%s" val)))))
                         ids))
             (overwrite (and non-blank
                             (yes-or-no-p
                              (format "%d of %d marked rows have values.  Overwrite? "
                                      (length non-blank) (length ids))))))
        (unless overwrite
          (setq ids (cl-remove-if
                     (lambda (id)
                       (let* ((rec (tabularium--get-record-by-id id))
                              (val (alist-get field-sym rec)))
                         (and val (not (string-empty-p (format "%s" val))))))
                     ids)))))
    (let ((count (length ids))
          (preview (if is-date
                       (let ((d2 (time-add date-time (days-to-time increment)))
                             (d3 (time-add date-time (days-to-time (* 2 increment)))))
                         (format "%s, %s, %s..."
                                 start
                                 (format-time-string tabularium-date-format d2)
                                 (format-time-string tabularium-date-format d3)))
                     (format "%s, %s, %s..."
                             start (+ start increment) (+ start (* 2 increment))))))
      (when (yes-or-no-p (format "Fill '%s' with series %s for %d rows? "
                                 field preview count))
        (let ((ops '())
              (current-val (if is-date date-time start)))
          (tabularium-db-with-transaction tabularium--db
            (dolist (id ids)
              (let* ((record (tabularium--get-record-by-id id))
                     (old-value (alist-get field-sym record))
                     (new-value (if is-date
                                    (format-time-string tabularium-date-format current-val)
                                  current-val)))
                (push (list :type 'update :row id :field field-sym
                            :old old-value :new new-value)
                      ops)
                (tabularium-db-update tabularium--db tabularium-table-name
                                  (list (cons field-sym new-value))
                                  (tabularium--primary-field-name) id)
                (setq current-val (if is-date
                                      (time-add current-val (days-to-time increment))
                                    (+ current-val increment))))))
          (when ops
            (tabularium--undo-push (list :type 'multi :ops (nreverse ops)))))
        (tabularium--invalidate-cache)
        (when has-marks
          (setq tabularium--marked-entries nil)
          (tabularium-view--update-mark-display))
        (revert-buffer)
        (message "Filled series in %d rows" count)))))

(defun tabularium-view-fill-series (field start increment)
  "Fill FIELD downward with a series starting at START with INCREMENT.
For numeric fields (integer, number), START and INCREMENT are numbers.
For date fields, START is a date string and INCREMENT is a number of days.
The mirror of `tabularium-view-fill-series-up'.  Undoable."
  (interactive (tabularium--fill-series-read-args))
  (tabularium--fill-series-fill field start increment 'down))

(defun tabularium-view-fill-series-up (field start increment)
  "Fill FIELD upward with a series starting at START with INCREMENT.
Like `tabularium-view-fill-series' but fills the blank run above
point; START is the value at point and successive cells upward step
by INCREMENT.  Undoable."
  (interactive (tabularium--fill-series-read-args))
  (tabularium--fill-series-fill field start increment 'up))

(defun tabularium--fill-run-ids (col-name direction)
  "Return row IDs of the same-value run from point in DIRECTION.
DIRECTION is \\='down or \\='up.  The run is the maximal block of
consecutive rows (starting at point and moving in DIRECTION) whose
COL-NAME value equals the value at point.  With marked rows active,
returns those instead (DIRECTION is ignored)."
  (let ((has-marks (and tabularium--marked-entries
                        (> (length tabularium--marked-entries) 0))))
    (if has-marks
        (copy-sequence tabularium--marked-entries)
      (let* ((current-id (or (tabulated-list-get-id)
                             (user-error "No row at point")))
             (start-rec (tabularium--get-record-by-id current-id))
             (ref-val (format "%s" (or (alist-get col-name start-rec) "")))
             (run '()))
        (save-excursion
          (if (eq direction 'up)
              ;; Read the current row *before* the `bobp' check so row #1
              ;; (which may sit at `point-min') is not skipped.
              (cl-block bwd
                (while t
                  (when-let ((id (tabulated-list-get-id)))
                    (let* ((rec (tabularium--get-record-by-id id))
                           (val (format "%s" (or (alist-get col-name rec) ""))))
                      (if (string= val ref-val)
                          (push id run)
                        (cl-return-from bwd))))
                  (when (bobp) (cl-return-from bwd))
                  (forward-line -1)))
            (cl-block fwd
              (while t
                (when-let ((id (tabulated-list-get-id)))
                  (let* ((rec (tabularium--get-record-by-id id))
                         (val (format "%s" (or (alist-get col-name rec) ""))))
                    (if (string= val ref-val)
                        (push id run)
                      (cl-return-from fwd))))
                (when (eobp) (cl-return-from fwd))
                (forward-line 1)
                (when (eobp) (cl-return-from fwd))))))
        (when (or (null run)
                  (and (= 1 (length run)) (string-empty-p ref-val)))
          (user-error "No matching cells from point"))
        run))))

(defun tabularium-view-fill-delete ()
  "Delete a same-value run in the current column downward from point.
Scans downward through consecutive cells that share the value at
point and clears them all.  With marks, clears the current column in
marked rows instead.  The mirror of `tabularium-view-fill-delete-up'.
Undoable."
  (interactive)
  (let ((col-name (or (tabularium--column-name-at-point)
                      (user-error "No column at point"))))
    (tabularium--fill-clear (tabularium--fill-run-ids col-name 'down) col-name)))

(defun tabularium-view-fill-delete-up ()
  "Delete a same-value run in the current column upward from point.
Scans upward through consecutive cells that share the value at point
and clears them all.  With marks, clears the current column in marked
rows instead.  Undoable."
  (interactive)
  (let ((col-name (or (tabularium--column-name-at-point)
                      (user-error "No column at point"))))
    (tabularium--fill-clear (tabularium--fill-run-ids col-name 'up) col-name)))

(defun tabularium-view-fill-replace ()
  "Replace a same-value run in the current column downward from point.
Scans downward through consecutive cells that share the value at
point and sets them all to a prompted replacement value.  With marks,
replaces the current column in marked rows instead.  The mirror of
`tabularium-view-fill-replace-up'.  Undoable."
  (interactive)
  (let* ((col-name (or (tabularium--column-name-at-point)
                       (user-error "No column at point")))
         (field (symbol-name col-name))
         (ids (tabularium--fill-run-ids col-name 'down))
         (value (tabularium--fill-source-choice field)))
    (tabularium--fill-set-rows ids col-name value "Replace" "Replaced")))

(defun tabularium-view-fill-replace-up ()
  "Replace a same-value run in the current column upward from point.
Scans upward through consecutive cells that share the value at point
and sets them all to a prompted replacement value.  With marks,
replaces the current column in marked rows instead.  Undoable."
  (interactive)
  (let* ((col-name (or (tabularium--column-name-at-point)
                       (user-error "No column at point")))
         (field (symbol-name col-name))
         (ids (tabularium--fill-run-ids col-name 'up))
         (value (tabularium--fill-source-choice field)))
    (tabularium--fill-set-rows ids col-name value "Replace" "Replaced")))

(defun tabularium--fill-clear-rows (target-id include-point)
  "Return the row IDs to clear for a fill-clear command.
TARGET-ID is the far endpoint of the range measured from point;
INCLUDE-POINT controls whether the row at point is part of the
range.  With marked rows active, returns those (INCLUDE-POINT is
ignored)."
  (let ((has-marks (and tabularium--marked-entries
                        (> (length tabularium--marked-entries) 0)))
        (point-id (tabulated-list-get-id)))
    (if has-marks
        (copy-sequence tabularium--marked-entries)
      (let ((start-id (or point-id (user-error "No row at point")))
            (range '()))
        (save-excursion
          (if (<= start-id target-id)
              ;; Forward range: read the current row, then advance.
              (cl-block fwd
                (while t
                  (when-let ((id (tabulated-list-get-id)))
                    (if (<= id target-id)
                        (push id range)
                      (cl-return-from fwd)))
                  (when (eobp) (cl-return-from fwd))
                  (forward-line 1)
                  (when (eobp) (cl-return-from fwd))))
            ;; Backward range: read the current row, then step up.
            ;; The current row must be read *before* the `bobp' check —
            ;; when row #1 sits at `point-min', testing `bobp' first
            ;; would skip it (the row-#1 bug).
            (cl-block bwd
              (while t
                (when-let ((id (tabulated-list-get-id)))
                  (if (>= id target-id)
                      (push id range)
                    (cl-return-from bwd)))
                (when (bobp) (cl-return-from bwd))
                (forward-line -1)))))
        (setq range (if include-point range (remove point-id range)))
        (unless range
          (user-error "No rows in range"))
        range))))

(defun tabularium--fill-clear (ids col-name)
  "Blank COL-NAME in the rows whose IDs are in IDS.  Undoable.
Shared worker for the fill-clear commands."
  (let* ((field (symbol-name col-name))
         (has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0))))
    (when (yes-or-no-p (format "Clear '%s' in %d rows? " field (length ids)))
      (let ((ops '())
            (cleared 0))
        (tabularium-db-with-transaction tabularium--db
          (dolist (id ids)
            (let* ((record (tabularium--get-record-by-id id))
                   (old-value (alist-get col-name record)))
              (when (and old-value (not (string-empty-p (format "%s" old-value))))
                (push (list :type 'update :row id :field col-name
                            :old old-value :new "")
                      ops)
                (tabularium-db-update tabularium--db tabularium-table-name
                                      (list (cons col-name ""))
                                      (tabularium--primary-field-name) id)
                (cl-incf cleared)))))
        (when ops
          (tabularium--undo-push (if (= 1 (length ops))
                                     (car ops)
                                   (list :type 'multi :ops (nreverse ops)))))
        (tabularium--invalidate-cache)
        (when has-marks
          (setq tabularium--marked-entries nil)
          (tabularium-view--update-mark-display))
        (revert-buffer)
        (message "Cleared %d row%s" cleared (if (= cleared 1) "" "s"))))))

(defun tabularium--fill-set-rows (ids col-name value prompt-verb done-verb)
  "Set COL-NAME to VALUE in the rows whose IDs are in IDS.  Undoable.
PROMPT-VERB (e.g. \"Replace\") heads the confirmation prompt and
DONE-VERB (e.g. \"Replaced\") the result message.  Cells already
holding VALUE are skipped.  With marked rows active, marks are
cleared afterward.  Shared worker for the fill-replace commands."
  (let* ((field (symbol-name col-name))
         (has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0)))
         (value-str (format "%s" value)))
    (when (yes-or-no-p (format "%s '%s' in %d rows? " prompt-verb field (length ids)))
      (let ((ops '())
            (changed 0))
        (tabularium-db-with-transaction tabularium--db
          (dolist (id ids)
            (let* ((record (tabularium--get-record-by-id id))
                   (old-value (alist-get col-name record))
                   (old-str (if old-value (format "%s" old-value) "")))
              (unless (string= old-str value-str)
                (push (list :type 'update :row id :field col-name
                            :old old-value :new value)
                      ops)
                (tabularium-db-update tabularium--db tabularium-table-name
                                      (list (cons col-name value))
                                      (tabularium--primary-field-name) id)
                (cl-incf changed)))))
        (when ops
          (tabularium--undo-push (if (= 1 (length ops))
                                     (car ops)
                                   (list :type 'multi :ops (nreverse ops)))))
        (tabularium--invalidate-cache)
        (when has-marks
          (setq tabularium--marked-entries nil)
          (tabularium-view--update-mark-display))
        (revert-buffer)
        (message "%s %d row%s" done-verb changed (if (= changed 1) "" "s"))))))

(defun tabularium-view-fill-clear (target-id)
  "Clear the current column from point to TARGET-ID (inclusive).
Prompts for a target row ID, then blanks every cell in the current
column between point and that row, including the row at point.  With
marks, clears the current column in marked rows instead.  Undoable.
See `tabularium-view-fill-clear-to-point' to leave the row at point
intact."
  (interactive
   (let ((has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0))))
     (if has-marks
         (list nil)
       (list (read-number
              "Clear current column from row ID (through the current row): "
              (tabulated-list-get-id))))))
  (let ((col-name (or (tabularium--column-name-at-point)
                      (user-error "No column at point"))))
    (tabularium--fill-clear
     (tabularium--fill-clear-rows target-id t) col-name)))

(defun tabularium-view-fill-clear-to-point (target-id)
  "Clear the current column from TARGET-ID up to point, excluding point.
Prompts for a target row ID, then blanks every cell in the current
column between that row and the row at point — but leaves the row at
point itself intact.  With marks, clears the current column in marked
rows instead.  Undoable.  See `tabularium-view-fill-clear' to include
the row at point."
  (interactive
   (let ((has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0))))
     (if has-marks
         (list nil)
       (list (read-number
              "Clear current column up to row ID (not including the current row): "
              (tabulated-list-get-id))))))
  (let ((col-name (or (tabularium--column-name-at-point)
                      (user-error "No column at point"))))
    (tabularium--fill-clear
     (tabularium--fill-clear-rows target-id nil) col-name)))

;;; * 8 Import & Export

;;; ** 8.1 Basic Import/Export

;;;###autoload
(defun tabularium-import (file)
  "Import FILE (auto-detects TSV/CSV/Org) as a new database.
Always creates a new database and registers it — FILE is never
merged into the currently open database.  Use
`tabularium-import-append' to append rows to an existing database.

Prompts for the new database file; schema is inferred from the
file's header row (and column types from its data)."
  (interactive
   (list (read-file-name "Import as new database: " nil nil t nil
                         (lambda (f) (or (file-directory-p f)
                                         (string-match-p "\\.csv$\\|\\.tsv$\\|\\.org$" f))))))
  (let* ((file (expand-file-name file))
         (ext (file-name-extension file))
         (default-db (concat (file-name-sans-extension file) ".db"))
         (db-file (read-file-name "New database file: "
                                  (file-name-directory file)
                                  default-db nil
                                  (file-name-nondirectory default-db))))
    (cond
     ((string= ext "org") (tabularium-import-org file db-file))
     ((string= ext "tsv") (tabularium-import-tsv file db-file))
     (t (tabularium-import-csv file db-file)))))

(defun tabularium-import--file-to-table (file)
  "Return (HEADERS . ROWS) parsed from FILE.
Dispatches on the extension: =.org= files yield their first
table, =.tsv= and =.csv= (or anything else) are parsed as
delimited text."
  (if (string= (file-name-extension file) "org")
      (with-temp-buffer
        (insert-file-contents file)
        (org-mode)
        (or (tabularium-import--org-find-first-table)
            (user-error "No org-table found in %s"
                        (file-name-nondirectory file))))
    (tabularium-import--parse-delimited-file file)))

;;;###autoload
(defun tabularium-import-append--map-columns (headers fields primary match-by)
  "Map HEADERS to schema FIELDS by name, returning a per-column field list.
HEADERS is the list of file column names; FIELDS the schema field
plists; PRIMARY the primary-key field id.  MATCH-BY is `id' or
`label' — which field property each header is compared against.
Matching is case-insensitive.  The result has one entry per
header: the matching field plist, or nil for an unmatched header
or one that maps to the primary key (which is never written)."
  (let ((field-key (if (eq match-by 'label)
                       (lambda (f) (or (plist-get f :label)
                                       (symbol-name (plist-get f :id))))
                     (lambda (f) (symbol-name (plist-get f :id))))))
    (mapcar (lambda (h)
              (let ((field (cl-find-if
                            (lambda (f)
                              (string-equal-ignore-case
                               (funcall field-key f) h))
                            fields)))
                (and field
                     (not (eq (plist-get field :id) primary))
                     field)))
            headers)))

;;;###autoload
(defun tabularium-import-append (file &optional match-by)
  "Append the rows of FILE to the currently open database.
FILE may be CSV, TSV, or an Org file (its first table is used).
Columns are matched to schema fields by header name.

By default the match is attempted against the field ids first,
and only if that matches no columns at all is it retried against
the human-readable field labels.  Field ids are the common case —
a file Tabularium itself exported uses ids as headers — while
labels cover hand-written or spreadsheet-exported files.  MATCH-BY,
when given non-interactively, forces a single mode (`id' or
`label') with no fallback.

Column order in FILE need not match the schema; headers with no
matching field are ignored.  Matching is case-insensitive.

The primary-key column is deliberately never written even if FILE
contains one — the database assigns fresh IDs to the appended
rows, so importing a file that carries its own ID column cannot
collide with existing rows.

Requires a database to be open; use `tabularium-import' to import
a file as a new database instead."
  (interactive
   (list (read-file-name "Append file to current database: " nil nil t nil
                         (lambda (f) (or (file-directory-p f)
                                         (string-match-p "\\.csv$\\|\\.tsv$\\|\\.org$" f))))))
  (unless (and tabularium--current-schema-name tabularium--db)
    (user-error "No database open — use `tabularium-import' to import as new"))
  (let* ((file (expand-file-name file))
         (table (tabularium--import-append-table file))
         (headers (mapcar (lambda (h) (string-trim (format "%s" h)))
                          (car table)))
         (rows (cdr table))
         (fields (tabularium--schema-fields))
         (primary (tabularium--primary-field-name))
         ;; Resolve the column mapping.  With an explicit MATCH-BY use
         ;; exactly that mode; otherwise try `id' and fall back to
         ;; `label' only if `id' matched nothing.
         (used-mode match-by)
         (col-fields
          (cond
           (match-by
            (tabularium-import-append--map-columns
             headers fields primary match-by))
           (t
            (let ((by-id (tabularium-import-append--map-columns
                          headers fields primary 'id)))
              (if (delq nil (copy-sequence by-id))
                  (progn (setq used-mode 'id) by-id)
                (setq used-mode 'label)
                (tabularium-import-append--map-columns
                 headers fields primary 'label))))))
         (matched (delq nil (copy-sequence col-fields)))
         (imported 0)
         (skipped 0))
    (when (null matched)
      (user-error
       "No file columns match schema fields (headers: %s)"
       (string-join headers ", ")))
    (tabularium-db-with-transaction tabularium--db
      (dolist (values rows)
        (if (or (null values)
                (cl-every (lambda (v) (or (null v)
                                          (string-empty-p (format "%s" v))))
                          values))
            (cl-incf skipped)
          (condition-case _err
              (let ((alist '()))
                (cl-loop for field in col-fields
                         for value in values
                         when field
                         do (push (cons (plist-get field :id)
                                        (tabularium--import-coerce-value
                                         value (plist-get field :type)))
                                  alist))
                (tabularium-db-insert tabularium--db tabularium-table-name
                                      (nreverse alist))
                (cl-incf imported))
            (error (cl-incf skipped))))))
    (tabularium--invalidate-cache)
    (when (derived-mode-p 'tabularium-view-mode)
      (revert-buffer))
    (message "Appended %d record%s to '%s' (matched columns by %s)%s"
             imported (if (= imported 1) "" "s")
             tabularium--current-schema-name
             (if (eq used-mode 'label) "label" "ID")
             (if (> skipped 0) (format ", skipped %d" skipped) ""))))

(defun tabularium--import-append-table (file)
  "Return (HEADERS . ROWS) for FILE, for use by `tabularium-import-append'.
Thin wrapper around `tabularium-import--file-to-table' kept as a
separate name so the append path has a stable internal entry point."
  (tabularium--import-file-to-table-checked file))

(defun tabularium--import-file-to-table-checked (file)
  "Return (HEADERS . ROWS) for FILE, signaling if it has no data rows."
  (let ((table (tabularium-import--file-to-table file)))
    (unless (car table)
      (user-error "No header row found in %s"
                  (file-name-nondirectory file)))
    table))

(defun tabularium--import-coerce-value (value type)
  "Coerce a string VALUE from an imported file to schema TYPE.
Integer and number fields parse numerically (empty stays nil);
all other types keep the string as-is."
  (pcase type
    ('integer (if (and value (not (string-empty-p (format "%s" value))))
                  (string-to-number (format "%s" value))
                nil))
    ('number (if (and value (not (string-empty-p (format "%s" value))))
                 (string-to-number (format "%s" value))
               nil))
    (_ value)))

(defun tabularium--escape-field (value separator)
  "Escape VALUE for RFC 4180-compliant export with SEPARATOR."
  (let ((s (if value (format "%s" value) "")))
    (if (or (string-match-p (regexp-quote (char-to-string separator)) s)
            (string-match-p "[\"\n\r]" s))
        (format "\"%s\"" (replace-regexp-in-string "\"" "\"\"" s))
      s)))

;;;###autoload
(defun tabularium-export (&optional file format ignore-marks columns)
  "Export records to FILE in FORMAT (tsv or csv).
Exports the marked rows if any are marked, otherwise every record.
With non-nil IGNORE-MARKS (interactively, never — use
`tabularium-export-all'), marks are ignored and every record is
exported regardless.

COLUMNS, when non-nil, is a list of column-id strings limiting the
export to those columns in that order; nil means every column.
Computed columns are included and written with their computed
values rendered literally.  Interactively the columns are picked
with `completing-read-multiple'; an `<<ALL>>' entry (the default)
selects every column."
  (interactive
   (let* ((fmt (tabularium--export-read-format))
          (ext (if (eq fmt 'tsv) ".tsv" ".csv"))
          (db-name (or tabularium--current-schema-name "database"))
          (all-cols (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                            (tabularium--schema-fields)))
          (chosen (completing-read-multiple
                   "Columns [<<ALL>>, or comma-separated]: "
                   (cons "<<ALL>>" all-cols) nil nil nil nil "<<ALL>>"))
          (cols (if (or (null chosen) (member "<<ALL>>" chosen))
                    nil
                  chosen))
          (default-name (concat (file-name-sans-extension
                                 (or (tabularium--schema-export-file)
                                     (buffer-name)))
                                ext))
          (file (read-file-name
                 (if tabularium--marked-entries
                     (format "Export %d marked rows of '%s' to: "
                             (length tabularium--marked-entries) db-name)
                   (format "Export '%s' to: " db-name))
                 nil default-name)))
     (list file fmt nil cols)))
  (tabularium--ensure-db)
  (let* ((fmt (or format tabularium-export-format))
         (db-name (or tabularium--current-schema-name "database"))
         (all-fields (tabularium--schema-fields))
         ;; Restrict to COLUMNS when given, preserving the requested
         ;; order; nil COLUMNS exports every field, computed included.
         (fields (if columns
                     (let ((bad (cl-remove-if
                                 (lambda (c)
                                   (cl-find-if
                                    (lambda (f)
                                      (equal (symbol-name (plist-get f :id)) c))
                                    all-fields))
                                 columns)))
                       (when bad
                         (user-error "Unknown column(s): %s"
                                     (string-join bad ", ")))
                       (mapcar (lambda (c)
                                 (cl-find-if
                                  (lambda (f)
                                    (equal (symbol-name (plist-get f :id)) c))
                                  all-fields))
                               columns))
                   all-fields))
         (col-names (mapcar (lambda (f) (symbol-name (plist-get f :id))) fields))
         (primary-name (symbol-name (tabularium--primary-field-name)))
         (marked-ids (and (not ignore-marks) tabularium--marked-entries))
         (where (if marked-ids
                    (format "WHERE %s IN (%s)"
                            primary-name
                            (mapconcat #'number-to-string marked-ids ","))
                  ""))
         (rows (tabularium--export-compute-rows fields where primary-name)))
    (tabularium--export-write file fmt col-names rows)
    ;; Clear marks if we exported marked rows
    (when marked-ids
      (setq tabularium--marked-entries nil)
      (tabularium-view--update-mark-display))
    (message "'%s' exported to %s (%d %s, %s)"
             db-name file
             (length rows)
             (if marked-ids "marked rows" "rows")
             (upcase (symbol-name fmt)))))

;;;###autoload
(defun tabularium-export-all (&optional file format)
  "Export every record and every column to FILE in FORMAT (tsv or csv).
Identical to `tabularium-export' except that marked rows are never
treated specially and the column set is not narrowed — the whole
table is always written, computed columns included."
  (interactive
   (let* ((fmt (tabularium--export-read-format))
          (ext (if (eq fmt 'tsv) ".tsv" ".csv"))
          (default-name (concat (file-name-sans-extension
                                 (or (tabularium--schema-export-file)
                                     (buffer-name)))
                                ext))
          (file (read-file-name
                 (format "Export all of '%s' to: "
                         (or tabularium--current-schema-name "database"))
                 nil default-name)))
     (list file fmt)))
  (tabularium-export file format t nil))

;;; ** 8.1.1 Scoped Export (visible / range)

(defun tabularium--export-write (file fmt columns rows)
  "Write ROWS to FILE as FMT (`tsv' or `csv') with COLUMNS as the header.
COLUMNS is a list of column-id strings; ROWS is a list of value
lists already in the desired output order and already projected
to COLUMNS.  Prompts before overwriting an existing FILE."
  (when (and (file-exists-p file)
             (not (y-or-n-p (format "File %s exists.  Overwrite? "
                                    (file-name-nondirectory file)))))
    (user-error "Export canceled"))
  (let* ((sep (if (eq fmt 'tsv) "\t" ","))
         (sep-char (string-to-char sep)))
    (with-temp-file file
      (insert (string-join columns sep) "\n")
      (dolist (row rows)
        (insert (mapconcat (lambda (v) (tabularium--escape-field v sep-char))
                           row sep)
                "\n")))))

(defun tabularium--export-compute-rows (fields where order &optional limit)
  "Return rows for FIELDS as fully-computed value lists for export.
FIELDS is the ordered list of field plists to export — it may
include computed fields, both SQL-expression and elisp `:computed'
ones, and may be any subset of the schema.  WHERE and ORDER are
SQL clause strings (without the leading keywords; empty string for
none).  LIMIT, when non-nil, is an integer row cap.

Computation runs over the *whole* schema, not just FIELDS: an
elisp `:computed' lambda may reference any field, so restricting
the query to the selected columns would starve it of context and
yield blank values.  The query therefore selects every schema
field (plus SQL-computed expressions), elisp `:computed' fields
are resolved against that full row via
`tabularium--apply-elisp-computed', and only then is each row
projected down to FIELDS in FIELDS order.  Computed values are
whatever the expression or lambda yields, written literally."
  (tabularium--ensure-db)
  (let* (;; Compute over the entire schema so elisp lambdas see every
         ;; field, then project to FIELDS afterwards.
         (all-fields (tabularium--schema-fields))
         (computed-select (tabularium--build-select-with-computed all-fields))
         (sql (format "SELECT %s FROM %s %s%s%s"
                      (string-join computed-select ", ")
                      tabularium-table-name
                      (if (string-empty-p where) "" (concat where " "))
                      (if (string-empty-p order) ""
                        (concat "ORDER BY " order))
                      (if limit (format " LIMIT %d" limit) "")))
         (rows (tabularium-db-query tabularium--db sql))
         (elisp-computed (cl-remove-if-not
                          (lambda (f)
                            (and (tabularium--computed-field-p f)
                                 (not (tabularium--computed-sql-expression f))))
                          all-fields))
         ;; `tabularium--build-select-with-computed' selected one item
         ;; per schema field in schema order, so a display-offset of 0
         ;; lines the row up with `all-fields' directly.
         (computed-rows
          (if elisp-computed
              (tabularium--apply-elisp-computed
               rows all-fields elisp-computed 0)
            rows))
         ;; Index of each schema field by id, to project to FIELDS.
         (index (let ((h (make-hash-table :test 'eq))
                      (i 0))
                  (dolist (f all-fields h)
                    (puthash (plist-get f :id) i h)
                    (setq i (1+ i)))))
         (sel-indices (mapcar (lambda (f) (gethash (plist-get f :id) index))
                              fields)))
    ;; Project each computed row down to the selected FIELDS, in order.
    (mapcar (lambda (row)
              (mapcar (lambda (idx) (and idx (nth idx row))) sel-indices))
            computed-rows)))

(defun tabularium--export-read-format ()
  "Prompt for an export format, returning `tsv' or `csv'."
  (if (string= (completing-read "Export format: "
                                '("TSV" "CSV") nil t nil nil
                                (if (eq tabularium-export-format 'tsv)
                                    "TSV" "CSV"))
               "TSV")
      'tsv 'csv))

(defun tabularium--format-row-ids (ids &optional max)
  "Format IDS, a list of row-id integers, as a compact bracket-less string.
IDS are de-duplicated and sorted ascending, then each run of three or
more consecutive ids collapses to =LO-HI= — so =5 6 7 8 9= becomes
=5-9=, while a lone pair such as =5 6= stays split.  At most MAX
tokens (default 3) are shown; any beyond that are elided as =…=, giving
forms like =1,3,5-9,…=.  This is the display inverse of
`tabularium--parse-id-range-spec' (lossy only in the elision), meant for
the brackets that mark a rule's row restriction.  Returns the empty
string when IDS is nil."
  (let ((max (or max 3))
        (sorted (sort (delete-dups (copy-sequence ids)) #'<))
        (tokens '()))
    (while sorted
      (let ((lo (car sorted))
            (hi (car sorted)))
        (setq sorted (cdr sorted))
        (while (and sorted (= (car sorted) (1+ hi)))
          (setq hi (car sorted)
                sorted (cdr sorted)))
        (if (>= (- hi lo) 2)
            ;; A run of three or more collapses to one range token.
            (push (format "%d-%d" lo hi) tokens)
          ;; A lone id, or a bare pair, stays as individual tokens so each
          ;; one counts as an entry toward the MAX cutoff.
          (cl-loop for i from lo to hi
                   do (push (number-to-string i) tokens)))))
    (setq tokens (nreverse tokens))
    (if (> (length tokens) max)
        (concat (string-join (seq-take tokens max) ",") ",…")
      (string-join tokens ","))))

(defun tabularium--format-column-ids (cols &optional max)
  "Format COLS, a list of column-id symbols, as a compact brace-less string.
Returns =*= for nil, meaning every column.  Up to MAX names (default 3)
are listed; beyond that the count is shown as =N cols=, since column ids
are names rather than a contiguous range to abbreviate.  Meant for the
brace that marks a column rule's eligible columns — e.g. ={notes,tags}=
or ={5 cols}=."
  (let ((max (or max 3)))
    (cond
     ((null cols) "*")
     ((> (length cols) max) (format "%d cols" (length cols)))
     (t (mapconcat #'symbol-name cols ",")))))

(defun tabularium--parse-id-range-spec (spec)
  "Parse SPEC, a string of integer IDs and ID ranges, into a sorted list.
SPEC items are comma- or whitespace-separated; each item is either
a single integer (=12=) or an inclusive range (=20-25=).  Whitespace
around items and around the range dash is tolerated.  The result
is sorted ascending with duplicates removed.  Signals a
`user-error' on any item that is neither an integer nor a range."
  ;; Collapse whitespace immediately around a `-' first, so that a
  ;; spaced range like \"5 - 8\" survives the whitespace-aware item
  ;; split below as the single token \"5-8\" rather than fragmenting
  ;; into \"5\" \"-\" \"8\".
  (let* ((normalized (replace-regexp-in-string "[ \t]*-[ \t]*" "-" spec))
         (items (split-string normalized "[, \t\n]+" t))
         (ids '()))
    (dolist (item items)
      (cond
       ((string-match "\\`\\([0-9]+\\)\\'" item)
        (push (string-to-number (match-string 1 item)) ids))
       ((string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" item)
        (let ((lo (string-to-number (match-string 1 item)))
              (hi (string-to-number (match-string 2 item))))
          (when (> lo hi)
            (user-error "Range %s is backwards (low > high)" item))
          (cl-loop for i from lo to hi do (push i ids))))
       (t
        (user-error "Bad id/range item: %s" item))))
    (sort (delete-dups ids) #'<)))

(defun tabularium--export-exportable-fields ()
  "Return the schema fields that may be exported.
This is every schema field, computed columns included — computed
columns export with their computed values rendered literally."
  (tabularium--schema-fields))

;;;###autoload
(defun tabularium-export-visible (file format)
  "Export the current view to FILE in FORMAT (`tsv' or `csv').
Exports exactly what the view buffer shows: only the visible
columns, in their current display order, and only the rows that
pass the active filters — in the active sort order, capped at the
current view limit.  Computed columns are included (their
displayed values are written).

This is the \"what you see is what you get\" export, distinct from
`tabularium-export' (the whole table, every column) and
`tabularium-export-range' (an explicit id/column range)."
  (interactive
   (let* ((fmt (tabularium--export-read-format))
          (ext (if (eq fmt 'tsv) ".tsv" ".csv"))
          (default-name (concat (file-name-sans-extension
                                 (or (tabularium--schema-export-file)
                                     (buffer-name)))
                                "-visible" ext))
          (file (read-file-name "Export visible to: " nil default-name)))
     (list file fmt)))
  (tabularium--ensure-db)
  (let* ((fmt (or format tabularium-export-format))
         (visible-fields (tabularium-view--ordered-visible-fields))
         (_ (unless visible-fields
              (user-error "No visible columns to export")))
         (col-names (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                            visible-fields))
         (primary-name (symbol-name (tabularium--primary-field-name)))
         (where-parts (delq nil
                            (list (tabularium--build-filter-clause)
                                  (tabularium--view-id-range-clause primary-name))))
         (where (if where-parts
                    (format "WHERE %s" (string-join where-parts " AND "))
                  ""))
         (order-clause (tabularium--build-order-clause))
         (limit (or tabularium--view-limit tabularium-view-page-size))
         ;; Shared helper resolves both SQL-expression and elisp
         ;; `:computed' fields, so computed columns export with their
         ;; real values, not blanks.
         (rows (tabularium--export-compute-rows
                visible-fields where order-clause limit)))
    (tabularium--export-write file fmt col-names rows)
    (message "Exported %d visible row%s, %d column%s to %s (%s)"
             (length rows) (if (= 1 (length rows)) "" "s")
             (length col-names) (if (= 1 (length col-names)) "" "s")
             file (upcase (symbol-name fmt)))))

;;;###autoload
(defun tabularium-export-range (file format ids columns)
  "Export an explicit range of rows and columns to FILE in FORMAT.
FORMAT is `tsv' or `csv'.  IDS is a list of primary-key integers
identifying the rows to export.  COLUMNS is a list of column-id
strings to include, in the order given.

Interactively, the rows are entered as a spec of IDs and ID ranges
\(e.g. =3-7,12,20-25=) parsed by `tabularium--parse-id-range-spec',
and the columns are picked with `completing-read-multiple' over
the field ids — a `<<ALL>>' entry, or an empty answer, selects
every column.

Unlike `tabularium-export' (the whole table) and
`tabularium-export-visible' (the on-screen view), this command
exports precisely the rows and columns named, in id order for
rows and pick order for columns.  Named \"range\" — not
\"selection\" — to avoid confusion with the marked-row set."
  (interactive
   (progn
     (tabularium--ensure-db)
     (let* ((fmt (tabularium--export-read-format))
            (ext (if (eq fmt 'tsv) ".tsv" ".csv"))
            (id-spec (read-string
                      "Row IDs [comma-separated or range]: "))
            (ids (tabularium--parse-id-range-spec id-spec))
            (_ (unless ids (user-error "No row IDs given")))
            ;; Column selection: a completing-read-multiple over the
            ;; field ids, with a `<<ALL>>' sentinel meaning every
            ;; column.  The double-angle-bracket form marks it as a
            ;; sentinel distinct from any real column id.
            (all-cols (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                              (tabularium--export-exportable-fields)))
            (chosen (completing-read-multiple
                     "Columns [<<ALL>>, or comma-separated]: "
                     (cons "<<ALL>>" all-cols) nil nil nil nil "<<ALL>>"))
            (columns (if (or (null chosen) (member "<<ALL>>" chosen))
                         all-cols
                       chosen))
            (default-name (concat (file-name-sans-extension
                                   (or (tabularium--schema-export-file)
                                       (buffer-name)))
                                  "-range" ext))
            (file (read-file-name "Export range to: " nil default-name)))
       (list file fmt ids columns))))
  (tabularium--ensure-db)
  (let* ((fmt (or format tabularium-export-format))
         (all-fields (tabularium--schema-fields))
         (exportable (mapcar (lambda (f) (symbol-name (plist-get f :id)))
                             all-fields))
         (bad-cols (cl-remove-if (lambda (c) (member c exportable)) columns)))
    (when bad-cols
      (user-error "Unknown column(s): %s" (string-join bad-cols ", ")))
    (unless columns
      (user-error "No columns selected"))
    (unless ids
      (user-error "No row IDs selected"))
    (let* ((primary-name (symbol-name (tabularium--primary-field-name)))
           ;; Resolve the chosen column-id strings to field plists, in
           ;; the order the spec named them.  Computed columns are
           ;; allowed and resolved by `tabularium--export-compute-rows'.
           (sel-fields
            (mapcar (lambda (c)
                      (cl-find-if (lambda (f)
                                    (equal (symbol-name (plist-get f :id)) c))
                                  all-fields))
                    columns))
           (where (format "WHERE %s IN (%s)"
                          primary-name
                          (mapconcat #'number-to-string ids ",")))
           (rows (tabularium--export-compute-rows
                  sel-fields where primary-name))
           (found (length rows))
           (missing (- (length ids) found)))
      (tabularium--export-write file fmt columns rows)
      (message "Exported %d row%s, %d column%s to %s (%s)%s"
               found (if (= 1 found) "" "s")
               (length columns) (if (= 1 (length columns)) "" "s")
               file (upcase (symbol-name fmt))
               (if (> missing 0)
                   (format " — %d requested ID%s not found"
                           missing (if (= 1 missing) "" "s"))
                 "")))))

;;; ** 8.2 Advanced Import

;;; *** 8.2.1 Data Type Inference

;; Forward declarations for org functions (loaded on demand)
(declare-function org-at-table-p "org-table" (&optional table-type))
(declare-function org-table-to-lisp "org-table" (&optional txt))
(declare-function org-table-end "org-table" ())

(defun tabularium-import--infer-type (values)
  "Infer the best type for a list of VALUES.
Returns one of: integer, number, date, text."
  (let ((non-empty (seq-filter (lambda (v) (and v (not (string-empty-p v)))) values)))
    (cond
     ((null non-empty) 'text)
     ((seq-every-p (lambda (v) (string-match-p "^-?[0-9]+$" v)) non-empty)
      'integer)
     ((seq-every-p (lambda (v) (string-match-p "^-?[0-9]*\\.?[0-9]+$" v)) non-empty)
      'number)
     ((seq-every-p (lambda (v) (string-match-p "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}$" v)) non-empty)
      'date)
     (t 'text))))

(defun tabularium-import--sanitize-column-name (name)
  "Convert NAME to a valid column name."
  (let ((clean (replace-regexp-in-string "[^a-zA-Z0-9_]" "_" (string-trim name))))
    (setq clean (replace-regexp-in-string "_+" "_" clean))
    (setq clean (replace-regexp-in-string "^_\\|_$" "" clean))
    (downcase clean)))

(defun tabularium-import--estimate-width (values name)
  "Estimate display width for column NAME based on VALUES."
  (let* ((max-value-len (apply #'max 0 (mapcar #'length values)))
         (name-len (length name))
         (max-len (max max-value-len name-len)))
    (min 50 (max 5 max-len))))

(defun tabularium-import--generate-schema (headers rows &optional primary-col)
  "Generate a Tabularium schema from HEADERS and ROWS.
PRIMARY-COL specifies which column (0-indexed) should be the primary key.
If no primary column is specified, an `id' column is prepended automatically."
  (let* ((n-cols (length headers))
         (columns-data (make-vector n-cols nil))
         (fields '()))
    ;; Collect values per column
    (dotimes (i n-cols)
      (aset columns-data i
            (mapcar (lambda (row) (string-trim (or (nth i row) ""))) rows)))
    ;; Generate field definitions
    (dotimes (i n-cols)
      (let* ((header (nth i headers))
             (name (tabularium-import--sanitize-column-name header))
             (values (aref columns-data i))
             (type (tabularium-import--infer-type values))
             (width (tabularium-import--estimate-width values name))
             (is-primary (and primary-col (= i primary-col)))
             (field (list :id (intern name)
                          :type type
                          :label header
                          :width width)))
        (when is-primary
          (setq field (plist-put field :primary t)))
        ;; Add historical completion for text fields with repeated values
        (when (eq type 'text)
          (let ((unique-count (length (delete-dups (copy-sequence values)))))
            (when (and (> (length values) 5)
                       (< unique-count (* 0.8 (length values))))
              (setq field (plist-put field :complete 'historical)))))
        (push field fields)))
    (setq fields (nreverse fields))
    ;; If no primary key was assigned, prepend an auto-increment
    ;; row-ID field.
    (unless (cl-find-if (lambda (f) (plist-get f :primary)) fields)
      (push (list :id 'row_id :type 'integer :primary t :label "ID" :width 5)
            fields))
    fields))

;;; *** 8.2.2 Database Creation

(defun tabularium-import--create-database (db-file schema-name fields)
  "Create a new Tabularium database at DB-FILE with SCHEMA-NAME and FIELDS."
  (let* ((db-file (expand-file-name db-file))
         (schema-file (tabularium-registry--schema-file-for-db db-file))
         (schema-content
          (format ";;; %s --- Tabularium schema -*- lexical-binding: t; -*-\n\n%s\n\n;;; %s ends here\n"
                  (file-name-nondirectory schema-file)
                  (pp-to-string
                   `(tabularium-define-schema ,schema-name
                      :file ,(abbreviate-file-name db-file)
                      :fields ',fields))
                  (file-name-nondirectory schema-file))))
    ;; Write schema file
    (with-temp-file schema-file
      (insert schema-content))
    ;; Delete existing db if present
    (when (file-exists-p db-file)
      (delete-file db-file))
    ;; Register schema directly in tabularium-schemas
    (let ((existing (assoc schema-name tabularium-schemas)))
      (if existing
          (setcdr existing (list :file db-file :fields fields))
        (push (cons schema-name (list :file db-file :fields fields)) tabularium-schemas)))
    ;; Set as current and ensure db connection
    (setq tabularium--current-schema-name schema-name)
    (tabularium--ensure-db)
    ;; Register in database list for future sessions
    (tabularium-registry--add
     (list :name schema-name
           :file db-file
           :schema-file schema-file
           :last-used (float-time)))
    schema-file))

(defun tabularium-import--insert-rows (rows fields)
  "Insert ROWS into the current Tabularium database using FIELDS schema.
Computed fields are skipped: they have no physical column, and the
imported file's values line up only with the stored fields.  If a
computed field were left in the zip it would shift every later
column out of alignment and could target a non-existent column."
  (let* ((stored-fields (cl-remove-if #'tabularium--computed-field-p fields))
         (field-names (mapcar (lambda (f) (plist-get f :id)) stored-fields))
         (imported 0)
         (errors 0))
    (tabularium-db-with-transaction tabularium--db
      (dolist (row rows)
        (let ((data '()))
          (cl-loop for name in field-names
                   for value in row
                   do (let ((clean-value (string-trim (or value ""))))
                        (push (cons name (if (string-empty-p clean-value) nil clean-value))
                              data)))
          (setq data (nreverse data))
          (condition-case err
              (progn
                (tabularium-db-insert tabularium--db tabularium-table-name data)
                (cl-incf imported))
            (error
             (cl-incf errors)
             (when (<= errors 3)
               (message "Import error (row %d): %s"
                        (+ imported errors) (error-message-string err))))))))
    (when (> errors 0)
      (message "Import: %d succeeded, %d failed" imported errors))
    imported))

;;; *** 8.2.3 Org-Table

(defun tabularium-import--org-parse-table-at-point ()
  "Parse the org-table at point, returning (HEADERS . ROWS)."
  (unless (org-at-table-p)
    (user-error "Not at an org-table"))
  (let* ((table (org-table-to-lisp))
         (data-rows (seq-filter #'listp table))
         (headers (car data-rows))
         (rows (cdr data-rows)))
    (cons headers rows)))

(defun tabularium-import--org-find-named-table (name)
  "Find and return the org-table with #+NAME: NAME."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (format "^#\\+NAME:\\s-*%s\\s-*$" (regexp-quote name)) nil t)
      (forward-line 1)
      (when (org-at-table-p)
        (tabularium-import--org-parse-table-at-point)))))

(defun tabularium-import--org-find-first-table ()
  "Find and return the first org-table in the buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^|" nil t)
      (beginning-of-line)
      (when (org-at-table-p)
        (tabularium-import--org-parse-table-at-point)))))

(defun tabularium-import--org-list-tables ()
  "Return a list of all tables in the current org buffer.
Each entry is (NAME . POSITION) where NAME is the #+NAME or a generated
description like \"Table at line 42\", and POSITION is the buffer position."
  (save-excursion
    (goto-char (point-min))
    (let ((tables '()))
      (while (re-search-forward "^|" nil t)
        (beginning-of-line)
        (if (org-at-table-p)
            (let* ((pos (point))
                   (line-num (line-number-at-pos))
                   ;; Check for #+NAME: on previous line(s)
                   (name (save-excursion
                           (forward-line -1)
                           (if (looking-at "^#\\+NAME:\\s-*\\(.+\\)\\s-*$")
                               (match-string-no-properties 1)
                             ;; Also check 2 lines up (in case of blank line)
                             (forward-line -1)
                             (when (looking-at "^#\\+NAME:\\s-*\\(.+\\)\\s-*$")
                               (match-string-no-properties 1)))))
                   (display-name (or name
                                     (format "Unnamed table at line %d" line-num))))
              (push (cons display-name pos) tables)
              ;; `org-table-end' returns a position but does not move point.
              ;; Jump there explicitly so the next iteration starts beyond
              ;; this table — otherwise we'd loop forever re-finding the
              ;; same first row.
              (goto-char (org-table-end)))
          ;; Not at a table — advance past the matched `|' so the search
          ;; doesn't re-find the same position on the next iteration.
          (forward-line 1)))
      (nreverse tables))))

;;;###autoload
(defun tabularium-import-org-table-at-point ()
  "Import the org-table at point into a Tabularium database.
Must be called with point inside an org-table."
  (interactive)
  (require 'org)
  (require 'org-table)
  (unless (org-at-table-p)
    (user-error "Point is not inside an org-table"))
  (let* ((parsed (tabularium-import--org-parse-table-at-point))
         (headers (car parsed))
         (rows (cdr parsed))
         (org-file (or buffer-file-name "untitled.org"))
         (default-db (concat (file-name-sans-extension org-file) ".db"))
         (db-file (expand-file-name
                   (read-file-name "Database file: "
                                   (file-name-directory org-file)
                                   default-db nil
                                   (file-name-nondirectory default-db))))
         (schema-name (file-name-base db-file))
         (default-schema-file (concat (file-name-sans-extension db-file)
                                      tabularium-schema-file-suffix))
         schema-file fields use-existing)
    (unless parsed
      (user-error "Could not parse org-table at point"))
    ;; Ask about schema
    (if (y-or-n-p "Create new schema from data? ")
        ;; Generate schema from data
        (let* ((first-col-values (mapcar #'car rows))
               (first-col-type (tabularium-import--infer-type first-col-values))
               (primary-col (when (eq first-col-type 'integer) 0)))
          (setq fields (tabularium-import--generate-schema headers rows primary-col))
          (setq schema-file default-schema-file)
          (setq use-existing nil))
      ;; Use existing schema file
      (setq schema-file
            (read-file-name "Schema file: "
                            (file-name-directory db-file)
                            (when (file-exists-p default-schema-file)
                              default-schema-file)
                            t
                            (when (file-exists-p default-schema-file)
                              (file-name-nondirectory default-schema-file))
                            (lambda (f) (or (file-directory-p f)
                                            (string-match-p "\\.schema\\.el$\\|\\.el$" f)))))
      (setq use-existing t))
    ;; Confirm and import
    (when (yes-or-no-p
           (format "Import %d rows with %d columns into %s%s? "
                   (length rows) (length headers) (abbreviate-file-name db-file)
                   (if use-existing
                       (format " using schema %s" (file-name-nondirectory schema-file))
                     " (generating new schema)")))
      (if use-existing
          (tabularium-import--with-existing-schema
           schema-file db-file schema-name rows)
        (let ((created-schema (tabularium-import--create-database db-file schema-name fields)))
          (let ((imported (tabularium-import--insert-rows rows fields)))
            (tabularium-view)
            (message "Imported %d rows into %s\nSchema saved to %s"
                     imported db-file created-schema)))))))

;;;###autoload
(defun tabularium-import-org-select-table (org-file)
  "Select and import a specific table from ORG-FILE.
Presents a list of all tables (named and unnamed) for selection."
  (interactive
   (list (read-file-name "Org file: " nil nil t nil
                         (lambda (f) (or (file-directory-p f)
                                         (string-match-p "\\.org$" f))))))
  (require 'org)
  (require 'org-table)
  (let* ((org-file (expand-file-name org-file))
         tables selected-table parsed)
    ;; Find all tables in the file
    (with-temp-buffer
      (insert-file-contents org-file)
      (org-mode)
      (setq tables (tabularium-import--org-list-tables)))
    (unless tables
      (user-error "No tables found in %s" org-file))
    ;; Let user select if multiple tables
    (if (= (length tables) 1)
        (setq selected-table (car tables))
      (let ((selection (completing-read
                        (format "Select table (%d found): " (length tables))
                        (mapcar #'car tables)
                        nil t)))
        (setq selected-table (assoc selection tables))))
    ;; Parse the selected table
    (with-temp-buffer
      (insert-file-contents org-file)
      (org-mode)
      (goto-char (cdr selected-table))
      (setq parsed (tabularium-import--org-parse-table-at-point)))
    ;; Now proceed with import
    (let* ((headers (car parsed))
           (rows (cdr parsed))
           (default-db (concat (file-name-sans-extension org-file) ".db"))
           (db-file (expand-file-name
                     (read-file-name "Database file: "
                                     (file-name-directory org-file)
                                     default-db nil
                                     (file-name-nondirectory default-db))))
           (schema-name (file-name-base db-file))
           (default-schema-file (concat (file-name-sans-extension db-file)
                                        tabularium-schema-file-suffix))
           schema-file fields use-existing)
      ;; Ask about schema
      (if (y-or-n-p "Create new schema from data? ")
          (let* ((first-col-values (mapcar #'car rows))
                 (first-col-type (tabularium-import--infer-type first-col-values))
                 (primary-col (when (eq first-col-type 'integer) 0)))
            (setq fields (tabularium-import--generate-schema headers rows primary-col))
            (setq schema-file default-schema-file)
            (setq use-existing nil))
        (setq schema-file
              (read-file-name "Schema file: "
                              (file-name-directory db-file)
                              (when (file-exists-p default-schema-file)
                                default-schema-file)
                              t
                              (when (file-exists-p default-schema-file)
                                (file-name-nondirectory default-schema-file))
                              (lambda (f) (or (file-directory-p f)
                                              (string-match-p "\\.schema\\.el$\\|\\.el$" f)))))
        (setq use-existing t))
      ;; Confirm and import
      (when (yes-or-no-p
             (format "Import %d rows from '%s' into %s%s? "
                     (length rows) (car selected-table) (abbreviate-file-name db-file)
                     (if use-existing
                         (format " using schema %s" (file-name-nondirectory schema-file))
                       " (generating new schema)")))
        (if use-existing
            (tabularium-import--with-existing-schema
             schema-file db-file schema-name rows)
          (let ((created-schema (tabularium-import--create-database db-file schema-name fields)))
            (let ((imported (tabularium-import--insert-rows rows fields)))
              (tabularium-view)
              (message "Imported %d rows into %s\nSchema saved to %s"
                       imported db-file created-schema))))))))

;;;###autoload
(defun tabularium-import-org (org-file db-file &optional table-name)
  "Import an org-table from ORG-FILE into a Tabularium database at DB-FILE.
TABLE-NAME specifies which #+NAME'd table to import, or nil for the first table.

Prompts for schema handling: create new from data, or use existing schema file."
  (interactive
   (let* ((org (read-file-name "Org file: " nil nil t nil
                               (lambda (f) (or (file-directory-p f)
                                               (string-match-p "\\.org$" f)))))
          (default-db (concat (file-name-sans-extension org) ".db"))
          (db (read-file-name "Database file: "
                              (file-name-directory org)
                              default-db nil
                              (file-name-nondirectory default-db)
                              (lambda (f) (or (file-directory-p f)
                                              (string-match-p "\\.db$" f)))))
          (name (read-string "Table name (empty for first table): ")))
     (list org db (if (string-empty-p name) nil name))))
  (require 'org)
  (require 'org-table)
  (let* ((org-file (expand-file-name org-file))
         (db-file (expand-file-name db-file))
         (schema-name (file-name-base db-file))
         (default-schema-file (concat (file-name-sans-extension db-file)
                                      tabularium-schema-file-suffix))
         parsed headers rows schema-file fields use-existing)
    ;; Parse the org file
    (with-temp-buffer
      (insert-file-contents org-file)
      (org-mode)
      (setq parsed (if table-name
                       (tabularium-import--org-find-named-table table-name)
                     (tabularium-import--org-find-first-table))))
    (unless parsed
      (user-error "No org-table found in %s%s"
                  org-file
                  (if table-name (format " with name '%s'" table-name) "")))
    (setq headers (car parsed)
          rows (cdr parsed))
    ;; Ask about schema
    (if (y-or-n-p "Create new schema from data? ")
        ;; Generate schema from data
        (let* ((first-col-values (mapcar #'car rows))
               (first-col-type (tabularium-import--infer-type first-col-values))
               (primary-col (when (eq first-col-type 'integer) 0)))
          (setq fields (tabularium-import--generate-schema headers rows primary-col))
          (setq schema-file default-schema-file)
          (setq use-existing nil))
      ;; Use existing schema file
      (setq schema-file
            (read-file-name "Schema file: "
                            (file-name-directory db-file)
                            (when (file-exists-p default-schema-file)
                              default-schema-file)
                            t  ; must exist
                            (when (file-exists-p default-schema-file)
                              (file-name-nondirectory default-schema-file))
                            (lambda (f) (or (file-directory-p f)
                                            (string-match-p "\\.schema\\.el$\\|\\.el$" f)))))
      (setq use-existing t))
    ;; Confirm and import
    (when (yes-or-no-p
           (format "Import %d rows with %d columns into %s%s? "
                   (length rows) (length headers) db-file
                   (if use-existing
                       (format " using schema %s" (file-name-nondirectory schema-file))
                     " (generating new schema)")))
      (if use-existing
          ;; Load existing schema and import
          (tabularium-import--with-existing-schema
           schema-file db-file schema-name rows)
        ;; Create new database and schema
        (let ((created-schema (tabularium-import--create-database db-file schema-name fields)))
          (let ((imported (tabularium-import--insert-rows rows fields)))
            (tabularium-view)
            (message "Imported %d rows into %s\nSchema saved to %s"
                     imported db-file created-schema)))))))

;;; *** 8.2.4 CSV/TSV with Schema Generation

(defun tabularium-import--parse-delimited-file (file &optional separator)
  "Parse a delimited FILE into (HEADERS . ROWS).
SEPARATOR defaults to comma for .csv, tab for .tsv.
Handles RFC 4180 quoting: fields may contain the separator,
newlines, and escaped quotes (\"\") when wrapped in double quotes."
  (let* ((sep (or separator
                  (if (string-match-p "\\.tsv$" file) ?\t ?,)))
         (content (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string)))
         (len (length content))
         (i 0)
         (rows '())
         (current-row '())
         (current-field "")
         (in-quotes nil))
    (while (< i len)
      (let ((char (aref content i)))
        (cond
         ;; Quote character
         ((= char ?\")
          (if in-quotes
              ;; Check for escaped quote ""
              (if (and (< (1+ i) len) (= (aref content (1+ i)) ?\"))
                  (progn
                    (setq current-field (concat current-field "\""))
                    (cl-incf i))
                (setq in-quotes nil))
            (setq in-quotes t)))
         ;; Separator outside quotes — end of field
         ((and (= char sep) (not in-quotes))
          (push current-field current-row)
          (setq current-field ""))
         ;; Newline outside quotes — end of row
         ((and (memq char '(?\n ?\r)) (not in-quotes))
          ;; Skip \r\n as single newline
          (when (and (= char ?\r) (< (1+ i) len) (= (aref content (1+ i)) ?\n))
            (cl-incf i))
          ;; Finish the row (skip empty trailing lines)
          (when (or (> (length current-field) 0) current-row)
            (push current-field current-row)
            (push (nreverse current-row) rows)
            (setq current-row nil)
            (setq current-field "")))
         ;; Regular character (including newlines inside quotes)
         (t
          (setq current-field (concat current-field (char-to-string char))))))
      (cl-incf i))
    ;; Final row (if file doesn't end with newline)
    (when (or (> (length current-field) 0) current-row)
      (push current-field current-row)
      (push (nreverse current-row) rows))
    (setq rows (nreverse rows))
    (cons (car rows) (cdr rows))))

;;;###autoload
(defun tabularium-import-csv (csv-file db-file)
  "Import a CSV file into a Tabularium database.
CSV-FILE is the source CSV file.
DB-FILE is the destination database file.

Prompts for schema handling: create new from data, or use existing schema file."
  (interactive
   (let* ((csv (read-file-name "CSV file: " nil nil t nil
                               (lambda (f) (or (file-directory-p f)
                                               (string-match-p "\\.csv$" f)))))
          (default-db (concat (file-name-sans-extension csv) ".db"))
          (db (read-file-name "Database file: "
                              (file-name-directory csv)
                              default-db nil
                              (file-name-nondirectory default-db)
                              (lambda (f) (or (file-directory-p f)
                                              (string-match-p "\\.db$" f))))))
     (list csv db)))
  (tabularium-import--delimited-with-schema csv-file db-file ?,))

;;;###autoload
(defun tabularium-import-tsv (tsv-file db-file)
  "Import a TSV file into a Tabularium database.
TSV-FILE is the source TSV file.
DB-FILE is the destination database file.

Prompts for schema handling: create new from data, or use existing schema file."
  (interactive
   (let* ((tsv (read-file-name "TSV file: " nil nil t nil
                               (lambda (f) (or (file-directory-p f)
                                               (string-match-p "\\.tsv$" f)))))
          (default-db (concat (file-name-sans-extension tsv) ".db"))
          (db (read-file-name "Database file: "
                              (file-name-directory tsv)
                              default-db nil
                              (file-name-nondirectory default-db)
                              (lambda (f) (or (file-directory-p f)
                                              (string-match-p "\\.db$" f))))))
     (list tsv db)))
  (tabularium-import--delimited-with-schema tsv-file db-file ?\t))

(defun tabularium-import--delimited-with-schema (file db-file separator)
  "Import delimited FILE into DB-FILE using SEPARATOR.
Prompts for schema handling: create new or use existing."
  (let* ((file (expand-file-name file))
         (db-file (expand-file-name db-file))
         (schema-name (file-name-base db-file))
         (default-schema-file (concat (file-name-sans-extension db-file)
                                      tabularium-schema-file-suffix))
         (parsed (tabularium-import--parse-delimited-file file separator))
         (headers (car parsed))
         (rows (cdr parsed))
         schema-file fields use-existing)
    ;; Ask about schema
    (if (y-or-n-p "Create new schema from data? ")
        ;; Generate schema from data
        (let* ((first-col-values (mapcar #'car rows))
               (first-col-type (tabularium-import--infer-type first-col-values))
               (primary-col (when (eq first-col-type 'integer) 0)))
          (setq fields (tabularium-import--generate-schema headers rows primary-col))
          (setq schema-file default-schema-file)
          (setq use-existing nil))
      ;; Use existing schema file
      (setq schema-file
            (read-file-name "Schema file: "
                            (file-name-directory db-file)
                            (when (file-exists-p default-schema-file)
                              default-schema-file)
                            t  ; must exist
                            (when (file-exists-p default-schema-file)
                              (file-name-nondirectory default-schema-file))
                            (lambda (f) (or (file-directory-p f)
                                            (string-match-p "\\.schema\\.el$\\|\\.el$" f)))))
      (setq use-existing t))
    ;; Confirm and import
    (when (yes-or-no-p
           (format "Import %d rows into %s%s? "
                   (length rows) db-file
                   (if use-existing
                       (format " using schema %s" (file-name-nondirectory schema-file))
                     " (generating new schema)")))
      (if use-existing
          ;; Load existing schema and import
          (tabularium-import--with-existing-schema
           schema-file db-file schema-name rows)
        ;; Create new database and schema
        (let ((created-schema (tabularium-import--create-database db-file schema-name fields)))
          (let ((imported (tabularium-import--insert-rows rows fields)))
            (tabularium-view)
            (message "Imported %d rows into %s\nSchema saved to %s"
                     imported db-file created-schema)))))))

(defun tabularium-import--with-existing-schema (schema-file db-file schema-name rows)
  "Import ROWS into DB-FILE using existing SCHEMA-FILE.
SCHEMA-NAME is used to look up the schema after loading."
  ;; Load the schema file - tabularium-define-schema must be available
  (load-file (expand-file-name schema-file))
  ;; Find the schema - try multiple strategies
  ;; Note: The schema's :file may not match db-file (user might be importing
  ;; to a different location), so we try name first, then use most recent
  (let* ((schema (or
                  ;; Try by name (derived from db-file basename)
                  (assoc schema-name tabularium-schemas)
                  ;; Try finding any schema that was just loaded from this schema-file
                  ;; (most recently defined will be first in list after push)
                  (car tabularium-schemas)))
         (actual-name (car schema))
         (fields (plist-get (cdr schema) :fields))
         (old-db-path (plist-get (cdr schema) :file)))
    (unless schema
      (user-error "No schema found in %s.  Make sure it contains a (tabularium-define-schema ...) form"
                  schema-file))
    (unless fields
      (user-error "Schema '%s' has no :fields defined" actual-name))
    ;; CRITICAL: Update the file path to match the import destination
    ;; This is necessary because the schema file may specify a different path
    ;; Use abbreviated path for portability across machines (Syncthing, etc.)
    (plist-put (cdr schema) :file (abbreviate-file-name (expand-file-name db-file)))
    ;; Delete existing database - required for fresh import with possibly different schema
    (when (file-exists-p db-file)
      (if (yes-or-no-p (format "Database %s exists.  Delete and reimport? "
                               (abbreviate-file-name db-file)))
          (progn
            (delete-file db-file)
            ;; Also delete WAL files if present
            (let ((wal-file (concat db-file "-wal"))
                  (shm-file (concat db-file "-shm")))
              (when (file-exists-p wal-file) (delete-file wal-file))
              (when (file-exists-p shm-file) (delete-file shm-file))))
        ;; User declined - abort import
        (user-error "Import canceled.  Cannot import into existing database without deleting it first")))
    ;; Set as current schema directly (bypass registry lookup which would fail)
    (setq tabularium--current-schema-name actual-name)
    ;; Ensure database connection is established
    (tabularium--ensure-db)
    ;; Register in database list
    (tabularium-registry--add
     (list :name actual-name
           :file db-file
           :schema-file schema-file
           :last-used (float-time)))
    ;; Import the rows
    (let ((imported (tabularium-import--insert-rows rows fields))
          (schema-updated nil))
      (tabularium-view)
      ;; Offer to update schema file if path changed
      (when (and old-db-path
                 (not (equal (expand-file-name old-db-path)
                             (expand-file-name db-file))))
        (when (y-or-n-p (format "Update schema file to point to %s? "
                                (abbreviate-file-name db-file)))
          (setq schema-updated
                (tabularium-db-update-schema-file-path schema-file db-file))))
      (message "Imported %d rows into %s using schema from %s%s"
               imported (abbreviate-file-name db-file)
               (file-name-nondirectory schema-file)
               (if schema-updated
                   (format ".  Schema updated to point to %s"
                           (abbreviate-file-name db-file))
                 "")))))

;;; *** 8.2.5 Schema Preview

;;;###autoload
(defun tabularium-import-preview-schema (file)
  "Preview the schema that would be generated from FILE.
FILE can be .org, .csv, or .tsv."
  (interactive
   (list (read-file-name "File to preview: " nil nil t)))
  (let* ((file (expand-file-name file))
         (ext (file-name-extension file))
         parsed headers rows fields)
    (cond
     ((string= ext "org")
      (require 'org)
      (require 'org-table)
      (with-temp-buffer
        (insert-file-contents file)
        (org-mode)
        (setq parsed (tabularium-import--org-find-first-table))))
     ((member ext '("csv" "tsv"))
      (setq parsed (tabularium-import--parse-delimited-file file)))
     (t
      (user-error "Unsupported file type: %s" ext)))
    (unless parsed
      (user-error "No table found in %s" file))
    (setq headers (car parsed)
          rows (cdr parsed))
    (let* ((first-col-values (mapcar #'car rows))
           (first-col-type (tabularium-import--infer-type first-col-values))
           (primary-col (when (eq first-col-type 'integer) 0)))
      (setq fields (tabularium-import--generate-schema headers rows primary-col)))
    ;; Display in a buffer
    (with-current-buffer (get-buffer-create "*Tabularium Schema Preview*")
      (erase-buffer)
      (emacs-lisp-mode)
      (insert ";; Auto-generated schema preview\n")
      (insert (format ";; Source: %s\n" file))
      (insert (format ";; Rows: %d, Columns: %d\n\n" (length rows) (length fields)))
      (insert "(tabularium-define-schema \"database-name\"\n")
      (insert "  :file \"~/path/to/database.db\"\n")
      (insert "  :fields\n")
      (insert "  '(")
      (let ((first t))
        (dolist (field fields)
          (if first
              (setq first nil)
            (insert "\n    "))
          (insert (pp-to-string field))))
      (insert "))\n")
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

;;; * 9 UI Integration

;;; ** 9.1 Module Autoloads

;; These autoload declarations allow users to call functions from optional
;; modules without explicitly requiring them.  The modules are loaded on-demand
;; when the function is first called.

;; tabularium-modeline.el — Modeline integration
;; (autoload cookies intentionally exceed 80 columns)
;;;###autoload (autoload 'tabularium-modeline-mode "tabularium-modeline" "Toggle Tabularium modeline indicator." t)
;;;###autoload (autoload 'tabularium-modeline-setup "tabularium-modeline" "Set up modeline for a specific package.")

;;; ** 9.2 Menu Entry Points

;; These wrapper functions provide stable entry points for keybindings.
;; They work regardless of whether hydra/transient has loaded yet.

(defun tabularium--dispatch-menu (hydra-fn transient-fn)
  "Dispatch to HYDRA-FN or TRANSIENT-FN based on `tabularium-menu-system'."
  (require 'tabularium-menu)
  (pcase tabularium-menu-system
    ('hydra
     (if (fboundp hydra-fn) (funcall hydra-fn)
       (user-error "Hydra not available; set `tabularium-menu-system' to `auto'")))
    ('transient
     (if (fboundp transient-fn) (funcall transient-fn)
       (user-error "Transient not available; set `tabularium-menu-system' to `auto'")))
    (_ (cond
        ((fboundp hydra-fn) (funcall hydra-fn))
        ((fboundp transient-fn) (funcall transient-fn))
        (t (user-error "No menu available; install hydra or transient"))))))

;;;###autoload
(defun tabularium-menu ()
  "Open the Tabularium menu (hydra or transient)."
  (interactive)
  (tabularium--dispatch-menu 'tabularium-hydra/body 'tabularium-transient))

;;;###autoload
(defun tabularium-view-menu ()
  "Open the Tabularium view mode menu (hydra or transient)."
  (interactive)
  (tabularium--dispatch-menu 'tabularium-view-hydra/body 'tabularium-view-transient))

;;;###autoload
(defun tabularium-customize ()
  "Open the Customize buffer for Tabularium."
  (interactive)
  (customize-group 'tabularium))

(defun tabularium--format-file-size (bytes)
  "Format BYTES as a human-readable size string."
  (cond
   ((null bytes) "—")
   ((< bytes 1024) (format "%d B" bytes))
   ((< bytes (* 1024 1024)) (format "%.1f KB" (/ bytes 1024.0)))
   ((< bytes (* 1024 1024 1024)) (format "%.1f MB" (/ bytes (* 1024.0 1024.0))))
   (t (format "%.2f GB" (/ bytes (* 1024.0 1024.0 1024.0))))))

(defun tabularium--describe-database-info (&optional schema-name)
  "Return an alist of database metadata.
With no argument, describes the currently open database.  With
SCHEMA-NAME, describes that schema instead — its schema file is
loaded if not already in memory, but no database connection is
opened.  In that case the row count is only available if a live
connection to SCHEMA-NAME happens to already exist; otherwise it
is reported as nil (the caller renders this as a dash).

Keys: name, backend, file, size, modified, row-count, fields."
  (let* ((name (or schema-name tabularium--current-schema-name))
         (_ (unless name (user-error "No database open")))
         (schema (or (tabularium--get-schema name)
                     ;; Not in memory — try to load the schema file via
                     ;; the registry without opening a connection.
                     (let ((entry (tabularium-registry--find-entry name)))
                       (when (and entry (plist-get entry :schema-file))
                         (tabularium-registry--load-schema-file
                          (expand-file-name (plist-get entry :schema-file))))
                       (tabularium--get-schema name))))
         (_ (unless schema
              (user-error "No schema found for '%s'" name)))
         (fields (plist-get schema :fields))
         (backend (or (plist-get schema :backend) 'sqlite))
         (file (plist-get schema :file))
         (expanded-file (and file (expand-file-name file)))
         (file-attrs (and expanded-file (file-exists-p expanded-file)
                          (file-attributes expanded-file)))
         (size (and file-attrs (file-attribute-size file-attrs)))
         (mtime (and file-attrs (file-attribute-modification-time file-attrs)))
         ;; Row count needs a live connection.  Use the current
         ;; connection only when it belongs to the schema being
         ;; described; otherwise leave it nil (rendered as a dash).
         (row-count
          (when (and tabularium--db
                     (equal name tabularium--current-schema-name))
            (condition-case nil
                (caar (tabularium-db-query
                       tabularium--db
                       (format "SELECT COUNT(*) FROM %s"
                               tabularium-table-name)))
              (error nil)))))
    `((name       . ,name)
      (backend    . ,backend)
      (file       . ,file)
      (size       . ,size)
      (modified   . ,mtime)
      (row-count  . ,row-count)
      (fields     . ,fields))))

;;;###autoload
(defun tabularium-describe-database (&optional schema-name)
  "Display a summary of a Tabularium database.
With no argument, describes the currently open database.  With
SCHEMA-NAME (interactively, the prefix-less default is the open
database; from the registry, the database at point), describes
that schema without opening a connection — file metadata and the
schema are read from disk, and the row count is shown only if a
live connection already exists.

Shows backend type, file location and size, row count, and the
list of schema fields with their types and constraints.  The
display follows the same `tabularium--make-box-header'/`-footer'
convention used by the registry and entry form."
  (interactive)
  (let* ((info (tabularium--describe-database-info schema-name))
         (name (alist-get 'name info))
         (backend (alist-get 'backend info))
         (file (alist-get 'file info))
         (size (alist-get 'size info))
         (mtime (alist-get 'modified info))
         (row-count (alist-get 'row-count info))
         (fields (alist-get 'fields info))
         (title (format "Database: %s (%s)" name backend))
         (buf (get-buffer-create "*Tabularium Database*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local truncate-lines nil)
        ;; Box-style header (matches registry / entry form convention)
        (insert (tabularium--make-box-header title 80 'double) "\n")
        (insert "\n")
        ;; File / size / modified
        (when file
          (insert (format "  %-12s%s\n"
                          (propertize "File:" 'face 'font-lock-keyword-face)
                          (abbreviate-file-name file))))
        (when size
          (insert (format "  %-12s%s\n"
                          (propertize "Size:" 'face 'font-lock-keyword-face)
                          (tabularium--format-file-size size))))
        (when mtime
          (insert (format "  %-12s%s\n"
                          (propertize "Modified:" 'face 'font-lock-keyword-face)
                          (format-time-string "%Y-%m-%d %H:%M:%S" mtime))))
        (insert "\n")
        ;; Schema section
        (insert (propertize (format "  Schema (%d field%s)\n"
                                    (length fields)
                                    (if (= 1 (length fields)) "" "s"))
                            'face '(:weight bold)))
        (insert (propertize (concat "  " (make-string 76 ?─) "\n")
                            'face 'shadow))
        (let ((max-name (apply #'max 8 (mapcar (lambda (f)
                                                 (length (symbol-name (plist-get f :id))))
                                               fields)))
              (max-type 8))
          (dolist (field fields)
            (let* ((fname (symbol-name (plist-get field :id)))
                   (ftype (plist-get field :type))
                   (primary (plist-get field :primary))
                   (required (plist-get field :required))
                   (computed (plist-get field :computed))
                   (hidden (plist-get field :hidden))
                   (long (plist-get field :long))
                   (flags (delq nil
                                (list (and primary "primary")
                                      (and required "required")
                                      (and computed "computed")
                                      (and hidden "hidden")
                                      (and long "long-edit")))))
              (insert (format "  %s  %s  %s\n"
                              (propertize (format (format "%%-%ds" max-name) fname)
                                          'face 'font-lock-variable-name-face)
                              (propertize (format (format "%%-%ds" max-type)
                                                  (if ftype (symbol-name ftype) "—"))
                                          'face 'font-lock-type-face)
                              (if flags
                                  (propertize (string-join flags ", ")
                                              'face 'font-lock-comment-face)
                                ""))))))
        (insert "\n")
        ;; Statistics section
        (insert (propertize "  Statistics\n" 'face '(:weight bold)))
        (insert (propertize (concat "  " (make-string 76 ?─) "\n")
                            'face 'shadow))
        (insert (format "  %-12s%s\n"
                        (propertize "Total rows:" 'face 'font-lock-keyword-face)
                        (if row-count
                            (format "%d" row-count)
                          (concat "—  "
                                  (propertize "(open the database to count rows)"
                                              'face 'shadow)))))
        ;; Footer (matches header style)
        (insert "\n")
        (insert (tabularium--make-box-footer 80 'double)
                "\n")
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;; ** 9.3 Command Map

;; A prefix keymap that mirrors the main menu's commands without
;; requiring `hydra' or `transient'.  Users who do not load
;; `tabularium-menu' can still access top-level commands by binding
;; this map to a prefix key, e.g.:
;;
;;   (global-set-key (kbd \"C-c t\") tabularium-command-map)
;;
;; Then `C-c t o' opens a database, `C-c t v' views all, `C-c t . s'
;; shows the current schema, `C-c t # s' computes a column sum, etc.

(defvar tabularium-schema-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "." #'tabularium-schema-edit)
    (define-key map "v" #'tabularium-schema-view)
    (define-key map "=" #'tabularium-schema-reload)
    (define-key map "w" #'tabularium-schema-switch)
    (define-key map "$" #'tabularium-schema-rename-field)
    (define-key map "+" #'tabularium-view-column-add)
    map)
  "Prefix keymap for tabularium schema commands.
Mirrors the schema sub-hydra in `tabularium-menu'.  Reached via
`.' from `tabularium-command-map'.")

(defvar tabularium-aggregate-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "c" #'tabularium-aggregate-count)
    (define-key map "s" #'tabularium-aggregate-sum)
    (define-key map "m" #'tabularium-aggregate-min-max)
    (define-key map "d" #'tabularium-aggregate-mean-sd)
    (define-key map "i" #'tabularium-aggregate-median-iqr)
    (define-key map "#" #'tabularium-aggregate-column-summary)
    map)
  "Prefix keymap for tabularium aggregate (statistics) commands.
Mirrors the calculate sub-hydra in `tabularium-menu'.  Reached via
`#' from `tabularium-command-map'.")

(defvar tabularium-create-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "C" #'tabularium-create-database)
    (define-key map "Q" #'tabularium-create-database-quick)
    (define-key map "H" #'tabularium-create-database-from-header)
    (define-key map "S" #'tabularium-create-database-from-schema-file)
    map)
  "Prefix keymap for tabularium database-creation commands.
Mirrors the create sub-hydra in `tabularium-menu'.  Reached via
`C' from `tabularium-command-map'.")

(defvar tabularium-export-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "e" #'tabularium-export)
    (define-key map "a" #'tabularium-export-all)
    (define-key map "v" #'tabularium-export-visible)
    (define-key map "r" #'tabularium-export-range)
    map)
  "Prefix keymap for tabularium export commands.
Reached via `e' from `tabularium-command-map': `e e' exports the
marked rows or, with none marked, the whole table; `e a' always
exports the whole table; `e v' the visible view; `e r' an explicit
id/column range.")

(defvar tabularium-import-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "i" #'tabularium-import)
    (define-key map "a" #'tabularium-import-append)
    map)
  "Prefix keymap for tabularium import commands.
Reached via `i' from `tabularium-command-map': `i i' imports a
file as a new database; `i a' appends a file to the open database.")

;;;###autoload
(defvar tabularium-command-map
  (let ((map (make-sparse-keymap)))
    ;; Database
    (define-key map "o" #'tabularium-open)
    (define-key map "O" #'tabularium-open-and-view)
    (define-key map "c" #'tabularium-close)
    (define-key map "r" #'tabularium-registry)
    (define-key map "$" #'tabularium-rename-database)
    (define-key map "R" #'tabularium-register-database)
    ;; Entry
    (define-key map "N" #'tabularium-new-entry)
    (define-key map "P" #'tabularium-prompt-entry)
    (define-key map "Q" #'tabularium-quick-entry)
    ;; Browse / Query
    (define-key map "v" #'tabularium-view)
    (define-key map "/" #'tabularium-find)
    (define-key map "t" #'tabularium-last)
    ;; Inspection
    (define-key map "?" #'tabularium-describe-database)
    ;; External
    (define-key map "e" tabularium-export-command-map)
    (define-key map "i" tabularium-import-command-map)
    (define-key map "s" #'tabularium-sync-prepare)
    ;; Submaps
    (define-key map "C" tabularium-create-command-map)
    (define-key map "." tabularium-schema-command-map)
    (define-key map "#" tabularium-aggregate-command-map)
    map)
  "Prefix keymap exposing top-level Tabularium commands.
Bind this map to a prefix key to access all main commands without
loading `tabularium-menu' (and thus without depending on `hydra'
or `transient').  Sub-prefixes `e', `i', `C', `.', and `#' lead to
the export, import, create, schema, and aggregate command maps
respectively.

Example binding:

  (global-set-key (kbd \"C-c t\") `tabularium-command-map')

See the README \"Bare keymap\" section for the full key table.")

;;; * 10 Provide

(provide 'tabularium)

;;; tabularium.el ends here
