(*
 * Copyright (C) 2015 Citrix Systems Inc.
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
open Lvm

val dm_name_of: Vg.t -> Lv.t -> string
(** [dm_name_of vg lv] returns the conventional name used for a device mapper
    device corresponding to [lv]. Device mapper devices are arbitrary but this
    is the naming convention that LVM uses. *)
