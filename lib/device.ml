(*
 * Copyright (C) 2009-2013 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)


(** Physical Volume module *)

open Absty
open Logging
open Lvmmarshal

let dummy_fname dev ty =
  let fname = Printf.sprintf "%s/%s/%s" (!Constants.dummy_base) dev ty in
  let basedir = Filename.dirname fname in
  Unixext.mkdir_rec basedir 0o755;
  fname

