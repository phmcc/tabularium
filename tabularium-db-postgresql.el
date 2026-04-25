;;; tabularium-db-postgresql.el --- PostgreSQL backend for Tabularium -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2026 Paul H. McClelland

;; Author: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Maintainer: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Version: 0.4.4
;; Package-Requires: ((emacs "29.1") (emacsql "4.0") (emacsql-pg "1.0"))
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

;; PostgreSQL backend for Tabularium using emacsql-pg.
;; Enables multi-device concurrent access and shared team databases.

;;; Code:

(require 'tabularium-db)

;; Forward declarations for emacsql functions
(declare-function emacsql "emacsql" (connection sql &rest args))
(declare-function emacsql-close "emacsql" (connection))
(declare-function emacsql-pg "emacsql-pg" (database &rest args))
(declare-function emacsql-live-p "emacsql" (connection))

;;; * 1 PostgreSQL Backend

;; Only define when emacsql-pg is available
(when (require 'emacsql-pg nil t)

  (defclass tabularium-db-postgresql (tabularium-db-backend)
    ((name :initform "PostgreSQL")
     (host :initarg :host :initform "localhost" :type string)
     (port :initarg :port :initform 5432 :type integer)
     (database :initarg :database :type string)
     (user :initarg :user :type string))
    "PostgreSQL backend using emacsql-pg.")

  (cl-defmethod tabularium-db-connect ((backend tabularium-db-postgresql) config)
    "Connect to PostgreSQL database."
    (let ((host (or (plist-get config :host) "localhost"))
          (port (or (plist-get config :port) 5432))
          (database (plist-get config :database))
          (user (plist-get config :user))
          (password (plist-get config :password)))
      (unless database
        (error "PostgreSQL backend requires :database in config"))
      (oset backend host host)
      (oset backend port port)
      (oset backend database database)
      (oset backend user user)
      (let ((conn (emacsql-pg database
                              :host host :port port
                              :user user :password password)))
        (oset backend connection conn)
        backend)))

  (cl-defmethod tabularium-db-disconnect ((backend tabularium-db-postgresql))
    "Disconnect from PostgreSQL database."
    (let ((conn (oref backend connection)))
      (when (and conn (emacsql-live-p conn))
        (emacsql-close conn)
        (oset backend connection nil))))

  (cl-defmethod tabularium-db-connected-p ((backend tabularium-db-postgresql))
    "Check if PostgreSQL connection is active."
    (let ((conn (oref backend connection)))
      (and conn (emacsql-live-p conn))))

  (cl-defmethod tabularium-db-execute ((backend tabularium-db-postgresql) sql &optional params)
    "Execute SQL on PostgreSQL."
    (let ((conn (oref backend connection)))
      (if params
          (apply #'emacsql conn (vector :raw sql) params)
        (emacsql conn (vector :raw sql)))))

  (cl-defmethod tabularium-db-query ((backend tabularium-db-postgresql) sql &optional params)
    "Query PostgreSQL, returning rows."
    (let ((conn (oref backend connection)))
      (if params
          (apply #'emacsql conn (vector :raw sql) params)
        (emacsql conn (vector :raw sql)))))

  (cl-defmethod tabularium-db-query-single ((backend tabularium-db-postgresql) sql &optional params)
    "Query PostgreSQL, returning first row."
    (car (tabularium-db-query backend sql params)))

  (cl-defmethod tabularium-db-query-scalar ((backend tabularium-db-postgresql) sql &optional params)
    "Query PostgreSQL, returning first value."
    (caar (tabularium-db-query backend sql params)))

  (cl-defmethod tabularium-db-table-exists-p ((backend tabularium-db-postgresql) table-name)
    "Check if TABLE-NAME exists in PostgreSQL."
    (not (null (emacsql (oref backend connection)
                        [:select [name]
                                 :from information_schema:tables
                                 :where (and (= table_schema "public")
                                             (= table_name $s1))]
                        table-name))))

  (cl-defmethod tabularium-db-table-columns ((backend tabularium-db-postgresql) table-name)
    "Get column info for PostgreSQL TABLE-NAME."
    (mapcar (lambda (row)
              (list :name (intern (nth 0 row))
                    :type (nth 1 row)
                    :notnull (string= (nth 2 row) "NO")
                    :default (nth 3 row)))
            (emacsql (oref backend connection)
                     [:select [column_name data_type is_nullable column_default]
                              :from information_schema:columns
                              :where (and (= table_schema "public")
                                          (= table_name $s1))
                              :order-by ordinal_position]
                     table-name)))

  (cl-defmethod tabularium-db-create-table ((backend tabularium-db-postgresql) table-name columns)
    "Create TABLE-NAME in PostgreSQL with COLUMNS."
    (let* ((col-defs
            (mapcar (lambda (col)
                      (let ((name (symbol-name (plist-get col :name)))
                            (type (plist-get col :sql-type))
                            (primary (plist-get col :primary)))
                        (concat name " " type (when primary " PRIMARY KEY"))))
                    columns))
           (sql (format "CREATE TABLE IF NOT EXISTS %s (%s,
                         created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                         updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)"
                        table-name (string-join col-defs ", "))))
      (emacsql (oref backend connection) (vector :raw sql))
      ;; Create update trigger
      (ignore-errors
        (emacsql (oref backend connection)
                 [:raw "CREATE OR REPLACE FUNCTION update_timestamp()
                        RETURNS TRIGGER AS $$
                        BEGIN NEW.updated_at = CURRENT_TIMESTAMP; RETURN NEW; END;
                        $$ LANGUAGE plpgsql"])
        (emacsql (oref backend connection)
                 (vector :raw (format "CREATE TRIGGER %s_update_timestamp
                                       BEFORE UPDATE ON %s
                                       FOR EACH ROW EXECUTE FUNCTION update_timestamp()"
                                      table-name table-name))))))

  (cl-defmethod tabularium-db-create-index ((backend tabularium-db-postgresql) table-name column-name)
    "Create index on COLUMN-NAME in PostgreSQL TABLE-NAME."
    (ignore-errors
      (emacsql (oref backend connection)
               (vector :raw (format "CREATE INDEX IF NOT EXISTS idx_%s_%s ON %s(%s)"
                                    table-name column-name table-name column-name)))))

  (cl-defmethod tabularium-db-insert ((backend tabularium-db-postgresql) table-name alist)
    "Insert row into PostgreSQL TABLE-NAME from ALIST."
    (let* ((fields (mapcar #'car alist))
           (values (mapcar #'cdr alist))
           (placeholders (cl-loop for i from 1 to (length fields)
                                  collect (format "$%d" i)))
           (field-names (mapconcat #'symbol-name fields ", ")))
      (apply #'emacsql (oref backend connection)
             (vector :raw (format "INSERT INTO %s (%s) VALUES (%s)"
                                  table-name field-names
                                  (string-join placeholders ", ")))
             values)))

  (cl-defmethod tabularium-db-update ((backend tabularium-db-postgresql) table-name alist where-column where-value)
    "Update PostgreSQL TABLE-NAME with ALIST."
    (when alist
      (let* ((set-clauses (cl-loop for pair in alist for i from 1
                                   collect (format "%s = $%d" (symbol-name (car pair)) i)))
             (where-idx (1+ (length alist)))
             (values (append (mapcar #'cdr alist) (list where-value))))
        (apply #'emacsql (oref backend connection)
               (vector :raw (format "UPDATE %s SET %s WHERE %s = $%d"
                                    table-name (string-join set-clauses ", ")
                                    (symbol-name where-column) where-idx))
               values))))

  (cl-defmethod tabularium-db-delete ((backend tabularium-db-postgresql) table-name where-column where-value)
    "Delete from PostgreSQL TABLE-NAME."
    (emacsql (oref backend connection)
             (vector :raw (format "DELETE FROM %s WHERE %s = $1"
                                  table-name (symbol-name where-column)))
             where-value))

  (cl-defmethod tabularium-db-last-insert-id ((_backend tabularium-db-postgresql))
    "Get last insert ID (requires RETURNING clause in PostgreSQL)."
    nil)

  (cl-defmethod tabularium-db-identifier ((backend tabularium-db-postgresql))
    "Return connection identifier for PostgreSQL."
    (format "postgresql://%s:%d/%s"
            (oref backend host) (oref backend port) (oref backend database)))

  (cl-defmethod tabularium-db-sql-type ((_backend tabularium-db-postgresql) field-type)
    "Convert FIELD-TYPE to PostgreSQL type."
    (pcase field-type
      ('integer "INTEGER")
      ('number "DOUBLE PRECISION")
      ('date "DATE")
      (_ "TEXT")))

  (cl-defmethod tabularium-db-date-function ((_backend tabularium-db-postgresql))
    "Return PostgreSQL datetime function."
    "CURRENT_TIMESTAMP")

  ;; Register the backend
  (tabularium-db-register-backend 'postgresql 'tabularium-db-postgresql))

(unless (featurep 'emacsql-pg)
  (message "tabularium-db-postgresql: emacsql-pg not available; \
PostgreSQL backend disabled.  Install emacsql and emacsql-pg \
to enable."))

;;; * 2 Provide

(provide 'tabularium-db-postgresql)

;;; tabularium-db-postgresql.el ends here
