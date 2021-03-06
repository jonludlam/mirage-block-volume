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

open Kaputt.Abbreviations
open Lvm.Allocator

let id a = a
let ($) f a = f a
let comp f g x = f (g x)
let (++) f g x = comp f g x
let on op f x y = op (f x) (f y)
let flip f a b = f b a
let const a b = a

let (=>>) a b = (not a) || b

module Opt = struct
let is_boxed = function
        | Some _ -> true
        | None -> false
let map f = function
        | Some x -> Some(f x)
        | None -> None
let default d = function
        | Some x -> x
        | None -> d
end

let rec tails = function
        | [] -> [[]]
        | (_::xs) as l -> l :: tails xs
let cons a b = a :: b
let take n list =
        let rec helper i acc list =
        if i <= 0 || list = []
        then acc
        else helper (i-1)  (List.hd list :: acc) (List.tl list)
        in List.rev $ helper n [] list

let make_area pv_name start size = (pv_name, (start,size))
let make_area_by_end name start endAr = make_area name start (Int64.sub endAr start)
let unpack_area (pv_name, (start,size)) = (pv_name, (start,size))
let to_string1 (p,(s,l)) = Printf.sprintf "(%s: [%Ld,%Ld])" p s l
(* Is a contained in a2? *)
let contained : area -> area -> bool =
  fun a a2 ->
    let (name, (start, size)) = unpack_area a in
    let (name2, (start2, size2)) = unpack_area a2 in
    name=name2 && start >= start2 && Int64.add start size <= Int64.add start2 size2

(* ToDo: Generate some test-data to test those propositions hold: *)

(* let bind f p ga = Gen.map2 ((++) f) p +++ Gen.zip2 *)

let pv_name_gen = (Gen.string (Gen.make_int 0 32) (Gen.alphanum))
let pv_pos_size = Gen.zip2 (Gen.make_int64 0L 121212131L) (Gen.make_int64 0L 121212131L)

let gen_area = (Gen.map3 make_area to_string1 (pv_name_gen, (Gen.make_int64 0L 121212131L), (Gen.make_int64 0L 121212131L)))
(* let gen_area pv_name = (Gen.map3 make_area to_string1 (pv_name, (Gen.make_int64 0L 121212131L), (Gen.make_int64 0L 121212131L))) *)
(* let gen_3area pv_name = *)
(*     let ga = gen_area pv_name *)
(*     in Gen.zip3 ga ga ga *)


(* Does manual lifting.  ToDo: Find a way to make it look less ugly. *)

let gen_3area = 
    let f (name, (p1, p2, p3)) =
	let m = Gen.apply2 (make_area name)
	in (m p1, m p2, m p3)
    and p = Kaputt.Utils.make_string_of_tuple3 to_string1 to_string1 to_string1
    in Gen.map1 f p (Gen.zip2 pv_name_gen (Gen.zip3 pv_pos_size pv_pos_size pv_pos_size))

let prop_contained_reflexive a = contained a a
let test_contained_is_reflexive =
  Test.make_random_test
    ~title:"contained is reflexive"
    gen_area
    id
    [Spec.always ==> prop_contained_reflexive]

let test_contained_is_transitive =
  Test.make_random_test
    ~title:"contained is transitive"
    gen_3area
    id
    [(fun (a,b,c) -> contained a b && contained b c) ==> (fun (a,b,c) -> contained a c)]
    
let prop_same_pv a b = (=>>) (contained a b) (get_name a == get_name b);;

(* allocate some random stuff.  make sure at all times, that (union
   alloced free) = all, and (intersection alloced free) = empty and
   that normalize does not change anything material. *)

let test_make_area =
    let name, start, size = "pv_123", Random.int64 (Int64.of_int 1024), Random.int64 (Int64.of_int 2025) in
    let area = make_area name start size in
    let test0 = ((name, (start, size)) = unpack_area area) in
    let test1 = (get_end area = Int64.add start size) in
    let test2 = (area = make_area_by_end name start (Int64.add start size)) in
    test0 && test1 && test2

let sum64 l = List.fold_left Int64.add Int64.zero l
let foldM op l acc =
    let op_ item = function
	| (Some acc) -> op item acc
	| None -> None
    in List.fold_right op_ l acc

let safe_alloc free demand = match find free demand with
| `Ok x -> Some (x, sub free x)
| `Error _ -> None

let test_alloc_everything =
    Test.make_random_test
      ~title:"alloc allocs all free space and nothing more.  On a single pv for a start."
      (Gen.zip2
	 (Gen.make_int64 (-10L) 10L)
	 (Gen.list (Gen.make_int 0 1000)
	    (Gen.make_int64 0L 1000L)))
      (fun (a, l) ->
	 let free_list = create "pv0" (max 0L $ Int64.add a (sum64 l))
	 in foldM ($) (List.map (fun demand free -> Opt.map snd $ safe_alloc free demand) l) (Some free_list))
      [Spec.always => fun ((a,l), res) -> (((max 0L $ Int64.add a (sum64 l)) < (sum64 l)) = (res = None))]

let size_create_destroy : int64 -> (int64 * int64 * int64) Gen.t = fun max_size -> 
  Gen.zip3 (Gen.make_int64 0L max_size) Gen.int64 Gen.int64

(* needlessly quadratic.  make it linear as the need arises. *)
let cumSum64 l = List.map sum64 ++ tails ++ List.rev $ l
let maximum1 = function
| x::xs -> List.fold_left max x xs
| [] -> assert false

