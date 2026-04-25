;;; tabularium-db.el --- Database backend abstraction for Tabularium -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul H. McClelland

;; Author: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Maintainer: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Version: 0.4.4
;; Package-Requires: ((emacs "29.1"))
;; Keywords: data
;; URL: https://codeberg.org/phmcc/tabularium
;; SPDX-License-Identifier: GPL-3.0-or-later

;;
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

;; Database backend abstraction layer for Tabularium using EIEIO generics.
;; Backends dispatch on the backend object, not the raw connection.
;;
;; Implemented: sqlite (Emacs 29+ built-in)
;; Planned: postgresql, mysql (via emacsql)

;;; Code:

(require 'cl-lib)
(require 'eieio)

;;; * 1 Backend Protocol

(cl-defgeneric tabularium-db-connect (backend config)
  "Connect BACKEND to a database described by CONFIG plist.")

(cl-defgeneric tabularium-db-disconnect (backend)
  "Disconnect BACKEND from its database.")

(cl-defgeneric tabularium-db-connected-p (backend)
  "Return non-nil if BACKEND has an active connection.")

(cl-defgeneric tabularium-db-execute (backend sql &optional params)
  "Execute SQL on BACKEND with optional PARAMS list.")

(cl-defgeneric tabularium-db-query (backend sql &optional params)
  "Execute SQL query on BACKEND, returning list of row lists.")

(cl-defgeneric tabularium-db-query-single (backend sql &optional params)
  "Execute SQL on BACKEND and return the first row, or nil.")

(cl-defgeneric tabularium-db-query-scalar (backend sql &optional params)
  "Execute SQL on BACKEND and return the first value, or nil.")

(cl-defgeneric tabularium-db-table-exists-p (backend table-name)
  "Return non-nil if TABLE-NAME exists in BACKEND's database.")

(cl-defgeneric tabularium-db-table-columns (backend table-name)
  "Return column info plists (:name :type) for TABLE-NAME.")

(cl-defgeneric tabularium-db-create-table (backend table-name columns)
  "Create TABLE-NAME in BACKEND with COLUMNS definition plists.")

(cl-defgeneric tabularium-db-create-index (backend table-name column-name)
  "Create index on COLUMN-NAME in TABLE-NAME.")

(cl-defgeneric tabularium-db-insert (backend table-name alist)
  "Insert row into TABLE-NAME from ALIST of (column . value) pairs.")

(cl-defgeneric tabularium-db-update (backend table-name alist where-column where-value)
  "Update TABLE-NAME with ALIST where WHERE-COLUMN = WHERE-VALUE.")

(cl-defgeneric tabularium-db-delete (backend table-name where-column where-value)
  "Delete from TABLE-NAME where WHERE-COLUMN = WHERE-VALUE.")

(cl-defgeneric tabularium-db-last-insert-id (backend)
  "Return the last inserted row ID for BACKEND.")

(cl-defgeneric tabularium-db-identifier (backend)
  "Return a unique identifier string for BACKEND's connection.")

(cl-defgeneric tabularium-db-sql-type (backend field-type)
  "Convert Tabularium FIELD-TYPE symbol to backend-specific SQL type string.")

(cl-defgeneric tabularium-db-date-function (backend)
  "Return SQL expression for current date/time on BACKEND.")

(cl-defgeneric tabularium-db-backend-name (backend)
  "Return human-readable name of BACKEND.")

;;; * 2 Backend Base Class

(defclass tabularium-db-backend ()
  ((name :initarg :name :initform "Unknown" :type string)
   (connection :initform nil))
  "Base class for Tabularium database backends."
  :abstract t)

(cl-defmethod tabularium-db-backend-name ((backend tabularium-db-backend))
  "Return the backend name."
  (oref backend name))

;;; * 3 SQLite Backend

(defcustom tabularium-db-sqlite-wal-mode t
  "Whether to enable WAL mode for SQLite.
WAL provides better concurrency and sync-friendliness."
  :type 'boolean
  :group 'tabularium)

(defcustom tabularium-db-sqlite-checkpoint-on-close t
  "Whether to checkpoint WAL before closing SQLite connections.
Merges write-ahead log into the main file for clean syncing."
  :type 'boolean
  :group 'tabularium)

(defclass tabularium-db-sqlite (tabularium-db-backend)
  ((name :initform "SQLite")
   (file :initarg :file :initform nil :type (or null string)))
  "SQLite backend using Emacs 29+ built-in sqlite.el.")

(cl-defmethod tabularium-db-connect ((backend tabularium-db-sqlite) config)
  "Connect to SQLite database specified by :file in CONFIG."
  (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (user-error "Tabularium requires Emacs compiled with SQLite support (--with-sqlite3)"))
  (let* ((file (expand-file-name (plist-get config :file)))
         (dir (file-name-directory file)))
    (unless (file-exists-p dir)
      (make-directory dir t))
    (let ((conn (sqlite-open file)))
      (unless conn
        (error "Failed to open SQLite database: %s" file))
      (oset backend file file)
      (oset backend connection conn)
      (when tabularium-db-sqlite-wal-mode
        (sqlite-execute conn "PRAGMA journal_mode=WAL"))
      (sqlite-execute conn "PRAGMA busy_timeout=5000")
      backend)))

(cl-defmethod tabularium-db-disconnect ((backend tabularium-db-sqlite))
  "Disconnect from SQLite database."
  (let ((conn (oref backend connection)))
    (when (and conn (sqlitep conn))
      (when tabularium-db-sqlite-checkpoint-on-close
        (ignore-errors
          (sqlite-execute conn "PRAGMA wal_checkpoint(TRUNCATE)")))
      (sqlite-close conn)
      (oset backend connection nil))))

(cl-defmethod tabularium-db-connected-p ((backend tabularium-db-sqlite))
  "Check if SQLite connection is active."
  (let ((conn (oref backend connection)))
    (and conn (sqlitep conn))))

(cl-defmethod tabularium-db-execute ((backend tabularium-db-sqlite) sql &optional params)
  "Execute SQL on SQLite."
  (let ((conn (oref backend connection)))
    (if params (sqlite-execute conn sql params) (sqlite-execute conn sql))))

(cl-defmethod tabularium-db-query ((backend tabularium-db-sqlite) sql &optional params)
  "Query SQLite, returning rows."
  (let ((conn (oref backend connection)))
    (if params (sqlite-select conn sql params) (sqlite-select conn sql))))

(cl-defmethod tabularium-db-query-single ((backend tabularium-db-sqlite) sql &optional params)
  "Query SQLite, returning first row."
  (car (tabularium-db-query backend sql params)))

(cl-defmethod tabularium-db-query-scalar ((backend tabularium-db-sqlite) sql &optional params)
  "Query SQLite, returning first value."
  (caar (tabularium-db-query backend sql params)))

(cl-defmethod tabularium-db-table-exists-p ((backend tabularium-db-sqlite) table-name)
  "Check if TABLE-NAME exists in SQLite."
  (not (null (tabularium-db-query
              backend
              "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
              (list table-name)))))

(cl-defmethod tabularium-db-table-columns ((backend tabularium-db-sqlite) table-name)
  "Get column info for SQLite TABLE-NAME."
  (mapcar (lambda (row)
            (list :name (intern (nth 1 row))
                  :type (nth 2 row)
                  :notnull (= (nth 3 row) 1)
                  :default (nth 4 row)
                  :primary-key (= (nth 5 row) 1)))
          (tabularium-db-query backend (format "PRAGMA table_info(%s)" table-name))))

(cl-defmethod tabularium-db-create-table ((backend tabularium-db-sqlite) table-name columns)
  "Create TABLE-NAME in SQLite with COLUMNS."
  (let* ((col-defs
          (mapcar (lambda (col)
                    (let ((name (symbol-name (plist-get col :name)))
                          (type (plist-get col :sql-type))
                          (primary (plist-get col :primary))
                          (check (plist-get col :check)))
                      (concat name " " type
                              (when primary " PRIMARY KEY")
                              (when check (format " CHECK (%s)" check)))))
                  columns))
         (sql (format "CREATE TABLE IF NOT EXISTS %s (%s)"
                      table-name (string-join col-defs ", "))))
    (tabularium-db-execute backend sql)))

(cl-defmethod tabularium-db-create-index ((backend tabularium-db-sqlite) table-name column-name)
  "Create index on COLUMN-NAME in SQLite TABLE-NAME."
  (tabularium-db-execute
   backend
   (format "CREATE INDEX IF NOT EXISTS idx_%s_%s ON %s(%s)"
           table-name column-name table-name column-name)))

(cl-defmethod tabularium-db-insert ((backend tabularium-db-sqlite) table-name alist)
  "Insert row into SQLite TABLE-NAME from ALIST."
  (let* ((fields (mapcar #'car alist))
         (values (mapcar #'cdr alist))
         (placeholders (mapconcat (lambda (_) "?") fields ", "))
         (field-names (mapconcat #'symbol-name fields ", ")))
    (sqlite-execute (oref backend connection)
                    (format "INSERT INTO %s (%s) VALUES (%s)"
                            table-name field-names placeholders)
                    values)))

(cl-defmethod tabularium-db-update ((backend tabularium-db-sqlite) table-name alist where-column where-value)
  "Update SQLite TABLE-NAME with ALIST."
  (when alist
    (let* ((set-clauses (mapconcat (lambda (pair)
                                     (format "%s = ?" (symbol-name (car pair))))
                                   alist ", "))
           (values (append (mapcar #'cdr alist) (list where-value))))
      (sqlite-execute (oref backend connection)
                      (format "UPDATE %s SET %s WHERE %s = ?"
                              table-name set-clauses (symbol-name where-column))
                      values))))

(cl-defmethod tabularium-db-delete ((backend tabularium-db-sqlite) table-name where-column where-value)
  "Delete from SQLite TABLE-NAME."
  (sqlite-execute (oref backend connection)
                  (format "DELETE FROM %s WHERE %s = ?" table-name (symbol-name where-column))
                  (list where-value)))

(cl-defmethod tabularium-db-last-insert-id ((backend tabularium-db-sqlite))
  "Get last insert row ID from SQLite."
  (caar (sqlite-select (oref backend connection) "SELECT last_insert_rowid()")))

(cl-defmethod tabularium-db-identifier ((backend tabularium-db-sqlite))
  "Return database file path as identifier."
  (oref backend file))

(cl-defmethod tabularium-db-sql-type ((_backend tabularium-db-sqlite) field-type)
  "Convert FIELD-TYPE to SQLite type."
  (pcase field-type
    ('integer "INTEGER") ('number "REAL") (_ "TEXT")))

(cl-defmethod tabularium-db-date-function ((_backend tabularium-db-sqlite))
  "Return SQLite datetime function."
  "datetime('now')")

;;; * 4 Backend Registry

(defvar tabularium-db--backend-types
  '((sqlite . tabularium-db-sqlite))
  "Alist mapping backend type symbols to their classes.")

(defun tabularium-db-get-backend-class (backend-type)
  "Get the backend class for BACKEND-TYPE symbol."
  (or (alist-get backend-type tabularium-db--backend-types)
      (error "Unknown database backend: %s" backend-type)))

(defun tabularium-db-create-backend (backend-type)
  "Create a new backend instance for BACKEND-TYPE."
  (make-instance (tabularium-db-get-backend-class backend-type)))

(defun tabularium-db-register-backend (type class)
  "Register backend CLASS for TYPE symbol."
  (setf (alist-get type tabularium-db--backend-types) class))

;;; * 5 Connection Manager

(defvar tabularium-db--connections (make-hash-table :test 'equal)
  "Active backend objects keyed by schema name.")

(defvar tabularium-db--hooks-registered nil
  "Whether cleanup hooks have been registered.")

(defun tabularium-db-get-connection (schema-name config)
  "Get or create backend for SCHEMA-NAME using CONFIG plist."
  (let* ((backend-type (or (plist-get config :backend) 'sqlite))
         (cached (gethash schema-name tabularium-db--connections)))
    (if (and cached (tabularium-db-connected-p cached))
        cached
      (when cached
        (ignore-errors (tabularium-db-disconnect cached)))
      (let ((backend (tabularium-db-create-backend backend-type)))
        (tabularium-db-connect backend config)
        (puthash schema-name backend tabularium-db--connections)
        (unless tabularium-db--hooks-registered
          (add-hook 'suspend-hook #'tabularium-db--suspend-hook)
          (add-hook 'kill-emacs-hook #'tabularium-db--kill-hook)
          (setq tabularium-db--hooks-registered t))
        backend))))

(defun tabularium-db-close-connection (schema-name)
  "Close connection for SCHEMA-NAME."
  (when-let ((backend (gethash schema-name tabularium-db--connections)))
    (ignore-errors (tabularium-db-disconnect backend))
    (remhash schema-name tabularium-db--connections)))

(defun tabularium-db-close-all-connections ()
  "Close all active database connections."
  (maphash (lambda (_name backend)
             (ignore-errors (tabularium-db-disconnect backend)))
           tabularium-db--connections)
  (clrhash tabularium-db--connections))

;;; * 6 SQL Helpers

(defun tabularium-db-build-like-clause (column pattern)
  "Build a LIKE clause for COLUMN matching PATTERN."
  (format "%s LIKE '%%%s%%'"
          (if (symbolp column) (symbol-name column) column)
          pattern))

(defun tabularium-db-sql-quote (value)
  "Quote VALUE for safe SQL insertion."
  (if (numberp value)
      (number-to-string value)
    (format "'%s'" (replace-regexp-in-string "'" "''" (format "%s" value)))))

(defun tabularium-db-collate (case-sensitive)
  "Return SQL COLLATE clause.
When CASE-SENSITIVE is non-nil, returns COLLATE BINARY."
  (if case-sensitive " COLLATE BINARY" ""))

(defun tabularium-db-like-op (case-sensitive)
  "Return the SQL match operator.
When CASE-SENSITIVE is non-nil, returns GLOB (case-sensitive).
Otherwise returns LIKE (case-insensitive)."
  (if case-sensitive "GLOB" "LIKE"))

(defun tabularium-db-like-pattern (value case-sensitive)
  "Wrap VALUE in wildcard pattern for the current match operator.
When CASE-SENSITIVE is non-nil, uses *value* for GLOB.
Otherwise uses %value% for LIKE."
  (if case-sensitive
      ;; GLOB: escape [ ] * ? by wrapping each in [c]
      (let ((escaped (replace-regexp-in-string
                      "[][*?]"
                      (lambda (m) (format "[%s]" m))
                      value t t)))
        (format "*%s*" escaped))
    (format "%%%s%%" value)))

(defun tabularium-db-update-schema-file-path (schema-file new-db-path)
  "Update the :file path in SCHEMA-FILE to NEW-DB-PATH.
Modifies the schema file on disk.  Returns non-nil on success."
  (with-temp-buffer
    (insert-file-contents schema-file)
    (goto-char (point-min))
    (when (re-search-forward ":file\\s-+\"\\([^\"]+\\)\"" nil t)
      (replace-match (format ":file \"%s\"" (abbreviate-file-name new-db-path)))
      (write-region (point-min) (point-max) schema-file)
      t)))

;;; * 7 Sync Safety

(defcustom tabularium-db-close-on-suspend t
  "Whether to close all connections when Emacs suspends."
  :type 'boolean
  :group 'tabularium)

(defcustom tabularium-db-close-on-kill t
  "Whether to close all connections when Emacs exits."
  :type 'boolean
  :group 'tabularium)

(defun tabularium-db--checkpoint-all ()
  "Checkpoint all open SQLite WALs without closing connections.
Internal; called by `tabularium-checkpoint'."
  (let ((count 0) (errors 0))
    (maphash (lambda (_name backend)
               (when (and backend
                          (tabularium-db-connected-p backend)
                          (object-of-class-p backend 'tabularium-db-sqlite))
                 (condition-case err
                     (progn
                       (sqlite-execute (oref backend connection)
                                       "PRAGMA wal_checkpoint(TRUNCATE)")
                       (cl-incf count))
                   (error
                    (cl-incf errors)
                    (message "Checkpoint error for %s: %s"
                             (oref backend file) (error-message-string err))))))
             tabularium-db--connections)
    (if (> errors 0)
        (message "Checkpointed %d database(s), %d error(s)" count errors)
      (message "Checkpointed %d database(s)" count))))

(defun tabularium-db--prepare-for-sync ()
  "Close all connections for clean sync state.
Internal; called by `tabularium-prepare-for-sync'."
  (tabularium-db-close-all-connections)
  (message "All databases closed and ready for sync"))

(defun tabularium-db-cleanup-wal-files (db-files)
  "Delete orphaned SQLite WAL and SHM files for DB-FILES.
DB-FILES is a list of database file paths.  Returns the number
of files deleted.  Safe to call when databases are closed."
  (let ((cleaned 0))
    (dolist (db-file db-files)
      (when db-file
        (dolist (suffix '("-wal" "-shm"))
          (let ((f (concat db-file suffix)))
            (when (file-exists-p f)
              (delete-file f)
              (cl-incf cleaned))))))
    cleaned))

(defun tabularium-db--suspend-hook ()
  "Close databases on suspend if configured."
  (when tabularium-db-close-on-suspend
    (tabularium-db-close-all-connections)))

(defun tabularium-db--kill-hook ()
  "Close databases on exit if configured."
  (when tabularium-db-close-on-kill
    (tabularium-db-close-all-connections)))

;;; * 8 Provide

(provide 'tabularium-db)

;;; tabularium-db.el ends here
