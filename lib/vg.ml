(*
 * Copyright (C) 2009-2015 Citrix Systems Inc.
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
open Sexplib.Std
open Absty
open Redo
open Logging
open Result

module Status = struct
  type t =
    | Read
    | Write
    | Resizeable
    | Clustered
  with sexp

  let to_string = function
    | Resizeable -> "RESIZEABLE"
    | Write -> "WRITE"
    | Read -> "READ"
    | Clustered -> "CLUSTERED"

  let of_string = function
    | "RESIZEABLE" -> return Resizeable
    | "WRITE" -> return Write
    | "READ" -> return Read
    | "CLUSTERED" -> return Clustered
    | x -> fail (Printf.sprintf "Bad VG status string: %s" x)
end

type t = {
  name : string;
  id : Uuid.t;
  seqno : int;
  status : Status.t list;
  extent_size : int64;
  max_lv : int;
  max_pv : int;
  pvs : Pv.t list; (* Device to pv map *)
  lvs : Lv.t list;
  free_space : Pv.Allocator.t;
  (* XXX: hook in the redo log *)
  ops : Redo.Op.t list;
} with sexp
  
let marshal vg b =
  let b = ref b in
  let bprintf fmt = Printf.kprintf (fun s ->
    let len = String.length s in
    Cstruct.blit_from_string s 0 !b 0 len;
    b := Cstruct.shift !b len
  ) fmt in
  bprintf "%s {\nid = \"%s\"\nseqno = %d\n" vg.name (Uuid.to_string vg.id) vg.seqno;
  bprintf "status = [%s]\nextent_size = %Ld\nmax_lv = %d\nmax_pv = %d\n\n"
    (String.concat ", " (List.map (o quote Status.to_string) vg.status))
    vg.extent_size vg.max_lv vg.max_pv;
  bprintf "physical_volumes {\n";
  b := List.fold_left (fun b pv -> Pv.marshal pv b) !b vg.pvs;
  bprintf "}\n\n";

  bprintf "logical_volumes {\n";
  b := List.fold_left (fun b lv -> Lv.marshal lv b) !b vg.lvs;
  bprintf "}\n}\n";

  bprintf "# Generated by MLVM version 0.1: \n\n";
  bprintf "contents = \"Text Format Volume Group\"\n";
  bprintf "version = 1\n\n";
  bprintf "description = \"\"\n\n";
  bprintf "creation_host = \"%s\"\n" "<need uname!>";
  bprintf "creation_time = %Ld\n\n" (Int64.of_float (Unix.time ()));
  !b
    
(*************************************************************)
(* METADATA CHANGING OPERATIONS                              *)
(*************************************************************)

let do_op vg op : (t, string) Result.result =
  let open Redo.Op in
  let rec createsegs acc ss s_start_extent = match ss with
  | a::ss ->
    let start_extent = Pv.Allocator.get_start a in
    let extent_count = Pv.Allocator.get_size a in
    let name = Pv.Allocator.get_name a in
    let cls = Lv.Segment.Linear { Lv.Linear.name; start_extent; } in
    createsegs ({ Lv.Segment.start_extent; cls; extent_count } :: acc) ss  (Int64.add start_extent extent_count)
  | [] -> List.rev acc in	
  let change_lv lv_name fn =
    let lv,others = List.partition (fun lv -> lv.Lv.name=lv_name) vg.lvs in
    match lv with
    | [lv] -> fn lv others
    | _ -> fail (Printf.sprintf "VG: unknown LV %s" lv_name) in
  let vg = {vg with ops=op::vg.ops} in
  match op with
  | LvCreate (name,l) ->
    let new_free_space = Pv.Allocator.sub vg.free_space l.lvc_segments in
    let segments = Lv.Segment.sort (createsegs [] l.lvc_segments 0L) in
    let lv = Lv.({ name; id = l.lvc_id; tags = []; status = [Status.Read; Status.Visible]; segments }) in
    return {vg with lvs = lv::vg.lvs; free_space = new_free_space}
  | LvExpand (name,l) ->
    change_lv name (fun lv others ->
      let old_size = Lv.size_in_extents lv in
      let free_space = Pv.Allocator.sub vg.free_space l.lvex_segments in
      let segments = createsegs [] l.lvex_segments old_size in
      let segments = Lv.Segment.sort (segments @ lv.Lv.segments) in
      let lv = {lv with Lv.segments} in
      return {vg with lvs = lv::others; free_space=free_space} )
  | LvReduce (name,l) ->
    change_lv name (fun lv others ->
      let allocation = Lv.to_allocation lv in
      Lv.reduce_size_to lv l.lvrd_new_extent_count >>= fun lv ->
      let new_allocation = Lv.to_allocation lv in
      let free_space = Pv.Allocator.sub (Pv.Allocator.merge vg.free_space allocation) new_allocation in
      return {vg with lvs = lv::others; free_space})
  | LvRemove name ->
    change_lv name (fun lv others ->
      let allocation = Lv.to_allocation lv in
      return {vg with lvs = others; free_space = Pv.Allocator.merge vg.free_space allocation })
  | LvRename (name,l) ->
    change_lv name (fun lv others ->
      return {vg with lvs = {lv with Lv.name=l.lvmv_new_name}::others })
  | LvAddTag (name, tag) ->
    change_lv name (fun lv others ->
      let tags = lv.Lv.tags in
      let lv' = {lv with Lv.tags = if List.mem tag tags then tags else tag::tags} in
      return {vg with lvs = lv'::others})
  | LvRemoveTag (name, tag) ->
    change_lv name (fun lv others ->
      let tags = lv.Lv.tags in
      let lv' = {lv with Lv.tags = List.filter (fun t -> t <> tag) tags} in
      return {vg with lvs = lv'::others})

(* Convert from bytes to extents, rounding up *)
let bytes_to_extents bytes vg =
  let extents_in_sectors = vg.extent_size in
  let open Int64 in
  let extents_in_bytes = mul extents_in_sectors 512L in
  div (add bytes (sub extents_in_bytes 1L)) extents_in_bytes

let create vg name size = 
  if List.exists (fun lv -> lv.Lv.name = name) vg.lvs
  then `Error "Duplicate name detected"
  else match Pv.Allocator.find vg.free_space (bytes_to_extents size vg) with
  | `Ok lvc_segments ->
    let lvc_id = Uuid.create () in
    do_op vg Redo.Op.(LvCreate (name,{lvc_id; lvc_segments}))
  | `Error free ->
    `Error (Printf.sprintf "insufficient free space: requested %Ld, free %Ld" size free)

let rename vg old_name new_name =
  do_op vg Redo.Op.(LvRename (old_name,{lvmv_new_name=new_name}))

let resize vg name new_size =
  let new_size = bytes_to_extents new_size vg in
  let lv,others = List.partition (fun lv -> lv.Lv.name=name) vg.lvs in
  ( match lv with 
    | [lv] ->
	let current_size = Lv.size_in_extents lv in
        let to_allocate = Int64.sub new_size current_size in
	if to_allocate > 0L then match Pv.Allocator.find vg.free_space to_allocate with
        | `Ok lvex_segments ->
	  return Redo.Op.(LvExpand (name,{lvex_segments}))
        | `Error free ->
          `Error (Printf.sprintf "insufficient free space: requested %Ld, free %Ld" to_allocate free)
	else
	  return Redo.Op.(LvReduce (name,{lvrd_new_extent_count=new_size}))
    | _ -> fail (Printf.sprintf "Can't find LV %s" name) ) >>= fun op ->
  do_op vg op

let remove vg name =
  do_op vg Redo.Op.(LvRemove name)

let add_tag vg name tag =
  do_op vg Redo.Op.(LvAddTag (name, tag))

let remove_tag vg name tag =
  do_op vg Redo.Op.(LvRemoveTag (name, tag))

module Make(DISK: S.DISK) = struct

module Pv_IO = Pv.Make(DISK)
module Label_IO = Label.Make(DISK)
module Metadata_IO = Metadata.Make(DISK)

let write vg =
  let buf = Cstruct.create (Int64.to_int Constants.max_metadata_size) in
  let buf' = marshal vg buf in
  let md = Cstruct.sub buf 0 buf'.Cstruct.off in
  let open IO in
  let rec write_pv pv acc = function
    | [] -> return (List.rev acc)
    | m :: ms ->
      Metadata_IO.write pv.Pv.real_device m md >>= fun h ->
      write_pv pv (h :: acc) ms in
  let rec write_vg acc = function
    | [] -> return (List.rev acc)
    | pv :: pvs ->
      Label_IO.write pv.Pv.label >>= fun () ->
      write_pv pv [] pv.Pv.headers >>= fun headers ->
      write_vg ({ pv with Pv.headers = headers } :: acc) pvs in
  write_vg [] vg.pvs >>= fun pvs ->
  let vg = { vg with pvs } in
  return vg

let of_metadata config =
  let open IO.FromResult in
  ( match config with
    | AStruct c -> `Ok c
    | _ -> `Error "VG metadata doesn't begin with a structure element" ) >>= fun config ->
  let vg = filter_structs config in
  ( match vg with
    | [ name, _ ] -> `Ok name
    | [] -> `Error "VG metadata contains no defined volume groups"
    | _ -> `Error "VG metadata contains multiple volume groups" ) >>= fun name ->
  expect_mapped_struct name vg >>= fun alist ->
  expect_mapped_string "id" alist >>= fun id ->
  Uuid.of_string id >>= fun id ->
  expect_mapped_int "seqno" alist >>= fun seqno ->
  let seqno = Int64.to_int seqno in
  map_expected_mapped_array "status" 
    (fun a -> let open Result in expect_string "status" a >>= fun x ->
              Status.of_string x) alist >>= fun status ->
  expect_mapped_int "extent_size" alist >>= fun extent_size ->
  expect_mapped_int "max_lv" alist >>= fun max_lv ->
  let max_lv = Int64.to_int max_lv in
  expect_mapped_int "max_pv" alist >>= fun max_pv ->
  let max_pv = Int64.to_int max_pv in
  expect_mapped_struct "physical_volumes" alist >>= fun pvs ->
  ( match expect_mapped_struct "logical_volumes" alist with
    | `Ok lvs -> `Ok lvs
    | `Error _ -> `Ok [] ) >>= fun lvs ->
  let open IO in
  all (Lwt_list.map_s (fun (a,_) ->
    let open IO.FromResult in
    expect_mapped_struct a pvs >>= fun x ->
    let open IO in
    Pv_IO.read a x
  ) pvs) >>= fun pvs ->
  all (Lwt_list.map_s (fun (a,_) ->
    let open IO.FromResult in
    expect_mapped_struct a lvs >>= fun x ->
    Lwt.return (Lv.of_metadata a x)
  ) lvs) >>= fun lvs ->

  (* Now we need to set up the free space structure in the PVs *)
  let free_space = List.flatten (List.map (fun pv -> Pv.Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in

  let free_space = List.fold_left (fun free_space lv -> 
    let lv_allocations = Lv.to_allocation lv in
    debug "Allocations for lv %s: %s" lv.Lv.name (Pv.Allocator.to_string lv_allocations);
    Pv.Allocator.sub free_space lv_allocations) free_space lvs in
  let ops = [] in
  let vg = { name; id; seqno; status; extent_size; max_lv; max_pv; pvs; lvs;  free_space; ops } in
  return vg

let parse buf =
  let text = Cstruct.to_string buf in
  let lexbuf = Lexing.from_string text in
  of_metadata (Lvmconfigparser.start Lvmconfiglex.lvmtok lexbuf)

let format name devices_and_names =
  let open IO in
  let rec write_pv acc = function
    | [] -> return (List.rev acc)
    | (dev, name) :: pvs ->
      Pv_IO.format dev name >>= fun pv ->
      write_pv (pv :: acc) pvs in
  write_pv [] devices_and_names >>= fun pvs ->
  debug "PVs created";
  let free_space = List.flatten (List.map (fun pv -> Pv.Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in
  let vg = { name; id=Uuid.create (); seqno=1; status=[Status.Read; Status.Write];
    extent_size=Constants.extent_size_in_sectors; max_lv=0; max_pv=0; pvs;
    lvs=[]; free_space; ops=[]; } in
  write vg >>= fun _ ->
  debug "VG created";
  return ()

open IO
let read = function
| [] -> Lwt.return (`Error "Vg.load needs at least one device")
| devices ->
  debug "Vg.load";
  IO.FromResult.all (Lwt_list.map_s Pv_IO.read_metadata devices) >>= fun md ->
  parse (List.hd md)
end
(*
let set_dummy_mode base_dir mapper_name full_provision =
  Constants.dummy_mode := true;
  Constants.dummy_base := base_dir;
  Constants.mapper_name := mapper_name;
  Constants.full_provision := full_provision
*)
