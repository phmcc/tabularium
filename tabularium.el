;;; tabularium.el --- Structured data management in Emacs using SQL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul H. McClelland

;; Author: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Maintainer: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Version: 0.4.7
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
;; - Pluggable database backends (SQLite default, PostgreSQL/MySQL via emacsql)
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
  "Display, formatting, and view-mode behavior."
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

  :name     - Symbol, the column name
  :prompt   - String, shown to user during entry
  :type     - One of: text, number, integer, date, choice
  :primary  - Exactly one field MUST have :primary t
  :default  - (optional) Default value, symbol, or function
  :required - (optional) If non-nil, field cannot be empty
  :choice  - (for type=choice) Valid choice values
  :width    - (optional) Display width in list view
  :hidden   - (optional) If non-nil, hide from list view by default
  :long     - (optional) If non-nil, edit in a dedicated buffer
  :computed - (optional) SQL string or elisp function for virtual fields
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
           ((:name id   :type integer :primary t :prompt \"ID\")
            (:name date :type date :default today :prompt \"Date\")
            (:name category :type text :prompt \"Category\"
             :complete historical)
            (:name status :type choice :prompt \"Status\"
             :choice (\"Open\" \"Closed\"))
            (:name notes :type text :prompt \"Notes\")))))

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
  :group 'tabularium-display)

(defcustom tabularium-table-name "data"
  "Name of the main data table in the database."
  :type 'string
  :group 'tabularium-database)

(defcustom tabularium-view-sort-ascending nil
  "Whether to sort list view in ascending order (oldest first).
When nil (default), newest entries appear at the top."
  :type 'boolean
  :group 'tabularium-display)

(defcustom tabularium-debug nil
  "When non-nil, print debug messages for troubleshooting."
  :type 'boolean
  :group 'tabularium)

(defcustom tabularium-case-sensitive t
  "When non-nil, replace and mark operations use case-sensitive matching.
This affects `tabularium-replace-substring', `tabularium-replace-exact',
`tabularium-replace-pattern', `tabularium-replace-regexp',
`tabularium-replace-query', and the `tabularium-view-mark-*' family.
Toggle interactively with `tabularium-toggle-case-sensitive'.
Default is t, matching standard Emacs/Linux behavior."
  :type 'boolean
  :group 'tabularium-display)

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

(defvar-local tabularium--filter-layers nil
  "List of filter layer plists.
Each layer has :field, :value, :join (logic operator), and optional
:fields/:across (for multi-column) or :raw/:sql (for saved views).")

(defvar-local tabularium--sort-ascending nil
  "Buffer-local sort order.  Overrides `tabularium-view-sort-ascending'.")

(defvar-local tabularium--marked-entries nil
  "List of marked entry IDs.")

(defvar-local tabularium--view-limit nil
  "Current limit for view, or nil to use `tabularium-view-page-size'.")

(defvar-local tabularium--view-id-range nil
  "Current ID range filter as (MIN . MAX), or nil for no range filter.")

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

;; Registry internal variables
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
                    (let* ((name (plist-get f :name))
                           (ftype (plist-get f :type))
                           (sql-type (tabularium-db-sql-type tabularium--db ftype))
                           (choices (plist-get f :choice))
                           (check (when (and (eq ftype 'choice) choices)
                                    (format "%s IN (%s, '')"
                                            (symbol-name name)
                                            (mapconcat (lambda (c)
                                                         (tabularium-db-sql-quote c))
                                                       choices ", ")))))
                      (list :name name
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
                                (symbol-name (plist-get f :name)))))))

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
     (let ((id (plist-get op :id)))
       (tabularium-db-delete tabularium--db tabularium-table-name
                         (tabularium--primary-field-name) id)
       (list :type 'delete :id id :data (plist-get op :data))))
    ('delete
     ;; Undo delete = re-insert
     (let ((data (plist-get op :data)))
       (tabularium-db-insert tabularium--db tabularium-table-name data)
       (list :type 'insert :id (plist-get op :id) :data data)))
    ('update
     ;; Undo update = restore old value
     (let ((id (plist-get op :id))
           (field (plist-get op :field))
           (old-val (plist-get op :old))
           (new-val (plist-get op :new)))
       (tabularium-db-update tabularium--db tabularium-table-name
                         (list (cons field old-val))
                         (tabularium--primary-field-name) id)
       (list :type 'update :id id :field field :old new-val :new old-val)))
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
    ('multi
     ;; Undo multiple ops in reverse order
     (let ((inverse-ops '()))
       (dolist (sub-op (reverse (plist-get op :ops)))
         (push (tabularium--apply-undo-op sub-op) inverse-ops))
       (list :type 'multi :ops (nreverse inverse-ops))))
    ('swap
     ;; Undo swap = re-swap (swap is its own inverse)
     (let* ((id1 (plist-get op :id1))
            (id2 (plist-get op :id2))
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
       (list :type 'swap :id1 id1 :id2 id2)))
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
            (list (cadr row) (car row))))
         ;; Return inverse: the current-map becomes the before-map for redo
         (list :type 'move :before-map current-map
               :count (plist-get op :count)))))
    ('add-column
     ;; Undo add-column = drop the column
     (let* ((name (plist-get op :name))
            (field-plist (plist-get op :field-plist))
            (name-str (symbol-name name))
            (schema-name (tabularium--schema-name))
            (fields (tabularium--schema-fields))
            ;; Save position and any data that was entered since adding
            (position (cl-position-if
                       (lambda (f) (eq (plist-get f :name) name)) fields))
            (primary-str (symbol-name (tabularium--primary-field-name)))
            (rows (tabularium-db-query
                   tabularium--db
                   (format "SELECT %s, %s FROM %s WHERE %s IS NOT NULL AND %s != ''"
                           primary-str name-str tabularium-table-name
                           name-str name-str)
                   nil))
            (col-data (mapcar (lambda (row) (cons (car row) (cadr row))) rows)))
       ;; Drop column from DB (recreate table)
       (let* ((keep-fields (cl-remove-if
                            (lambda (f) (eq (plist-get f :name) name)) fields))
              (keep-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
                                  keep-fields))
              (cols-str (string-join keep-names ", ")))
         (tabularium-db-execute tabularium--db
                            (format "CREATE TABLE %s_backup AS SELECT %s FROM %s"
                                    tabularium-table-name cols-str
                                    tabularium-table-name)
                            nil)
         (tabularium-db-execute tabularium--db
                            (format "DROP TABLE %s" tabularium-table-name)
                            nil)
         (tabularium-db-execute tabularium--db
                            (format "ALTER TABLE %s_backup RENAME TO %s"
                                    tabularium-table-name tabularium-table-name)
                            nil))
       ;; Remove from schema
       (let* ((schema (assoc schema-name tabularium-schemas))
              (plist (cdr schema))
              (new-fields (cl-remove-if
                           (lambda (f) (eq (plist-get f :name) name))
                           (plist-get plist :fields))))
         (setf (cdr schema) (plist-put plist :fields new-fields))
         (tabularium--save-schema-to-file schema-name))
       ;; Return inverse: delete-column (so redo re-adds it)
       (list :type 'delete-column :name name
             :field-plist field-plist :position position
             :data col-data)))
    ('delete-column
     ;; Undo delete-column = re-add the column and restore data
     (let* ((name (plist-get op :name))
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
            (primary-str (symbol-name (tabularium--primary-field-name))))
       ;; Add column back to DB
       (tabularium-db-execute tabularium--db
                          (format "ALTER TABLE %s ADD COLUMN %s %s"
                                  tabularium-table-name name-str sql-type)
                          nil)
       ;; Restore data
       (dolist (pair col-data)
         (tabularium-db-execute
          tabularium--db
          (format "UPDATE %s SET %s = ? WHERE %s = ?"
                  tabularium-table-name name-str primary-str)
          (list (cdr pair) (car pair))))
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
       (list :type 'add-column :name name
             :field-plist field-plist)))
    ('reorder-columns
     ;; Undo reorder = restore old column order
     (let* ((old-order (plist-get op :old-order))
            (schema-name (tabularium--schema-name))
            (schema (assoc schema-name tabularium-schemas))
            (plist (cdr schema))
            (fields (plist-get plist :fields))
            (current-order (mapcar (lambda (f) (plist-get f :name)) fields))
            ;; Reorder fields to match old-order
            (new-fields (mapcar (lambda (name)
                                  (cl-find-if (lambda (f) (eq (plist-get f :name) name))
                                              fields))
                                old-order)))
       (setf (cdr schema) (plist-put plist :fields new-fields))
       (tabularium--save-schema-to-file schema-name)
       (setq tabularium--column-order nil)
       ;; Return inverse: reorder with current order
       (list :type 'reorder-columns :old-order current-order)))
    ('edit-column
     ;; Undo edit-column = restore old field plist
     (let* ((old-field-plist (plist-get op :old-field-plist))
            (current-name (plist-get op :new-name))
            (original-name (plist-get old-field-plist :name))
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
              (field (cl-find-if (lambda (f) (eq (plist-get f :name) current-name))
                                 cur-fields))
              ;; Save current state for redo
              (current-field-plist (copy-sequence field)))
         (when field
           ;; Restore all properties from old plist
           (dolist (key '(:name :type :prompt :width :default :complete))
             (let ((old-val (plist-get old-field-plist key)))
               (if old-val
                   (plist-put field key old-val)
                 (cl-remf field key))))
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
      (progn
        (let ((undo-op (tabularium--apply-undo-op op)))
          ;; Push back to undo without clearing redo
          (let* ((schema (tabularium--schema-name))
                 (stack (gethash schema tabularium--undo-ring)))
            (push undo-op stack)
            (puthash schema stack tabularium--undo-ring)))
        (tabularium--invalidate-cache)
        (when (derived-mode-p 'tabularium-view-mode)
          (let ((saved-id (tabulated-list-get-id))
                (saved-col (tabularium--column-name-at-point)))
            (revert-buffer)
            (tabularium-view--goto-position saved-id saved-col)))
        (message "Redo: %s" (tabularium--describe-op op)))
    (message "Nothing to redo")))

(defun tabularium--describe-op (op)
  "Return human-readable description of OP."
  (pcase (plist-get op :type)
    ('insert (format "insert #%s" (plist-get op :id)))
    ('delete (format "delete #%s" (plist-get op :id)))
    ('update (format "update #%s.%s" (plist-get op :id) (plist-get op :field)))
    ('paste (format "paste %d entries" (length (plist-get op :ops))))
    ('unpaste (format "unpaste %d entries" (length (plist-get op :ops))))
    ('yank (format "yank %d entries" (length (plist-get op :ops))))
    ('unyank (format "unyank %d entries" (length (plist-get op :ops))))
    ('multi (format "%d operations" (length (plist-get op :ops))))
    ('swap (format "swap #%s ↔ #%s" (plist-get op :id1) (plist-get op :id2)))
    ('move (format "move %d %s"
                   (or (plist-get op :count) 1)
                   (if (= 1 (or (plist-get op :count) 1)) "entry" "entries")))
    ('add-column (format "add column %s" (plist-get op :name)))
    ('delete-column (format "delete column %s" (plist-get op :name)))
    ('reorder-columns "reorder columns")
    ('edit-column (format "edit column %s"
                          (plist-get op :new-name)))))

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
                        (let* ((name (plist-get col :name))
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
    (insert (propertize (tabularium--make-box-footer 80) 'face 'shadow) "\n")
    (insert (format "  Total: %d %s\n\n"
                    (length tabularium--kill-ring)
                    (if (= 1 (length tabularium--kill-ring)) "batch" "batches")))
    (insert "  " (propertize "V" 'face 'help-key-binding) " Paste   "
            (propertize "c" 'face 'help-key-binding) " Clear   "
            (propertize "g" 'face 'help-key-binding) " Refresh   "
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
    (define-key map (kbd "c") #'tabularium-kill-ring-clear)
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
  "Format TIMESTAMP as relative time string."
  (if timestamp
      (let* ((diff (- (float-time) timestamp))
             (days (floor (/ diff 86400))))
        (cond
         ((< diff 3600) "< 1 hour ago")
         ((< diff 86400) (format "%d hours ago" (floor (/ diff 3600))))
         ((= days 1) "yesterday")
         ((< days 7) (format "%d days ago" days))
         ((< days 30) (format "%d weeks ago" (floor (/ days 7))))
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
  "Load SCHEMA-FILE, offering recovery if it fails.
Returns the schema name on success."
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
  "Check that the :file in SCHEMA-NAME matches DB-FILE, offering to fix it."
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
                      (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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
             (field (list :name (intern col-name)
                          :type tabularium-type
                          :prompt (capitalize (replace-regexp-in-string "_" " " col-name)))))
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
  (unless (yes-or-no-p (format "Forget database '%s'?  Files will not be deleted. " name))
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
Updates in-memory schema, registry, and optionally files on disk."
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
         (old-db-file (and entry (plist-get entry :file)))
         (old-schema-file (and entry (plist-get entry :schema-file)))
         (new-db-file nil)
         (new-schema-file nil)
         (slug (tabularium-rename--make-slug new-name)))

    ;; Determine new file paths based on slug
    (when old-db-file
      (setq new-db-file (expand-file-name
                         (concat slug ".db")
                         (file-name-directory old-db-file))))
    (when old-schema-file
      (setq new-schema-file (expand-file-name
                             (concat slug tabularium-schema-file-suffix)
                             (file-name-directory old-schema-file))))

    ;; Step 1: Update in-memory tabularium-schemas
    (let ((schema (assoc old-name tabularium-schemas)))
      (when schema
        (setcar schema new-name)
        ;; Update :file in schema if renaming the db file
        (when (and new-db-file
                   (not (equal old-db-file new-db-file))
                   (y-or-n-p (format "Rename database file to %s? "
                                     (file-name-nondirectory new-db-file))))
          (when (file-exists-p old-db-file)
            (rename-file old-db-file new-db-file)
            ;; Also rename WAL/SHM files if present
            (let ((old-wal (concat old-db-file "-wal"))
                  (old-shm (concat old-db-file "-shm"))
                  (new-wal (concat new-db-file "-wal"))
                  (new-shm (concat new-db-file "-shm")))
              (when (file-exists-p old-wal) (rename-file old-wal new-wal))
              (when (file-exists-p old-shm) (rename-file old-shm new-shm))))
          (plist-put (cdr schema) :file new-db-file)
          (setq old-db-file new-db-file))))  ; Update for schema file update

    ;; Step 2: Update current schema name if it is the one being renamed
    (when (equal tabularium--current-schema-name old-name)
      (setq tabularium--current-schema-name new-name))

    ;; Step 3: Update schema file contents
    (when (and old-schema-file (file-exists-p old-schema-file))
      (when (y-or-n-p (format "Update schema file contents? "))
        (tabularium-rename--update-schema-file-contents
         old-schema-file old-name new-name
         (when new-db-file (expand-file-name new-db-file))
         slug)
        ;; Step 4: Rename the schema file itself
        (when (and new-schema-file
                   (not (equal old-schema-file new-schema-file)))
          (when (y-or-n-p (format "Rename schema file to %s? "
                                  (file-name-nondirectory new-schema-file)))
            (rename-file old-schema-file new-schema-file)
            (setq old-schema-file new-schema-file)))))

    ;; Step 5: Update registry
    (let ((reg-entry (tabularium-registry--find-entry old-name)))
      (when reg-entry
        (plist-put reg-entry :name new-name)
        (when new-db-file
          (plist-put reg-entry :file (abbreviate-file-name new-db-file)))
        (when new-schema-file
          (plist-put reg-entry :schema-file (abbreviate-file-name new-schema-file)))))

    ;; Step 6: Save registry
    (tabularium-registry--save)
    (message "Renamed '%s' to '%s'" old-name new-name)))

(defun tabularium-rename--make-slug (name)
  "Convert NAME to a filesystem-safe slug."
  (let ((slug (downcase name)))
    ;; Replace spaces and underscores with hyphens
    (setq slug (replace-regexp-in-string "[_ ]+" "-" slug))
    ;; Remove parentheses and other special characters
    (setq slug (replace-regexp-in-string "[()\\[\\]{}'\"/\\\\:;,.<>?!@#$%^&*=+|`~]" "" slug))
    ;; Collapse multiple hyphens
    (setq slug (replace-regexp-in-string "-+" "-" slug))
    ;; Remove leading/trailing hyphens
    (setq slug (replace-regexp-in-string "^-+\\|-+$" "" slug))
    slug))

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
Uses abbreviate-file-name first, then truncates to show ~/first/.../last/file."
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

(defun tabularium-registry--refresh-if-visible ()
  "Refresh the registry buffer if it exists, preserving cursor position."
  (when-let ((buf (get-buffer "*Tabularium Registry*")))
    (let ((win (get-buffer-window buf)))
      (with-current-buffer buf
        (let ((line (line-number-at-pos)))
          (tabularium-registry)
          (goto-char (point-min))
          (forward-line (1- line))))
      ;; If the buffer is visible but we switched away, restore the window
      (when (and win (not (eq (window-buffer win) buf)))
        (set-window-buffer win buf)))))

;;;###autoload
(defun tabularium-registry ()
  "Display a buffer listing all known databases."
  (interactive)
  (let ((databases (tabularium-registry--all-databases))
        (buf (get-buffer-create "*Tabularium Registry*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (first-entry-pos nil)
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
                 (start (point))
                 (line-num (line-number-at-pos start)))
            ;; Track first/last entry lines for navigation bounds
            (unless first-entry-line
              (setq first-entry-line line-num)
              (setq first-entry-pos start))
            (setq last-entry-line line-num)
            ;; Insert with text property for database name
            (insert (propertize (format "  %-20s %-8s %s\n"
                                        (truncate-string-to-width (or name "?") 20)
                                        (if has-schema "Yes" "No")
                                        display-path)
                                'tabularium-db-name name))))
        ;; Footer - heavy lines to match header
        (insert "\n")
        (insert (propertize (tabularium--make-box-footer 80 'heavy) 'face 'shadow) "\n")
        (insert (format "  Total: %d databases\n\n" (length databases)))
        (insert "  " (propertize "RET" 'face 'help-key-binding) "/"
                (propertize "O" 'face 'help-key-binding) " Open + View   "
                (propertize "o" 'face 'help-key-binding) " Open   "
                (propertize "v" 'face 'help-key-binding) " View   "
                (propertize "C" 'face 'help-key-binding) " Create   "
                (propertize "+" 'face 'help-key-binding) " Register\n")
        (insert "  " (propertize "." 'face 'help-key-binding) " Edit schema   "
                (propertize "$" 'face 'help-key-binding) " Rename   "
                (propertize "D" 'face 'help-key-binding) " Delete   "
                (propertize "X" 'face 'help-key-binding) " Expunge   "
                (propertize "g" 'face 'help-key-binding) "/"
                (propertize "=" 'face 'help-key-binding) " Refresh   "
                (propertize "q" 'face 'help-key-binding) " Quit\n")
        ;; Activate mode FIRST (kills local variables)
        (tabularium-registry-mode)
        ;; THEN store bounds for navigation (after mode is active)
        (setq tabularium-registry--first-line (or first-entry-line 5))
        (setq tabularium-registry--last-line (or last-entry-line 5))
        ;; Position cursor on first entry
        (goto-char (or first-entry-pos (point-min)))))
    (switch-to-buffer buf)))

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
    (define-key map (kbd "+") #'tabularium-register-database)
    (define-key map (kbd "$") #'tabularium-registry-rename-at-point)
    (define-key map (kbd "D") #'tabularium-forget-database)
    (define-key map (kbd "X") #'tabularium-expunge-database)
    (define-key map (kbd ".") #'tabularium-registry-edit-schema-at-point)
    (define-key map (kbd "e") #'tabularium-registry-edit-schema-at-point)
    (define-key map (kbd "g") #'tabularium-registry)
    (define-key map (kbd "=") #'tabularium-registry)
    (define-key map (kbd "TAB") #'tabularium-registry-next-entry)
    (define-key map (kbd "<backtab>") #'tabularium-registry-prev-entry)
    (define-key map (kbd "n") #'tabularium-registry-next-entry)
    (define-key map (kbd "p") #'tabularium-registry-prev-entry)
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

(defun tabularium-registry-rename-at-point ()
  "Rename the database at point.
Reads the new name interactively, then delegates to
`tabularium-rename-database' for the full rename workflow
including optional file renames on disk."
  (interactive)
  (let ((old-name (tabularium-registry--db-at-point)))
    (unless old-name
      (user-error "No database at point"))
    (let ((new-name (read-string (format "Rename '%s' to: " old-name) old-name)))
      (tabularium-rename-database old-name new-name)
      (tabularium-registry--refresh-if-visible))))

(define-derived-mode tabularium-registry-mode special-mode "Tabularium-Registry"
  "Mode for listing known databases.")

;;; ** 3.8 Open / Close

;;;###autoload
(defun tabularium-close ()
  "Close the current database connection."
  (interactive)
  (when tabularium--current-schema-name
    (let ((name tabularium--current-schema-name))
      (tabularium-db-close-connection name)
      (setq tabularium--db nil)
      (setq tabularium--current-schema-name nil)
      (tabularium--invalidate-cache)
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
      (user-error "Database '%s' not found. Use `tabularium-create-database' to create one" name))
    (let* ((db-file (plist-get entry :file))
           (schema-name (tabularium-registry--ensure-schema-loaded db-file)))
      (unless schema-name
        (user-error "No schema found for %s. Create one with `tabularium-create-database'" db-file))
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
      (message "Opened: %s (%s)" schema-name (abbreviate-file-name db-file)))))

(defun tabularium-schema-switch ()
  "Switch to a different database/schema."
  (interactive)
  (let ((name (completing-read "Switch to schema: "
                               (tabularium-registry--completion-table)
                               nil t)))
    (tabularium-open name)))

;;; ** 3.9 Database Creation Wizard

(defvar tabularium-wizard--field-types
  '(("text" . text)
    ("integer" . integer)
    ("number" . number)
    ("date" . date)
    ("choice" . choice))
  "Alist of field type names to symbols.")

(defvar tabularium-wizard--completion-types
  '(("none" . nil)
    ("historical" . historical)
    ("fixed" . fixed))
  "Alist of completion type names to symbols.")

(defun tabularium-wizard--read-field ()
  "Interactively read a single field definition.
Returns a field plist or nil if user cancels."
  (let* ((name (read-string "Field name (empty to finish): "))
         field)
    (unless (string-empty-p name)
      (let* ((prompt (read-string (format "Prompt for '%s' [%s]: " name name)
                                  nil nil name))
             (type-name (completing-read "Type: " tabularium-wizard--field-types nil t nil nil "text"))
             (type (alist-get type-name tabularium-wizard--field-types nil nil #'equal))
             (choices nil)
             (completion nil)
             (default nil)
             (required nil)
             (primary nil))
        ;; For choice type, get the choices
        (when (eq type 'choice)
          (setq choices (tabularium-wizard--read-choices)))
        ;; Ask about completion for text fields
        (when (eq type 'text)
          (let ((comp-name (completing-read "Completion: " tabularium-wizard--completion-types nil t nil nil "none")))
            (setq completion (alist-get comp-name tabularium-wizard--completion-types nil nil #'equal))
            ;; For fixed completion, get choices
            (when (eq completion 'fixed)
              (setq choices (tabularium-wizard--read-choices)))))
        ;; Ask about default
        (when (y-or-n-p "Set a default value? ")
          (setq default
                (pcase type
                  ('date (if (y-or-n-p "Default to today? ")
                             'today
                           (read-string "Default date (YYYY-MM-DD): ")))
                  ('choice (completing-read "Default: " choices nil t))
                  ('integer (read-number "Default: "))
                  ('number (read-number "Default: "))
                  (_ (read-string "Default: ")))))
        ;; Ask about required
        (setq required (y-or-n-p "Required field? "))
        ;; Ask about primary key (for integer fields)
        (when (eq type 'integer)
          (setq primary (y-or-n-p "Primary key (auto-increment)? ")))
        ;; Build field plist
        (setq field (list :name (intern name)
                          :prompt prompt
                          :type type))
        (when choices
          (setq field (plist-put field :choice choices)))
        (when completion
          (setq field (plist-put field :complete completion)))
        (when default
          (setq field (plist-put field :default default)))
        (when required
          (setq field (plist-put field :required t)))
        (when primary
          (setq field (plist-put field :primary t)))))
    field))

(defun tabularium-wizard--read-choices ()
  "Read a list of choices from user."
  (let ((choices '())
        (choice nil))
    (message "Enter choices one at a time (empty to finish):")
    (while (not (string-empty-p (setq choice (read-string "Choice: "))))
      (push choice choices))
    (nreverse choices)))

(defun tabularium-wizard--read-fields ()
  "Read multiple field definitions.
Returns list of field plists."
  (let ((fields '())
        (field nil)
        (has-primary nil))
    (message "Define fields for your database (enter empty name to finish):")
    ;; Suggest adding an ID field first
    (when (y-or-n-p "Add an auto-increment ID field? ")
      (push '(:name id :prompt "ID" :type integer :primary t) fields)
      (setq has-primary t)
      (message "Added 'id' field as primary key."))
    ;; Read remaining fields
    (while (setq field (tabularium-wizard--read-field))
      (when (and (plist-get field :primary) has-primary)
        (message "Warning: Already have a primary key, removing from this field.")
        (setq field (plist-put field :primary nil)))
      (when (plist-get field :primary)
        (setq has-primary t))
      (push field fields)
      (message "Added field: %s" (plist-get field :name)))
    (nreverse fields)))

(defun tabularium-wizard--format-field (field)
  "Format a single FIELD plist as a string."
  (let ((items '()))
    (push (format ":name %s" (plist-get field :name)) items)
    (push (format ":prompt \"%s\"" (plist-get field :prompt)) items)
    (push (format ":type %s" (plist-get field :type)) items)
    (when (plist-get field :primary)
      (push ":primary t" items))
    (when (plist-get field :required)
      (push ":required t" items))
    (when (plist-get field :complete)
      (push (format ":complete %s" (plist-get field :complete)) items))
    (when (plist-get field :choice)
      (push (format ":choice %S" (plist-get field :choice)) items))
    (when (plist-get field :default)
      (let ((def (plist-get field :default)))
        (push (format ":default %s"
                      (if (or (symbolp def) (numberp def))
                          def
                        (format "\"%s\"" def)))
              items)))
    (concat "(" (string-join (nreverse items) " ") ")")))

(defun tabularium-wizard--generate-schema-file (name db-file fields &optional feature-name)
  "Generate contents for a schema file.
NAME is the schema name, DB-FILE is the database path,
FIELDS is the list of field definitions,
FEATURE-NAME is the feature to provide (defaults to NAME-schema)."
  (let ((feature (or feature-name
                     (intern (concat (downcase (replace-regexp-in-string " " "-" name))
                                     "-schema")))))
    (with-temp-buffer
      (insert (format ";;; %s.el --- Schema for %s -*- lexical-binding: t; -*-\n\n"
                      feature name))
      (insert ";;; Commentary:\n\n")
      (insert (format ";; Schema definition for the %s database.\n" name))
      (insert (format ";; Database file: %s\n" (abbreviate-file-name db-file)))
      (insert ";;\n")
      (insert ";; This file is automatically loaded when the database is opened.\n")
      (insert ";; You can add custom functions below the schema definition.\n\n")
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
      (insert "))\n\n")
      ;; Custom functions section
      (insert ";;; Custom Functions\n\n")
      (insert ";; Add your database-specific functions here.\n")
      (insert ";; Examples:\n")
      (insert ";;\n")
      (insert (format ";;   (defun %s-count-by-field (field value)\n"
                      (downcase (replace-regexp-in-string " " "-" name))))
      (insert ";;     \"Count records where FIELD equals VALUE.\"\n")
      (insert ";;     (interactive ...)\n")
      (insert ";;     ...)\n")
      (insert ";;\n")
      (insert (format ";;   (defhydra %s-hydra (:color blue :hint nil)\n"
                      (downcase (replace-regexp-in-string " " "-" name))))
      (insert ";;     \"Custom hydra for this database.\"\n")
      (insert ";;     ...)\n\n")
      ;; Provide
      (insert (format "(provide '%s)\n\n" feature))
      (insert (format ";;; %s.el ends here\n" feature))
      (buffer-string))))

;;;###autoload
(defun tabularium-create-database (name db-file)
  "Create a new database NAME at DB-FILE using an interactive wizard.
Walks through field definition, creates the schema and database files,
registers the database, and opens it."
  (interactive
   (let* ((name (read-string "Database name: "))
          (default-dir (expand-file-name "~/"))
          (default-base (concat (downcase (replace-regexp-in-string " " "-" name)) ".db"))
          (db-file (read-file-name "Database file: " default-dir default-base nil default-base)))
     (list name db-file)))
  (let ((db-file (expand-file-name db-file))
        (schema-file (tabularium-registry--schema-file-for-db db-file)))
    ;; Check if files already exist
    (when (file-exists-p db-file)
      (unless (y-or-n-p (format "Database %s exists. Overwrite? " db-file))
        (user-error "Aborted")))
    (when (file-exists-p schema-file)
      (unless (y-or-n-p (format "Schema %s exists. Overwrite? " schema-file))
        (user-error "Aborted")))
    ;; Read field definitions
    (let ((fields (tabularium-wizard--read-fields)))
      (when (null fields)
        (user-error "Cannot create database with no fields"))
      ;; Ensure directory exists
      (let ((dir (file-name-directory db-file)))
        (unless (file-exists-p dir)
          (make-directory dir t)))
      ;; Write schema file
      (let ((schema-content (tabularium-wizard--generate-schema-file name db-file fields)))
        (with-temp-file schema-file
          (insert schema-content)))
      (message "Created schema file: %s" schema-file)
      ;; Load the schema
      (tabularium-registry--load-schema-file schema-file)
      ;; Register in database list
      (tabularium-registry--add
       (list :name name
             :file db-file
             :schema-file schema-file
             :last-used (float-time)))
      ;; Open the database (this creates the .db file)
      (tabularium-open name)
      (tabularium-registry--refresh-if-visible)
      ;; Offer to edit the schema file
      (when (y-or-n-p "Open schema file for editing? ")
        (find-file schema-file)))))

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

View definitions are plists with:
  :name    - Display name for the view
  :default - If t, apply this view when opening the database
  :filter  - SQL WHERE clause (or nil to clear filter)
  :columns - List of column symbols to show (hides others)
  :sort    - Sort spec: (column . direction) for single-column,
             or ((col1 . dir1) (col2 . dir2)) for multi-column.
             Direction is \\='asc or \\='desc"
  (let* ((fields (plist-get args :fields))
         (has-primary (cl-find-if (lambda (f) (plist-get f :primary)) fields)))
    ;; Validate: a primary key field is required
    (unless has-primary
      (error "Schema \"%s\": no field has :primary t.  \
  Tabularium requires a primary key field (typically an integer ID) \
  for row identification, undo/redo, move, sort, and mark operations.  \
  Add :primary t to one field, e.g. (:name id :type integer :primary t :prompt \"ID\")"
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
      (mapcar (lambda (f) (plist-get f :name)) (tabularium--schema-fields))))

(defun tabularium--field-by-name (name)
  "Get field definition for NAME."
  (cl-find-if (lambda (f) (eq (plist-get f :name) name))
              (tabularium--schema-fields)))

(defun tabularium--stored-field-names ()
  "Return name strings for all non-computed fields."
  (mapcar (lambda (f) (symbol-name (plist-get f :name)))
          (cl-remove-if #'tabularium--computed-field-p
                        (tabularium--schema-fields))))

(defun tabularium--field-accepts-value-p (field-name value)
  "Return non-nil if FIELD-NAME's schema allows VALUE.
Choice fields with a `:choice' list reject values not in that list
\(empty values are always allowed).  Other types accept any value."
  (let* ((fields (tabularium--schema-fields))
         (field (cl-find-if
                 (lambda (f) (string= (symbol-name (plist-get f :name))
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
                 (lambda (f) (string= (symbol-name (plist-get f :name))
                                      (if (symbolp field-name)
                                          (symbol-name field-name)
                                        field-name)))
                 fields)))
    (and field (plist-get field :choice))))

(defun tabularium--field-crm ()
  "Prompt for field selection using `completing-read-multiple'.
Returns a list of field name strings, or nil meaning all stored fields."
  (let* ((all-fields (tabularium--stored-field-names))
         (candidates (cons "<<ALL>>" all-fields))
         (selected (completing-read-multiple
                    "Fields (<ALL>, or comma-separated): "
                    candidates nil t)))
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
    (user-error "No database open. Use `tabularium-open' first"))
  (let* ((schema (assoc tabularium--current-schema-name tabularium-schemas))
         (db-file (plist-get (cdr schema) :file))
         (schema-file (tabularium-registry--schema-file-for-db db-file)))
    (if (file-exists-p schema-file)
        (find-file schema-file)
      (user-error "Schema file not found: %s" schema-file))))

;;;###autoload
(defun tabularium-schema-show ()
  "Display the current database schema in a read-only buffer."
  (interactive)
  (unless tabularium--current-schema-name
    (user-error "No database open. Use `tabularium-open' first"))
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

(defun tabularium-schema-reload ()
  "Reload the current schema from its file.
Useful after editing the schema file externally."
  (interactive)
  (unless tabularium--current-schema-name
    (user-error "No database open. Use `tabularium-open' first"))
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
                      (lambda (f) (eq (plist-get f :name) primary))
                      fields))
          (choices (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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
  ;; Delegate to the multi-property column editor with just the rename slot
  (tabularium-view-column-edit
   (list (list :old-name old-name :new-name new-name))))

;;; ** 4.4 Computed Fields

;; Computed fields can be defined in the schema with:
;;   :computed EXPRESSION
;; Where EXPRESSION can be:
;;   - A string: SQL expression (e.g., "price * quantity")
;;   - A function: Elisp function receiving the row alist, returns computed value
;;   - A plist with :sql or :elisp key for explicit type
;;
;; Example schema:
;;   (:name total :type number :prompt "Total" :computed "price * quantity")
;;   (:name status :type text :prompt "Status" :computed (:elisp my-status-fn))
;;   (:name age :type integer :prompt "Age" :computed (:sql "strftime('%Y', 'now') - birth_year"))

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
  "Build SELECT clause including computed fields for VISIBLE-FIELDS."
  (mapcar (lambda (f)
            (let ((name (symbol-name (plist-get f :name)))
                  (sql-expr (tabularium--computed-sql-expression f)))
              (if sql-expr
                  (format "(%s) AS %s" sql-expr name)
                name)))
          visible-fields))

(defun tabularium--apply-elisp-computed (rows visible-fields computed-fields display-offset)
  "Apply elisp computed field values to ROWS.
VISIBLE-FIELDS is the ordered list of visible field plists.
COMPUTED-FIELDS is the subset with elisp :computed specs.
DISPLAY-OFFSET is the column offset for the primary key."
  (let ((visible-names (mapcar (lambda (f) (plist-get f :name)) visible-fields)))
    (mapcar
     (lambda (row)
       (let* ((row-list (copy-sequence row))
              ;; Build alist from all visible fields for computation context
              (alist (cl-mapcar
                      (lambda (f val) (cons (plist-get f :name) val))
                      visible-fields (nthcdr display-offset row-list))))
         ;; Compute each elisp field and update the row
         (dolist (cf computed-fields)
           (let* ((name (plist-get cf :name))
                  (value (tabularium--compute-field-value cf alist))
                  (pos (cl-position name visible-names))
                  (idx (when pos (+ display-offset pos))))
             (when (and idx value)
               (setf (nth idx row-list) value))))
         row-list))
     rows)))

;;; *** 4.4.2 Computational Helpers (tabularium-fn-*)

;; The functions below are intended for use inside `:computed' lambdas
;; in schema files.  Each receives the current row as an alist of
;; (FIELD-NAME . VALUE) pairs.

;; Conditional logic

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

;; Numeric and string aggregation across fields of the same row

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

;; Date arithmetic

(defun tabularium-fn-today ()
  "Return today's date as an ISO 8601 string (YYYY-MM-DD)."
  (format-time-string "%Y-%m-%d"))

(defun tabularium-fn-now ()
  "Return the current timestamp as an ISO 8601 string."
  (format-time-string "%Y-%m-%dT%H:%M:%S"))

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
Both arguments are ISO date strings.  Returns nil if either is empty."
  (when (and date1 date2
             (not (string-empty-p date1))
             (not (string-empty-p date2)))
    (let* ((p1 (parse-time-string date1))
           (p2 (parse-time-string date2))
           (t1 (encode-time (or (nth 0 p1) 0) (or (nth 1 p1) 0)
                            (or (nth 2 p1) 0)
                            (nth 3 p1) (nth 4 p1) (nth 5 p1)))
           (t2 (encode-time (or (nth 0 p2) 0) (or (nth 1 p2) 0)
                            (or (nth 2 p2) 0)
                            (nth 3 p2) (nth 4 p2) (nth 5 p2))))
      (round (/ (float-time (time-subtract t2 t1)) 86400)))))

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

;; Cross-row lookup and aggregation
;;
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
  (plist-get (tabularium--primary-field) :name))

;;; ** 4.5 Completion

;; Completion types: historical, recent, fixed, vocabulary, related,
;; filtered, function, union.  See `tabularium-schemas' docstring for details.

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
  (let* ((field-name (plist-get field :name))
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
                          (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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

;;; * 5 View & Navigation

;;; ** 5.1 View Core Functions

(defun tabularium-view--field-visible-p (field)
  "Return non-nil if FIELD should be visible."
  (let ((name (plist-get field :name)))
    (and (not (plist-get field :hidden))
         (not (memq name tabularium--hidden-columns)))))

(defun tabularium-view--ordered-visible-fields ()
  "Return visible fields in display order."
  (let* ((schema-fields (tabularium--schema-fields))
         (ordered (if tabularium--column-order
                      (cl-remove-if
                       #'null
                       (mapcar (lambda (name)
                                 (cl-find-if (lambda (f) (eq (plist-get f :name) name))
                                             schema-fields))
                               tabularium--column-order))
                    schema-fields)))
    (cl-remove-if-not #'tabularium-view--field-visible-p ordered)))

(defun tabularium-view--setup-columns ()
  "Set up tabulated list columns from schema."
  (let* ((visible-fields (tabularium-view--ordered-visible-fields))
         (base-columns
          (mapcar (lambda (field)
                    (list (plist-get field :prompt)
                          (or (plist-get field :width) 15)
                          t))
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

(defun tabularium-view--refresh ()
  "Refresh the list from database."
  (tabularium--ensure-db)
  (tabularium-view--setup-columns)
  (let* ((visible-fields (tabularium-view--ordered-visible-fields))
         (field-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
                              visible-fields))
         (primary-name (symbol-name (tabularium--primary-field-name)))
         ;; Build WHERE clause combining filter and ID range
         (where-parts (delq nil
                            (list
                             (tabularium--build-filter-clause)
                             (when tabularium--view-id-range
                               (format "%s >= %d AND %s <= %d"
                                       primary-name (car tabularium--view-id-range)
                                       primary-name (cdr tabularium--view-id-range))))))
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
         ;; Use custom limit or default page size
         (limit (or tabularium--view-limit tabularium-view-page-size))
         (sql (format "SELECT %s FROM %s %s ORDER BY %s LIMIT %d"
                      (string-join select-fields ", ")
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
                                          visible-fields)))))
    ;; Apply elisp computed fields if any
    (when elisp-computed
      (setq rows (tabularium--apply-elisp-computed rows visible-fields
                                                elisp-computed display-offset)))
    ;; Cell formatter: sanitize long fields for tabulated display
    (cl-flet ((format-cells (row)
               (let ((values (nthcdr display-offset row))
                     (idx -1))
                 (mapcar (lambda (v)
                           (cl-incf idx)
                           (let ((s (format "%s" (or v ""))))
                             (if (memq idx long-indices)
                                 ;; Strip newlines, truncate
                                 (let ((clean (replace-regexp-in-string
                                               "[\n\r]+" " " s)))
                                   (if (> (length clean) 60)
                                       (concat (substring clean 0 57) "...")
                                     clean))
                               s)))
                         values))))
    ;; Partition rows into frozen and regular
    (dolist (row rows)
      (if (member (car row) tabularium--frozen-ids)
          (push row frozen-rows)
        (push row regular-rows)))
    ;; Fetch any frozen rows that were not in the query results
    (dolist (fid tabularium--frozen-ids)
      (unless (cl-find-if (lambda (r) (equal (car r) fid)) frozen-rows)
        (let* ((fsql (format "SELECT %s FROM %s WHERE %s = ?"
                             (string-join select-fields ", ")
                             tabularium-table-name primary-name))
               (frow (tabularium-db-query-single tabularium--db fsql (list fid))))
          (when frow
            ;; Apply elisp computed to frozen row too
            (when elisp-computed
              (setq frow (car (tabularium--apply-elisp-computed
                               (list frow) visible-fields
                               elisp-computed display-offset))))
            (push frow frozen-rows)))))
    ;; Build entries with frozen rows first
    (setq tabulated-list-entries
          (append
           ;; Frozen rows with indicator
           (mapcar (lambda (row)
                     (list (car row)
                           (vconcat
                            (cons (propertize "∙" 'face 'font-lock-constant-face)
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
If a default view is defined in the schema, it will be applied automatically."
  (interactive)
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (buf (get-buffer-create (format "*%s*" (tabularium--schema-name))))
         (new-buffer-p (not (buffer-local-value 'tabularium--buffer-schema-name buf))))
    (with-current-buffer buf
      (tabularium-view-mode)
      (setq-local tabularium--buffer-schema-name schema-name)
      ;; Apply default view on first open
      (when new-buffer-p
        (tabularium--apply-default-view))
      (tabularium-view--refresh)
      (tabulated-list-print))
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
                  (sort-spec (plist-get updated-view :sort)))
              (setq tabularium--filter-layers
                    (when filter
                      (list (list :raw t :sql filter :desc active-view-name :join nil))))
              (when columns
                (let ((all-fields (mapcar (lambda (f) (plist-get f :name))
                                          (tabularium--schema-fields))))
                  (setq tabularium--hidden-columns
                        (cl-remove-if (lambda (col) (memq col columns)) all-fields)))
                (setq tabularium--column-order columns))
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

(defvar tabularium-view-mode-map
  (let ((map (make-sparse-keymap)))

    ;; === Navigation ===
    (define-key map (kbd "RET") #'tabularium-view-entry)
    (define-key map (kbd "g") #'tabularium-view-refresh)
    (define-key map (kbd "=") #'tabularium-view-refresh)
    (define-key map (kbd "^") #'tabularium-view-sort-reverse)
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
    (define-key map (kbd "M-<down>") #'tabularium-view-cell-jump-down)
    (define-key map (kbd "M-<up>") #'tabularium-view-cell-jump-up)
    (define-key map (kbd "M-<right>") #'tabularium-view-cell-jump-forward)
    (define-key map (kbd "M-<left>") #'tabularium-view-cell-jump-backward)
    (define-key map (kbd "C-<down>") #'tabularium-view-page-down)
    (define-key map (kbd "C-<up>") #'tabularium-view-page-up)
    (define-key map (kbd "C-<right>") #'tabularium-view-scroll-column-right)
    (define-key map (kbd "C-<left>") #'tabularium-view-scroll-column-left)
    ;; Filter
    (define-key map (kbd "f f") #'tabularium-view-filter)
    (define-key map (kbd "f =") #'tabularium-view-filter-exact)
    (define-key map (kbd "f #") #'tabularium-view-filter-numeric)
    (define-key map (kbd "f @") #'tabularium-view-filter-across)
    (define-key map (kbd "f d") #'tabularium-view-filter-delete)
    (define-key map (kbd "f s") #'tabularium-view-filter-toggle)
    (define-key map (kbd "f x") #'tabularium-view-clear-filter)
    (define-key map (kbd "f 0") #'tabularium-view-clear-filter)
    ;; Fill operations
    (define-key map (kbd "F F") #'tabularium-view-fill)
    (define-key map (kbd "F f") #'tabularium-view-fill-forward)
    (define-key map (kbd "F n") #'tabularium-view-fill-down)
    (define-key map (kbd "F p") #'tabularium-view-fill-up)
    (define-key map (kbd "F ,") #'tabularium-view-fill-up-to-point)
    (define-key map (kbd "F .") #'tabularium-view-fill-down-to-point)
    (define-key map (kbd "F s") #'tabularium-view-fill-series)
    (define-key map (kbd "F d") #'tabularium-view-fill-delete)
    (define-key map (kbd "F x") #'tabularium-view-fill-clear)
    ;; View management
    (define-key map (kbd "v v") #'tabularium-select-view)
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
    (define-key map (kbd "* *") #'tabularium-view-mark-matching)
    (define-key map (kbd "* =") #'tabularium-view-mark-exact)
    (define-key map (kbd "* p") #'tabularium-view-mark-pattern)
    (define-key map (kbd "* x") #'tabularium-view-mark-regexp)
    (define-key map (kbd "* #") #'tabularium-view-count-marked)
    ;; Freeze
    (define-key map (kbd "z z") #'tabularium-view-freeze)
    (define-key map (kbd "z *") #'tabularium-view-freeze-marked)
    (define-key map (kbd "z u") #'tabularium-view-unfreeze)
    (define-key map (kbd "z U") #'tabularium-view-unfreeze-marked)
    (define-key map (kbd "z x") #'tabularium-view-unfreeze-all)

    ;; === Constructive/Destructive ===
    ;; Create
    (define-key map (kbd "N") #'tabularium-new-entry)
    (define-key map (kbd "P") #'tabularium-prompt-entry)
    (define-key map (kbd "Q") #'tabularium-quick-entry)
    (define-key map (kbd "I") #'tabularium-view-insert)
    (define-key map (kbd "d") #'tabularium-view-duplicate)
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
    (define-key map (kbd "R r") #'tabularium-replace-substring)
    (define-key map (kbd "R R") #'tabularium-replace-visible-substring)
    (define-key map (kbd "R e") #'tabularium-replace-exact)
    (define-key map (kbd "R E") #'tabularium-replace-visible-exact)
    (define-key map (kbd "R p") #'tabularium-replace-pattern)
    (define-key map (kbd "R x") #'tabularium-replace-regexp)
    (define-key map (kbd "R X") #'tabularium-replace-visible-regexp)
    (define-key map (kbd "R /") #'tabularium-replace-query)
    (define-key map (kbd "R ?") #'tabularium-replace-visible-query)
    (define-key map (kbd "R c") #'tabularium-toggle-case-sensitive)
    ;; Sort (S prefix)
    (define-key map (kbd "s s") #'tabularium-view-sort-add)
    (define-key map (kbd "s d") #'tabularium-view-sort-delete)
    (define-key map (kbd "s x") #'tabularium-view-sort-clear)
    (define-key map (kbd "s 0") #'tabularium-view-sort-clear)
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
    (define-key map (kbd "| d") #'tabularium-view-column-duplicate)
    (define-key map (kbd "| M") #'tabularium-view-column-move)
    (define-key map (kbd "| W") #'tabularium-view-column-swap)
    (define-key map (kbd "| C") #'tabularium-view-column-copy)
    (define-key map (kbd "| X") #'tabularium-view-column-cut)
    (define-key map (kbd "| V") #'tabularium-view-column-paste)
    (define-key map (kbd "| A") #'tabularium-view-column-paste-append)
    ;; Schema operations
    (define-key map (kbd ". .") #'tabularium-schema-edit)
    (define-key map (kbd ". s") #'tabularium-schema-show)
    (define-key map (kbd ". r") #'tabularium-schema-reload)
    (define-key map (kbd ". w") #'tabularium-schema-switch)
    (define-key map (kbd ". +") #'tabularium-view-column-add)
    ;; Calculate operations
    (define-key map (kbd "# c") #'tabularium-aggregate-count)
    (define-key map (kbd "# V") #'tabularium-aggregate-visible-count)
    (define-key map (kbd "# *") #'tabularium-view-count-marked)
    (define-key map (kbd "# @") #'tabularium-view-count-across)
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
    (define-key map (kbd "v r") #'tabularium-view-show-range)
    (define-key map (kbd "v =") #'tabularium-view-reset-limit)

    ;; === Import/Export/Help ===
    (define-key map (kbd "e") #'tabularium-export)
    (define-key map (kbd "i") #'tabularium-import)
    (define-key map (kbd "$") #'tabularium-rename-database)
    (define-key map (kbd "o") #'tabularium-open)
    (define-key map (kbd "O") #'tabularium-open-and-view)
    (define-key map (kbd "?") #'tabularium-view-menu)
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
  (add-hook 'tabulated-list-revert-hook #'tabularium-view--refresh nil t)
  ;; Override revert so mark overlays are re-applied after tabulated-list-print
  (setq-local revert-buffer-function #'tabularium-view--revert))

(defun tabularium-view--revert (_ignore-auto _noconfirm)
  "Revert the view buffer and re-apply mark overlays."
  (let ((saved-id (tabulated-list-get-id))
        (saved-col (tabularium--column-name-at-point))
        (saved-win-start (window-start)))
    (tabularium-view--refresh)
    (tabulated-list-print t)
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
                    (mapcar (lambda (f) (plist-get f :name)) fields)))
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
   (let* ((all-fields (mapcar (lambda (f) (symbol-name (plist-get f :name)))
                              (tabularium--schema-fields)))
          (field (completing-read "Toggle column: " all-fields nil t)))
     (list (intern field))))
  (if (memq column-name tabularium--hidden-columns)
      (setq tabularium--hidden-columns (delq column-name tabularium--hidden-columns))
    (push column-name tabularium--hidden-columns))
  (revert-buffer)
  (message "Column %s %s" column-name
           (if (memq column-name tabularium--hidden-columns) "hidden" "shown")))

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
   (let* ((all-fields (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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

(defun tabularium-view-show-only-columns (columns)
  "Show only the selected COLUMNS, hiding all others."
  (interactive
   (let* ((all-fields (mapcar (lambda (f) (symbol-name (plist-get f :name)))
                              (tabularium--schema-fields)))
          (selected (completing-read-multiple "Show only columns: " all-fields)))
     (list (mapcar #'intern selected))))
  (when (null columns)
    (user-error "No columns selected"))
  (let ((all-names (mapcar (lambda (f) (plist-get f :name))
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
                     (mapcar (lambda (f) (plist-get f :name)) fields)))
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

(defun tabularium-last (field pattern)
  "Find most recent record where FIELD matches PATTERN."
  (interactive
   (let* ((field-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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
                       (symbol-name (plist-get date-field :name))
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
  "Move forward N cells in the tabulated list."
  (interactive "p")
  (dotimes (_ (or n 1))
    (tabulated-list-next-column 1)))

(defun tabularium-view-backward-cell (&optional n)
  "Move backward N cells in the tabulated list."
  (interactive "p")
  (dotimes (_ (or n 1))
    (tabulated-list-previous-column 1)))

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
         (col-start-pos (tabularium-view--column-start-position col-idx))
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
      (beginning-of-line)
      (forward-char col-start-pos)
      (tabularium-view-forward-cell)
      (message "First row"))))

(defun tabularium-view-last-row ()
  "Move to the last data row in the view, staying in the same column.
If already at the last row, move to the end of the line (bottom-right)."
  (interactive)
  (let* ((col-idx (tabularium--current-column-index))
         (col-start-pos (tabularium-view--column-start-position col-idx))
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
      (beginning-of-line)
      (forward-char col-start-pos)
      (tabularium-view-forward-cell)
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
COL-IDX is 0-based."
  (let ((pos 0))
    (dotimes (i col-idx)
      (setq pos (+ pos 1 (cadr (aref tabulated-list-format i)))))
    pos))

(defun tabularium-view--move-to-column (col-idx)
  "Move point to column COL-IDX on the current line.
COL-IDX is 0-based."
  (beginning-of-line)
  (forward-char (tabularium-view--column-start-position col-idx)))

(defun tabularium-view-cell-jump-down (&optional n)
  "Jump down to the next row where the current column value changes.
With prefix N, jump N value transitions."
  (interactive "p")
  (let* ((col-idx (tabularium--current-column-index))
         (col-start-pos (tabularium-view--column-start-position col-idx))
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
            (beginning-of-line)
            (forward-char col-start-pos)
            (cl-incf jumped))
           (last-row
            ;; No different value, but there are rows below - go to last row
            (goto-char last-row)
            (beginning-of-line)
            (forward-char col-start-pos)
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
         (col-start-pos (tabularium-view--column-start-position col-idx))
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
            (beginning-of-line)
            (forward-char col-start-pos)
            (tabularium-view-forward-cell)
            (cl-incf jumped))
           (first-row
            ;; No different value, but there are rows above - go to first row
            (goto-char first-row)
            (beginning-of-line)
            (forward-char col-start-pos)
            (tabularium-view-forward-cell)
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
      (tabularium-view--move-to-column found)
      (tabularium-view-forward-cell))
     ((> start-col 0)
      ;; No different value, go to first column
      (tabularium-view--move-to-column 0)
      (tabularium-view-forward-cell)
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
         (field-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) fields))
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
  "Fuzzy-find a record using completing-read."
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
  "Show all entries (remove page limit)."
  (interactive)
  (setq tabularium--view-limit most-positive-fixnum)
  (setq tabularium--view-id-range nil)
  (revert-buffer)
  (message "Showing all entries"))

(defun tabularium-view-show-range (start end)
  "Show entries with IDs from START to END (inclusive)."
  (interactive
   (let* ((default-start (or (tabularium--id-at-point) 1))
          (start (read-number "Start ID: " default-start))
          (end (read-number "End ID: " (+ start 100))))
     (list start end)))
  (setq tabularium--view-id-range (cons (min start end) (max start end)))
  (setq tabularium--view-limit most-positive-fixnum)
  (revert-buffer)
  (message "Showing entries %d-%d" (car tabularium--view-id-range) (cdr tabularium--view-id-range)))

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
VIEW is a plist with optional keys :filter, :columns, :sort."
  (let ((name (plist-get view :name))
        (filter (plist-get view :filter))
        (columns (plist-get view :columns))
        (sort-spec (plist-get view :sort)))
    ;; Apply filter
    (setq tabularium--filter-layers
          (when filter
            (list (list :raw t :sql filter :desc name :join nil))))
    ;; Apply column visibility and ordering
    (when columns
      (let ((all-fields (mapcar (lambda (f) (plist-get f :name))
                                (tabularium--schema-fields))))
        (setq tabularium--hidden-columns
              (cl-remove-if (lambda (col) (memq col columns)) all-fields)))
      (setq tabularium--column-order columns))
    ;; Apply sort — sort-spec is either (col . dir) or ((col1 . dir1) (col2 . dir2) ...)
    (when sort-spec
      (setq tabularium--sort-columns
            (if (and (consp (car sort-spec)) (symbolp (caar sort-spec)))
                ;; List of cons cells: ((year . desc) (month . desc))
                sort-spec
              ;; Single cons cell: (year . desc)
              (list sort-spec))))
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

(defun tabularium-view-clear ()
  "Clear the current view: no filter, all columns, default sort."
  (interactive)
  (setq tabularium--filter-layers nil)
  (setq tabularium--hidden-columns nil)
  (setq tabularium--sort-columns nil)
  ;; Reset sort direction to schema default or global default
  (setq tabularium--sort-ascending
        (if tabularium--current-schema-name
            (eq (tabularium--schema-default-sort) 'asc)
          tabularium-view-sort-ascending))
  (setq tabularium--column-order nil)
  (setq tabularium--current-view nil)
  (setq mode-name "Tabularium")
  (revert-buffer)
  (message "Cleared view - showing all data, all columns, default sort"))

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
Sets view parameters without calling revert-buffer (caller should refresh)."
  (when-let ((default-view (tabularium--schema-default-view)))
    (let ((name (plist-get default-view :name))
          (filter (plist-get default-view :filter))
          (columns (plist-get default-view :columns))
          (sort-spec (plist-get default-view :sort)))
      ;; Apply filter
      (setq tabularium--filter-layers
            (when filter
              (list (list :raw t :sql filter :desc name :join nil))))
      ;; Apply column visibility and ordering
      (when columns
        (let ((all-fields (mapcar (lambda (f) (plist-get f :name))
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
  :group 'tabularium)

(defface tabularium-query-replace-face
  '((t :inherit isearch))
  "Face for highlighting matches during query-replace."
  :group 'tabularium)

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

(defun tabularium-view-mark-matching (value &optional fields)
  "Mark all entries where VALUE appears as a substring in FIELDS.
FIELDS is a list of field name strings.  If nil, searches all fields."
  (interactive
   (let* ((value (read-string "Mark containing: "))
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
   (let* ((value (read-string "Mark equal to: "))
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
   (let* ((regexp (read-string "Mark matching regexp: "))
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
                    ("fill"         . tabularium-view-fill)
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
  "Line offset from window-start in the source buffer when the form was opened.")

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

;;; Long-field editing

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
Derived from `text-mode' with visual-line-mode and outline support.
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

(defface tabularium-entry-current-field
  '((((class color) (background dark))
     :background "#3a3a5a" :extend t)
    (((class color) (background light))
     :background "#dce4f8" :extend t)
    (t :inherit highlight :extend t))
  "Face for the currently selected field in entry mode."
  :group 'tabularium)

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
    (define-key map (kbd "d") #'tabularium-entry-duplicate)
    (define-key map (kbd "D") #'tabularium-entry-delete)
    (define-key map (kbd "C-x C-s") #'tabularium-entry-submit)
    ;; Navigation
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "M-n") #'tabularium-entry-next-entry)
    (define-key map (kbd "M-p") #'tabularium-entry-prev-entry)
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
  "Compute the default value for FIELD."
  (let ((default (plist-get field :default)))
    (pcase default
      ('today (format-time-string tabularium-date-format))
      ('now (format-time-string "%Y-%m-%d %H:%M:%S"))
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
         (col-names (mapcar (lambda (c) (plist-get c :name)) col-info))
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
     ;; Boolean type
     ((eq type 'boolean)
      '("yes" "no" "true" "false" "1" "0"))
     ;; No completion
     (t nil))))

(defvar-local tabularium-entry-first-field-line nil
  "Line number of first field in form buffer.")

(defvar-local tabularium-entry-footer-start nil
  "Position where footer starts in form buffer.")

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
      (let* ((name (plist-get field :name))
             (prompt (plist-get field :prompt))
             (required (plist-get field :required))
             (dyn-required
              (and (not required)
                   (run-hook-with-args-until-success
                    'tabularium-entry-required-field-functions
                    name tabularium-entry--values)))
             (type (plist-get field :type))
             (choices (plist-get field :choice))
             (value (or (alist-get name tabularium-entry--values) ""))
             (value-str (format "%s" value)))
        ;; Track first field line
        (unless first-field-line
          (setq first-field-line (line-number-at-pos)))
        ;; Field label — required marker occupies the last padding character
        ;; so the colon aligns at the same column for all fields.
        ;; `*' for static :required t (always required)
        ;; `+' for dynamic-required (plugin-declared, contextual)
        (cond
         (required
          (insert (propertize (format "  %-19s" prompt)
                              'face 'font-lock-keyword-face
                              'tabularium-entry-label name)
                  (propertize "*" 'face 'error)))
         (dyn-required
          (insert (propertize (format "  %-19s" prompt)
                              'face 'font-lock-keyword-face
                              'tabularium-entry-label name)
                  (propertize "+" 'face 'warning)))
         (t
          (insert (propertize (format "  %-20s" prompt)
                              'face 'font-lock-keyword-face
                              'tabularium-entry-label name))))
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
        ;; Type hint for choice fields (respect right padding)
        (when (and choices (eq type 'choice))
          (let* ((display-choices (if (<= (length choices) 5)
                                      (string-join choices ", ")
                                    (concat (string-join (seq-take choices 4) ", ") ", …")))
                 (hint (format "  [%s]" display-choices))
                 (avail (- 78 (current-column))))
            (when (> (length hint) avail)
              (setq hint (if (> avail 6)
                             (concat (substring hint 0 (- avail 1)) "…")
                           "")))
            (unless (string-empty-p hint)
              (insert (propertize hint 'face 'shadow)))))
        (insert "\n")))
    ;; Footer - double lines to match header
    (insert "\n")
    (setq footer-start (point))
    (insert (propertize (tabularium--make-box-footer 80 'double) 'face 'shadow) "\n")
    (insert "  "
            (propertize "TAB" 'face 'help-key-binding) "/"
            (propertize "S-TAB" 'face 'help-key-binding) " Nav  "
            (propertize "n" 'face 'help-key-binding) "/"
            (propertize "p" 'face 'help-key-binding) " Line ↓/↑  "
            (propertize "RET" 'face 'help-key-binding) " Edit  "
            (propertize "x" 'face 'help-key-binding) " Clear  "
            (propertize "X" 'face 'help-key-binding) " Clear+edit  "
            (propertize "=" 'face 'help-key-binding) " Default\n")
    (insert "  "
            (propertize "M-n" 'face 'help-key-binding) "/"
            (propertize "M-p" 'face 'help-key-binding) " Entry ↓/↑  "
            (propertize "v" 'face 'help-key-binding) " View  "
            (propertize "N" 'face 'help-key-binding) " New  "
            (propertize "I" 'face 'help-key-binding) " Insert  "
            (propertize "d" 'face 'help-key-binding) " Dup  "
            (propertize "D" 'face 'help-key-binding) " Del\n")
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

(defun tabularium-entry--read-with-prev-field (prompt completions initial)
  "Read input with PROMPT, COMPLETIONS, and INITIAL value.
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
              (if completions
                  (completing-read prompt completions nil nil initial)
                (read-string prompt initial))
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
    (when-let* ((field (cl-find-if (lambda (f) (eq (plist-get f :name) field-name))
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
                 (message "Saved %s (%d chars)" (plist-get field :prompt)
                          (length text))))))
        ;; Normal field: minibuffer prompt
        (let* ((prompt (plist-get field :prompt))
               (current-value (or (alist-get field-name tabularium-entry--values) ""))
               ;; Track if field was empty before editing
               (was-empty (tabularium-entry--field-empty-p field-name))
               (completions (tabularium-entry--get-field-completions field))
               (initial (if (stringp current-value)
                            current-value
                          (format "%s" current-value)))
               (new-value (tabularium-entry--read-with-prev-field
                           (format "%s: " prompt) completions initial)))
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
        (let* ((target-name (plist-get target-field :name))
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
                         (plist-get target-field :prompt) autofill-value)))))))))

(defun tabularium-entry-set-default ()
  "Set current field to its default value."
  (interactive)
  (when-let* ((field-name tabularium-entry--current-field)
              (field (cl-find-if (lambda (f) (eq (plist-get f :name) field-name))
                                 tabularium-entry--fields))
              (default (tabularium--compute-default field)))
    (tabularium-entry--set-field-value field-name default)
    (tabularium-entry-render)
    (tabularium-entry--goto-field field-name)
    (message "Set %s to default: %s" (plist-get field :prompt) default)))

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
      (let* ((name (plist-get field :name))
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
                          (plist-get field :prompt)))))))
    ;; Save
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
                            :id tabularium-entry-editing-id
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
        (tabularium--undo-push (list :type 'insert :id new-id :data values))
        (tabularium--invalidate-cache)
        (message "Entry added")))
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
Returns t if the buffer is safe to clobber (no changes, or user
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
          (tabularium--undo-push (list :type 'delete :id id :data old-data)))
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
        (dolist (old-id ids-to-shift)
          (tabularium-db-execute
           tabularium--db
           (format "UPDATE %s SET %s = ? WHERE %s = ?"
                   tabularium-table-name primary-name-str primary-name-str)
           (list (1+ old-id) old-id)))
        (tabularium--invalidate-cache)
        ;; Open new entry form with the position as ID (not editing existing)
        (let* ((fields (tabularium--schema-fields))
               (buf (get-buffer-create (format "*%s Form*" schema-name)))
               (initial-values
                (mapcar (lambda (f)
                          (let ((name (plist-get f :name)))
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
                      (let ((name (plist-get f :name)))
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

;;; *** 6.1.2 Prompt Entry

(defun tabularium--read-field (field &optional initial context)
  "Read a value for FIELD with appropriate completion.
INITIAL provides pre-filled value for editing.
CONTEXT is an alist of current field values for related completion.
Fields with `:long t' open a dedicated editing buffer."
  (if (plist-get field :long)
      ;; Long field: open buffer, use recursive-edit to block
      (let* ((field-name (symbol-name (plist-get field :name)))
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
            (when (not (string-empty-p initial-str))
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
    (let* ((prompt-base (plist-get field :prompt))
         (field-type (plist-get field :type))
         (required (plist-get field :required))
         (default (or initial (tabularium--compute-default field)))
         (prompt (format "%s%s%s: "
                         prompt-base
                         (if required "*" "")
                         (if default (format " [%s]" default) "")))
         value)
    (setq value
          (pcase field-type
            ('date
             (read-string prompt (or initial default)))
            ('integer
             (let ((input (read-string prompt (when (or initial default)
                                                (format "%s" (or initial default))))))
               (if (string-empty-p input)
                   default
                 (string-to-number input))))
            ('number
             (let ((input (read-string prompt (when (or initial default)
                                                (format "%s" (or initial default))))))
               (if (string-empty-p input)
                   default
                 (string-to-number input))))
            ('choice
             (let ((choices (plist-get field :choice)))
               (completing-read prompt (append choices '("")) nil nil nil nil (or initial default))))
            ('text
             (if (plist-get field :complete)
                 (let ((candidates (tabularium--get-completion-candidates field context)))
                   (completing-read prompt candidates nil nil nil nil (or initial default)))
               (read-string prompt (or initial default))))
            (_ (read-string prompt (or initial default)))))
    ;; Handle empty string (default)
    (when (and (stringp value) (string-empty-p value))
      (setq value default))
    ;; Validate required
    (when (and required (or (null value) (and (stringp value) (string-empty-p value))))
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
      (let* ((name (plist-get field :name))
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
         (col-names (mapcar (lambda (c) (plist-get c :name)) col-info))
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
      (let* ((name (plist-get field :name))
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

;;; ** 6.2 Duplicate Entry

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
        (let* ((name (plist-get field :name))
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

;;; ** 6.3 Edit Entry

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
        (let* ((name (plist-get field :name))
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

;;; * 7 Data Manipulation

;;; ** 7.1 Row Operations

;;; *** 7.1.1 Index Management

(defcustom tabularium-auto-reindex nil
  "If non-nil, automatically reindex after operations that modify row count.
This ensures IDs stay sequential without gaps.
WARNING: Enabling this breaks undo/redo functionality for those operations.
Consider leaving this nil and using `tabularium-reindex' manually when needed."
  :type 'boolean
  :group 'tabularium-database)

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
            (cl-incf final-id))))

      (tabularium--invalidate-cache))))

(defun tabularium-reindex ()
  "Renumber all entries sequentially starting from 1.
Fixes gaps and duplicates in the primary key column."
  (interactive)
  (tabularium--ensure-db)
  (when (yes-or-no-p "Reindex all entries? This will renumber all IDs starting from 1. ")
    (let ((count (caar (tabularium-db-query
                        tabularium--db
                        (format "SELECT COUNT(*) FROM %s" tabularium-table-name)))))
      (tabularium--reindex-silent)
      (when (derived-mode-p 'tabularium-view-mode)
        (revert-buffer))
      (message "Reindexed %d entries (1 to %d)" count count))))

;;; *** 7.1.2 Multi-Column Sort

(defun tabularium-view-sort-reverse ()
  "Reverse the current sort order.
If a custom sort is active, flips the direction of every column.
Otherwise, toggles the default primary-key sort direction."
  (interactive)
  (if tabularium--sort-columns
      (progn
        (setq tabularium--sort-columns
              (mapcar (lambda (x)
                        (cons (car x) (if (eq (cdr x) 'asc) 'desc 'asc)))
                      tabularium--sort-columns))
        (revert-buffer)
        (message "Sort reversed: %s" (tabularium--sort-description)))
    (setq tabularium--sort-ascending (not tabularium--sort-ascending))
    (revert-buffer)
    (message "Sort order: %s first" (if tabularium--sort-ascending "oldest" "newest"))))

(defun tabularium-view-sort-delete (column)
  "Delete COLUMN from the current sort order."
  (interactive
   (if (null tabularium--sort-columns)
       (user-error "No sort columns to delete")
     (let* ((current (mapcar (lambda (x)
                               (format "%s %s" (car x)
                                       (if (eq (cdr x) 'asc) "↑" "↓")))
                             tabularium--sort-columns))
            (choice (completing-read "Delete sort column: " current nil t))
            (col-name (car (split-string choice " "))))
       (list (intern col-name)))))
  (let ((new-sort (cl-remove-if (lambda (x) (eq (car x) column))
                                tabularium--sort-columns)))
    (setq tabularium--sort-columns new-sort)
    (revert-buffer)
    (if new-sort
        (message "Sort: %s" (tabularium--sort-description))
      (message "Sort cleared (default order)"))))

(defun tabularium-view-sort-add (column direction)
  "Add COLUMN as additional sort key with DIRECTION."
  (interactive
   (let* ((existing (mapcar #'car tabularium--sort-columns))
          (fields (cl-remove-if
                   (lambda (name) (memq (intern name) existing))
                   (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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
  (setq tabularium--sort-columns
        (append tabularium--sort-columns
                (list (cons column direction))))
  (revert-buffer)
  (message "Sort: %s" (tabularium--sort-description)))

(defun tabularium-view-sort-clear ()
  "Clear all sort columns, return to default (primary key desc)."
  (interactive)
  (setq tabularium--sort-columns nil)
  (revert-buffer)
  (message "Sort cleared (default order)"))

(defun tabularium--sort-description ()
  "Return human-readable sort description."
  (if tabularium--sort-columns
      (mapconcat (lambda (x)
                   (format "%s %s" (car x) (if (eq (cdr x) 'asc) "↑" "↓")))
                 tabularium--sort-columns ", ")
    "default"))

(defun tabularium--build-order-clause ()
  "Build ORDER BY clause from `tabularium--sort-columns'."
  (if tabularium--sort-columns
      (mapconcat (lambda (x)
                   (format "%s %s" (car x) (upcase (symbol-name (cdr x)))))
                 tabularium--sort-columns ", ")
    ;; Default sort
    (format "%s %s"
            (tabularium--primary-field-name)
            (if tabularium--sort-ascending "ASC" "DESC"))))

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
      ;; Collect data and delete
      (dolist (id ids)
        (when-let ((data (tabularium--get-record-by-id id)))
          (push data entries)
          (push (list :type 'delete :id id :data data) ops)
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
      ;; Auto-reindex if enabled
      (when tabularium-auto-reindex
        (tabularium--reindex-silent))
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
        (tabularium--paste-column-batch batch consume)
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
            (push (list :type 'insert :id new-id :data data) ops)
            (cl-incf new-id))))
      ;; Record undo - type depends on whether batch was consumed
      (if consumed
          ;; Consumed: undo should restore batch to kill ring
          (tabularium--undo-push (list :type 'paste
                                   :ops (nreverse ops)
                                   :batch batch))
        ;; Not consumed: undo just deletes, does not touch kill ring
        (tabularium--undo-push (list :type 'yank :ops (nreverse ops))))
      ;; Auto-reindex if enabled
      (when tabularium-auto-reindex
        (tabularium--reindex-silent))
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
                   (list new-id temp-id)))
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
          (dolist (id ids)
            (let* ((data (tabularium--get-record-by-id id))
                   (new-id (tabularium--next-id)))
              (when data
                (setf (alist-get primary-name data) new-id)
                (tabularium-db-insert tabularium--db tabularium-table-name data)
                (push (list :type 'insert :id new-id :data data) ops))))
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
        (dolist (id ids)
          (let ((data (tabularium--get-record-by-id id)))
            (push (list :type 'delete :id id :data data) ops)
            (tabularium-db-delete tabularium--db
                              tabularium-table-name
                              (tabularium--primary-field-name)
                              id)))
        (tabularium--undo-push (if (= 1 (length ops))
                               (car ops)
                             (list :type 'multi :ops (nreverse ops))))
        (setq tabularium--marked-entries nil)
        ;; Auto-reindex if enabled
        (when tabularium-auto-reindex
          (tabularium--reindex-silent))
        (tabularium--invalidate-cache)
        (let ((saved-col (tabularium--column-name-at-point)))
          (revert-buffer)
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
      (user-error "Position %d is beyond current max (%d). Use new-entry instead." position max-id))
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
                      (let ((name (plist-get f :name)))
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
  "Swap positions of two entries.
If exactly 2 entries are marked, swaps them.
If >2 entries are marked, suggests using move instead.
Otherwise swaps entry at point with another.  Undoable."
  (interactive
   (cond
    ((and tabularium--marked-entries
          (> (length tabularium--marked-entries) 2))
     (user-error "Cannot swap >2 entries. Use `tabularium-view-move' (M) to reorder multiple entries"))
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
    (tabularium--undo-push (list :type 'swap :id1 id1 :id2 id2))
    ;; Clear marks
    (when tabularium--marked-entries
      (setq tabularium--marked-entries nil)
      (tabularium-view--update-mark-display))
    (tabularium--invalidate-cache)
    (revert-buffer)
    (message "Swapped entries %d and %d" id1 id2)))

;;; *** 7.1.4 Freeze Rows

(defun tabularium-view-freeze ()
  "Freeze entry at point or all marked entries to the top of view.
If entries are marked, freezes all marked entries and clears marks.
Otherwise, freezes the entry at point."
  (interactive)
  (if tabularium--marked-entries
      (tabularium-view-freeze-marked)
    (when-let ((id (tabularium--id-at-point)))
      (if (member id tabularium--frozen-ids)
          (message "Entry #%s is already frozen" id)
        (push id tabularium--frozen-ids)
        (revert-buffer)
        (message "Frozen entry #%s (%d frozen)" id (length tabularium--frozen-ids))))))

(defun tabularium-view-freeze-marked ()
  "Freeze all marked entries to the top of the view.
Clears marks after pinning."
  (interactive)
  (unless tabularium--marked-entries
    (user-error "No marked entries"))
  (let ((count 0))
    (dolist (id tabularium--marked-entries)
      (unless (member id tabularium--frozen-ids)
        (push id tabularium--frozen-ids)
        (cl-incf count)))
    (setq tabularium--marked-entries nil)
    (tabularium-view--update-mark-display)
    (revert-buffer)
    (message "Frozen %d marked entries (%d total frozen)" count (length tabularium--frozen-ids))))

(defun tabularium-view-unfreeze ()
  "Unfreeze entry at point."
  (interactive)
  (when-let ((id (tabularium--id-at-point)))
    (if (member id tabularium--frozen-ids)
        (progn
          (setq tabularium--frozen-ids (delete id tabularium--frozen-ids))
          (revert-buffer)
          (message "Unfroze entry #%s (%d still frozen)" id (length tabularium--frozen-ids)))
      (message "Entry #%s is not frozen" id))))

(defun tabularium-view-unfreeze-marked ()
  "Unfreeze all marked entries.
Clears marks after unpinning."
  (interactive)
  (unless tabularium--marked-entries
    (user-error "No marked entries"))
  (let ((count 0))
    (dolist (id tabularium--marked-entries)
      (when (member id tabularium--frozen-ids)
        (setq tabularium--frozen-ids (delete id tabularium--frozen-ids))
        (cl-incf count)))
    (setq tabularium--marked-entries nil)
    (tabularium-view--update-mark-display)
    (revert-buffer)
    (message "Unfroze %d marked entries (%d still frozen)" count (length tabularium--frozen-ids))))

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
                            (mapcar (lambda (f) (plist-get f :name)) fields)))
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
  "Move the current column one position left."
  (interactive)
  (let* ((col-idx (tabularium--current-column-index))
         (fields (tabularium--schema-fields))
         (order (or tabularium--column-order
                    (mapcar (lambda (f) (plist-get f :name)) fields))))
    (when (and col-idx (> col-idx 0))
      (let ((col (nth col-idx order)))
        (setq order (delete col order))
        (setq order (append (seq-take order (1- col-idx))
                            (list col)
                            (seq-drop order (1- col-idx))))
        (setq tabularium--column-order order)
        (revert-buffer)))))

(defun tabularium-view-move-column-right ()
  "Move the current column one position right."
  (interactive)
  (let* ((col-idx (tabularium--current-column-index))
         (fields (tabularium--schema-fields))
         (order (or tabularium--column-order
                    (mapcar (lambda (f) (plist-get f :name)) fields)))
         (max-idx (1- (length order))))
    (when (and col-idx (< col-idx max-idx))
      (let ((col (nth col-idx order)))
        (setq order (delete col order))
        (setq order (append (seq-take order (1+ col-idx))
                            (list col)
                            (seq-drop order (1+ col-idx))))
        (setq tabularium--column-order order)
        (revert-buffer)))))

(defun tabularium-view-reset-column-order ()
  "Reset columns to schema-defined order."
  (interactive)
  (setq tabularium--column-order nil)
  (revert-buffer)
  (message "Column order reset to default"))

(defun tabularium--current-column-index ()
  "Get the index of the column at point."
  (when (derived-mode-p 'tabularium-view-mode)
    (let ((col (current-column))
          (idx 0)
          (pos 0))
      (dotimes (i (length tabulated-list-format))
        (let ((width (+ 1 (cadr (aref tabulated-list-format i)))))
          (when (and (>= col pos) (< col (+ pos width)))
            (setq idx i))
          (setq pos (+ pos width))))
      idx)))

;;; *** 7.2.2 Creative/Destructive Operations

(defun tabularium--column-name-at-point ()
  "Return the column name (symbol) at point in view mode, or nil."
  (when (derived-mode-p 'tabularium-view-mode)
    (when-let ((idx (tabularium--current-column-index)))
      (let* ((fields (tabularium--schema-fields))
             (order (or tabularium--column-order
                        (mapcar (lambda (f) (plist-get f :name)) fields)))
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

(defun tabularium-view-column-add (name type prompt &optional default after-column)
  "Add a new column NAME with TYPE and PROMPT to the current table.
TYPE should be one of: text, integer, number, date, choice.
AFTER-COLUMN is the column name (symbol) to insert after; the symbol
\\='__first__ means insert after the primary key column; nil means append.
This modifies both the database and the schema.  Undoable."
  (interactive
   (let* ((name (read-string "Column name (symbol): "))
          (type (intern (completing-read "Type: "
                                         '("text" "integer" "number" "date" "choice") nil t)))
          (prompt (read-string "Prompt: " (capitalize name)))
          (default-val (read-string "Default value (empty for none): "))
          ;; Build position candidates
          (fields (tabularium--schema-fields))
          (col-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) fields))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (tabularium--column-name-at-point)))
          (candidates (append (when at-point-name
                               (list (format "<POINT> %s" (symbol-name at-point-name))))
                             (list "<<FIRST>>" "<<LAST>>")
                             col-names))
          (pos-default (if at-point-name
                           (format "<POINT> %s" (symbol-name at-point-name))
                         "<<LAST>>"))
          (choice (completing-read "Insert after: " candidates nil t nil nil pos-default))
          (after (cond
                  ((string= choice "<<LAST>>") nil)
                  ((string= choice "<<FIRST>>") '__first__)
                  ((string-prefix-p "<POINT> " choice) at-point-name)
                  (t (intern choice)))))
     (list (intern name) type prompt
           (if (string-empty-p default-val) nil default-val)
           after)))
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (primary (tabularium--primary-field-name))
         (sql-type (pcase type
                     ('integer "INTEGER")
                     ('number "REAL")
                     (_ "TEXT")))
         (default-clause (if default
                             (format " DEFAULT '%s'" default)
                           ""))
         ;; Calculate width based on prompt length or default value
         (width (max (length prompt)
                     (if default (length default) 10)
                     10)))
    ;; Add column to database
    (tabularium-db-execute tabularium--db
                           (format "ALTER TABLE %s ADD COLUMN %s %s%s"
                                   tabularium-table-name name sql-type default-clause)
                           nil)
    ;; Update schema in memory
    (let* ((schema (assoc schema-name tabularium-schemas))
           (plist (cdr schema))
           (fields (plist-get plist :fields))
           (new-field (list :name name :type type :prompt prompt :width width
                            :complete (if (eq type 'text) 'historical nil))))
      (when default
        (setq new-field (plist-put new-field :default default)))
      ;; Insert at the right position
      (cond
       ((eq after-column '__first__)
        ;; After primary key column
        (let ((pk-pos (or (cl-position-if
                           (lambda (f) (eq (plist-get f :name) primary))
                           fields)
                          0)))
          (setq fields (append (seq-take fields (1+ pk-pos))
                               (list new-field)
                               (seq-drop fields (1+ pk-pos))))))
       (after-column
        (let ((pos (cl-position-if
                    (lambda (f) (eq (plist-get f :name) after-column))
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
       (list :type 'add-column :name name :field-plist new-field)))
    (tabularium--invalidate-cache)
    (when (derived-mode-p 'tabularium-view-mode)
      (let ((saved-id (tabulated-list-get-id)))
        (revert-buffer)
        (tabularium-view--goto-position saved-id name)))
    (message "Added column '%s' (%s)%s" name type
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
                      (lambda (f) (eq (plist-get f :name) primary))
                      fields))
          (choices (mapcar (lambda (f) (symbol-name (plist-get f :name))) deletable))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (let ((col (tabularium--column-name-at-point)))
                             (when (and col (not (eq col primary)))
                               col))))
          (candidates (append (when at-point-name
                               (list (format "<POINT> %s"
                                             (symbol-name at-point-name))))
                             choices))
          (selected (completing-read-multiple "Delete column(s): " candidates nil t))
          (resolved (mapcar (lambda (s)
                              (if (string-prefix-p "<POINT> " s)
                                  at-point-name
                                (intern s)))
                            selected)))
     (list (delete-dups resolved))))
  (tabularium--ensure-db)
  (let* ((primary-name (tabularium--primary-field-name))
         ;; Save visible column order before deletion for cursor fallback
         (pre-visible
          (when (derived-mode-p 'tabularium-view-mode)
            (mapcar (lambda (f) (plist-get f :name))
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
               (field-plist (cl-find-if (lambda (f) (eq (plist-get f :name) name)) fields))
               (position (cl-position field-plist fields :test #'equal))
               (primary-str (symbol-name primary-name))
               (rows (tabularium-db-query
                      tabularium--db
                      (format "SELECT %s, %s FROM %s WHERE %s IS NOT NULL AND %s != ''"
                              primary-str name-str tabularium-table-name
                              name-str name-str)
                      nil))
               (col-data (mapcar (lambda (row) (cons (car row) (cadr row))) rows)))
          ;; Recreate table without this column
          (let* ((keep-fields (cl-remove-if (lambda (f) (eq (plist-get f :name) name)) fields))
                 (keep-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) keep-fields))
                 (cols-str (string-join keep-names ", ")))
            (tabularium-db-execute tabularium--db
                                   (format "CREATE TABLE %s_backup AS SELECT %s FROM %s"
                                           tabularium-table-name cols-str tabularium-table-name)
                                   nil)
            (tabularium-db-execute tabularium--db
                                   (format "DROP TABLE %s" tabularium-table-name)
                                   nil)
            (tabularium-db-execute tabularium--db
                                   (format "ALTER TABLE %s_backup RENAME TO %s"
                                           tabularium-table-name tabularium-table-name)
                                   nil))
          ;; Update schema in memory
          (let* ((schema (assoc schema-name tabularium-schemas))
                 (plist (cdr schema))
                 (new-fields (cl-remove-if (lambda (f) (eq (plist-get f :name) name))
                                           (plist-get plist :fields))))
            (setf (cdr schema) (plist-put plist :fields new-fields))
            (tabularium--save-schema-to-file schema-name))
          (push (list :type 'delete-column :name name
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
                            (when (not result) (setq result prev))
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
          (all-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) fields))
          (movable (cl-remove-if
                    (lambda (f) (eq (plist-get f :name) primary))
                    fields))
          (movable-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) movable))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (let ((col (tabularium--column-name-at-point)))
                             (when (and col (not (eq col primary)))
                               col))))
          (sel-candidates (append (when at-point-name
                                   (list (format "<POINT> %s"
                                                 (symbol-name at-point-name))))
                                 movable-names))
          (selected (completing-read-multiple "Move columns: " sel-candidates nil t))
          (sel-syms (mapcar (lambda (s)
                              (if (string-prefix-p "<POINT> " s)
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
                                   (list (format "<POINT> %s"
                                                 (symbol-name tgt-at-point))))
                                 (list "<<FIRST>>" "<<LAST>>")
                                 remaining))
          (tgt-default (if tgt-at-point
                           (format "<POINT> %s" (symbol-name tgt-at-point))
                         "<<FIRST>>"))
          (target-choice (completing-read "Move before: " tgt-candidates nil t
                                          nil nil tgt-default))
          (before-col (cond
                       ((string= target-choice "<<FIRST>>") '__first__)
                       ((string= target-choice "<<LAST>>") nil)
                       ((string-prefix-p "<POINT> " target-choice) tgt-at-point)
                       (t (intern target-choice)))))
     (list sel-syms before-col)))
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (schema (assoc schema-name tabularium-schemas))
         (plist (cdr schema))
         (fields (plist-get plist :fields))
         (old-order (mapcar (lambda (f) (plist-get f :name)) fields))
         (primary (tabularium--primary-field-name))
         ;; Ensure columns is a proper list of symbols
         (columns (if (listp columns) columns (list columns)))
         ;; Remove selected columns from the list
         (remaining (cl-remove-if (lambda (f)
                                    (member (plist-get f :name) columns))
                                  fields))
         (moved-fields (cl-remove-if-not (lambda (f)
                                           (member (plist-get f :name) columns))
                                         fields))
         ;; Convert before-column to insertion position
         (pos (cond
               ;; __first__: after primary key
               ((eq target '__first__)
                (1+ (or (cl-position-if
                         (lambda (f) (eq (plist-get f :name) primary))
                         remaining)
                        0)))
               ;; nil: at end
               ((null target) (length remaining))
               ;; Named column: before it (find its position in remaining)
               (t (or (cl-position-if
                       (lambda (f) (eq (plist-get f :name) target))
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
          (all-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) fields))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (tabularium--column-name-at-point)))
          (first-candidates (append (when at-point-name
                                     (list (format "<POINT> %s" (symbol-name at-point-name))))
                                   all-names))
          (first-choice (completing-read "Swap column: " first-candidates nil t))
          (first (if (string-prefix-p "<POINT> " first-choice)
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
         (old-order (mapcar (lambda (f) (plist-get f :name)) fields))
         (idx-a (cl-position-if (lambda (f) (eq (plist-get f :name) col-a)) fields))
         (idx-b (cl-position-if (lambda (f) (eq (plist-get f :name) col-b)) fields)))
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
          (all-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) fields))
          (selected (completing-read-multiple "Copy columns: " all-names nil t)))
     (list (mapcar #'intern selected))))
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
        (push (list :name col :field-plist (copy-sequence field-plist) :data col-data)
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
          (col-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) fields))
          (at-point (when (derived-mode-p 'tabularium-view-mode)
                      (tabularium--column-name-at-point)))
          (candidates (append (when at-point
                                (list (format "<POINT> %s" (symbol-name at-point))))
                              col-names))
          (default (if at-point
                       (format "<POINT> %s" (symbol-name at-point))
                     (car col-names)))
          (choice (completing-read "Duplicate column: " candidates nil t nil nil default))
          (source (if (string-prefix-p "<POINT> " choice)
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
    (setq new-field (plist-put new-field :name new-name))
    (setq new-field (plist-put new-field :prompt
                               (or (read-string
                                    (format "Prompt for %s: " new-name)
                                    (plist-get field-plist :prompt))
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
                 (lambda (f) (eq (plist-get f :name) source-col))
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
       (list :type 'add-column :name new-name :field-plist new-field)))
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
                      (lambda (f) (eq (plist-get f :name) primary))
                      fields))
          (choices (mapcar (lambda (f) (symbol-name (plist-get f :name))) deletable))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (let ((col (tabularium--column-name-at-point)))
                             (when (and col (not (eq col primary)))
                               col))))
          (candidates (append (when at-point-name
                               (list (format "<POINT> %s"
                                             (symbol-name at-point-name))))
                             choices))
          (selected (completing-read-multiple "Cut columns: " candidates nil t))
          (resolved (mapcar (lambda (s)
                              (if (string-prefix-p "<POINT> " s)
                                  at-point-name
                                (intern s)))
                            selected)))
     (list (delete-dups resolved))))
  (tabularium--ensure-db)
  ;; Save visible order before cut for cursor fallback
  (let ((pre-visible
         (when (derived-mode-p 'tabularium-view-mode)
           (mapcar (lambda (f) (plist-get f :name))
                   (cl-remove-if-not #'tabularium-view--field-visible-p
                                     (tabularium--schema-fields))))))
    ;; First copy to kill ring
    (tabularium-view-column-copy columns)
    ;; Then delete each column
    (let ((ops '()))
    (dolist (col columns)
      (let* ((schema-name (tabularium--schema-name))
             (fields (tabularium--schema-fields))
             (field-plist (cl-find-if (lambda (f) (eq (plist-get f :name) col)) fields))
             (position (cl-position field-plist fields :test #'equal))
             (name-str (symbol-name col))
             (primary-str (symbol-name (tabularium--primary-field-name)))
             (rows (tabularium-db-query
                    tabularium--db
                    (format "SELECT %s, %s FROM %s WHERE %s IS NOT NULL AND %s != ''"
                            primary-str name-str tabularium-table-name
                            name-str name-str)
                    nil))
             (col-data (mapcar (lambda (row) (cons (car row) (cadr row))) rows)))
        ;; Recreate table without this column
        (let* ((current-fields (tabularium--schema-fields))
               (keep-fields (cl-remove-if (lambda (f) (eq (plist-get f :name) col))
                                           current-fields))
               (keep-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
                                    keep-fields))
               (cols-str (string-join keep-names ", ")))
          (tabularium-db-execute tabularium--db
                                 (format "CREATE TABLE %s_backup AS SELECT %s FROM %s"
                                         tabularium-table-name cols-str tabularium-table-name)
                                 nil)
          (tabularium-db-execute tabularium--db
                                 (format "DROP TABLE %s" tabularium-table-name)
                                 nil)
          (tabularium-db-execute tabularium--db
                                 (format "ALTER TABLE %s_backup RENAME TO %s"
                                         tabularium-table-name tabularium-table-name)
                                 nil))
        ;; Update schema
        (let* ((schema (assoc schema-name tabularium-schemas))
               (plist (cdr schema))
               (new-fields (cl-remove-if (lambda (f) (eq (plist-get f :name) col))
                                          (plist-get plist :fields))))
          (setf (cdr schema) (plist-put plist :fields new-fields))
          (tabularium--save-schema-to-file schema-name))
        (push (list :type 'delete-column :name col
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
      (let* ((saved-id (tabulated-list-get-id))
             (saved-col (tabularium--column-name-at-point))
             (fallback-col
              (when (and pre-visible (member saved-col columns))
                (let ((found-deleted nil)
                      (result nil))
                  (dolist (col pre-visible)
                    (if (member col columns)
                        (setq found-deleted t)
                      (when (and found-deleted (not result))
                        (setq result col))))
                  (unless result
                    (let ((prev nil))
                      (dolist (col pre-visible)
                        (if (member col columns)
                            (when (not result) (setq result prev))
                          (setq prev col)))))
                  result))))
        (revert-buffer)
        (tabularium-view--goto-position saved-id
                                        (if (member saved-col columns)
                                            fallback-col
                                          saved-col))))
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
POSITION may be a column name (paste before that column), the symbol
\\='__first__ (paste after the primary key), \\='last (append at end),
or nil (prompt the user)."
  (tabularium--ensure-db)
  (let* ((columns (plist-get batch :columns))
         (schema-name (tabularium--schema-name))
         (primary (tabularium--primary-field-name))
         (fields (tabularium--schema-fields))
         (col-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) fields))
         (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                          (tabularium--column-name-at-point)))
         (before-column
          (cond
           ;; Caller specified a position
           ((eq position 'last) nil)
           ((eq position '__first__) '__first__)
           ((symbolp position) position)
           ;; Otherwise prompt
           (t
            (let* ((candidates (append (when at-point-name
                                         (list (format "<POINT> %s"
                                                       (symbol-name at-point-name))))
                                       (list "<<FIRST>>" "<<LAST>>")
                                       col-names))
                   (pos-default (if at-point-name
                                    (format "<POINT> %s" (symbol-name at-point-name))
                                  "<<FIRST>>"))
                   (choice (completing-read "Paste before: " candidates nil t nil nil pos-default)))
              (cond
               ((string= choice "<<LAST>>") nil)
               ((string= choice "<<FIRST>>") '__first__)
               ((string-prefix-p "<POINT> " choice) at-point-name)
               (t (intern choice)))))))
         ;; Convert before-column to after-column
         (after-column
          (cond
           ;; <LAST>: append at end
           ((null before-column) nil)
           ;; <FIRST>: after primary key
           ((eq before-column '__first__) '__first__)
           ;; Named column: find the column before it
           (t (let ((pos (cl-position-if
                          (lambda (f) (eq (plist-get f :name) before-column))
                          fields)))
                (if (or (null pos) (<= pos 0))
                    '__first__  ; before first data column = after PK
                  (plist-get (nth (1- pos) fields) :name))))))
         (ops '())
         (renamed '()))
    (dolist (entry columns)
      (let* ((orig-name (plist-get entry :name))
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
        (setq field-plist (plist-put field-plist :name name))
        ;; Add column to DB
        (tabularium-db-execute tabularium--db
                               (format "ALTER TABLE %s ADD COLUMN %s %s"
                                       tabularium-table-name name-str sql-type)
                               nil)
        ;; Restore data
        (dolist (pair col-data)
          (tabularium-db-execute
           tabularium--db
           (format "UPDATE %s SET %s = ? WHERE %s = ?"
                   tabularium-table-name name-str primary-str)
           (list (cdr pair) (car pair))))
        ;; Insert field into schema
        (let* ((schema (assoc schema-name tabularium-schemas))
               (plist (cdr schema))
               (cur-fields (plist-get plist :fields))
               (pos (cond
                     ((eq after-column '__first__)
                      (1+ (or (cl-position-if
                               (lambda (f) (eq (plist-get f :name) primary))
                               cur-fields)
                              0)))
                     (after-column
                      (1+ (or (cl-position-if
                               (lambda (f) (eq (plist-get f :name) after-column))
                               cur-fields)
                              (length cur-fields))))
                     (t (length cur-fields))))
               (new-fields (append (seq-take cur-fields pos)
                                   (list field-plist)
                                   (seq-drop cur-fields pos))))
          (setf (cdr schema) (plist-put plist :fields new-fields))
          ;; Update after-column for the next pasted column to go after this one
          (setq after-column name))
        (push (list :type 'add-column :name name :field-plist field-plist) ops)))
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
                                      (format "%s→%s" (car pair) (cdr pair)))
                                    (nreverse renamed) ", ")
                          ")")))
      (message "%s" msg))))

(defun tabularium-view-column-paste (&optional consume)
  "Paste columns from the most recent column batch in the kill ring.
With prefix arg CONSUME, remove the batch from the kill ring."
  (interactive "P")
  (unless tabularium--kill-ring
    (user-error "Kill ring is empty"))
  ;; Find the most recent column batch
  (let ((batch (cl-find-if (lambda (b) (eq (tabularium--kill-ring-batch-type b) 'columns))
                            tabularium--kill-ring)))
    (unless batch
      (user-error "No column batches in kill ring"))
    (when consume
      (setq tabularium--kill-ring (delq batch tabularium--kill-ring)))
    (tabularium--paste-column-batch batch consume nil)))

(defun tabularium-view-column-paste-append (&optional consume)
  "Paste columns from the most recent column batch at end of schema.
Skips the position prompt, always appending after the last existing column.
With prefix arg CONSUME, remove the batch from the kill ring."
  (interactive "P")
  (unless tabularium--kill-ring
    (user-error "Kill ring is empty"))
  (let ((batch (cl-find-if (lambda (b) (eq (tabularium--kill-ring-batch-type b) 'columns))
                            tabularium--kill-ring)))
    (unless batch
      (user-error "No column batches in kill ring"))
    (when consume
      (setq tabularium--kill-ring (delq batch tabularium--kill-ring)))
    (tabularium--paste-column-batch batch consume 'last)))

(defun tabularium-view-column-edit (edits)
  "Edit properties of one or more columns.
EDITS is a list of plists, each with :old-name and optional
:new-name, :new-prompt, :new-type, :new-default.
Modifies the column in both the database and the schema.  Undoable."
  (interactive
   (let* ((fields (tabularium--schema-fields))
          (primary (tabularium--primary-field-name))
          (editable (cl-remove-if
                     (lambda (f) (eq (plist-get f :name) primary))
                     fields))
          (choices (mapcar (lambda (f) (symbol-name (plist-get f :name))) editable))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (let ((col (tabularium--column-name-at-point)))
                             (when (and col (not (eq col primary)))
                               col))))
          (candidates (append (when at-point-name
                                (list (format "<POINT> %s"
                                              (symbol-name at-point-name))))
                              choices))
          (selected (completing-read-multiple "Edit column(s): " candidates nil t))
          (sel-syms (delete-dups
                     (mapcar (lambda (s)
                               (if (string-prefix-p "<POINT> " s)
                                   at-point-name
                                 (intern s)))
                             selected)))
          (edit-list
           (mapcar
            (lambda (old-sym)
              (let* ((field (tabularium--field-by-name old-sym))
                     (old-prompt (or (plist-get field :prompt)
                                     (capitalize (symbol-name old-sym))))
                     (old-type (symbol-name (plist-get field :type)))
                     (old-default (or (plist-get field :default) ""))
                     (old-default-str (if (symbolp old-default)
                                          (symbol-name old-default)
                                        (format "%s" old-default)))
                     ;; Prompt for each property with current value as initial input
                     (new-name-str (read-string
                                    (format "Name [%s]: " old-sym)
                                    (symbol-name old-sym)))
                     (new-prompt (read-string
                                  (format "Prompt [%s]: " old-prompt)
                                  old-prompt))
                     (new-type (completing-read
                                (format "Type [%s]: " old-type)
                                '("text" "integer" "number" "date" "choice")
                                nil t nil nil old-type))
                     (new-default (read-string
                                   (format "Default [%s]: " old-default-str)
                                   old-default-str)))
                (list :old-name old-sym
                      :new-name (intern new-name-str)
                      :new-prompt new-prompt
                      :new-type (intern new-type)
                      :new-default (if (string-empty-p new-default) nil new-default))))
            sel-syms)))
     (list edit-list)))
  (tabularium--ensure-db)
  (let* ((schema-name (tabularium--schema-name))
         (ops '())
         (changes '()))
    (dolist (edit edits)
      (let* ((old-name (plist-get edit :old-name))
             (new-name (plist-get edit :new-name))
             (new-prompt (plist-get edit :new-prompt))
             (new-type (plist-get edit :new-type))
             (new-default (plist-get edit :new-default))
             (schema (assoc schema-name tabularium-schemas))
             (plist (cdr schema))
             (cur-fields (plist-get plist :fields))
             (field (cl-find-if (lambda (f) (eq (plist-get f :name) old-name))
                                cur-fields))
             ;; Save old state for undo
             (old-field-plist (copy-sequence field))
             (changed nil)
             (filled-ids nil))
        (unless field
          (user-error "Column '%s' not found" old-name))
        ;; Rename in database if name changed
        (unless (eq old-name new-name)
          (when (tabularium--field-by-name new-name)
            (user-error "Column '%s' already exists" new-name))
          (tabularium-db-execute
           tabularium--db
           (format "ALTER TABLE %s RENAME COLUMN %s TO %s"
                   tabularium-table-name
                   (symbol-name old-name) (symbol-name new-name))
           nil)
          (plist-put field :name new-name)
          (push (format "%s→%s" old-name new-name) changed))
        ;; Update prompt
        (when (and new-prompt (not (string= new-prompt (plist-get field :prompt))))
          (plist-put field :prompt new-prompt)
          (push (format "prompt='%s'" new-prompt) changed))
        ;; Update type
        (when (and new-type (not (eq new-type (plist-get field :type))))
          (plist-put field :type new-type)
          (push (format "type=%s" new-type) changed))
        ;; Update default
        (let ((old-default (plist-get field :default)))
          (unless (equal new-default old-default)
            (if new-default
                (plist-put field :default new-default)
              (cl-remf field :default))
            ;; Fill blank cells with the new default value
            (when new-default
              (let* ((col-name-str (symbol-name (or new-name old-name)))
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
                   (list new-default))
                  (push (format "default='%s' (filled %d blanks)"
                                new-default (length filled-ids))
                        changed))))
            (unless (or new-default filled-ids)
              (push (format "default=''") changed))
            (when (and new-default (not filled-ids))
              (push (format "default='%s'" new-default) changed))))
        ;; Update width based on new prompt
        (when new-prompt
          (plist-put field :width
                     (max (length new-prompt)
                          (if new-default (length new-default) 10)
                          10)))
        (setf (cdr schema) (plist-put plist :fields cur-fields))
        (push (list :type 'edit-column
                    :old-field-plist old-field-plist
                    :new-name (or new-name old-name)
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
            (first-new (plist-get (car edits) :new-name)))
        (revert-buffer)
        (tabularium-view--goto-position saved-id (or first-new
                                                 (plist-get (car edits) :old-name)))))
    (if changes
        (message "Edited: %s" (string-join (nreverse changes) "; "))
      (message "No changes made"))))

(defun tabularium-view-column-insert (name type prompt &optional default before-column)
  "Insert a new empty column NAME before BEFORE-COLUMN.
Like `tabularium-view-column-add' but inserts before rather than after."
  (interactive
   (let* ((name (read-string "Column name (symbol): "))
          (type (intern (completing-read "Type: "
                                         '("text" "integer" "number" "date" "choice") nil t)))
          (prompt (read-string "Prompt: " (capitalize name)))
          (default-val (read-string "Default value (empty for none): "))
          (fields (tabularium--schema-fields))
          (col-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) fields))
          (at-point-name (when (derived-mode-p 'tabularium-view-mode)
                           (tabularium--column-name-at-point)))
          (candidates (append (when at-point-name
                                (list (format "<POINT> %s"
                                              (symbol-name at-point-name))))
                              (list "<<FIRST>>" "<<LAST>>")
                              col-names))
          (pos-default (if at-point-name
                           (format "<POINT> %s" (symbol-name at-point-name))
                         "<<FIRST>>"))
          (choice (completing-read "Insert before: " candidates nil t nil nil pos-default))
          (before (cond
                   ((string= choice "<<FIRST>>") '__first__)
                   ((string= choice "<<LAST>>") nil)
                   ((string-prefix-p "<POINT> " choice) at-point-name)
                   (t (intern choice)))))
     (list (intern name) type prompt
           (if (string-empty-p default-val) nil default-val)
           before)))
  (cond
   ;; <LAST>: append at end
   ((null before-column)
    (tabularium-view-column-add name type prompt default nil))
   ;; <FIRST>: after primary key
   ((eq before-column '__first__)
    (tabularium-view-column-add name type prompt default '__first__))
   ;; Named column: find the column before it and delegate
   (t
    (let* ((fields (tabularium--schema-fields))
           (pos (cl-position-if
                 (lambda (f) (eq (plist-get f :name) before-column))
                 fields))
           (after (when (and pos (> pos 0))
                    (plist-get (nth (1- pos) fields) :name))))
      (if (or (null pos) (= pos 0))
          ;; Before the first column, after primary key
          (tabularium-view-column-add name type prompt default '__first__)
        (tabularium-view-column-add name type prompt default after))))))

;;; ** 7.3 Filter

(defun tabularium--filter-layer-sql (layer)
  "Return the SQL condition for a single filter LAYER."
  (cond
   ((plist-get layer :raw)
    (plist-get layer :sql))
   ((plist-get layer :across)
    (let* ((value (format "%s" (plist-get layer :value)))
           (op (tabularium-db-like-op tabularium-case-sensitive))
           (pattern (tabularium-db-like-pattern value tabularium-case-sensitive))
           (escaped (replace-regexp-in-string "'" "''" pattern))
           (conditions (mapcar (lambda (f)
                                 (format "%s %s '%s'" f op escaped))
                               (plist-get layer :fields))))
      (format "(%s)" (string-join conditions " OR "))))
   (t
    (let* ((op (plist-get layer :op))
           (field (plist-get layer :field))
           (value (plist-get layer :value))
           (vstr (format "%s" value)))
      (pcase op
        ('= (format "%s = %s" field (tabularium-db-sql-quote vstr)))
        ('> (format "CAST(%s AS REAL) > %s" field
                    (tabularium-db-sql-quote vstr)))
        ('>= (format "CAST(%s AS REAL) >= %s" field
                     (tabularium-db-sql-quote vstr)))
        ('< (format "CAST(%s AS REAL) < %s" field
                    (tabularium-db-sql-quote vstr)))
        ('<= (format "CAST(%s AS REAL) <= %s" field
                     (tabularium-db-sql-quote vstr)))
        (_ (tabularium-db-build-like-clause
            field vstr tabularium-case-sensitive)))))))

(defun tabularium--build-filter-clause ()
  "Build a SQL WHERE clause fragment from `tabularium--filter-layers'.
Returns nil if no filters are set."
  (when tabularium--filter-layers
    (let ((parts '()))
      (dolist (layer tabularium--filter-layers)
        (let ((sql (tabularium--filter-layer-sql layer))
              (join (plist-get layer :join)))
          (cond
           ((null join)
            (push (format "(%s)" sql) parts))
           ((eq join 'and)
            (push (format "AND (%s)" sql) parts))
           ((eq join 'or)
            (push (format "OR (%s)" sql) parts))
           ((eq join 'and-not)
            (push (format "AND NOT (%s)" sql) parts))
           ((eq join 'or-not)
            (push (format "OR NOT (%s)" sql) parts)))))
      (string-join (nreverse parts) " "))))

(defun tabularium--filter-layer-desc (layer)
  "Return a human-readable description for a single filter LAYER."
  (cond
   ((plist-get layer :raw)
    (or (plist-get layer :desc) "view"))
   ((plist-get layer :across)
    (let ((fields (plist-get layer :fields)))
      (format "'%s'@%s" (plist-get layer :value)
              (if (> (length fields) 3)
                  (format "%d fields" (length fields))
                (string-join fields ",")))))
   (t
    (let ((op (plist-get layer :op))
          (field (plist-get layer :field))
          (value (plist-get layer :value)))
      (pcase op
        ('= (format "%s = %s" field value))
        ('> (format "%s > %s" field value))
        ('>= (format "%s >= %s" field value))
        ('< (format "%s < %s" field value))
        ('<= (format "%s <= %s" field value))
        (_ (format "%s ~ %s" field value)))))))

(defconst tabularium--filter-join-symbols
  '((nil . "") (and . " ∧ ") (or . " ∨ ") (and-not . " ∧¬ ") (or-not . " ∨¬ "))
  "Alist mapping join types to display symbols.")

(defun tabularium--filter-description ()
  "Return a human-readable description of all filter layers."
  (when tabularium--filter-layers
    (let ((parts '()))
      (dolist (layer tabularium--filter-layers)
        (let ((join-sym (alist-get (plist-get layer :join)
                                   tabularium--filter-join-symbols))
              (desc (tabularium--filter-layer-desc layer)))
          (push (concat join-sym "(" desc ")") parts)))
      (string-join (nreverse parts)))))

(defun tabularium--filter-update-modeline ()
  "Update the mode-name to reflect current filter state."
  (let ((desc (tabularium--filter-description)))
    (setq mode-name (if desc
                        (format "Tabularium[%s]" desc)
                      "Tabularium"))))

(defun tabularium-view-filter (field value)
  "Add a filter layer for FIELD containing VALUE.
When no filters exist, this becomes the base layer.  When filters
already exist, prompts for a join operator (AND, OR, AND NOT, OR NOT).
Works on all field types including numbers and dates."
  (interactive
   (let* ((field-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
                               (cl-remove-if #'tabularium--computed-field-p
                                             (tabularium--schema-fields))))
          (field (completing-read
                  (if tabularium--filter-layers
                      (format "Filter [%s] + field: "
                              (tabularium--filter-description))
                    "Filter by field: ")
                  field-names nil t))
          (candidates (mapcar (lambda (v) (format "%s" v))
                              (tabularium--get-historical-values field)))
          (value (completing-read (format "Filter %s contains: " field)
                                  candidates)))
     (list field value)))
  (tabularium--filter-add-layer (list :field field :value value)))

(defun tabularium--filter-prompt-join ()
  "Prompt for join operator if filters already exist.
Returns a join symbol or nil for the first layer."
  (when tabularium--filter-layers
    (let ((choice (completing-read "Join logic: "
                                   '("AND" "OR" "AND NOT" "OR NOT")
                                   nil t nil nil "AND")))
      (cdr (assoc choice '(("AND" . and) ("OR" . or)
                           ("AND NOT" . and-not)
                           ("OR NOT" . or-not)))))))

(defun tabularium--filter-add-layer (layer)
  "Add LAYER to the filter stack with join prompt if needed."
  (let ((join (tabularium--filter-prompt-join)))
    (setq tabularium--filter-layers
          (append tabularium--filter-layers
                  (list (plist-put layer :join join))))
    (tabularium--filter-update-modeline)
    (revert-buffer)))

(defun tabularium-view-filter-exact (field value)
  "Add an exact-match filter layer for FIELD equal to VALUE.
Unlike `tabularium-view-filter', matches the complete cell value
rather than a substring."
  (interactive
   (let* ((field-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
                               (cl-remove-if #'tabularium--computed-field-p
                                             (tabularium--schema-fields))))
          (field (completing-read
                  (if tabularium--filter-layers
                      (format "Filter [%s] + exact field: "
                              (tabularium--filter-description))
                    "Filter exact by field: ")
                  field-names nil t))
          (candidates (mapcar (lambda (v) (format "%s" v))
                              (tabularium--get-historical-values field)))
          (value (completing-read (format "Filter %s = " field)
                                  candidates nil nil)))
     (list field value)))
  (tabularium--filter-add-layer (list :field field :value value :op '=)))

(defun tabularium-view-filter-numeric (field op value)
  "Add a numeric comparison filter for FIELD.
OP is one of >, >=, <, <=."
  (interactive
   (let* ((numeric-fields (cl-remove-if-not
                           (lambda (f)
                             (and (memq (plist-get f :type) '(integer number))
                                  (not (tabularium--computed-field-p f))))
                           (tabularium--schema-fields)))
          (field-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
                               numeric-fields))
          (field (completing-read
                  (if tabularium--filter-layers
                      (format "Filter [%s] + numeric field: "
                              (tabularium--filter-description))
                    "Filter numeric field: ")
                  field-names nil t))
          (op-choice (completing-read (format "%s operator: " field)
                                       '(">" ">=" "<" "<=") nil t))
          (value (read-string (format "%s %s " field op-choice))))
     (list field (intern op-choice) value)))
  (tabularium--filter-add-layer (list :field field :value value :op op)))

(defun tabularium-view-filter-delete (index)
  "Delete a filter layer by INDEX."
  (interactive
   (if (null tabularium--filter-layers)
       (user-error "No filter layers to delete")
     (let* ((descs (cl-loop for layer in tabularium--filter-layers
                            for i from 1
                            collect (format "%d: %s%s" i
                                            (let ((sym (alist-get (plist-get layer :join)
                                                                  tabularium--filter-join-symbols)))
                                              (if (string-empty-p sym) "" sym))
                                            (tabularium--filter-layer-desc layer))))
            (choice (completing-read "Delete filter layer: " descs nil t))
            (idx (1- (string-to-number (car (split-string choice ":"))))))
       (list idx))))
  (setq tabularium--filter-layers (cl-remove-if
                                (let ((i -1))
                                  (lambda (_) (= (cl-incf i) index)))
                                tabularium--filter-layers))
  ;; Fix join on new first layer
  (when (and tabularium--filter-layers
             (plist-get (car tabularium--filter-layers) :join))
    (setq tabularium--filter-layers
          (cons (plist-put (copy-sequence (car tabularium--filter-layers)) :join nil)
                (cdr tabularium--filter-layers))))
  (tabularium--filter-update-modeline)
  (revert-buffer)
  (if tabularium--filter-layers
      (message "Filter: %s" (tabularium--filter-description))
    (message "All filters cleared")))

(defun tabularium-view-filter-toggle ()
  "Cycle the join logic of a filter layer.
Cycles through: and → or → and-not → or-not → and."
  (interactive)
  (when (< (length tabularium--filter-layers) 2)
    (user-error "Need at least 2 filter layers to toggle join logic"))
  (let* ((non-first (cdr tabularium--filter-layers))
         (descs (cl-loop for layer in non-first
                         for i from 2
                         collect (format "%d: %s%s" i
                                         (let ((sym (alist-get (plist-get layer :join)
                                                               tabularium--filter-join-symbols)))
                                           (if (string-empty-p sym) "" sym))
                                         (tabularium--filter-layer-desc layer))))
         (choice (completing-read "Toggle join on layer: " descs nil t))
         (idx (1- (string-to-number (car (split-string choice ":")))))
         (layer (nth idx tabularium--filter-layers))
         (cycle '(and or and-not or-not))
         (current (plist-get layer :join))
         (next (or (cadr (memq current cycle)) 'and))
         (new-layer (plist-put (copy-sequence layer) :join next)))
    (setf (nth idx tabularium--filter-layers) new-layer)
    (tabularium--filter-update-modeline)
    (revert-buffer)
    (message "Filter: %s" (tabularium--filter-description))))

(defun tabularium-view-clear-filter ()
  "Clear all filter layers."
  (interactive)
  (setq tabularium--filter-layers nil)
  (setq mode-name "Tabularium")
  (revert-buffer))

(defun tabularium-view-filter-across (value &rest fields)
  "Add a filter-across layer: VALUE appears in any of FIELDS.
If FIELDS is nil, searches all fields.  When filters already exist,
prompts for a join operator."
  (interactive
   (let* ((value (read-string "Search for value: "))
          (fields (tabularium--field-crm)))
     (if fields (cons value fields) (list value))))
  (tabularium--ensure-db)
  (let ((search-fields (or fields (tabularium--stored-field-names))))
    (tabularium--filter-add-layer (list :fields search-fields :value value :across t))))

;;; ** 7.4 Find/Replace

;;; *** 7.4.1 Standard

(defvar tabularium--replace-scope nil
  "Scope description for replace messages: nil, \"marked\", or \"visible\".")

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
   (let* ((old-value (read-string "Replace value: "))
          (new-value (read-string (format "Replace '%s' with: " old-value)))
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
        ;; Process each field with undo tracking
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
                        (push (list :type 'update :id id :field (intern field)
                                    :old current-val :new updated-val)
                              all-undo-ops))
                    (error
                     (cl-incf skipped)
                     (cl-pushnew field skipped-fields :test #'string=)
                     (message "Skipped ID %s (%s): %s" id field (error-message-string err)))))))))
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
   (let* ((old-value (read-string "Replace exact value: "))
          (new-value (read-string (format "Replace '%s' with: " old-value)))
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
                      (push (list :type 'update :id id :field (intern field)
                                  :old old-value :new new-value)
                            all-undo-ops))
                  (error
                   (cl-incf skipped)
                   (cl-pushnew field skipped-fields :test #'string=)
                   (message "Skipped ID %s (%s): %s" id field (error-message-string err))))))))
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
          (replacement (read-string (format "Replace matches of '%s' with: " pattern)))
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
                      (push (list :type 'update :id id :field (intern field)
                                  :old old-val :new replacement)
                            all-undo-ops))
                  (error
                   (cl-incf skipped)
                   (cl-pushnew field skipped-fields :test #'string=)
                   (message "Skipped ID %s (%s): %s" id field (error-message-string err))))))))
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
   (let* ((regexp (read-string "Replace regexp: "))
          (replacement (read-string (format "Replace matches of '%s' with: " regexp)))
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
    ;; Fetch all rows and filter in Emacs
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
                        (push (list :type 'update :id id :field (intern field)
                                    :old val :new new-val)
                              all-undo-ops))
                    (error
                     (cl-incf skipped)
                     (cl-pushnew field skipped-fields :test #'string=)
                     (message "Skipped ID %s (%s): %s" id field (error-message-string err)))))))))))
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
Prompts y/n/!/q at each match.  Nil FIELDS means all."
  (interactive
   (let* ((old-value (read-string "Query replace: "))
          (new-value (read-string (format "Replace '%s' with: " old-value)))
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
                                      (prog1 (cons (symbol-name (plist-get f :name)) pos)
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
                                (push (list :type 'update :id id :field (intern field)
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
                             (message "Skipped ID %s (%s): %s" id field (error-message-string err)))))))))))
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
            (let ((f (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :name)) field-name))
                                 schema-fields)))
              (when f (plist-get f :prompt))))
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
  "Replace substring OLD-VALUE with NEW-VALUE in visible rows.
Like `tabularium-replace-substring' but scoped to the current view
\(respecting filters and range limits)."
  (interactive
   (let* ((old-value (read-string "Replace (visible): "))
          (new-value (read-string (format "Replace '%s' with: " old-value)))
          (fields (tabularium--field-crm)))
     (list old-value new-value fields)))
  (let ((tabularium--marked-entries (tabularium--visible-row-ids))
        (tabularium--replace-scope "visible"))
    (tabularium-replace-substring old-value new-value fields)))

(defun tabularium-replace-visible-exact (old-value new-value &optional fields)
  "Replace exact OLD-VALUE with NEW-VALUE in visible rows.
Like `tabularium-replace-exact' but scoped to the current view."
  (interactive
   (let* ((old-value (read-string "Replace exact (visible): "))
          (new-value (read-string (format "Replace '%s' with: " old-value)))
          (fields (tabularium--field-crm)))
     (list old-value new-value fields)))
  (let ((tabularium--marked-entries (tabularium--visible-row-ids))
        (tabularium--replace-scope "visible"))
    (tabularium-replace-exact old-value new-value fields)))

(defun tabularium-replace-visible-regexp (regexp replacement &optional fields)
  "Replace REGEXP with REPLACEMENT in visible rows.
Like `tabularium-replace-regexp' but scoped to the current view."
  (interactive
   (let* ((regexp (read-string "Replace regexp (visible): "))
          (replacement (read-string (format "Replace '%s' with: " regexp)))
          (fields (tabularium--field-crm)))
     (list regexp replacement fields)))
  (let ((tabularium--marked-entries (tabularium--visible-row-ids))
        (tabularium--replace-scope "visible"))
    (tabularium-replace-regexp regexp replacement fields)))

(defun tabularium-replace-visible-query (old-value new-value &optional fields)
  "Interactive query-replace OLD-VALUE with NEW-VALUE in visible rows.
Like `tabularium-replace-query' but scoped to the current view."
  (interactive
   (let* ((old-value (read-string "Query replace (visible): "))
          (new-value (read-string (format "Replace '%s' with: " old-value)))
          (fields (tabularium--field-crm)))
     (list old-value new-value fields)))
  (let ((tabularium--marked-entries (tabularium--visible-row-ids))
        (tabularium--replace-scope "visible"))
    (tabularium-replace-query old-value new-value fields)))

;;; ** 7.5 Aggregate Operations

;;; *** 7.5.1 Count

(defun tabularium-aggregate-count (field pattern &optional extra-field extra-value)
  "Count records where FIELD matches PATTERN.
Optional EXTRA-FIELD and EXTRA-VALUE for additional filtering."
  (interactive
   (let* ((field-names (tabularium--stored-field-names))
          (field (completing-read "Count field: " field-names nil t))
          (candidates (tabularium--get-historical-values field))
          (pattern (completing-read (format "Count %s matching: " field) candidates)))
     (list field pattern nil nil)))
  (tabularium--ensure-db)
  (let* ((extra-clause (if (and extra-field extra-value (not (string-empty-p extra-value)))
                           (format "AND %s"
                                   (tabularium-db-build-equals-clause
                                    extra-field extra-value))
                         ""))
         (like-clause (tabularium-db-build-like-clause
                       field pattern tabularium-case-sensitive))
         (sql (format "SELECT COUNT(*) FROM %s WHERE %s %s"
                      tabularium-table-name like-clause extra-clause))
         (count (tabularium-db-query-scalar tabularium--db sql)))
    (message "Found %d records where %s matches '%s'%s"
             count field pattern
             (if (and extra-field extra-value (not (string-empty-p extra-value)))
                 (format " (%s=%s)" extra-field extra-value)
               ""))
    count))

(defun tabularium-view-count-across (value &rest fields)
  "Count records where VALUE appears in any of FIELDS.
If FIELDS is nil, searches all fields."
  (interactive
   (let* ((value (read-string "Count value: "))
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
             (if (> (length search-fields) 3)
                 (format "%d fields" (length search-fields))
               (string-join search-fields ", "))
             count)))

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
          (field-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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
        (message "Sum of %s (where %s ~ %s): %s" field filter-field filter-value (or result 0))
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
          (field-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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
        (message "%s (where %s ~ %s): min = %s, max = %s" field filter-field filter-value
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
          (field-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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
                              (format " (where %s ~ %s)" filter-field filter-value)
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
          (field-names (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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
                              (format " (where %s ~ %s)" filter-field filter-value)
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
         (field-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) numeric-fields))
         (prompt (completing-read "Sum field: " field-names nil t))
         (field (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :name)) prompt))
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
         (field-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) numeric-fields))
         (prompt (completing-read "Field: " field-names nil t))
         (field (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :name)) prompt))
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
                              :key (lambda (f) (symbol-name (plist-get f :name)))
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
         (max-val-len (if freq-results
                          (apply #'max 8
                                 (mapcar (lambda (r)
                                           (min 30 (length (format "%s" (or (car r) "")))))
                                         (seq-take freq-results 20)))
                        8))
         (val-fmt (format "    %%-%ds  %%5d  (%%5.1f%%%%)\n" max-val-len))
         (box-width 60)
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
        (insert (propertize "  Column Info\n" 'face 'bold))
        (insert (format "    Type:       %s\n" field-type))
        (insert (format "    Total:      %d\n" total-rows))
        (insert (format "    Non-null:   %d\n" non-null))
        (insert (format "    Null/empty: %d (%.1f%%)\n"
                        null-count
                        (if (> total-rows 0)
                            (* 100.0 (/ null-count (float total-rows)))
                          0.0)))
        (insert (format "    Unique:     %d\n" unique-count))
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
                (insert (propertize "  Descriptive Statistics\n" 'face 'bold))
                (insert (format "    N:              %d\n" n))
                (insert (format "    Sum:            %.2f\n" sum))
                (insert (format "    Mean ± SD:      %.2f ± %.2f\n" mean sd))
                (insert (format "    Median [IQR]:   %.2f [%.2f, %.2f]\n" med q1 q3))
                (insert (format "    Range:          %.2f – %.2f\n" min-val max-val))))))
        ;; Frequency table
        (when freq-results
          (let* ((n-results (length freq-results))
                 (show-all (<= n-results 20))
                 (freq-total (cl-reduce #'+ (mapcar #'cadr freq-results))))
            (insert "\n")
            (insert (propertize (format "  Values (%d unique)\n" n-results) 'face 'bold))
            (insert (format (format "    %%-%ds  %%5s  %%7s\n" max-val-len) "Value" "Count" "Pct"))
            (insert "    " (make-string (+ max-val-len 18) ?─) "\n")
            (if show-all
                ;; Show all values
                (dolist (row freq-results)
                  (let ((val (format "%s" (or (car row) "(empty)")))
                        (cnt (cadr row)))
                    (insert (format val-fmt
                                    (if (> (length val) 30)
                                        (concat (substring val 0 27) "...")
                                      val)
                                    cnt
                                    (* 100.0 (/ cnt (float freq-total)))))))
              ;; Top 10 + bottom 5
              (dolist (row (seq-take freq-results 10))
                (let ((val (format "%s" (or (car row) "(empty)")))
                      (cnt (cadr row)))
                  (insert (format val-fmt
                                  (if (> (length val) 30)
                                      (concat (substring val 0 27) "...")
                                    val)
                                  cnt
                                  (* 100.0 (/ cnt (float freq-total)))))))
              (when (> n-results 15)
                (insert (format "\n    ... %d more ...\n\n" (- n-results 15))))
              (insert (propertize "  Least Common\n" 'face 'bold))
              (insert "    " (make-string (+ max-val-len 18) ?─) "\n")
              (dolist (row (seq-take (reverse freq-results) 5))
                (let ((val (format "%s" (or (car row) "(empty)")))
                      (cnt (cadr row)))
                  (insert (format val-fmt
                                  (if (> (length val) 30)
                                      (concat (substring val 0 27) "...")
                                    val)
                                  cnt
                                  (* 100.0 (/ cnt (float freq-total))))))))))
        ;; Footer
        (insert "\n")
        (insert (propertize (tabularium--make-box-footer box-width 'single) 'face 'shadow) "\n")
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
                                (format "%d of %d marked rows have values. Overwrite? "
                                        (length non-blank) (length ids))))))
          (unless overwrite
            ;; Only fill blanks among the marked rows
            (setq ids (cl-remove-if
                       (lambda (id)
                         (let* ((rec (tabularium--get-record-by-id id))
                                (val (alist-get field-sym rec)))
                           (and val (not (string-empty-p (format "%s" val))))))
                       ids)))))
      (dolist (id ids)
        (let* ((record (tabularium--get-record-by-id id))
               (old-value (alist-get field-sym record)))
          (unless (equal old-value source-value)
            (push (list :type 'update :id id :field field-sym
                        :old old-value :new source-value)
                  ops)
            (tabularium-db-update tabularium--db tabularium-table-name
                                  (list (cons field-sym source-value))
                                  (tabularium--primary-field-name) id)
            (cl-incf filled))))
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

(defun tabularium-view-fill ()
  "Fill the blank gap above point in the current column.
Scans upward to find the nearest non-blank value, then fills all
blank cells between that value and point (inclusive) with it.
With marks, fills the marked rows instead.  Undoable."
  (interactive)
  (let* ((col-name (or (tabularium--column-name-at-point)
                       (user-error "No column at point")))
         (field (symbol-name col-name))
         (has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0)))
         ;; Scan upward for nearest non-blank value
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
    (if has-marks
        (tabularium--fill-execute field fill-value)
      ;; Fill blank cells upward from point to the source row
      (tabularium--fill-execute field fill-value 'up))))

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
    (when (not cell-blank)
      (forward-line 1))
    (tabularium--fill-execute field fill-value 'down)))

(defun tabularium-view-fill-down (field source-value)
  "Fill FIELD downward with SOURCE-VALUE from point.
Undoable.  When called interactively, offers choice of copying
from a row, entering manually, or picking from existing values."
  (interactive
   (let* ((field (completing-read "Fill down field: "
                                  (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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
                                  (mapcar (lambda (f) (symbol-name (plist-get f :name)))
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

(defun tabularium-view-fill-series (field start increment)
  "Fill FIELD with a series starting at START with INCREMENT.
For numeric fields (integer, number), START and INCREMENT are numbers.
For date fields, START is a date string and INCREMENT is a number of days.
Undoable."
  (interactive
   (let* ((fillable-types '(integer number date))
          (field (completing-read "Fill series in field: "
                                  (mapcar (lambda (f) (symbol-name (plist-get f :name)))
                                          (cl-remove-if-not
                                           (lambda (f) (memq (plist-get f :type) fillable-types))
                                           (tabularium--schema-fields)))
                                  nil t))
          (field-def (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :name)) field))
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
  (let* ((has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0)))
         (field-def (cl-find-if (lambda (f) (string= (symbol-name (plist-get f :name)) field))
                                (tabularium--schema-fields)))
         (field-type (plist-get field-def :type))
         (is-date (eq field-type 'date))
         (field-sym (intern field))
         (ids (if has-marks
                  (cl-sort (copy-sequence tabularium--marked-entries) #'<)
                ;; Auto-detect blank range from point
                (tabularium--find-blank-range-down field)))
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
                              (format "%d of %d marked rows have values. Overwrite? "
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
          (dolist (id ids)
            (let* ((record (tabularium--get-record-by-id id))
                   (old-value (alist-get field-sym record))
                   (new-value (if is-date
                                  (format-time-string tabularium-date-format current-val)
                                current-val)))
              (push (list :type 'update :id id :field field-sym
                          :old old-value :new new-value)
                    ops)
              (tabularium-db-update tabularium--db tabularium-table-name
                                (list (cons field-sym new-value))
                                (tabularium--primary-field-name) id)
              (setq current-val (if is-date
                                    (time-add current-val (days-to-time increment))
                                  (+ current-val increment)))))
          (when ops
            (tabularium--undo-push (list :type 'multi :ops (nreverse ops)))))
        (tabularium--invalidate-cache)
        (when has-marks
          (setq tabularium--marked-entries nil)
          (tabularium-view--update-mark-display))
        (revert-buffer)
        (message "Filled series in %d rows" count)))))

(defun tabularium-view-fill-delete ()
  "Delete a same-value run in the current column from point.
Scans downward through consecutive cells that share the same value
as the cell at point, and clears them all.  With marks, clears the
current column in marked rows instead.  Undoable."
  (interactive)
  (let* ((col-name (or (tabularium--column-name-at-point)
                       (user-error "No column at point")))
         (field (symbol-name col-name))
         (has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0)))
         (ids
          (if has-marks
              (copy-sequence tabularium--marked-entries)
            ;; Scan same-value run downward
            (let* ((current-id (or (tabulated-list-get-id)
                                   (user-error "No row at point")))
                   (start-rec (tabularium--get-record-by-id current-id)))
              (let ((ref-val (format "%s" (or (alist-get col-name start-rec) "")))
                    (run '()))
                (save-excursion
                  (while (and (not (eobp))
                              (when-let ((id (tabulated-list-get-id)))
                                (let* ((rec (tabularium--get-record-by-id id))
                                       (val (format "%s" (or (alist-get col-name rec) ""))))
                                  (when (string= val ref-val)
                                    (push id run)
                                    t))))
                    (forward-line 1)))
                (when (or (null run)
                          (and (= 1 (length run))
                               (string-empty-p ref-val)))
                  (user-error "No filled cells to delete from point"))
                (nreverse run))))))
    (when (yes-or-no-p (format "Clear '%s' in %d rows? " field (length ids)))
      (let ((ops '())
            (cleared 0))
        (dolist (id ids)
          (let* ((record (tabularium--get-record-by-id id))
                 (old-value (alist-get col-name record)))
            (when (and old-value (not (string-empty-p (format "%s" old-value))))
              (push (list :type 'update :id id :field col-name
                          :old old-value :new "")
                    ops)
              (tabularium-db-update tabularium--db tabularium-table-name
                                (list (cons col-name ""))
                                (tabularium--primary-field-name) id)
              (cl-incf cleared))))
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

(defun tabularium-view-fill-clear (target-id)
  "Clear the current column from point to TARGET-ID (inclusive).
Prompts for a target row ID, then blanks every cell in the current
column between point and that row.  With marks, clears the current
column in marked rows instead.  Undoable."
  (interactive
   (let ((has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0))))
     (if has-marks
         (list nil)
       (list (read-number "Clear to row ID: "
                          (tabulated-list-get-id))))))
  (let* ((col-name (or (tabularium--column-name-at-point)
                       (user-error "No column at point")))
         (field (symbol-name col-name))
         (has-marks (and tabularium--marked-entries
                         (> (length tabularium--marked-entries) 0)))
         (ids
          (if has-marks
              (copy-sequence tabularium--marked-entries)
            ;; Collect all row IDs between point and target
            (let ((start-id (or (tabulated-list-get-id)
                                (user-error "No row at point")))
                  (range '()))
              (save-excursion
                (if (<= start-id target-id)
                    ;; Forward range
                    (while (and (not (eobp))
                                (when-let ((id (tabulated-list-get-id)))
                                  (when (<= id target-id)
                                    (push id range)
                                    t)))
                      (forward-line 1))
                  ;; Backward range
                  (while (and (not (bobp))
                              (when-let ((id (tabulated-list-get-id)))
                                (when (>= id target-id)
                                  (push id range)
                                  t)))
                    (forward-line -1))))
              (unless range
                (user-error "No rows in range"))
              range))))
    (when (yes-or-no-p (format "Clear '%s' in %d rows? " field (length ids)))
      (let ((ops '())
            (cleared 0))
        (dolist (id ids)
          (let* ((record (tabularium--get-record-by-id id))
                 (old-value (alist-get col-name record)))
            (when (and old-value (not (string-empty-p (format "%s" old-value))))
              (push (list :type 'update :id id :field col-name
                          :old old-value :new "")
                    ops)
              (tabularium-db-update tabularium--db tabularium-table-name
                                    (list (cons col-name ""))
                                    (tabularium--primary-field-name) id)
              (cl-incf cleared))))
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

;;; * 8 Import & Export

;;; ** 8.1 Basic Import/Export

;;;###autoload
(defun tabularium-import (file)
  "Import records from FILE (auto-detects TSV/CSV/Org).

If a database is already open, imports into it.
If no database is open, prompts for database file and schema handling
(same as `tabularium-import-csv' etc.)."
  (interactive
   (list (read-file-name "Import from: " nil nil t nil
                         (lambda (f) (or (file-directory-p f)
                                         (string-match-p "\\.csv$\\|\\.tsv$\\|\\.org$" f))))))
  (let* ((file (expand-file-name file))
         (ext (file-name-extension file)))
    (cond
     ;; Database is already open - use simple import
     ((and tabularium--current-schema-name tabularium--db)
      (tabularium-import--into-current-db file))
     ;; No database open - use the full schema-aware import
     ((string= ext "org")
      (let ((default-db (concat (file-name-sans-extension file) ".db")))
        (tabularium-import-org file
                               (read-file-name "Database file: "
                                               (file-name-directory file)
                                               default-db nil
                                               (file-name-nondirectory default-db)))))
     ((string= ext "tsv")
      (let ((default-db (concat (file-name-sans-extension file) ".db")))
        (tabularium-import-tsv file
                               (read-file-name "Database file: "
                                               (file-name-directory file)
                                               default-db nil
                                               (file-name-nondirectory default-db)))))
     (t  ; csv or unknown - treat as CSV
      (let ((default-db (concat (file-name-sans-extension file) ".db")))
        (tabularium-import-csv file
                               (read-file-name "Database file: "
                                               (file-name-directory file)
                                               default-db nil
                                               (file-name-nondirectory default-db))))))))

(defun tabularium-import--into-current-db (file)
  "Import records from FILE into the currently open database."
  (tabularium--ensure-db)
  (let* ((parsed (tabularium-import--parse-delimited-file file))
         (rows (cdr parsed))
         (imported 0)
         (skipped 0))
    (dolist (values rows)
      (when (and values (> (length values) 0)
                 (not (string-empty-p (car values))))
        (condition-case _err
            (progn
              (tabularium--import-row values)
              (cl-incf imported))
          (error
           (cl-incf skipped)))))
    (tabularium--invalidate-cache)
    (message "Imported %d records, skipped %d" imported skipped)))

(defun tabularium--import-row (values)
  "Import VALUES as a new record."
  (let* ((fields (tabularium--schema-fields))
         (alist '()))
    (cl-loop for field in fields
             for value in values
             for name = (plist-get field :name)
             for type = (plist-get field :type)
             do (push (cons name
                            (pcase type
                              ('integer (if (and value (not (string-empty-p value)))
                                            (string-to-number value)
                                          nil))
                              ('number (if (and value (not (string-empty-p value)))
                                           (string-to-number value)
                                         nil))
                              (_ value)))
                      alist))
    (tabularium-db-insert tabularium--db tabularium-table-name (nreverse alist))))

(defun tabularium--escape-field (value separator)
  "Escape VALUE for RFC 4180-compliant export with SEPARATOR."
  (let ((s (if value (format "%s" value) "")))
    (if (or (string-match-p (regexp-quote (char-to-string separator)) s)
            (string-match-p "[\"\n\r]" s))
        (format "\"%s\"" (replace-regexp-in-string "\"" "\"\"" s))
      s)))

;;;###autoload
(defun tabularium-export (&optional file format)
  "Export records to FILE in FORMAT (tsv or csv).
Exports marked rows if any, otherwise all records."
  (interactive
   (let* ((format-choice (completing-read "Export format: "
                                          '("<<TSV>>" "<<CSV>>") nil t nil nil
                                          (if (eq tabularium-export-format 'tsv)
                                              "<<TSV>>" "<<CSV>>")))
          (fmt (if (string= format-choice "<<TSV>>") 'tsv 'csv))
          (ext (if (eq fmt 'tsv) ".tsv" ".csv"))
          (default-name (concat (file-name-sans-extension
                                 (or (tabularium--schema-export-file)
                                     (buffer-name)))
                                ext))
          (file (read-file-name
                 (if tabularium--marked-entries
                     (format "Export %d marked to: " (length tabularium--marked-entries))
                   "Export all to: ")
                 nil default-name)))
     (list file fmt)))
  (when (and (file-exists-p file)
             (not (y-or-n-p (format "File %s exists. Overwrite? "
                                    (file-name-nondirectory file)))))
    (user-error "Export canceled"))
  (tabularium--ensure-db)
  (let* ((fmt (or format tabularium-export-format))
         (sep (if (eq fmt 'tsv) "\t" ","))
         (sep-char (string-to-char sep))
         (fields (cl-remove-if #'tabularium--computed-field-p
                               (tabularium--schema-fields)))
         (col-names (mapcar (lambda (f) (symbol-name (plist-get f :name))) fields))
         (primary-name (symbol-name (tabularium--primary-field-name)))
         (marked-ids tabularium--marked-entries)
         (sql (if marked-ids
                  (format "SELECT %s FROM %s WHERE %s IN (%s) ORDER BY %s"
                          (string-join col-names ", ")
                          tabularium-table-name
                          primary-name
                          (mapconcat #'number-to-string marked-ids ",")
                          primary-name)
                (format "SELECT %s FROM %s ORDER BY %s"
                        (string-join col-names ", ")
                        tabularium-table-name
                        primary-name)))
         (rows (tabularium-db-query tabularium--db sql)))
    (with-temp-file file
      ;; Header
      (insert (string-join col-names sep) "\n")
      ;; Data
      (dolist (row rows)
        (insert (mapconcat (lambda (v) (tabularium--escape-field v sep-char))
                           row sep)
                "\n")))
    ;; Clear marks if we exported marked rows
    (when marked-ids
      (setq tabularium--marked-entries nil)
      (tabularium-view--update-mark-display))
    (message "Exported %d %s to %s (%s)"
             (length rows)
             (if marked-ids "marked entries" "records")
             file
             (upcase (symbol-name fmt)))))

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
             (field (list :name (intern name)
                          :type type
                          :prompt header
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
    ;; If no primary key was assigned, prepend an auto-increment id field
    (unless (cl-find-if (lambda (f) (plist-get f :primary)) fields)
      (push (list :name 'id :type 'integer :primary t :prompt "ID" :width 5)
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
  "Insert ROWS into the current Tabularium database using FIELDS schema."
  (let ((field-names (mapcar (lambda (f) (plist-get f :name)) fields))
        (imported 0)
        (errors 0))
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
                      (+ imported errors) (error-message-string err)))))))
    (when (> errors 0)
      (message "Import: %d succeeded, %d failed" imported errors))
    imported))

;;; *** 8.2.3 Org-Table

(defun tabularium-import--org-parse-table-at-point ()
  "Parse the org-table at point.  Returns (HEADERS . ROWS)."
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
        (when (org-at-table-p)
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
            ;; Skip past this table
            (org-table-end))))
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
      (user-error "No schema found in %s. Make sure it contains a (tabularium-define-schema ...) form"
                  schema-file))
    (unless fields
      (user-error "Schema '%s' has no :fields defined" actual-name))
    ;; CRITICAL: Update the file path to match the import destination
    ;; This is necessary because the schema file may specify a different path
    ;; Use abbreviated path for portability across machines (Syncthing, etc.)
    (plist-put (cdr schema) :file (abbreviate-file-name (expand-file-name db-file)))
    ;; Delete existing database - required for fresh import with possibly different schema
    (when (file-exists-p db-file)
      (if (yes-or-no-p (format "Database %s exists. Delete and reimport? "
                               (abbreviate-file-name db-file)))
          (progn
            (delete-file db-file)
            ;; Also delete WAL files if present
            (let ((wal-file (concat db-file "-wal"))
                  (shm-file (concat db-file "-shm")))
              (when (file-exists-p wal-file) (delete-file wal-file))
              (when (file-exists-p shm-file) (delete-file shm-file))))
        ;; User declined - abort import
        (user-error "Import canceled. Cannot import into existing database without deleting it first")))
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
                   (format ". Schema updated to point to %s"
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

(defun tabularium--describe-database-info ()
  "Return an alist of database metadata for the open database.
Keys: name, backend, file, size, modified, row-count, fields."
  (unless tabularium--current-schema-name
    (user-error "No database open"))
  (let* ((schema (tabularium--current-schema))
         (fields (tabularium--schema-fields))
         (backend (or (plist-get (cdr schema) :backend) 'sqlite))
         (file (plist-get (cdr schema) :file))
         (file-attrs (and file (file-exists-p file) (file-attributes file)))
         (size (and file-attrs (file-attribute-size file-attrs)))
         (mtime (and file-attrs (file-attribute-modification-time file-attrs)))
         (row-count (condition-case nil
                        (caar (tabularium-db-query
                               tabularium--db
                               (format "SELECT COUNT(*) FROM %s"
                                       tabularium-table-name)))
                      (error nil))))
    `((name       . ,tabularium--current-schema-name)
      (backend    . ,backend)
      (file       . ,file)
      (size       . ,size)
      (modified   . ,mtime)
      (row-count  . ,row-count)
      (fields     . ,fields))))

;;;###autoload
(defun tabularium-describe-database ()
  "Display a summary of the currently open Tabularium database.
Shows backend type, file location and size, row count, and the
list of schema fields with their types and constraints."
  (interactive)
  (let* ((info (tabularium--describe-database-info))
         (name (alist-get 'name info))
         (backend (alist-get 'backend info))
         (file (alist-get 'file info))
         (size (alist-get 'size info))
         (mtime (alist-get 'modified info))
         (row-count (alist-get 'row-count info))
         (fields (alist-get 'fields info))
         (buf (get-buffer-create "*Tabularium Database*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local truncate-lines nil)
        ;; Header
        (insert (propertize (format "Database: %s (%s)\n" name backend)
                            'face '(:weight bold :height 1.2)))
        (insert (make-string 78 ?═) "\n")
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
        ;; Schema
        (insert (propertize (format "Schema (%d field%s)\n"
                                    (length fields)
                                    (if (= 1 (length fields)) "" "s"))
                            'face '(:weight bold)))
        (insert (make-string 78 ?─) "\n")
        (let ((max-name (apply #'max 8 (mapcar (lambda (f)
                                                 (length (symbol-name (plist-get f :name))))
                                               fields)))
              (max-type 8))
          (dolist (field fields)
            (let* ((fname (symbol-name (plist-get field :name)))
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
        ;; Statistics
        (insert (propertize "Statistics\n" 'face '(:weight bold)))
        (insert (make-string 78 ?─) "\n")
        (insert (format "  %-12s%s\n"
                        (propertize "Total rows:" 'face 'font-lock-keyword-face)
                        (if row-count (format "%d" row-count) "—")))
        (goto-char (point-min))))
    (display-buffer buf)))

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
    (define-key map "s" #'tabularium-schema-show)
    (define-key map "r" #'tabularium-schema-reload)
    (define-key map "w" #'tabularium-schema-switch)
    (define-key map "n" #'tabularium-schema-rename-field)
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

;;;###autoload
(defvar tabularium-command-map
  (let ((map (make-sparse-keymap)))
    ;; Database
    (define-key map "o" #'tabularium-open)
    (define-key map "O" #'tabularium-open-and-view)
    (define-key map "x" #'tabularium-close)
    (define-key map "C" #'tabularium-create-database)
    (define-key map "r" #'tabularium-registry)
    (define-key map "$" #'tabularium-rename-database)
    (define-key map "+" #'tabularium-register-database)
    ;; Entry
    (define-key map "N" #'tabularium-new-entry)
    (define-key map "P" #'tabularium-prompt-entry)
    (define-key map "Q" #'tabularium-quick-entry)
    ;; Browse / Query
    (define-key map "v" #'tabularium-view)
    (define-key map "/" #'tabularium-find)
    (define-key map "t" #'tabularium-last)
    ;; Inspection / Customization
    (define-key map "?" #'tabularium-describe-database)
    (define-key map "c" #'tabularium-customize)
    ;; External
    (define-key map "e" #'tabularium-export)
    (define-key map "i" #'tabularium-import)
    (define-key map "s" #'tabularium-sync-prepare)
    ;; Submaps
    (define-key map "." tabularium-schema-command-map)
    (define-key map "#" tabularium-aggregate-command-map)
    map)
  "Prefix keymap exposing top-level Tabularium commands.
Bind this map to a prefix key to access all main commands without
loading `tabularium-menu' (and thus without depending on `hydra'
or `transient').  Sub-prefixes `.' and `#' lead to the schema and
aggregate command maps respectively.

Example binding:

  (global-set-key (kbd \"C-c t\") tabularium-command-map)

See the README \"Bare keymap\" section for the full key table.")

;;; * 10 Provide

(provide 'tabularium)

;;; tabularium.el ends here
