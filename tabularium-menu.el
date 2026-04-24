;;; tabularium-menu.el --- Hydra and Transient menus for Tabularium -*- lexical-binding: t; no-byte-compile: t; -*-

;; Author: Paul H. McClelland
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Paul H. McClelland

;; Version: 0.4.3
;; Package-Requires: ((emacs "29.1"))
;; Keywords: data
;; URL: https://codeberg.org/phmcc/tabularium

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

;;; ** 2.1. Main Menu

(when (require 'hydra nil t)
  (defhydra tabularium-hydra (:color blue :hint nil)
    "
┌────────────┐
│ Tabularium │  %s(tabularium--hydra-db-info)
└────────────┘
  Database            Entry               Browse/Query        External            Schema
  ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [_o_] Open            [_N_] New (form)      [_v_] View all        [_i_] Import          [_._] Schema »
  [_O_] Open+View       [_P_] Prompt          [_/_] Fuzzy find      [_e_] Export
  [_x_] Close           [_Q_] Quick           [_t_] Last match      [_+_] Register
  [_C_] Create                              [_#_] Calculate »     [_s_] Sync prep
  [_r_] Registry
  [_$_] Rename
  ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("q" nil)
    ;; Database
    ("o" tabularium-open)
    ("O" tabularium-open-and-view)
    ("x" tabularium-close)
    ("C" tabularium-create-database)
    ("r" tabularium-registry)
    ("$" tabularium-rename-database)
    ;; Schema submenu
    ("." tabularium-schema-hydra/body)
    ;; Entry
    ("N" tabularium-new-entry)
    ("P" tabularium-prompt-entry)
    ("Q" tabularium-quick-entry)
    ;; Browse/Query
    ("v" tabularium-view)
    ("/" tabularium-find)
    ("t" tabularium-last)
    ("#" tabularium-calculate-hydra/body)
    ;; External
    ("e" tabularium-export)
    ("i" tabularium-import)
    ("+" tabularium-register-database)
    ("s" tabularium-prepare-for-sync))

  ;; Schema sub-hydra
  (defhydra tabularium-schema-hydra (:color blue :hint nil)
    "
┌────────┐
│ Schema │  %s(tabularium--hydra-db-info)
└────────┘
  ───────────────────────────────────────────────────────────────────────────────
  [_._] Edit          [_s_] Show          [_r_] Reload        [_w_] Switch
  [_+_] Add field
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("." tabularium-schema-edit)
    ("s" tabularium-schema-show)
    ("r" tabularium-schema-reload)
    ("w" tabularium-schema-switch)
    ("+" tabularium-view-column-add)
    ("q" nil))

  ;; Calculate sub-hydra (accessible from main hydra)
  ;; Note: view-dependent functions (count visible/marked/across, sum visible)
  ;; are only in the view-mode calculate hydra.
  (defhydra tabularium-calculate-hydra (:color blue :hint nil)
    "
┌───────────┐
│ Calculate │  %s(tabularium--hydra-db-info)
└───────────┘
  Count                     Aggregate                   Advanced
  ───────────────────────────────────────────────────────────────────────────────
  [_c_] Count query          [_s_] Sum                    [_d_] Mean ± SD
                            [_m_] Min / Max              [_M_] Median [IQR]

  [_#_] Column summary
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ;; Count
    ("c" tabularium-count)
    ;; Aggregate
    ("s" tabularium-sum)
    ("m" tabularium-min-max)
    ;; Advanced
    ("d" tabularium-mean-sd)
    ("M" tabularium-median-iqr)
    ;; Summary
    ("#" tabularium-column-summary)
    ("q" nil)))

;;; ** 2.2. View Mode

(when (require 'hydra nil t)
  (defhydra tabularium-view-hydra (:color pink :hint nil)
    "
┌─────────────────┐
│ Tabularium View │  %s(tabularium--hydra-db-info)   %s(tabularium--hydra-view-stats)
└─────────────────┘
%s(tabularium--hydra-filter-info)   %s(tabularium--hydra-sort-info)   View: %s(or tabularium--current-view \"<none>\")

  Navigate              Modify                Mark                  View                Calculate
  ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [_n_/_p_] Row up/down     [_N_] New entry         [_m_] Mark row          [_f_] Filter »        [_#_] Calculate »
  [_{_/_}_] First/last      [_P_] Prompt entry      [_u_] Unmark row        [_v_] Views »
  [_[_/_]_] Line beg/end    [_Q_] Quick entry       [_U_] Unmark all        [_|_] Columns »       [_C-/_] Undo
  [_TAB_] Next cell       [_I_] Insert            [_t_] Toggle marks      [_^_] Reverse sort    [_C-?_] Redo
  [_M-n_/_M-p_] Jump ↓/↑    [_E_] Edit              [_x_] Execute marks     [_s_] Sort »          [_y_] Kill ring
  [_g_/_=_] Refresh         [_d_] Duplicate         [_*_] Mark menu »       [_z_] Freeze
  [_/_] Fuzzy find        [_D_] Delete                                  [_Z_] Unfreeze all
  [_RET_] Details         [_X_] Cut    [_C_] Copy                         [_`_] Reindex
  [_'_] Goto »            [_V_] Paste  [_A_] Append  
                        [_M_] Move   [_W_] Swap
                        [_R_] Replace »                                 
                        [_F_] Fill »                       
  ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [_o_] Open   [_O_] Open+View   [_e_] Export   [_i_] Import   [_$_] Rename   [_._] Schema   [_?_] Help   [_q_] Quit
"
    ("q" nil :color blue)
    ;; Navigate
    ("n" next-line)
    ("p" previous-line)
    ("{" tabularium-view-first-row)
    ("}" tabularium-view-last-row)
    ("[" tabularium-view-beginning-of-line)
    ("]" tabularium-view-end-of-line)
    ("TAB" tabularium-view-forward-cell)
    ("<backtab>" tabularium-view-backward-cell)
    ("M-n" tabularium-view-cell-jump-down)
    ("M-p" tabularium-view-cell-jump-up)
    ("M-]" tabularium-view-cell-jump-forward)
    ("M-[" tabularium-view-cell-jump-backward)
    ("C-<down>" tabularium-view-cell-jump-down)
    ("C-<up>" tabularium-view-cell-jump-up)
    ("C-<right>" tabularium-view-cell-jump-forward)
    ("C-<left>" tabularium-view-cell-jump-backward)
    ("g" tabularium-view-refresh)
    ("=" tabularium-view-refresh)
    ("'" tabularium-view-goto-hydra/body :color blue)
    ("RET" tabularium-view-entry :color blue)
    ("/" tabularium-find :color blue)
    ;; Modify
    ("N" tabularium-new-entry :color blue)
    ("P" tabularium-prompt-entry :color blue)
    ("Q" tabularium-quick-entry :color blue)
    ("I" tabularium-view-insert :color blue)
    ("E" tabularium-view-edit :color blue)
    ("D" tabularium-view-delete :color blue)
    ("d" tabularium-view-duplicate :color blue)
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
    ("x" tabularium-view-execute :color blue)
    ("*" tabularium-view-mark-hydra/body :color blue)
    ;; View
    ("f" tabularium-view-filter-hydra/body :color blue)
    ("v" tabularium-view-views-hydra/body :color blue)
    ("|" tabularium-view-columns-hydra/body :color blue)
    ("^" tabularium-view-sort-reverse)
    ("s" tabularium-view-sort-hydra/body :color blue)
    ("z" tabularium-view-freeze)
    ("Z" tabularium-view-unfreeze-all)
    ("`" tabularium-reindex :color blue)
    ;; Calculate
    ("#" tabularium-view-calculate-hydra/body :color blue)
    ;; Schema submenu
    ("." tabularium-view-schema-hydra/body :color blue)
    ;; Undo/Redo
    ("C-/" tabularium-undo)
    ("C-_" tabularium-undo)
    ("C-?" tabularium-redo)
    ;; Bottom row
    ("o" tabularium-open :color blue)
    ("O" tabularium-open-and-view :color blue)
    ("e" tabularium-export :color blue)
    ("i" tabularium-import :color blue)
    ("$" tabularium-rename-database :color blue)
    ("?" tabularium-view-hydra/body))

  ;; Schema sub-hydra (view mode)
  (defhydra tabularium-view-schema-hydra (:color blue :hint nil)
    "
┌────────┐
│ Schema │  %s(tabularium--hydra-db-info)
└────────┘
  ───────────────────────────────────────────────────────────────────────────────
  [_._] Edit          [_s_] Show          [_r_] Reload        [_w_] Switch
  [_+_] Add field
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("." tabularium-schema-edit)
    ("s" tabularium-schema-show)
    ("r" tabularium-schema-reload)
    ("w" tabularium-schema-switch)
    ("+" tabularium-view-column-add)
    ("q" nil))

  ;; Replace sub-hydra (view mode)
  (defhydra tabularium-view-replace-hydra (:color blue :hint nil)
    "
┌─────────┐
│ Replace │  %s(tabularium--hydra-db-info)
└─────────┘
  All rows                  Visible only                Other
  ───────────────────────────────────────────────────────────────────────────────
  [_r_] Substring            [_R_] Substring             [_=_] Exact (all)
  [_q_] Query-Replace        [_Q_] Query-Replace         [_p_] Pattern (all)
  [_x_] Regexp               [_X_] Regexp                [_c_] Case toggle
  ───────────────────────────────────────────────────────────────────────────────
  [_z_] Quit
"
    ;; All rows
    ("r" tabularium-replace-substring)
    ("q" tabularium-query-replace)
    ("x" tabularium-replace-regexp)
    ("=" tabularium-replace-exact)
    ("p" tabularium-replace-pattern)
    ;; Visible only
    ("R" tabularium-visible-replace-substring)
    ("Q" tabularium-visible-query-replace)
    ("X" tabularium-visible-replace-regexp)
    ;; Other
    ("c" tabularium-toggle-case-sensitive)
    ("z" nil))

  ;; Mark sub-hydra
  (defhydra tabularium-view-mark-hydra (:color blue :hint nil)
    "
┌──────┐
│ Mark │  %s(tabularium--hydra-db-info)   Marked: %s(length tabularium--marked-entries)
└──────┘
  ───────────────────────────────────────────────────────────────────────────────
  [_*_] Substring       [_=_] Exact           [_p_] Pattern         [_x_] Regexp
  [_#_] Count marked
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("*" tabularium-view-mark-matching)
    ("=" tabularium-view-mark-exact)
    ("p" tabularium-view-mark-pattern)
    ("x" tabularium-view-mark-regexp)
    ("#" tabularium-view-count-marked)
    ("q" nil))

  ;; Filter sub-hydra
  (defhydra tabularium-view-filter-hydra (:color blue :hint nil)
    "
┌────────┐
│ Filter │  %s(tabularium--hydra-db-info)   %s(tabularium--hydra-filter-info)
└────────┘
  ───────────────────────────────────────────────────────────────────────────────
  [_f_] Substring          [_=_] Exact match     [_#_] Numeric (> >= < <=)
  [_@_] Across columns     [_d_] Delete layer    [_s_] Toggle join
  [_x_] Clear all
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("f" tabularium-view-filter)
    ("=" tabularium-view-filter-exact)
    ("#" tabularium-view-filter-numeric)
    ("@" tabularium-view-filter-across)
    ("d" tabularium-view-filter-delete)
    ("s" tabularium-view-filter-toggle)
    ("x" tabularium-view-clear-filter)
    ("q" nil))

  ;; Sort sub-hydra
  (defhydra tabularium-view-sort-hydra (:color blue :hint nil)
    "
┌──────┐
│ Sort │  %s(tabularium--hydra-db-info)
└──────┘
  %s(tabularium--hydra-sort-info)
  ───────────────────────────────────────────────────────────────────────────────
  [_s_] Add layer       [_d_] Delete layer    [_x_] Clear sort      [_^_] Reverse
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("s" tabularium-view-sort-add)
    ("d" tabularium-view-sort-delete)
    ("x" tabularium-view-sort-clear)
    ("^" tabularium-view-sort-reverse)
    ("q" nil))

  ;; Fill sub-hydra
  (defhydra tabularium-view-fill-hydra (:color blue :hint nil)
    "
┌──────┐
│ Fill │  %s(tabularium--hydra-db-info)
└──────┘
  ───────────────────────────────────────────────────────────────────────────────
  [_F_] Fill gap ↑       [_f_] Fill forward ↓  [_s_] Fill series
  [_n_] Fill next ↓      [_p_] Fill prev ↑     [_z_] Freeze marked
  [_,_] To point ↑       [_._] To point ↓
  [_d_] Delete run       [_x_] Clear to row
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("F" tabularium-view-fill)
    ("f" tabularium-view-fill-forward)
    ("n" tabularium-view-fill-down)
    ("p" tabularium-view-fill-up)
    ("," tabularium-view-fill-up-to-point)
    ("." tabularium-view-fill-down-to-point)
    ("s" tabularium-view-fill-series)
    ("d" tabularium-view-fill-delete)
    ("x" tabularium-view-fill-clear)
    ("z" tabularium-view-freeze-marked)
    ("q" nil))

  ;; Columns sub-hydra
  (defhydra tabularium-view-columns-hydra (:color blue :hint nil)
    "
┌─────────┐
│ Columns │  %s(tabularium--hydra-db-info)
└─────────┘
  Visibility            Ordering              Schema
  ───────────────────────────────────────────────────────────────────────────────
  [_t_] Toggle            [_r_] Reorder           [_N_] New           [_d_] Duplicate
  [_h_] Hide              [_<_] Move left          [_I_] Insert        [_C_] Copy
  [_o_] Show only         [_>_] Move right         [_D_] Delete        [_X_] Cut
  [_a_] Show all          [_=_] Reset order       [_E_] Edit          [_V_] Paste
                        [_M_] Move              [_W_] Swap
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ;; Visibility
    ("t" tabularium-view-toggle-column)
    ("h" tabularium-view-hide-columns)
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
    ("d" tabularium-view-column-duplicate)
    ("C" tabularium-view-column-copy)
    ("X" tabularium-view-column-cut)
    ("V" tabularium-view-column-paste)
    ("q" nil))

  ;; Goto sub-hydra
  (defhydra tabularium-view-goto-hydra (:color blue :hint nil)
    "
┌──────┐
│ Goto │  %s(tabularium--hydra-db-info)
└──────┘
  ───────────────────────────────────────────────────────────────────────────────
  [_'_] Entry          [_r_] Row             [_c_] Column
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ("'" tabularium-view-goto-entry)
    ("r" tabularium-view-goto-row)
    ("c" tabularium-view-goto-column)
    ("q" nil))

  ;; Calculate sub-hydra (view mode)
  ;; Reserved keys for future functions:
  ;; C=count-if A=sum-if .=avg-if X=cross-tab H=histogram
  ;; L=lookup D=date-diff r=running-total R=rank P=percentile ~=correlate
  (defhydra tabularium-view-calculate-hydra (:color blue :hint nil)
    "
┌───────────┐
│ Calculate │  %s(tabularium--hydra-db-info)
└───────────┘
  Count                     All rows                    Visible only
  ───────────────────────────────────────────────────────────────────────────────
  [_c_] Count query          [_s_] Sum                    [_S_] Sum
  [_V_] Count visible        [_m_] Min / Max              [_M_] Min / Max
  [_*_] Count marked         [_d_] Mean ± SD              [_D_] Mean ± SD
  [_@_] Count across         [_q_] Median [IQR]           [_Q_] Median [IQR]

  [_#_] Column summary
  ───────────────────────────────────────────────────────────────────────────────
  [_x_] Quit
"
    ;; Count
    ("c" tabularium-count)
    ("V" tabularium-visible-count)
    ("*" tabularium-view-count-marked)
    ("@" tabularium-view-count-across)
    ;; Aggregate (all)
    ("s" tabularium-sum)
    ("m" tabularium-min-max)
    ("d" tabularium-mean-sd)
    ("q" tabularium-median-iqr)
    ;; Aggregate (visible)
    ("S" tabularium-visible-sum)
    ("M" tabularium-visible-min-max)
    ("D" tabularium-visible-mean-sd)
    ("Q" tabularium-visible-median-iqr)
    ;; Summary
    ("#" tabularium-column-summary)
    ("x" nil))

  ;; Views sub-hydra (presets + expansion)
  (defhydra tabularium-view-views-hydra (:color blue :hint nil)
    "
┌───────┐
│ Views │  %s(tabularium--hydra-db-info)   View: %s(or tabularium--current-view \"<none>\")
└───────┘
  Presets                                   Expand
  ───────────────────────────────────────────────────────────────────────────────
  [_v_] Select view       [_1_]..[_9_] Preset    [_>_] Show more       [_a_] Show all
  [_0_] Reset views       [_x_] Clear all         [_r_] Show range       [_=_] Reset limit
  ───────────────────────────────────────────────────────────────────────────────
  [_q_] Quit
"
    ;; Presets
    ("v" tabularium-select-view)
    ("0" tabularium-view-0)
    ("x" tabularium-clear-view)
    ("1" tabularium-view-1)
    ("2" tabularium-view-2)
    ("3" tabularium-view-3)
    ("4" tabularium-view-4)
    ("5" tabularium-view-5)
    ("6" tabularium-view-6)
    ("7" tabularium-view-7)
    ("8" tabularium-view-8)
    ("9" tabularium-view-9)
    ;; Expand
    (">" tabularium-view-show-more)
    ("a" tabularium-view-show-all)
    ("r" tabularium-view-show-range)
    ("=" tabularium-view-reset-limit)
    ("q" nil)))

;;; * 3 Transient

;;; ** 3.1. Main Menu

(when (require 'transient nil t)
  (transient-define-prefix tabularium-transient ()
                           "Tabularium commands."
                           [:description
                            (lambda () (format "Tabularium: %s" (or tabularium--current-schema-name "<none>")))
                            ["Database"
                             ("o" "Open" tabularium-open)
                             ("O" "Open+View" tabularium-open-and-view)
                             ("x" "Close" tabularium-close)
                             ("C" "Create new" tabularium-create-database)
                             ("r" "List databases" tabularium-registry)
                             ("$" "Rename" tabularium-rename-database)]
                            ["Schema"
                             ("." "Edit" tabularium-schema-edit)
                             ("?" "Show" tabularium-schema-show)
                             ("~" "Reload" tabularium-schema-reload)
                             ("w" "Switch" tabularium-schema-switch)
                             ("+" "Add field" tabularium-view-column-add)]
                            ["Entry"
                             ("N" "New (form)" tabularium-new-entry)
                             ("P" "Prompt entry" tabularium-prompt-entry)
                             ("Q" "Quick entry" tabularium-quick-entry)]
                            ["Browse/Query"
                             ("v" "View all" tabularium-view)
                             ("/" "Fuzzy find" tabularium-find)
                             ("t" "Last match" tabularium-last)
                             ("#" "Calculate »" tabularium-calculate-transient)]
                            ["External"
                             ("e" "Export" tabularium-export)
                             ("i" "Import" tabularium-import)
                             ("s" "Sync prep" tabularium-prepare-for-sync)]])

  ;; Calculate transient submenu
  (transient-define-prefix tabularium-calculate-transient ()
                           "Calculate operations."
                           [:description
                            (lambda () (format "Calculate: %s" (or tabularium--current-schema-name "<none>")))
                            ["Count"
                             ("c" "Count query" tabularium-count)]
                            ["Aggregate"
                             ("s" "Sum" tabularium-sum)
                             ("m" "Min/Max" tabularium-min-max)]
                            ["Advanced"
                             ("d" "Mean±SD" tabularium-mean-sd)
                             ("M" "Median[IQR]" tabularium-median-iqr)]
                            ["Summary"
                             ("#" "Column summary" tabularium-column-summary)]]))

;;; ** 3.2. View Mode

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
                             ("'" "Goto »" tabularium-view-goto-transient)]
                            ["Modify"
                             ("N" "New entry" tabularium-new-entry)
                             ("E" "Edit" tabularium-view-edit)
                             ("d" "Duplicate" tabularium-view-duplicate)
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
                             ("x" "Execute" tabularium-view-execute)
                             ("* *" "Mark substring" tabularium-view-mark-matching)
                             ("* =" "Mark exact" tabularium-view-mark-exact)
                             ("* p" "Mark pattern" tabularium-view-mark-pattern)
                             ("* x" "Mark regexp" tabularium-view-mark-regexp)
                             ("* #" "Count marked" tabularium-view-count-marked)]
                            ["View" :pad-keys t
                             ("f f" "Substring" tabularium-view-filter)
                             ("f =" "Exact match" tabularium-view-filter-exact)
                             ("f #" "Numeric" tabularium-view-filter-numeric)
                             ("f @" "Add across" tabularium-view-filter-across)
                             ("f d" "Delete filter" tabularium-view-filter-delete)
                             ("f s" "Toggle join" tabularium-view-filter-toggle)
                             ("f c" "Clear filter" tabularium-view-clear-filter)
                             ("v v" "Select view" tabularium-select-view)
                             ("v 0" "Reset views" tabularium-view-0)
                             ("v x" "Clear all" tabularium-clear-view)
                             ("v >" "Show more" tabularium-view-show-more)
                             ("v a" "Show all" tabularium-view-show-all)
                             ("v r" "Show range" tabularium-view-show-range)
                             ("v =" "Reset limit" tabularium-view-reset-limit)
                             ("^" "Reverse sort" tabularium-view-sort-reverse)
                             ("s s" "Add sort" tabularium-view-sort-add)
                             ("s d" "Delete sort" tabularium-view-sort-delete)
                             ("s x" "Clear sort" tabularium-view-sort-clear)
                             ("z" "Freeze" tabularium-view-freeze)
                             ("Z" "Unfreeze all" tabularium-view-unfreeze-all)
                             ("`" "Reindex" tabularium-reindex)]
                            ["Modify »" :pad-keys t
                             ("R r" "Replace substr" tabularium-replace-substring)
                             ("R R" "Visible: substr" tabularium-visible-replace-substring)
                             ("R =" "Replace exact" tabularium-replace-exact)
                             ("R p" "Replace pattern" tabularium-replace-pattern)
                             ("R x" "Replace regexp" tabularium-replace-regexp)
                             ("R X" "Visible: regexp" tabularium-visible-replace-regexp)
                             ("R q" "Query-replace" tabularium-query-replace)
                             ("R Q" "Visible: query" tabularium-visible-query-replace)
                             ("R c" "Case toggle" tabularium-toggle-case-sensitive)
                             ("F F" "Fill gap ↑" tabularium-view-fill)
                             ("F f" "Fill forward ↓" tabularium-view-fill-forward)
                             ("F n" "Fill next ↓" tabularium-view-fill-down)
                             ("F p" "Fill prev ↑" tabularium-view-fill-up)
                             ("F ," "To point ↑" tabularium-view-fill-up-to-point)
                             ("F ." "To point ↓" tabularium-view-fill-down-to-point)
                             ("F s" "Fill series" tabularium-view-fill-series)
                             ("F d" "Delete run" tabularium-view-fill-delete)
                             ("F x" "Clear to row" tabularium-view-fill-clear)
                             ("F z" "Freeze marked" tabularium-view-freeze-marked)]
                            ["Calculate (# prefix)"
                             ("# c" "Count query" tabularium-count)
                             ("# V" "Count visible" tabularium-visible-count)
                             ("# *" "Count marked" tabularium-view-count-marked)
                             ("# @" "Count across" tabularium-view-count-across)
                             ("# s" "Sum" tabularium-sum)
                             ("# S" "Visible: Sum" tabularium-visible-sum)
                             ("# m" "Min/Max" tabularium-min-max)
                             ("# M" "Visible: Min/Max" tabularium-visible-min-max)
                             ("# d" "Mean±SD" tabularium-mean-sd)
                             ("# D" "Visible: Mean±SD" tabularium-visible-mean-sd)
                             ("# q" "Median[IQR]" tabularium-median-iqr)
                             ("# Q" "Visible: Med[IQR]" tabularium-visible-median-iqr)
                             ("# #" "Column summary" tabularium-column-summary)]
                            ["Columns (| prefix)" :pad-keys t
                             ("| t" "Toggle" tabularium-view-toggle-column)
                             ("| h" "Hide" tabularium-view-hide-columns)
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
                             ("| d" "Duplicate col" tabularium-view-column-duplicate)
                             ("| M" "Move cols" tabularium-view-column-move)
                             ("| W" "Swap cols" tabularium-view-column-swap)
                             ("| C" "Copy cols" tabularium-view-column-copy)
                             ("| X" "Cut cols" tabularium-view-column-cut)
                             ("| V" "Paste cols" tabularium-view-column-paste)]
                            ["Database"
                             ("o" "Open" tabularium-open)
                             ("O" "Open+View" tabularium-open-and-view)
                             ("e" "Export" tabularium-export)
                             ("i" "Import" tabularium-import)
                             ("$" "Rename DB" tabularium-rename-database)]
                            ["Schema"
                             (". ." "Edit" tabularium-schema-edit)
                             (". s" "Show" tabularium-schema-show)
                             (". r" "Reload" tabularium-schema-reload)
                             (". w" "Switch" tabularium-schema-switch)
                             (". +" "Add field" tabularium-view-column-add)]])

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