let simulate_space : (int64 * int64 * int64) list -> int64 = fun l -> 
  let op (size, d1, d2) = [(min d1 d2,size); (max d1 d2,(Int64.sub 0L size))]
  in maximum1 ++ cons 0L ++
       cumSum64 ++ List.map snd ++
       List.sort (on compare fst) ++ List.flatten ++ List.map op $ l

type date = int64
type size = int64
type index = int64
type op = Alloc of (date * size * index) | DeAlloc of (date * index)
let get_date = function | Alloc (date, _, _) | DeAlloc (date, _) -> date

let add_index : 'a list -> (int64 * 'a) list = List.rev ++ fst ++ List.fold_left (fun (l, i) x -> ((i,x)::l, Int64.add i 1L)) ([],0L)

let toOps : (int64 * int64 * int64) list -> op list = 
    let toOp1 (index, (size, d1, d2)) = [Alloc (min d1 d2, size, index); DeAlloc (max d1 d2, index)]
    in List.sort (on compare get_date) ++ List.flatten ++ List.map toOp1 ++ add_index

module IndexMap = Map.Make (Int64)
	 
let simulate_full : op list -> t -> (t * (area list) IndexMap.t) option = fun ops free_list ->
  let op (fl, alloced) = function
      | Alloc (_, size, index) ->
	  (match (try safe_alloc fl size with x -> (print_endline "safe_alloc:";
						    print_endline ++ to_string ++ List.sort (on compare (snd ++ snd ++ unpack_area))$ fl;
						    print_endline ++ Int64.to_string $ size;
						    print_endline "";
						    raise x))
	   with | None -> None
                | Some (segs, fl_) -> 
		    Some (fl_, IndexMap.add index segs alloced))
      | DeAlloc (_, index) ->
	  Some (merge (IndexMap.find index alloced) fl, IndexMap.remove index alloced)
	      
  in List.fold_left (Opt.default (const None) ++ Opt.map op) (Some (free_list, IndexMap.empty)) $ ops

let show_op = function
    | Alloc x -> "Alloc " ^ Kaputt.Utils.make_string_of_tuple3 Int64.to_string Int64.to_string Int64.to_string x
    | DeAlloc x -> "DeAlloc " ^ Kaputt.Utils.make_string_of_tuple2 Int64.to_string Int64.to_string x

let test_alloc_works =
    let pv_size = 1000L in
    Test.make_random_test
      ~title:"alloc works when there's enough free space."
      (Gen.list (Gen.make_int 0 300) (size_create_destroy 1000L))
      (Opt.is_boxed ++ flip simulate_full (create "pv_name0" pv_size) ++ toOps)
      [(fun pOps -> ((simulate_space $ pOps) <= pv_size)) ==> id;]

let test_alloc_fails =
    let pv_size = 1000L in
    Test.make_random_test
      ~title:"and alloc doesn't work when there's not enough free space."
      (Gen.list (Gen.make_int 0 300) (size_create_destroy 1000L))
      (Opt.is_boxed ++ flip simulate_full (create "pv_name0" pv_size) ++ toOps)
      [(fun pOps -> ((simulate_space $ pOps) > pv_size)) ==> not]

(* tests to add:
   + alloced_segment <*> new_free = empty (intersection)

   generators:

   + make a generator for partly alloced disks. Needs to have
   knowledge of inside stuff --- or do a long sequence of alloc and
   free commands.  We could just generate a random bitmap of alloced
   and free stuff.  Or create random extends after each other.

   (The long list of commands is what we do at the moment.)
*)

let _ =	
    let free_list =
	let m = make_area "pv_name0"
	in [m 65652L 11L; m 26860L 9L; m 25282L 5L; m 15696L 8L]
    in match safe_alloc free_list 162L with
	| Some (alloced, free_list2) -> 
	    (print_endline $ "free_list: " ^ to_string free_list;
	     print_endline $ "alloced: " ^ to_string alloced;
	     print_endline $ "free_list2: " ^ to_string free_list2;)
	| None -> print_endline "Not enough space."

let tests = [
    test_contained_is_reflexive;
    test_contained_is_transitive;
    test_alloc_everything;
    test_alloc_works;
    test_alloc_fails;
]


let () =
    let results = Test.exec_tests tests in
    let passed = ref true in
    let open Kaputt.Test in
    List.iter (function
    | Passed -> ()
    | Failed _ -> Printf.fprintf stderr "BAD: Kaputt.Assertion.failure\n%!"; passed := false
    | Uncaught (exn, str) -> Printf.fprintf stderr "BAD: Uncaught %s %s\n%!" (Printexc.to_string exn) str; passed := false
    | Report(passed_cases, total_cases, 0, _, _) when passed_cases = total_cases -> ()
    | Report(_, _, uncaught_exns, _, _) when uncaught_exns > 0 -> Printf.fprintf stderr "BAD: %d uncaught exceptions\n%!" uncaught_exns; passed := false
    | Report(passed_cases, total_cases, _, _, _) -> Printf.fprintf stderr "BAD: %d out of %d cases passed\n%!" passed_cases total_cases; passed := false
    | Exit_code 0 -> ()
    | Exit_code n -> Printf.fprintf stderr "BAD: Exit code %d\n%!" n; passed := false
    ) results;
    if not !passed then exit 1
