;;; tabularium-menu.el --- Hydra and Transient menus for Tabularium -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2026 Paul H. McClelland

;; Author: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Maintainer: Paul H. McClelland <paulhmcclelland@protonmail.com>
;; Version: 0.5.4
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

;; This file provides hydra and transient menus for Tabularium.
;;
;; n.b.: This file has `no-byte-compile: t' because hydra macros
;; generate warnings when byte-compiled without hydra loaded.
;; This is intentional and does not affect functionality.
;;
;; Keybinding convention:
;;   lowercase = viewing, navigation, non-destructive commands
;;   UPPERCASE = creating, modifying, destructive commands
;;
;; Usage:
;;   Use `tabularium-menu' or `tabularium-view-menu' as entry points.
;;   These are autoloaded from tabularium.el and work regardless of
;;   whether hydra or transient is loaded.
;;
;; Or bind directly after requiring:
;;
;;   (require 'tabularium-menu)
;;   (global-set-key (kbd "C-c t") #'tabularium-hydra/body)

;;; Code:

(require 'tabularium)

;;; * 1 Helper Functions for Dynamic Display

(defun tabularium--hydra-db-info ()
  "Return database info string for hydra display."
  (if tabularium--current-schema-name
      (format "DB: %s" tabularium--current-schema-name)
    "DB: <none>"))

(defun tabularium--hydra-view-stats ()
  "Return view stats string for hydra display."
  (format "Marked: %d  Frozen: %d"
          (length tabularium--marked-entries)
          (length tabularium--frozen-ids)))

(defun tabularium--hydra-filter-info ()
  "Return filter info for hydra display."
  (let ((desc (tabularium--filter-description)))
    (if desc
        (format "Filter: %s" desc)
      "Filter: none")))

(defun tabularium--hydra-sort-info ()
  "Return sort info for hydra display."
  (format "Sort: %s" (or (tabularium--sort-description) "default")))

;;; * 2 Hydra

;;; ** 2.1 Main Menu

(when (require 'hydra nil t)
  (defhydra tabularium-hydra (:color blue :hint nil)
    "
┌────────────┐
│ Tabularium │  %s(tabularium--hydra-db-info)
└────────────┘
  Database              Entry                   Browse/Query            External                Schema                  
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [_o_] Open              [_N_] New (form)          [_v_] View all            [_i_/_<_] Import…           [_._] Schema…
  [_O_] Open + View       [_P_] Prompt              [_/_] Fuzzy find          [_e_/_>_] Export…
  [_x_] Close             [_Q_] Quick               [_l_] Last match          [_R_] Register
  [_C_] Create…                                   [_%_] Aggregate…          [_s_] Sync prep
  [_r_] Registry
  [_$_] Rename
  [_?_] Describe
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("q" nil)
    ;; Database
    ("o" tabularium-open)
    ("O" tabularium-open-and-view)
    ("x" tabularium-close)
    ("C" tabularium-create-hydra/body)
    ("r" tabularium-registry)
    ("$" tabularium-rename-database)
    ("?" tabularium-describe-database)
    ;; Schema submenu
    ("." tabularium-schema-hydra/body)
    ;; Entry
    ("N" tabularium-new-entry)
    ("P" tabularium-prompt-entry)
    ("Q" tabularium-quick-entry)
    ;; Browse/Query
    ("v" tabularium-view)
    ("/" tabularium-find)
    ("l" tabularium-last)
    ("%" tabularium-aggregate-hydra/body)
    ;; External
    ("i" tabularium-import-hydra/body)
    ("<" tabularium-import-hydra/body)
    ("e" tabularium-export-hydra/body)
    (">" tabularium-export-hydra/body)
    ("R" tabularium-register-database)
    ("s" tabularium-sync-prepare))

  ;; Import sub-hydra: new database vs. append
  (defhydra tabularium-import-hydra (:color blue :hint nil)
    "
┌────────┐
│ Import │
└────────┘
  Main                    
 ────────────────────────────────────────────────────────────────────────────────
  [_i_] Import as new
  [_a_] Append current
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("i" tabularium-import)
    ("a" tabularium-import-append)
    ("q" nil))

  ;; Export sub-hydra: four scopes
  (defhydra tabularium-export-hydra (:color blue :hint nil)
    "
┌────────┐
│ Export │
└────────┘
  Main
 ────────────────────────────────────────────────────────────────────────────────
  [_e_] Export
  [_a_] All
  [_v_] Visible
  [_c_] Copy to clipboard
  [_r_] Range
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("e" tabularium-export)
    ("a" tabularium-export-all)
    ("v" tabularium-export-visible)
    ("c" tabularium-export-to-clipboard)
    ("r" tabularium-export-range)
    ("q" nil))

  ;; Create sub-hydra: four wizard variants
  (defhydra tabularium-create-hydra (:color blue :hint nil)
    "
┌────────┐
│ Create │
└────────┘
  Main
 ────────────────────────────────────────────────────────────────────────────────
  [_C_] Walkthrough
  [_Q_] Quick spec
  [_H_] From header row
  [_._] From schema file
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("C" tabularium-create-database)
    ("Q" tabularium-create-database-quick)
    ("H" tabularium-create-database-from-header)
    ("." tabularium-create-database-from-schema-file)
    ("q" tabularium-hydra/body :color blue))

  ;; Schema sub-hydra
  (defhydra tabularium-schema-hydra (:color blue :hint nil)
    "
┌────────┐
│ Schema │  %s(tabularium--hydra-db-info)
└────────┘
  Edit                    View
 ────────────────────────────────────────────────────────────────────────────────
  [_._] Edit source         [_v_] View
  [_+_] Add field           [_g_/_=_] Reload
  [_$_] Rename field        [_w_] Switch
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("." tabularium-schema-edit)
    ("v" tabularium-schema-view)
    ("g" tabularium-schema-reload)
    ("=" tabularium-schema-reload)
    ("w" tabularium-schema-switch)
    ("+" tabularium-view-column-add)
    ("$" tabularium-schema-rename-field)
    ("q" tabularium-hydra/body :color blue))

  ;; Aggregate sub-hydra (accessible from main hydra)
  ;; n.b.: view-dependent functions (count visible/marked/across, sum visible)
  ;; are only in the view-mode calculate hydra.
  (defhydra tabularium-aggregate-hydra (:color blue :hint nil)
    "
┌───────────┐
│ Aggregate │  %s(tabularium--hydra-db-info)
└───────────┘
  Main
 ────────────────────────────────────────────────────────────────────────────────
  [_s_] Sum
  [_d_] Mean ± SD
  [_i_] Median [IQR]
  [_m_] Min / Max
  [_%_] Field summary
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("s" tabularium-aggregate-sum)
    ("d" tabularium-aggregate-mean-sd)
    ("i" tabularium-aggregate-median-iqr)
    ("m" tabularium-aggregate-min-max)
    ("%" tabularium-aggregate-field-summary)
    ("q" tabularium-hydra/body :color blue)))

;;; ** 2.2 View Mode

(when (require 'hydra nil t)
  (defhydra tabularium-view-hydra (:color pink :hint nil)
    "
┌─────────────────┐
│ Tabularium View │  %s(tabularium--hydra-db-info)   %s(tabularium--hydra-view-stats)
└─────────────────┘
  %s(tabularium--hydra-filter-info)   %s(tabularium--hydra-sort-info)   View: %s(or tabularium--current-view \"<none>\")

  Navigate                Modify                  Mark                      View                      Miscellaneous
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [_p_/_n_] Row ↑/↓           [_N_] New entry           [_m_] Mark row              [_f_] Filter…               [_`_] Reindex
  [_S-TAB_/_TAB_] Cell ←/→    [_P_] Prompt entry        [_u_] Unmark row            [_v_] Views…                [_%_] Aggregate…
  [_[_/_]_] Line ←/→          [_Q_] Quick entry         [_U_] Unmark all            [_|_] Columns…              [_#_] Count…
  [_{_/_}_] Table ↑/↓         [_I_] Insert              [_t_] Toggle marks          [_s_] Sort…                 [_C-/_] Undo
  [_M-{_/_M-}_] Jump ↑/↓      [_E_] Edit                [_a_] Action                [_z_] Freeze…               [_C-?_] Redo
  [_M-[_/_M-]_] Jump ←/→      [_+_] Duplicate           [_*_] Mark menu…                                      [_y_] Kill ring
  [_g_/_=_] Refresh           [_D_] Delete              [_h_] Highlight…                          
  [_/_] Fuzzy find          [_X_/_C_] Cut/Copy                                                    
  [_RET_] Details           [_V_/_A_] Paste/Append                                                
  [_'_] Goto…               [_M_/_W_] Move/Swap                                                   
                          [_R_] Replace…                                                          
                          [_F_] Fill…                                                             
  
 ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit   [_o_] Open   [_O_] Open + View   [_i_/_<_] Import…    [_e_/_>_] Export…    [_$_] Rename   [_._] Schema   [_?_] Describe
"
    ("q" nil :color blue)
    ;; Navigate
    ("n" next-line)
    ("p" previous-line)
    ("{" tabularium-view-first-row)
    ("}" tabularium-view-last-row)
    ("[" tabularium-view-beginning-of-line)
    ("]" tabularium-view-end-of-line)
    ("S-TAB" tabularium-view-backward-cell)
    ("TAB" tabularium-view-forward-cell)
    ("M-n" tabularium-view-cell-jump-down)
    ("M-p" tabularium-view-cell-jump-up)
    ("M-]" tabularium-view-cell-jump-forward)
    ("M-[" tabularium-view-cell-jump-backward)
    ("M-}" tabularium-view-cell-jump-down)
    ("M-{" tabularium-view-cell-jump-up)
    ("M-<down>" tabularium-view-cell-jump-down)
    ("M-<up>" tabularium-view-cell-jump-up)
    ("M-<right>" tabularium-view-cell-jump-forward)
    ("M-<left>" tabularium-view-cell-jump-backward)
    ("C-<down>" tabularium-view-scroll-row-down)
    ("C-<up>" tabularium-view-scroll-row-up)
    ("C-<right>" tabularium-view-scroll-column-right)
    ("C-<left>" tabularium-view-scroll-column-left)
    ("C-S-<down>" tabularium-view-page-down)
    ("C-S-<up>" tabularium-view-page-up)
    ("C-S-<right>" tabularium-view-scroll-page-right)
    ("C-S-<left>" tabularium-view-scroll-page-left)
    ("g" tabularium-view-refresh)
    ("=" tabularium-view-refresh)
    ("'" tabularium-view-goto-hydra/body :color blue)
    ("RET" tabularium-view-entry :color blue)
    ("/" tabularium-find :color blue)
    ;; Modify
    ("N" tabularium-new-entry :color blue)
    ("P" tabularium-prompt-entry :color blue)
    ("Q" tabularium-quick-entry :color blue)
    ("+" tabularium-view-column-add :color blue)
    ("I" tabularium-view-insert :color blue)
    ("E" tabularium-view-edit :color blue)
    ("D" tabularium-view-delete :color blue)
    ("+" tabularium-view-duplicate :color blue)
    ("C" tabularium-view-copy)
    ("V" tabularium-view-paste)
    ("A" tabularium-view-paste-append)
    ("X" tabularium-view-cut)
    ("y" tabularium-kill-ring-view :color blue)
    ("M" tabularium-view-move :color blue)
    ("W" tabularium-view-swap :color blue)
    ("F" tabularium-view-fill-hydra/body :color blue)
    ("R" tabularium-view-replace-hydra/body :color blue)
    ;; Mark
    ("m" tabularium-view-mark)
    ("u" tabularium-view-unmark)
    ("U" tabularium-view-unmark-all)
    ("t" tabularium-view-toggle-marks)
    ("a" tabularium-view-action :color blue)
    ("*" tabularium-view-mark-hydra/body :color blue)
    ("h" tabularium-view-highlight-hydra/body :color blue)
    ;; View
    ("f" tabularium-view-filter-hydra/body :color blue)
    ("v" tabularium-view-views-hydra/body :color blue)
    ("|" tabularium-view-columns-hydra/body :color blue)
    ("s" tabularium-view-sort-hydra/body :color blue)
    ("z" tabularium-view-freeze-hydra/body :color blue)
    ("`" tabularium-reindex :color blue)
    ;; Calculate
    ("%" tabularium-view-aggregate-hydra/body :color blue)
    ("#" tabularium-view-count-hydra/body :color blue)
    ;; Schema submenu
    ("." tabularium-schema-hydra/body :color blue)
    ;; Undo/Redo
    ("C-/" tabularium-undo)
    ("C-_" tabularium-undo)
    ("C-?" tabularium-redo)
    ;; Bottom row
    ("o" tabularium-open :color blue)
    ("O" tabularium-open-and-view :color blue)
    ("i" tabularium-import-hydra/body :color blue)
    ("<" tabularium-import-hydra/body :color blue)
    ("e" tabularium-export-hydra/body :color blue)
    (">" tabularium-export-hydra/body :color blue)
    ("$" tabularium-rename-database :color blue)
    ("?" tabularium-describe-database :color blue))

  ;; Replace sub-hydra (view mode)
  (defhydra tabularium-view-replace-hydra (:color blue :hint nil)
    "
┌─────────┐
│ Replace │  %s(tabularium--hydra-db-info)
└─────────┘
  All rows                Visible only              Other
 ────────────────────────────────────────────────────────────────────────────────
  [_s_] Substring           [_S_] Substring             [_p_] Pattern (all)
  [_e_] Exact               [_E_] Exact                 [_c_] Case toggle
  [_r_] Regexp              [_R_] Regexp
  [_/_] Query-Replace       [_?_] Query-Replace
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ;; All rows
    ("s" tabularium-replace-substring)
    ("e" tabularium-replace-exact)
    ("/" tabularium-replace-query)
    ("r" tabularium-replace-regexp)
    ("p" tabularium-replace-pattern)
    ;; Visible only
    ("S" tabularium-replace-visible-substring)
    ("E" tabularium-replace-visible-exact)
    ("?" tabularium-replace-visible-query)
    ("R" tabularium-replace-visible-regexp)
    ;; Other
    ("c" tabularium-toggle-case-sensitive)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Mark sub-hydra
  (defhydra tabularium-view-mark-hydra (:color blue :hint nil)
    "
┌──────┐
│ Mark │  %s(tabularium--hydra-db-info)   Marked: %s(length tabularium--marked-entries)
└──────┘
  Main                    Other
 ────────────────────────────────────────────────────────────────────────────────
  [_s_] Substring           [_a_] Action
  [_e_] Exact               [_#_] Count marked
  [_r_] Regexp              
  [_p_] Pattern
  [_n_] Rows (range)
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("s" tabularium-view-mark-matching)
    ("e" tabularium-view-mark-exact)
    ("r" tabularium-view-mark-regexp)
    ("n" tabularium-view-mark-range)
    ("p" tabularium-view-mark-pattern)
    ("a" tabularium-view-action :color blue)
    ("#" tabularium-view-count-marked)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Filter sub-hydra
  (defhydra tabularium-view-filter-hydra (:color blue :hint nil)
    "
┌────────┐
│ Filter │  %s(tabularium--hydra-db-info)   %s(tabularium--hydra-filter-info)
└────────┘
  Row                     Column                  Rules
 ────────────────────────────────────────────────────────────────────────────────
  [_f_] At point            [_|_] By value            [_a_] Add rule…
  [_s_] Substring                                   [_l_] Rules list
  [_e_] Exact                                       [_c_] Cycle connective
  [_r_] Regexp                                      [_x_] Remove
  [_n_] Numeric                                     [_X_] Remove all
  [_t_] Datetime
  [_u_] Unique
  [_d_] Duplicate
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("a" tabularium-view-filter-add)
    ("f" tabularium-view-filter-at-point)
    ("s" tabularium-view-filter-substring)
    ("e" tabularium-view-filter-exact)
    ("n" tabularium-view-filter-numeric)
    ("r" tabularium-view-filter-regexp)
    ("t" tabularium-view-filter-datetime)
    ("u" tabularium-view-filter-unique)
    ("d" tabularium-view-filter-duplicates)
    ("|" tabularium-view-filter-column)
    ("l" tabularium-view-filter-buffer)
    ("c" tabularium-view-filter-cycle-connective)
    ("x" tabularium-view-filter-remove)
    ("X" tabularium-view-filter-remove-all)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Sort sub-hydra
  (defhydra tabularium-view-sort-hydra (:color blue :hint nil)
    "
┌──────┐
│ Sort │  %s(tabularium--hydra-db-info)   %s(tabularium--hydra-sort-info)
└──────┘
  Main                  Manage
 ────────────────────────────────────────────────────────────────────────────────
  [_s_] Reverse           [_a_] Add rule…
  [_`_] By index          [_l_] Rules list
                        [_c_] Cycle order
                        [_x_] Remove
                        [_X_] Remove all
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("a" tabularium-view-sort-add)
    ("s" tabularium-view-sort-reverse)
    ("`" tabularium-view-sort-index)
    ("c" tabularium-view-sort-cycle)
    ("x" tabularium-view-sort-remove)
    ("X" tabularium-view-sort-remove-all)
    ("l" tabularium-view-sort-buffer)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Fill sub-hydra
  (defhydra tabularium-view-fill-hydra (:color blue :hint nil)
    "
┌──────┐
│ Fill │  %s(tabularium--hydra-db-info)
└──────┘
  Fill                            Edit
 ────────────────────────────────────────────────────────────────────────────────
  [_f_/_F_] Fill ↓ / ↑ (context)    [_d_/_D_] Delete run ↓ / ↑
  [_n_/_p_] Fill ↓ / ↑ (prompt)     [_r_/_R_] Replace run ↓ / ↑
  [_._/_,_] To point ↓ / ↑          [_x_/_X_] Clear to row excl / incl
  [_s_/_S_] Series ↓ / ↑
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("f" tabularium-view-fill-forward)
    ("F" tabularium-view-fill-backward)
    ("n" tabularium-view-fill-down)
    ("p" tabularium-view-fill-up)
    ("." tabularium-view-fill-down-to-point)
    ("," tabularium-view-fill-up-to-point)
    ("s" tabularium-view-fill-series)
    ("S" tabularium-view-fill-series-up)
    ("d" tabularium-view-fill-delete)
    ("D" tabularium-view-fill-delete-up)
    ("r" tabularium-view-fill-replace)
    ("R" tabularium-view-fill-replace-up)
    ("x" tabularium-view-fill-clear-to-point)
    ("X" tabularium-view-fill-clear)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Highlight sub-hydra
  (defhydra tabularium-view-highlight-hydra (:color blue :hint nil)
    "
┌───────────┐
│ Highlight │  %s(tabularium--hydra-db-info)
└───────────┘
  Row                     Column                  Rules
 ────────────────────────────────────────────────────────────────────────────────
  [_h_] At point            [_\\_] At point            [_a_] Add rule…
  [_s_] Substring           [_|_] Columns…            [_l_] Rules list
  [_e_] Exact match                                 [_x_] Remove
  [_r_] Regexp                                      [_X_] Expunge
  [_n_] Numeric                                     [_._] Save one
  [_t_] Datetime                                    [_>_] Save all
  [_u_] Unique
  [_d_] Duplicates
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("h" tabularium-view-highlight-rows)
    ("\\" tabularium-view-highlight-column)
    ("|" tabularium-view-highlight-columns)
    ("a" tabularium-view-highlight-new)
    ("s" tabularium-view-highlight-substring)
    ("e" tabularium-view-highlight-exact)
    ("t" tabularium-view-highlight-datetime)
    ("u" tabularium-view-highlight-unique)
    ("n" tabularium-view-highlight-numeric)
    ("d" tabularium-view-highlight-duplicates)
    ("r" tabularium-view-highlight-regexp)
    ("l" tabularium-view-highlight-buffer)
    ("x" tabularium-view-highlight-remove)
    ("X" tabularium-view-highlight-expunge)
    ("." tabularium-view-highlight-save)
    (">" tabularium-view-highlight-save-all)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Freeze sub-hydra
  (defhydra tabularium-view-freeze-hydra (:color blue :hint nil)
    "
┌────────┐
│ Freeze │  %s(tabularium--hydra-db-info)
└────────┘
  Main
 ────────────────────────────────────────────────────────────────────────────────
  [_z_]   Freeze row(s)
  [_u_/_x_] Unfreeze row(s)
  [_U_/_X_] Unfreeze all
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("z" tabularium-view-freeze)
    ("u" tabularium-view-unfreeze)
    ("x" tabularium-view-unfreeze)
    ("U" tabularium-view-unfreeze-all)
    ("X" tabularium-view-unfreeze-all)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Columns sub-hydra
  (defhydra tabularium-view-columns-hydra (:color blue :hint nil)
    "
┌─────────┐
│ Columns │  %s(tabularium--hydra-db-info)
└─────────┘
  Visibility              Ordering                  Schema
 ────────────────────────────────────────────────────────────────────────────────
  [_t_] Toggle              [_r_] Reorder               [_N_] New
  [_h_] Hide                [_<_] Move left             [_I_] Insert
  [_s_] Show                [_>_] Move right            [_D_] Delete
  [_o_] Show only           [_=_] Reset order           [_E_] Edit
  [_a_] Show all            [_M_/_W_] Move/Swap           [_+_] Duplicate
                                                    [_$_] Rename
                                                    [_l_] Relabel
                                                    [_F_] Formula
  [_/_] Select by title
                                                    [_X_/_C_] Cut/Copy
                                                    [_V_/_A_] Paste/Append
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ;; Visibility
    ("/" tabularium-view-select-columns)
    ("t" tabularium-view-toggle-column)
    ("h" tabularium-view-hide-columns)
    ("s" tabularium-view-show-columns)
    ("o" tabularium-view-show-only-columns)
    ("a" tabularium-view-show-all-columns)
    ;; Ordering
    ("r" tabularium-view-reorder-columns)
    ("<" tabularium-view-move-column-left)
    (">" tabularium-view-move-column-right)
    ("=" tabularium-view-reset-column-order)
    ("M" tabularium-view-column-move)
    ("W" tabularium-view-column-swap)
    ;; Schema
    ("N" tabularium-view-column-add)
    ("I" tabularium-view-column-insert)
    ("D" tabularium-view-column-delete)
    ("E" tabularium-view-column-edit)
    ("$" tabularium-schema-rename-field)
    ("l" tabularium-view-column-relabel)
    ("F" tabularium-view-column-formula)
    ("+" tabularium-view-column-duplicate)
    ("C" tabularium-view-column-copy)
    ("X" tabularium-view-column-cut)
    ("V" tabularium-view-column-paste)
    ("A" tabularium-view-column-paste-append)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Goto sub-hydra
  (defhydra tabularium-view-goto-hydra (:color blue :hint nil)
    "
┌──────┐
│ Goto │  %s(tabularium--hydra-db-info)
└──────┘
  Main
 ────────────────────────────────────────────────────────────────────────────────
  [_'_] Entry
  [_r_] Row
  [_c_] Column
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("'" tabularium-view-goto-entry)
    ("r" tabularium-view-goto-row)
    ("c" tabularium-view-goto-column)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Count sub-hydra (view mode)
  (defhydra tabularium-view-count-hydra (:color blue :hint nil)
    "
┌───────┐
│ Count │  %s(tabularium--hydra-db-info)
└───────┘
  All                   Visible rows           Tally
 ────────────────────────────────────────────────────────────────────────────────
  [_s_] Substring         [_S_] Substring          [_a_] All
  [_e_] Exact             [_E_] Exact              [_#_] Visible
  [_r_] Regexp            [_R_] Regexp             [_*_] Marked
  [_n_] Numeric           [_N_] Numeric
  [_t_] Datetime          [_T_] Datetime
  [_u_] Unique            [_U_] Unique
  [_d_] Duplicate         [_D_] Duplicate
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("s" tabularium-count-substring)
    ("S" tabularium-count-visible-substring)
    ("e" tabularium-count-exact)
    ("E" tabularium-count-visible-exact)
    ("r" tabularium-count-regexp)
    ("R" tabularium-count-visible-regexp)
    ("n" tabularium-count-numeric)
    ("N" tabularium-count-visible-numeric)
    ("t" tabularium-count-datetime)
    ("T" tabularium-count-visible-datetime)
    ("u" tabularium-count-unique)
    ("U" tabularium-count-visible-unique)
    ("d" tabularium-count-duplicate)
    ("D" tabularium-count-visible-duplicate)
    ("a" tabularium-count-tally)
    ("#" tabularium-count-visible-tally)
    ("*" tabularium-view-count-marked)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Calculate sub-hydra (view mode)
  (defhydra tabularium-view-aggregate-hydra (:color blue :hint nil)
    "
┌───────────┐
│ Aggregate │  %s(tabularium--hydra-db-info)
└───────────┘
  Summarize               Visible                Miscellaneous
 ────────────────────────────────────────────────────────────────────────────────
  [_s_] Sum                 [_S_] Sum                [_%_] Field summary
  [_d_] Mean ± SD           [_D_] Mean ± SD
  [_i_] Median [IQR]        [_I_] Median [IQR]
  [_m_] Min / Max           [_M_] Min / Max
 ────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ;; Aggregate (all)
    ("s" tabularium-aggregate-sum)
    ("d" tabularium-aggregate-mean-sd)
    ("i" tabularium-aggregate-median-iqr)
    ("m" tabularium-aggregate-min-max)
    ;; Aggregate (visible)
    ("S" tabularium-aggregate-visible-sum)
    ("D" tabularium-aggregate-visible-mean-sd)
    ("I" tabularium-aggregate-visible-median-iqr)
    ("M" tabularium-aggregate-visible-min-max)
    ;; Summary
    ("%" tabularium-aggregate-field-summary)
    ("q" tabularium-view-hydra/body :color blue))

  ;; Views sub-hydra (presets + expansion)
  (defhydra tabularium-view-views-hydra (:color blue :hint nil)
    "
┌───────┐
│ Views │  %s(tabularium--hydra-db-info)   View: %s(or tabularium--current-view \"<none>\")
└───────┘
  Presets                 Save / Reset            Expand
 ───────────────────────────────────────────────────────────────────────────
  [_v_] Select view         [_._] Save current        [_>_] Show more
  [_1_-_9_] Preset            [_x_] Clear view          [_+_] All in view
                            [_X_] Expunge saved         [_a_] All
                          [_0_] Reset views         [_r_] Range
                                                [_=_] Reset
                                                [_#_] Count rows / columns
 ───────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ;; Apply
    ("v" tabularium-select-view)
    ("1" tabularium-view-1)
    ("2" tabularium-view-2)
    ("3" tabularium-view-3)
    ("4" tabularium-view-4)
    ("5" tabularium-view-5)
    ("6" tabularium-view-6)
    ("7" tabularium-view-7)
    ("8" tabularium-view-8)
    ("9" tabularium-view-9)
    ;; Save / Reset
    ("." tabularium-view-save)
    ("x" tabularium-view-clear)
    ("X" tabularium-view-expunge)
    ("0" tabularium-view-0)
    ;; Expand
    (">" tabularium-view-show-more)
    ("+" tabularium-view-show-all-in-view)
    ("a" tabularium-view-show-all)
    ("r" tabularium-view-show-range)
    ("=" tabularium-view-reset-limit)
    ("#" tabularium-count-visible-tally)
    ("q" tabularium-view-hydra/body :color blue)))

;;; * 3 Transient

;;; ** 3.1 Main Menu

(when (require 'transient nil t)
  (transient-define-prefix tabularium-transient ()
                           "Tabularium commands."
                           [:description
                            (lambda () (format "Tabularium: %s" (or tabularium--current-schema-name "<none>")))
                            ["Database"
                             ("o" "Open" tabularium-open)
                             ("O" "Open + View" tabularium-open-and-view)
                             ("x" "Close" tabularium-close)
                             ("C" "Create…" tabularium-create-transient)
                             ("r" "List databases" tabularium-registry)
                             ("$" "Rename" tabularium-rename-database)
                             ("?" "Describe" tabularium-describe-database)]
                            ["Schema"
                             (". ." "Edit" tabularium-schema-edit)
                             (". v" "View" tabularium-schema-view)
                             (". =" "Reload" tabularium-schema-reload)
                             (". w" "Switch" tabularium-schema-switch)
                             (". +" "Add field" tabularium-view-column-add)
                             (". $" "Rename field" tabularium-schema-rename-field)]
                            ["Entry"
                             ("N" "New (form)" tabularium-new-entry)
                             ("P" "Prompt entry" tabularium-prompt-entry)
                             ("Q" "Quick entry" tabularium-quick-entry)]
                            ["Browse/Query"
                             ("v" "View all" tabularium-view)
                             ("/" "Fuzzy find" tabularium-find)
                             ("l" "Last match" tabularium-last)
                             ("%" "Aggregate…" tabularium-aggregate-transient)]
                            ["External"
                             ("i" "Import…" tabularium-import-transient)
                             ("<" "Import… (alt)" tabularium-import-transient)
                             ("e" "Export…" tabularium-export-transient)
                             (">" "Export… (alt)" tabularium-export-transient)
                             ("s" "Sync prep" tabularium-sync-prepare)]])

  ;; Create transient submenu: four wizard variants
  (transient-define-prefix tabularium-create-transient ()
                           "Create a new Tabularium database."
                           ["Create"
                            ("C" "Walkthrough" tabularium-create-database)
                            ("Q" "Quick spec" tabularium-create-database-quick)
                            ("H" "From header row" tabularium-create-database-from-header)
                            ("S" "From schema file" tabularium-create-database-from-schema-file)])

  ;; Export transient submenu: four scopes
  (transient-define-prefix tabularium-export-transient ()
                           "Export Tabularium data."
                           ["Export"
                            ("e" "Export (marked or all)" tabularium-export)
                            ("a" "All" tabularium-export-all)
                            ("v" "Visible view" tabularium-export-visible)
                            ("c" "Copy to clipboard" tabularium-export-to-clipboard)
                            ("r" "Range (IDs/columns)" tabularium-export-range)])

  ;; Import transient submenu: new database vs. append
  (transient-define-prefix tabularium-import-transient ()
                           "Import data into Tabularium."
                           ["Import"
                            ("i" "As new database" tabularium-import)
                            ("a" "Append to current database" tabularium-import-append)])

  ;; Aggregate transient submenu
  (transient-define-prefix tabularium-aggregate-transient ()
                           "Aggregate operations."
                           [:description
                            (lambda () (format "Aggregate: %s" (or tabularium--current-schema-name "<none>")))
                            ["Aggregate"
                             ("s" "Sum" tabularium-aggregate-sum)
                             ("m" "Min/Max" tabularium-aggregate-min-max)]
                            ["Advanced"
                             ("d" "Mean±SD" tabularium-aggregate-mean-sd)
                             ("i" "Median[IQR]" tabularium-aggregate-median-iqr)]
                            ["Summary"
                             ("%" "Field summary" tabularium-aggregate-field-summary)]]))

;;; ** 3.2 View Mode

(when (require 'transient nil t)
  (transient-define-prefix tabularium-view-transient ()
    "Tabularium view mode commands."
    [:description
     (lambda () (let ((fdesc (tabularium--filter-description)))
                  (format "Tabularium View: %s%s  |  Marked: %d  Frozen: %d"
                          (or tabularium--current-schema-name "<none>")
                          (if fdesc
                              (format " [%s]" fdesc)
                            "")
                          (length tabularium--marked-entries)
                          (length tabularium--frozen-ids))))
     ["Navigate"
      ("RET" "View entry" tabularium-view-entry)
      ("g" "Refresh" tabularium-view-refresh)
      ("/" "Fuzzy find" tabularium-find)
      ("'" "Goto…" tabularium-view-goto-transient)]
     ["Modify"
      ("N" "New entry" tabularium-new-entry)
      ("E" "Edit" tabularium-view-edit)
      ("+" "Duplicate" tabularium-view-duplicate)
      ("D" "Delete" tabularium-view-delete)
      ("C" "Copy" tabularium-view-copy)
      ("V" "Paste" tabularium-view-paste)
      ("A" "Paste append" tabularium-view-paste-append)
      ("X" "Cut" tabularium-view-cut)]
     ["Create/Move"
      ("P" "Prompt entry" tabularium-prompt-entry)
      ("Q" "Quick entry" tabularium-quick-entry)
      ("I" "Insert at" tabularium-view-insert)
      ("M" "Move" tabularium-view-move)
      ("W" "Swap" tabularium-view-swap)]
     ["Undo/Redo"
      ("C-/" "Undo" tabularium-undo)
      ("C-?" "Redo" tabularium-redo)
      ("y" "Kill ring" tabularium-kill-ring-view)]
     ["Mark"
      ("m" "Mark" tabularium-view-mark)
      ("u" "Unmark" tabularium-view-unmark)
      ("U" "Unmark all" tabularium-view-unmark-all)
      ("t" "Toggle" tabularium-view-toggle-marks)
      ("a" "Action" tabularium-view-action)
      ("* s" "Mark substring" tabularium-view-mark-matching)
      ("* e" "Mark exact" tabularium-view-mark-exact)
      ("* p" "Mark pattern" tabularium-view-mark-pattern)
      ("* r" "Mark regexp" tabularium-view-mark-regexp)
      ("* n" "Mark rows (range)" tabularium-view-mark-range)
      ("* #" "Count marked" tabularium-view-count-marked)
      ("h h" "Highlight rows" tabularium-view-highlight-rows)
      ("h \\" "Highlight column" tabularium-view-highlight-column)
      ("h |" "Highlight columns" tabularium-view-highlight-columns)
      ("h a" "Add highlight rule" tabularium-view-highlight-new)
      ("h n" "Highlight numeric" tabularium-view-highlight-numeric)
      ("h d" "Highlight duplicates" tabularium-view-highlight-duplicates)
      ("h r" "Highlight regexp" tabularium-view-highlight-regexp)
      ("h l" "Highlight rules list" tabularium-view-highlight-buffer)
      ("h x" "Remove highlight" tabularium-view-highlight-remove)
      ("h X" "Expunge highlights" tabularium-view-highlight-expunge)
      ("h ." "Save one highlight" tabularium-view-highlight-save)
      ("h >" "Save all highlights" tabularium-view-highlight-save-all)]
     ["View" :pad-keys t
      ("f a" "Add rule" tabularium-view-filter-add)
      ("f f" "At point" tabularium-view-filter-at-point)
      ("f s" "Substring" tabularium-view-filter-substring)
      ("f e" "Exact match" tabularium-view-filter-exact)
      ("f n" "Numeric" tabularium-view-filter-numeric)
      ("f l" "Rules list" tabularium-view-filter-buffer)
      ("f c" "Cycle connective" tabularium-view-filter-cycle-connective)
      ("f x" "Remove filter" tabularium-view-filter-remove)
      ("f X" "Remove all filters" tabularium-view-filter-remove-all)
      ("v v" "Select view" tabularium-select-view)
      ("v ." "Save current" tabularium-view-save)
      ("v 0" "Reset views" tabularium-view-0)
      ("v x" "Clear all" tabularium-view-clear)
      ("v X" "Expunge saved view" tabularium-view-expunge)
      ("v >" "Show more" tabularium-view-show-more)
      ("v a" "Show all (no constraints)" tabularium-view-show-all)
      ("v +" "Show all in view" tabularium-view-show-all-in-view)
      ("v r" "Show range" tabularium-view-show-range)
      ("v =" "Reset limit" tabularium-view-reset-limit)
      ("s a" "Add rule" tabularium-view-sort-add)
      ("s s" "Sort by column" tabularium-view-sort-reverse)
      ("s `" "Sort by index" tabularium-view-sort-index)
      ("s c" "Cycle order" tabularium-view-sort-cycle)
      ("s l" "Rules list" tabularium-view-sort-buffer)
      ("s x" "Remove sort" tabularium-view-sort-remove)
      ("s X" "Remove all sorts" tabularium-view-sort-remove-all)
      ("z z" "Freeze row" tabularium-view-freeze)
      ("z u" "Unfreeze row" tabularium-view-unfreeze)
      ("z x" "Unfreeze row" tabularium-view-unfreeze)
      ("z U" "Unfreeze all" tabularium-view-unfreeze-all)
      ("z X" "Unfreeze all" tabularium-view-unfreeze-all)
      ("`" "Reindex" tabularium-reindex)]
     ["Modify" :pad-keys t
      ("R s" "Replace substr" tabularium-replace-substring)
      ("R S" "Visible: substr" tabularium-replace-visible-substring)
      ("R e" "Replace exact" tabularium-replace-exact)
      ("R E" "Visible: exact" tabularium-replace-visible-exact)
      ("R p" "Replace pattern" tabularium-replace-pattern)
      ("R r" "Replace regexp" tabularium-replace-regexp)
      ("R R" "Visible: regexp" tabularium-replace-visible-regexp)
      ("R /" "Query-replace" tabularium-replace-query)
      ("R ?" "Visible: query" tabularium-replace-visible-query)
      ("R c" "Case toggle" tabularium-toggle-case-sensitive)
      ("F f" "Fill ↓ (context)" tabularium-view-fill-forward)
      ("F F" "Fill ↑ (context)" tabularium-view-fill-backward)
      ("F n" "Fill ↓ (prompt)" tabularium-view-fill-down)
      ("F p" "Fill ↑ (prompt)" tabularium-view-fill-up)
      ("F ." "To point ↓" tabularium-view-fill-down-to-point)
      ("F ," "To point ↑" tabularium-view-fill-up-to-point)
      ("F s" "Series ↓" tabularium-view-fill-series)
      ("F S" "Series ↑" tabularium-view-fill-series-up)
      ("F d" "Delete run ↓" tabularium-view-fill-delete)
      ("F D" "Delete run ↑" tabularium-view-fill-delete-up)
      ("F r" "Replace run ↓" tabularium-view-fill-replace)
      ("F R" "Replace run ↑" tabularium-view-fill-replace-up)
      ("F x" "Clear down through row" tabularium-view-fill-clear)
      ("F X" "Clear up through row" tabularium-view-fill-clear-to-point)]
     ["Count (# prefix)"
      ("# s" "Substring" tabularium-count-substring)
      ("# S" "Visible: Substring" tabularium-count-visible-substring)
      ("# e" "Exact" tabularium-count-exact)
      ("# E" "Visible: Exact" tabularium-count-visible-exact)
      ("# r" "Regexp" tabularium-count-regexp)
      ("# R" "Visible: Regexp" tabularium-count-visible-regexp)
      ("# n" "Numeric" tabularium-count-numeric)
      ("# N" "Visible: Numeric" tabularium-count-visible-numeric)
      ("# t" "Datetime" tabularium-count-datetime)
      ("# T" "Visible: Datetime" tabularium-count-visible-datetime)
      ("# u" "Unique" tabularium-count-unique)
      ("# U" "Visible: Unique" tabularium-count-visible-unique)
      ("# d" "Duplicate" tabularium-count-duplicate)
      ("# D" "Visible: Duplicate" tabularium-count-visible-duplicate)
      ("# a" "Tally all" tabularium-count-tally)
      ("# #" "Tally visible" tabularium-count-visible-tally)
      ("# *" "Marked" tabularium-view-count-marked)]
     ["Aggregate (% prefix)"
      ("% s" "Sum" tabularium-aggregate-sum)
      ("% S" "Visible: Sum" tabularium-aggregate-visible-sum)
      ("% m" "Min/Max" tabularium-aggregate-min-max)
      ("% M" "Visible: Min/Max" tabularium-aggregate-visible-min-max)
      ("% d" "Mean±SD" tabularium-aggregate-mean-sd)
      ("% D" "Visible: Mean±SD" tabularium-aggregate-visible-mean-sd)
      ("% i" "Median[IQR]" tabularium-aggregate-median-iqr)
      ("% I" "Visible: Med[IQR]" tabularium-aggregate-visible-median-iqr)
      ("% %" "Field summary" tabularium-aggregate-field-summary)]
     ["Columns (| prefix)" :pad-keys t
      ("| t" "Toggle" tabularium-view-toggle-column)
      ("| h" "Hide" tabularium-view-hide-columns)
      ("| s" "Show" tabularium-view-show-columns)
      ("| o" "Show only" tabularium-view-show-only-columns)
      ("| a" "Show all" tabularium-view-show-all-columns)
      ("| r" "Reorder" tabularium-view-reorder-columns)
      ("| <" "Move left" tabularium-view-move-column-left)
      ("| >" "Move right" tabularium-view-move-column-right)
      ("| =" "Reset order" tabularium-view-reset-column-order)
      ("| N" "New column" tabularium-view-column-add)
      ("| I" "Insert col" tabularium-view-column-insert)
      ("| D" "Delete col" tabularium-view-column-delete)
      ("| E" "Edit col" tabularium-view-column-edit)
      ("| $" "Rename col" tabularium-schema-rename-field)
      ("| l" "Relabel col" tabularium-view-column-relabel)
      ("| F" "Edit formula" tabularium-view-column-formula)
      ("| +" "Duplicate col" tabularium-view-column-duplicate)
      ("| M" "Move cols" tabularium-view-column-move)
      ("| W" "Swap cols" tabularium-view-column-swap)
      ("| C" "Copy cols" tabularium-view-column-copy)
      ("| X" "Cut cols" tabularium-view-column-cut)
      ("| V" "Paste cols" tabularium-view-column-paste)
      ("| A" "Append cols" tabularium-view-column-paste-append)]
     ["Database"
      ("o" "Open" tabularium-open)
      ("O" "Open + View" tabularium-open-and-view)
      ("i" "Import…" tabularium-import-transient)
      ("<" "Import… (alt)" tabularium-import-transient)
      ("e" "Export…" tabularium-export-transient)
      (">" "Export… (alt)" tabularium-export-transient)
      ("$" "Rename DB" tabularium-rename-database)
      ("?" "Describe DB" tabularium-describe-database)]
     ["Schema"
      (". ." "Edit" tabularium-schema-edit)
      (". v" "View" tabularium-schema-view)
      (". =" "Reload" tabularium-schema-reload)
      (". w" "Switch" tabularium-schema-switch)
      (". +" "Add field" tabularium-view-column-add)
      (". $" "Rename field" tabularium-schema-rename-field)]])

  ;; Goto transient (for view mode)
  (transient-define-prefix tabularium-view-goto-transient ()
    "Goto operations."
    [:description
     (lambda () (format "Goto: %s" (or tabularium--current-schema-name "<none>")))
     ["Goto"
      ("c" "Column" tabularium-view-goto-column)
      ("r" "Row" tabularium-view-goto-row)
      ("e" "Entry" tabularium-view-goto-entry)]]))

;;; * 4 Provide

(provide 'tabularium-menu)

;;; tabularium-menu.el ends here
