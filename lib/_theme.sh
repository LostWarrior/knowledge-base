#!/usr/bin/env bash
# lib/_theme.sh - Shared output helpers for consistent CLI appearance
# Source this file from other lib scripts: source "${KB_ROOT}/lib/_theme.sh"

# --- Color detection ---
_c_reset=""
_c_bold=""
_c_dim=""
_c_red=""
_c_green=""
_c_yellow=""
_c_cyan=""

if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    _c_reset=$'\033[0m'
    _c_bold=$'\033[1m'
    _c_dim=$'\033[2m'
    _c_red=$'\033[1;31m'
    _c_green=$'\033[1;32m'
    _c_yellow=$'\033[1;33m'
    _c_cyan=$'\033[1;36m'
fi

# --- Symbol helpers ---
# >>  action/progress
_info()    { printf '%s>>%s  %s\n' "$_c_cyan" "$_c_reset" "$1"; }
# ok  success
_ok()      { printf '%sok%s  %s\n' "$_c_green" "$_c_reset" "$1"; }
# ++  created/added
_created() { printf '%s++%s  %s\n' "$_c_green" "$_c_reset" "$1"; }
# ->  moved/mapped
_moved()   { printf '%s->%s  %s\n' "$_c_cyan" "$_c_reset" "$1"; }
# --  skipped
_skip()    { printf '%s--%s  %s\n' "$_c_yellow" "$_c_reset" "$1"; }
# !!  warning
_warn()    { printf '%s!!%s  %s\n' "$_c_yellow" "$_c_reset" "$1"; }
# **  error
_err()     { printf '%s**%s  %s\n' "$_c_red" "$_c_reset" "$1" >&2; }
# == section header ==
_header()  { printf '\n%s== %s %s\n' "$_c_bold" "$1" "$_c_reset"; }
# dim metadata line (indented)
_detail()  { printf '   %s%s%s\n' "$_c_dim" "$1" "$_c_reset"; }
