(*---------------------------------------------------------------------------
   Copyright 2013 Daniel C. Bünzli. All rights reserved.
   Distributed under the BSD3 license, see license at the end of the file.
   %%NAME%% release %%VERSION%%
  ---------------------------------------------------------------------------*)

open Gg

(* Invalid_arg strings *)

let err_empty = "empty path"
let err_meta_unbound = "key unbound in metadata"
let err_bounds j l = Printf.sprintf "invalid bounds (index %d, length %d)" j l 
let err_exp_await = "`Await expected"
let err_end = "`End rendered, render can't be used on renderer"
let err_once = "a single `Image can be rendered"

(* Unsafe string byte manipulations. If you don't believe the authors's 
   invariants, replacing with safe versions makes everything safe in the 
   module. He won't be upset. *)

let unsafe_blit = String.unsafe_blit
let unsafe_set_byte s j byte = String.unsafe_set s j (Char.unsafe_chr byte)
let unsafe_byte s j = Char.code (String.unsafe_get s j)

(* A few useful definitions *)

external ( >> ) : 'a -> ('a -> 'b) -> 'b = "%revapply"
let eps = 1e-9
let io_buffer_size = 65536                          (* IO_BUFFER_SIZE 4.0.0 *)

(* Pretty printing *)

let pp ppf fmt = Format.fprintf ppf fmt
let pp_str = Format.pp_print_string
let pp_space = Format.pp_print_space 
let pp_float ppf v = pp ppf "%g" v
let pp_comma ppf () = pp ppf ",@ "
let pp_date ppf ((y, m, d), (hh, mm, ss)) = 
  pp ppf "%4d-%2d-%2dT%2d:%2d:%2dZ" y m d hh mm ss

let rec pp_list ?(pp_sep = Format.pp_print_cut) pp_v ppf = function 
| [] -> ()
| v :: vs -> 
    pp_v ppf v; if vs <> [] then (pp_sep ppf (); pp_list ~pp_sep pp_v ppf vs)

let to_string_of_formatter pp v =                       (* NOT thread safe. *)
  Format.fprintf Format.str_formatter "%a" pp v; 
  Format.flush_str_formatter ()

(* Render metadata 

   The type for metadata is an heterogenous dictionary, for the tricks
   see http://mlton.org/PropertyList. Map keys are augmented to allow
   key value comparison and pretty printing. *)

module Vgm = struct

  let uid =               (* thread-safe UID, don't use Oo.id (object end). *) 
    let c = ref min_int in
    fun () ->
      let id = !c in
      incr c; if id > !c then assert false (* too many ids *) else id
  
  (* Keys *)

  type key_u =                                   (* concrete Map.Make keys. *)
    { id : int;                   (* key identifier, defines the key order. *)
      name : string;                                           (* key name. *)
      pp : Format.formatter -> exn -> unit;    (* key value pretty-printer. *)
      cmp : exn -> exn -> int; }                   (* key value comparison. *)

  module Key = struct
    type t = key_u
    let compare k0 k1 = Pervasives.compare k0.id k1.id
  end

  type 'a key =                                     (* typed metadata keys. *)
    { k : key_u;                                                (* map key. *)
      set : 'a -> exn;                                 (* key value setter. *)
      get : exn -> 'a; }                               (* key value getter. *)

  let key (type v) ?(cmp = Pervasives.compare) name pp =
    let module Store = struct exception V of v end in
    let set = fun v -> Store.V v in 
    let get = function Store.V v -> v | _ -> assert false in
    let pp ppf = function Store.V v -> pp ppf v | _ -> assert false in
    let cmp e e' = match e, e' with 
    | Store.V v, Store.V v' -> cmp v v' 
    | _, _ -> assert false
    in
    let k = { id = uid (); name; pp; cmp } in
    { k; set; get}

  (* Metadata *)
      
  module M = (Map.Make (Key) : Map.S with type key = Key.t)
  type t = exn M.t
      
  let empty = M.empty 
  let is_empty = M.is_empty
  let mem m k = M.mem k.k m
  let add m k v = M.add k.k (k.set v) m
  let rem m k = M.remove k.k m
  let find m k = try Some (k.get (M.find k.k m)) with Not_found -> None
  let get ?absent m k = try k.get (M.find k.k m) with 
  | Not_found -> 
      match absent with 
      | Some d -> d
      | None -> invalid_arg err_meta_unbound

  let add_meta m m' = M.fold M.add m' m 
  let compare m0 m1 = 
    let rec loop b0 b1 = match b0, b1 with 
    | (k0, v0) :: b0, (k1, v1) :: b1 ->
        let c = Pervasives.compare k0.id k1.id in 
        if c <> 0 then c else
        let c = k0.cmp v0 v1 in 
        if c <> 0 then c else 
        loop b0 b1
    | [], [] -> 0 
    | [], _ :: _ -> -1 
    | _ :: _, [] -> 1
    in
    loop (M.bindings m0) (M.bindings m1)
        
  let equal m m' = compare m m' = 0 
  let pp ppf m =
    let pp_kv ppf (k, v) = pp ppf "@[(%s@ %a)@]" k.name k.pp v in
    let bs = M.bindings m in 
    pp ppf "@[(meta@ %a)@]" (pp_list ~pp_sep:Format.pp_print_space pp_kv) bs

  (* Standard keys *)
      
  let resolution = key "resolution" ~cmp:V2.compare V2.pp
  let title = key "title" pp_str
  let authors = key "authors" (pp_list ~pp_sep:pp_comma pp_str)
  let creator = key "creator" pp_str
  let keywords = key "keywords" (pp_list ~pp_sep:pp_comma pp_str)
  let subject = key "subject" pp_str
  let description = key "description" pp_str
  let creation_date = key "creation_date" pp_date
end

type meta = Vgm.t
type 'a key = 'a Vgm.key

(* Paths *)

module P = struct

  (* Path outline caps *)

  type cap = [ `Butt | `Round | `Square ]

  let pp_cap ppf = function 
  | `Butt -> pp ppf "Butt" | `Round -> pp ppf "Round" 
  | `Square -> pp ppf "Square"

  (* Path outline joins *)

  type join = [ `Miter | `Round | `Bevel ]

  let pp_join ppf = function 
  | `Bevel -> pp ppf "Bevel" | `Miter -> pp ppf "Miter" 
  | `Round -> pp ppf "Round"

  (* Path outline dashes *)

  type dashes = float * float list

  let eq_dashes eq d d' = match d, d' with 
  | Some (f, ds), Some (f', ds') -> 
      eq f f' && (try List.for_all2 eq ds ds' with Invalid_argument _ -> false)
  | d, d' -> d = d'
          
  let cmp_dashes cmp d d' = match d, d' with
  | Some (f, ds), Some (f', ds') -> 
      let rec dashes ds ds' = match ds, ds' with 
      | d :: ds, d' :: ds' -> 
          let c = cmp d d' in 
          if c <> 0 then c else dashes ds ds'
      | ds, ds' -> Pervasives.compare ds ds' 
      in
      let c = cmp f f' in 
      if c <> 0 then c else dashes ds ds'
  | d, d' -> Pervasives.compare d d'

  let pp_dashes pp_f ppf = function 
  | None -> () | Some (f, ds) -> 
      let pp_dashes ppf ds = pp_list ~pp_sep:pp_space pp_f ppf ds in
      pp ppf "@ (dashes %a @[<1>(%a)@])" pp_f f pp_dashes ds

  (* Path outlines *)

  type outline = 
    { width : float; cap : cap; join : join; miter_angle : float; 
      dashes : dashes option }

  let o = { width = 1.; cap = `Butt; join = `Miter; miter_angle = 0.; 
            dashes = None }

  let pp_outline_f pp_f ppf o =
    pp ppf "@[<1>(outline@ (width %a)@ (cap %a)@ (join %a)\
            @ (miter-angle %a)%a)@]"
      pp_f o.width pp_cap o.cap pp_join o.join pp_f o.miter_angle 
      (pp_dashes pp_f) o.dashes

  let pp_outline ppf o = pp_outline_f pp_float ppf o

  (* Path areas *)

  type area = [ `Aeo | `Anz | `O of outline ]
        
  let eq_area eq a a' = match a, a' with
  | `O o, `O o' ->
      eq o.width o'.width && o.cap = o'.cap && o.join = o'.join &&
      eq o.miter_angle o'.miter_angle && eq_dashes eq o.dashes o'.dashes
  | a, a' -> a = a'

  let cmp_area cmp a a' = match a, a' with
  | `O o, `O o' ->
      let c = cmp o.width o'.width in 
      if c <> 0 then c else 
      let c = Pervasives.compare o.cap o'.cap in 
      if c <> 0 then c else
      let c = Pervasives.compare o.join o'.join in 
      if c <> 0 then c else
      let c = cmp o.miter_angle o'.miter_angle in 
      if c <> 0 then c else cmp_dashes cmp o.dashes o'.dashes
  | a, a' -> Pervasives.compare a a'

  let pp_area_f pp_f ppf = function 
  | `Anz -> pp ppf "@[<1>anz@]"
  | `Aeo -> pp ppf "@[<1>aeo@]"
  | `O o -> pp ppf "%a" (pp_outline_f pp_f) o

  let pp_area ppf a = pp_area_f pp_float ppf a 

  (* Paths *)
  
  type segment = 
    [ `Sub of p2                          (* subpath start, "empty" segment *)
    | `Line of p2
    | `Qcurve of p2 * p2 
    | `Ccurve of p2 * p2 * p2 
    | `Earc of bool * bool * float * size2 * p2
    | `Close ]
	
  type t = segment list
  (* The list is reversed. The following invariants hold. The last
     element of the list is always `Sub. Between any two `Sub there is
     always at least one element different from `Sub. If there's an
     element preceding a `Close it's a `Sub. *)

  let empty = []
  let last_pt = function 
  | [] -> None
  | s :: ss -> 
      match s with 
      | `Sub pt | `Line pt | `Qcurve (_, pt) | `Ccurve (_, _, pt) 
      | `Earc (_, _, _, _, pt) -> Some pt 
      | `Close -> 
          let rec find_sub = function
          | `Sub pt :: _ -> pt
          | _ :: ss -> find_sub ss
          | [] -> assert false
          in
          Some (find_sub ss)
            
  (* Subpath and segments *)	

  let abs_origin p = match last_pt p with None -> P2.o | Some o -> o
  let abs p pt = match last_pt p with None -> pt | Some o -> V2.(o + pt)
  let close_empty_sub = function
  | (`Sub _ as s) :: p -> `Close :: s :: p 
  | p -> p 

  let push seg = function 
  | [] | `Close :: _  as p -> seg :: `Sub P2.o :: p 
  | p  -> seg :: p
        
  let sub ?(rel = false) pt p =
    let pt = if rel then abs p pt else pt in
    `Sub pt :: (close_empty_sub p)
    
  let line ?(rel = false) pt p =
    let pt = if rel then abs p pt else pt in 
    push (`Line pt) p 
            
  let qcurve ?(rel = false) c pt p =
    if not rel then push (`Qcurve (c, pt)) p else
    let o = abs_origin p in
    push (`Qcurve (V2.(o + c), V2.(o + pt))) p 
      
  let ccurve ?(rel = false) c c' pt p =
    if not rel then push (`Ccurve (c, c', pt)) p else
    let o = abs_origin p in
    push (`Ccurve (V2.(o + c), V2.(o + c'), V2.(o + pt))) p 

  let earc ?(rel = false) ?(large = false) ?(cw = false) ?(angle = 0.) r pt p = 
    let pt = if rel then abs p pt else pt in
    push (`Earc (large, cw, angle, r, pt)) p
      
  let close p = push `Close p
        
  (* Derived subpaths *)

  let circle ?(rel = false) c r p =
    let c = if rel then abs p c else c in
    let cx = P2.x c in
    let cy = P2.y c in
    let a0 = P2.v (cx +. r) cy in 
    let api = P2.v (cx -. r) cy in
    let r = V2.v r r in
    p >> sub a0 >> earc r api >> earc r a0 >> close
    
  let ellipse ?(rel = false) ?(angle = 0.) c r p = 
    let c = if rel then abs p c else c in
    let cx = P2.x c in
    let cy = P2.y c in
    let xx = (if angle = 0. then 1.0 else cos angle) *. V2.x r in
    let xy = (if angle = 0. then 0.0 else sin angle) *. V2.x r in 
    let a0 = P2.v (cx +. xx) (cy +. xy) in
    let api = P2.v (cx -. xx) (cy -. xy) in
    p >> sub a0 >> earc r ~angle api >> earc r ~angle a0 >> close
      
  let rect ?(rel = false) r p = 
    if Box2.is_empty r then p else
    let lb = if rel then abs p (Box2.o r) else (Box2.o r) in
    let size = Box2.size r in
    let l = P2.x lb in
    let r = l +. Size2.w size in
    let b = P2.y lb in 
    let t = b +. Size2.h size in
    p >> sub lb >> line (P2.v r b) >> line (P2.v r t) >> line (P2.v l t) >> 
    close
      
  let rrect ?(rel = false) r cr p = 
    if Box2.is_empty r then p else
    let lb = if rel then abs p (Box2.o r) else (Box2.o r) in
    let size = Box2.size r in
    let rx = V2.x cr in
    let ry = V2.y cr in
    let l = P2.x lb in
    let l_inset = l +. rx in 
    let r = l +. Size2.w size in
    let r_inset = r -. rx in 
    let b = P2.y lb in 
    let b_inset = b +. ry in 
    let t = b +. Size2.h size in 
    let t_inset = t -. ry in 
    p >> sub (P2.v l b_inset) >>
    earc cr (P2.v l_inset b) >> line (P2.v r_inset b) >>
    earc cr (P2.v r b_inset) >> line (P2.v r t_inset) >>
    earc cr (P2.v r_inset t) >> line (P2.v l_inset t) >>
    earc cr (P2.v l t_inset) >> close

  (* Geometry *)

  (* See Vgr.Private.P.earc_params in mli file for the doc. The center is 
     found by first transforming the points on the ellipse to points on 
     a unit circle (i.e. we rotate by -a and scale by 1/rx 1/ry). *)

  let earc_params p0 ~large ~cw a r p1 = 
    let rx = V2.x r in let ry = V2.y r in
    let x0 = V2.x p0 in let y0 = V2.y p0 in
    let x1 = V2.x p1 in let y1 = V2.y p1 in
    if Float.is_zero ~eps rx || Float.is_zero ~eps ry then None else
    let sina = Float.round_zero ~eps (sin a) in
    let cosa = Float.round_zero ~eps (cos a) in
    let x0' = (cosa *. x0 +. sina *. y0) /. rx in(* transform to unit circle *)
    let y0' = (-. sina *. x0 +. cosa *. y0) /. ry in
    let x1' = (cosa *. x1 +. sina *. y1) /. rx in
    let y1' = (-. sina *. x1 +. cosa *. y1) /. ry in
    let vx = x1' -. x0' in
    let vy = y1' -. y0' in
    let nx = vy in                                       (* normal to p0'p1' *)
    let ny = -. vx in 
    let nn = (nx *. nx) +. (ny *. ny) in
    if Float.is_zero ~eps nn then None (* points coincide *) else 
    let d2 = Float.round_zero ~eps (1. /. nn -. 0.25) in
    if d2 < 0. then None (* points are too far apart *) else
    let d = sqrt d2 in
    let d = if (large && cw) || (not large && not cw) then -. d else d in
    let cx' = 0.5 *. (x0' +. x1') +. d *. nx  in            (* circle center *)
    let cy' = 0.5 *. (y0' +. y1') +. d *. ny in
    let t0 = atan2 (y0' -. cy') (x0' -. cx') in              (* angle of p0' *)
    let t1 = atan2 (y1' -. cy') (x1' -. cx') in
    let dt = (t1 -. t0) in
    let adjust = 
      if dt > 0. && cw then -. 2. *. Float.pi else
      if dt < 0. && not cw then 2. *. Float.pi else
      0.
    in
    let t1 = t0 +. (dt +. adjust) in                         (* angle of p1' *)
    let e1x = rx *. cosa in 
    let e1y = rx *. sina in
    let e2x = -. ry *. sina in
    let e2y = ry *. cosa in
    let cx = e1x *. cx' +. e2x *. cy' in            (* transform center back *)
    let cy = e1y *. cx' +. e2y *. cy' in 
    let m = M2.v e1x e2x 
                 e1y e2y
    in
    Some ((P2.v cx cy), m, t0, t1)

  let casteljau pt c c' pt' t =
    let b00 = V2.mix pt c t in
    let b01 = V2.mix c c' t in
    let b02 = V2.mix c' pt' t in
    let b10 = V2.mix b00 b01 t in
    let b11 = V2.mix b01 b02 t in
    let b = V2.mix b10 b11 t in
    b

  (* Functions *)
      
  let last_pt p = match last_pt p with 
  | None -> invalid_arg err_empty | Some pt -> pt
        
  let append p' p =
    let p = close_empty_sub p in
    List.rev_append (List.rev p') p
      
  let bounds ?(ctrl = false) = function
  | [] -> Box2.empty
  | p ->
      let xmin = ref max_float in
      let ymin = ref max_float in
      let xmax = ref ~-.max_float in
      let ymax = ref ~-.max_float in
      let update pt = 
	let x = P2.x pt in
        let y = P2.y pt in
	if x < !xmin then xmin := x;
	if x > !xmax then xmax := x;
	if y < !ymin then ymin := y;
	if y > !ymax then ymax := y
      in
      let rec seg_ctrl = function
      | `Sub pt :: l -> update pt; seg_ctrl l
      | `Line pt :: l -> update pt; seg_ctrl l
      | `Qcurve (c, pt) :: l -> update c; update pt; seg_ctrl l
      | `Ccurve (c, c', pt) :: l -> update c; update c'; update pt; seg_ctrl l
      | `Earc (large, cw, angle, radii, pt) :: l ->
	  let last = last_pt l in
          begin match earc_params last large cw angle radii pt with
          | None -> update pt; seg_ctrl l
          | Some (c, m, a1, a2) ->
              (* TODO wrong in general. *)
	      let t = (a1 +. a2) /. 2. in
              let b = V2.add c (V2.ltr m (V2.v (cos t) (sin t))) in
              update b; update pt; seg_ctrl l
	    end
	| `Close :: l -> seg_ctrl l
	| [] -> ()
      in
      let rec seg = function 
      | `Sub pt :: l -> update pt; seg l
      | `Line pt :: l -> update pt; seg l
      | `Qcurve (c, pt) :: l -> (* TODO *) update c; update pt; seg l
      | `Ccurve (c, c', pt) :: l -> 
	  let last = last_pt l in
          let update_z dim = (* Kallay, computing thight bounds *)
	      let fuzz = 1e-12 in
	      let solve a b c f = 
		let d = b *. b -. a *. c in
		if (d <= 0.) then () else 
		begin
		  let d = sqrt d in
		  let b = -. b in
		  let b = if (b > 0.) then b +. d else b -. d in
		  if (b *. a > 0.) then f (b /. a);
		  let a = d *. c in
		  let b = c *. c *. fuzz in 
		  if (a > b || -. a < -. b) then f (c /. d);
		end
	      in
	      let a = dim last in 
	      let b = dim c in
	      let cc = dim c' in
	      let d = dim pt in
	      if (a < b && b < d) && (a < cc && cc < d) then () else
	      let a = b -. a in
	      let b = cc -. b in
	      let cc = d -. cc in
	      let fa = abs_float a in
	      let fb = abs_float b *. fuzz in
	      let fc = abs_float cc in
	      if (fa < fb && fc < fb) then () else
	      if (fa > fc) then
		let upd s = 
                  update (casteljau last c c' pt (1.0 /. (1.0 +. s))) 
                in
		solve a b cc upd;		
	      else
		let upd s = update (casteljau last c c' pt (s /. (1.0 +. s))) in
		solve cc b a upd
	    in
	    update_z V2.x; update_z V2.y; update pt; seg l
	| `Earc (large, cw, angle, radii, pt) :: l ->
	    let last = last_pt l in
	    begin match earc_params last large cw angle radii pt with
	    | None -> update pt; seg l
	    | Some (c, m, a1, a2) ->
		(* TODO wrong in general. *)
		let t = (a1 +. a2) /. 2. in
		let b = V2.add c (V2.ltr m (V2.v (cos t) (sin t))) in
		update b;  update pt; seg l
	    end
	| `Close :: l -> seg l
	| [] -> ()
      in
      if ctrl then seg_ctrl p else seg p;
      Box2.v (P2.v !xmin !ymin) (Size2.v (!xmax -. !xmin) (!ymax -. !ymin))

  let tr m p = 
    let tr_seg m = function 
    | `Sub pt -> `Sub (P2.tr m pt)
    | `Line pt -> `Line (P2.tr m pt) 
    | `Qcurve (c, pt) -> `Qcurve (P2.tr m c, P2.tr m pt) 
    | `Ccurve (c, c', pt) -> `Ccurve (P2.tr m c, P2.tr m c', P2.tr m pt)
    | `Earc (l, cw, a, r, pt) -> (* TODO recheck that *)
	let sina = sin a in
        let cosa = cos a in
        let rx = V2.x r in
        let ry = V2.y r in
        let ax = V2.v (cosa *. rx) (sina *. rx) in 
        let ay = V2.v (-. sina *. ry) (cosa *. ry) in 
	let ax' = V2.tr m ax in
	let ay' = V2.tr m ay in
	let a' = atan2 (V2.y ax') (V2.x ax') in 
	let rx' = V2.norm ax' in
	let ry' = V2.norm ay' in
        `Earc (l, cw, a', (V2.v rx' ry'), (P2.tr m pt))
    | `Close -> `Close 
    in
    List.rev (List.rev_map (tr_seg m) p)

  (* Traversal *)

  type fold = segment 
  type linear_fold = [ `Sub of p2 | `Line of p2 | `Close ]
  type sampler = [ `Sub of p2 | `Sample of p2 | `Close ]

  let fold ?(rev = false) f acc p = 
    List.fold_left f acc (if rev then p else List.rev p) 

  (* linear_{qcurve,ccurve,earc} functions are not t.r. but the recursion
     should converge stop rapidly. *)

  let linear_qcurve tol line acc p0 p1 p2 = 
    let tol = 16. *. tol *. tol in
    let rec loop tol line acc p0 p1 p2 = 
      let is_flat =                          (* adapted from the cubic case. *)
	let ux = 2. *. P2.x p1 -. P2.x p0 -. P2.x p2 in 
        let uy = 2. *. P2.y p1 -. P2.y p0 -. P2.y p2 in
	let ux = ux *. ux in
	let uy = uy *. uy in
	ux +. uy <= tol
      in
      if is_flat then line acc p2 else
      let p01 = P2.mid p0 p1 in
      let p12 = P2.mid p1 p2 in
      let p012 = P2.mid p01 p12 in
      loop tol line (loop tol line acc p0 p01 p012) p012 p12 p2
    in
    loop tol line acc p0 p1 p2

  let rec linear_ccurve tol line acc p0 p1 p2 p3 =   
    let tol = 16. *. tol *. tol in 
    let rec loop tol line acc p0 p1 p2 p3 = 
      let is_flat = (* cf. Kaspar Fischer according to R. Willocks. *)
	let ux = 3. *. P2.x p1 -. 2. *. P2.x p0 -. P2.x p3 in
	let uy = 3. *. P2.y p1 -. 2. *. P2.y p0 -. P2.y p3 in 
	let ux = ux *. ux in
	let uy = uy *. uy in
	let vx = 3. *. P2.x p2 -. 2. *. P2.x p3 -. P2.x p0 in
	let vy = 3. *. P2.y p2 -. 2. *. P2.y p3 -. P2.y p0 in
	let vx = vx *. vx in
	let vy = vy *. vy in
	let mx = if ux > vx then ux else vx in
	let my = if uy > vy then uy else vy in
	mx +. my <= tol
      in
      if is_flat then line acc p3 else    
      let p01 = P2.mid p0 p1 in 
      let p12 = P2.mid p1 p2 in 
      let p23 = P2.mid p2 p3 in
      let p012 = P2.mid p01 p12 in
      let p123 = P2.mid p12 p23 in
      let p0123 = P2.mid p012 p123 in    
      loop tol line (loop tol line acc p0 p01 p012 p0123) p0123 p123 p23 p3
    in
    loop tol line acc p0 p1 p2 p3
  
  let linear_earc tol line acc p0 large cw a r p1 =
    match earc_params p0 large cw a r p1 with
    | None -> line acc p1
    | Some (c, m, t0, t1) -> 
	let tol2 = tol *. tol in
	let rec loop tol line acc p0 t0 p1 t1 = 
	  let t = (t0 +. t1) /. 2. in
	  let b = V2.add c (V2.ltr m (V2.v (cos t) (sin t))) in
	  let is_flat =               (* cf. Drawing elliptic... L. Maisonbe *)
	    let x0 = V2.x p0 in 
	    let y0 = V2.y p0 in 
	    let px = V2.y p1 -. y0 in
	    let py = -. (V2.x p1 -. x0) in
	    let vx = V2.x b -. x0 in
	    let vy = V2.y b -. y0 in
	    let dot = (px *. vx +. py *. vy) in
	    let d = dot *. dot /. (vx *. vx +. vy *. vy) in
	    d <= tol
	  in
	  if is_flat then line acc p1 else
	  loop tol line (loop tol line acc p0 t0 b t) b t p1 t1 
	in
	loop tol2 line acc p0 t0 p1 t1
	  
  let linear_fold ?(tol = 1e-3) f acc p =
    let line acc pt = f acc (`Line pt) in
    let linear (acc, last) = function 
    | `Sub pt -> f acc (`Sub pt), pt
    | `Line pt -> line acc pt, pt
    | `Qcurve (c, pt) ->  linear_qcurve tol line acc last c pt, pt
    | `Ccurve (c, c', pt) -> linear_ccurve tol line acc last c c' pt, pt
    | `Earc (l, cw, a, r, pt) -> linear_earc tol line acc last l cw a r pt, pt
    | `Close -> f acc `Close, (* ignored, `Sub or end follows *) last 
    in
    fst (fold linear (acc, P2.o) p)

  let sample ?tol period f acc p =
    let sample (acc, last, residual) = function
    | `Sub pt -> f acc (`Sub pt), pt, 0.
    | `Line pt ->
        let seg_len = V2.(norm (pt - last)) in
        let first_pt = period -. residual in
        let to_walk = seg_len -. first_pt in
        let pt_count = int_of_float (to_walk /. period) in
        let residual' = to_walk -. (float pt_count) *. period in
        let acc = ref acc in
        for i = 0 to pt_count do 
	  let t = (first_pt +. (float i) *. period) /. seg_len in
          acc := f !acc (`Sample (V2.mix last pt t))
        done;
        (!acc, pt, residual')
    | `Close -> f acc `Close, (* ignored `Sub or end follows *) last, 0. 
    in
    let acc, _, _ = linear_fold ?tol sample (acc, P2.o, 0.) p in
    acc

  (* TODO This is needed by the PDF renderer to approximate elliptical arcs. 
     Do we add something like Vg.P.cubic_fold or just move that to 
     the pdf renderer ? *)
  
  let one_div_3 = 1. /. 3. 
  let two_div_3 = 2. /. 3. 
  let cubic_earc tol cubic acc p0 large cw r a p1 = (* TODO tailrec *)
    match earc_params p0 large cw a r p1 with
    | None -> (* line with a cubic *)
	let c = V2.add (V2.smul two_div_3 p0) (V2.smul one_div_3 p1) in
        let c' = V2.add (V2.smul one_div_3 p0) (V2.smul two_div_3 p1) in
        cubic c c' p1 acc
    | Some (c, m, t0, t1) -> 
	let mt = (* TODO something better *)
	  M2.v (-. (M2.e00 m)) (M2.e10 m) (* gives the tngt to a point *)
	       (-. (M2.e01 m)) (M2.e11 m)
	in
	let tol = tol /. max (V2.x r) (V2.y r) in
	let rec loop tol cubic acc p0 t0 p1 t1 = 
	  let dt = t1 -. t0 in
	  let a = 0.25 *. dt in
	  let is_flat = (2.*. (sin a) ** 6.) /. (27.*. (cos a) ** 2.) <= tol in
	  if is_flat then 
	    let l = (4. *. tan a) /. 3. in
	    let c = V2.add p0 (V2.smul l (V2.ltr mt (V2.v (sin t0) (cos t0)))) 
            in
	    let c' = V2.sub p1 (V2.smul l (V2.ltr mt (V2.v (sin t1) (cos t1))))
            in
	    cubic c c' p1 acc
	  else
	    let t = (t0 +. t1) /. 2. in
	    let b = V2.(c + ltr m (V2.v (cos t) (sin t))) in
	    loop tol cubic (loop tol cubic acc p0 t0 b t) b t p1 t1
      in
      loop tol cubic acc p0 t0 p1 t1

  (* Predicates and comparisons *)

  let is_empty = function [] -> true | _ -> false 
  let equal p p' = p = p' 
  let rec equal_f eq p p' =
    let equal_seg eq s s' = match s, s' with 
    | `Sub pt, `Sub pt' 
    | `Line pt, `Line pt' -> 
        V2.equal_f eq pt pt' 
    | `Qcurve (c0, pt), `Qcurve (c0', pt') -> 
        V2.equal_f eq c0 c0' && V2.equal_f eq pt pt'
    | `Ccurve (c0, c1, pt), `Ccurve (c0', c1', pt') -> 
        V2.equal_f eq c0 c0' && V2.equal_f eq c1 c1' && V2.equal_f eq pt pt'
    | `Earc (l, ccw, a, r, pt), `Earc (l', ccw', a', r', pt') ->
        l = l' && ccw = ccw' && eq a a' && V2.equal_f eq r r' &&  
        V2.equal_f eq pt pt'
    | `Close, `Close -> true
    | _, _ -> false 
    in
    match p, p' with 
    | s :: p, s' :: p' -> if equal_seg eq s s' then equal_f eq p p' else false
    | [], [] -> true
    | _ -> false
          
  let compare p p' = Pervasives.compare p p'
  let rec compare_f cmp p p' = 
    let compare_seg cmp s s' = match s, s' with 
    | `Sub pt, `Sub pt' 
    | `Line pt, `Line pt' -> 
        V2.compare_f cmp pt pt' 
    | `Qcurve (c0, pt), `Qcurve (c0', pt') -> 
        let c = V2.compare_f cmp c0 c0' in 
        if c <> 0 then c else V2.compare_f cmp pt pt'
    | `Ccurve (c0, c1, pt), `Ccurve (c0', c1', pt') -> 
        let c = V2.compare_f cmp c0 c0' in 
        if c <> 0 then c else 
        let c = V2.compare_f cmp c1 c1' in 
        if c <> 0 then c else V2.compare_f cmp pt pt'
    | `Earc (l, ccw, a, r, pt), `Earc (l', ccw', a', r', pt') ->
        let c = Pervasives.compare l l' in 
        if c <> 0 then c else
        let c = Pervasives.compare ccw ccw' in 
        if c <> 0 then c else 
        let c = cmp a a' in 
        if c <> 0 then c else 
        let c = V2.compare_f cmp r r' in 
        if c <> 0 then c else V2.compare_f cmp pt pt'
    | s, s' -> Pervasives.compare s s'
    in
    match p, p' with 
    | s :: p, s' :: p' ->
        let c = compare_seg cmp s s' in 
        if c <> 0 then c else compare_f cmp p p' 
    | p, p' -> Pervasives.compare p p'
       
  (* Printers *)

  let pp_seg pp_f pp_v2 ppf = function
  | `Sub pt -> 
      pp ppf "@ S@ %a" pp_v2 pt 
  | `Line pt -> 
      pp ppf "@ L@ %a" pp_v2 pt
  | `Qcurve (c, pt) -> 
      pp ppf "@ Qc@ %a@ %a" pp_v2 c pp_v2 pt
  | `Ccurve (c, c', pt) -> 
      pp ppf "@ Cc@ %a@ %a@ %a" pp_v2 c pp_v2 c' pp_v2 pt
  | `Earc (l, ccw, a, r, pt) -> 
      let l = if l then "large" else "small" in 
      let ccw = if ccw then "ccw" else "cw" in
      pp ppf "@ E@ %s@ %s@ %a@ %a@ %a" l ccw pp_f a pp_v2 r pp_v2 pt
  | `Close ->
      pp ppf "@ Z"
        
  let pp_path pp_f ppf p = 
    let pp_v2 = V2.pp_f pp_f in
    let pp_segs ppf ss = List.iter (pp_seg pp_f pp_v2 ppf) ss in 
    pp ppf "@[<1>(path%a)@]" pp_segs (List.rev p)

  let pp_f pp_f ppf p = pp_path pp_f ppf p    
  let pp ppf p = pp_path pp_float ppf p
  let to_string p = to_string_of_formatter pp p 
end

type path = P.t

(* Images *)

module I = struct

  (* Blenders *)

  type blender = [ `Atop | `In | `Out | `Over | `Plus | `Copy | `Xor ]  

  let pp_blender ppf = function
  | `Atop -> pp ppf "Atop" | `Copy -> pp ppf "Copy" | `In -> pp ppf "In" 
  | `Out -> pp ppf "Out" | `Over -> pp ppf "Over" | `Plus -> pp ppf "Plus"
  | `Xor -> pp ppf "Xor"

  (* Transforms *)

  type tr = Move of v2 | Rot of float | Scale of v2 | Matrix of m3

  let eq_tr eq tr tr' = match tr, tr' with 
  | Move v, Move v' -> V2.equal_f eq v v' 
  | Rot r, Rot r' -> eq r r' 
  | Scale s, Scale s' -> V2.equal_f eq s s' 
  | Matrix m, Matrix m' -> M3.equal_f eq m m' 
  | _, _ -> false

  let compare_tr cmp tr tr' = match tr, tr' with 
  | Move v, Move v' -> V2.compare_f cmp v v' 
  | Rot r, Rot r' -> cmp r r' 
  | Scale s, Scale s' -> V2.compare_f cmp s s' 
  | Matrix m, Matrix m' -> M3.compare_f cmp m m' 
  | tr, tr' -> compare tr tr'

  let pp_tr pp_f ppf = function 
  | Move v -> pp ppf "(move %a)" (V2.pp_f pp_f) v
  | Rot a -> pp ppf "(rot %a)" pp_f a
  | Scale s -> pp ppf "(scale %a)" (V2.pp_f pp_f) s
  | Matrix m -> pp ppf "%a" (M3.pp_f pp_f) m

  (* Color stops *)

  type stops = Color.stops
  
  let pp_stops pp_f ppf ss =
    let pp_stop ppf (s, c) = pp ppf "@ %a@ %a" pp_f s (V4.pp_f pp_f) c in 
    pp ppf "@[<1>(stops%a)@]" (fun ppf ss -> List.iter (pp_stop ppf) ss) ss

  let rec eq_stops eq ss ss' = match ss, ss' with 
  | (s, c) :: ss, (s', c') :: ss' -> 
      eq s s' && V4.equal_f eq c c' && eq_stops eq ss ss'
  | [], [] -> true
  | _, _ -> false

  let rec compare_stops cmp ss ss' = match ss, ss' with
  | (s, sc) :: ss, (s', sc') :: ss' -> 
      let c = cmp s s' in
      if c <> 0 then c else 
      let c = V4.compare_f cmp sc sc' in 
      if c <> 0 then c else compare_stops cmp ss ss' 
  | ss, ss' -> Pervasives.compare ss ss'

  (* Primitives *)

  type primitive = 
    | Const of color
    | Axial of Color.stops * p2 * p2
    | Radial of Color.stops * p2 * p2 * float
    | Raster of box2 * raster
          
  let eq_primitive eq i i' = match i, i' with 
  | Const c, Const c' -> 
      V4.equal_f eq c c'
  | Axial (stops, p1, p2), Axial (stops', p1', p2') -> 
      V2.equal_f eq p1 p1' && V2.equal_f eq p2 p2' && eq_stops eq stops stops'
  | Radial (stops, p1, p2, r), Radial (stops', p1', p2', r') -> 
      V2.equal_f eq p1 p1' && V2.equal_f eq p2 p2' && eq r r' && 
      eq_stops eq stops stops'
  | Raster (r, ri), Raster (r', ri') ->
      Box2.equal_f eq r r' && Raster.equal ri ri'
  | _, _ -> false
                 
  let compare_primitive cmp i i' = match i, i' with 
  | Const c, Const c' -> 
      V4.compare_f cmp c c' 
  | Axial (stops, p1, p2), Axial (stops', p1', p2') -> 
      let c = compare_stops cmp stops stops' in 
      if c <> 0 then c else 
      let c = V2.compare_f cmp p1 p1' in 
      if c <> 0 then c else V2.compare_f cmp p2 p2'
  | Radial (stops, p1, p2, r), Radial (stops', p1', p2', r') -> 
      let c = compare_stops cmp stops stops' in 
      if c <> 0 then c else 
      let c = V2.compare_f cmp p1 p1' in 
      if c <> 0 then c else 
      let c = V2.compare_f cmp p2 p2' in 
      if c <> 0 then c else cmp r r'
  | Raster (r, ri), Raster (r', ri') ->
      let c = Box2.compare_f cmp r r' in 
      if c <> 0 then c else Raster.compare ri ri'
  | i, i' -> Pervasives.compare i i'

  let pp_primitive pp_f ppf = function
  | Const c -> 
      pp ppf "@[<1>(i-const@ %a)@]" (V4.pp_f pp_f) c
  | Axial (stops, p, p') -> 
      pp ppf "@[<1>(i-axial@ %a@ %a@ %a)@]" 
        (pp_stops pp_f) stops (V2.pp_f pp_f) p (V2.pp_f pp_f) p'
  | Radial (stops, p, p', r) ->
      pp ppf "@[<1>(i-radial@ %a@ %a@ %a@ %a)@]"
        (pp_stops pp_f) stops (V2.pp_f pp_f) p (V2.pp_f pp_f) p' pp_f r
  | Raster (r, ri) -> 
      pp ppf "@[<1>(i-raster %a@ %a)@]" (Box2.pp_f pp_f) r Raster.pp ri
          
  (* Images *)

  type t = 
    | Primitive of primitive
    | Cut of P.area * P.t * t
    | Blend of blender * float option * t * t
    | Tr of tr * t
    | Meta of meta * t

  (* Primitive images *)

  let const c = Primitive (Const c)
  let void = const Color.void
  let axial stops pt pt' = Primitive (Axial (stops, pt, pt'))
  let raster b r = Primitive (Raster (b, r))
  let radial stops ?f c r = 
    let f = match f with None -> c | Some f -> f in
    Primitive (Radial (stops, f, c, r))

  (* Cutting images *)

  let cut ?(area = `Anz) p i = Cut (area, p, i)  

  (* Blending images *)

  let blend ?a ?(blender = `Over) i i' = Blend (blender, a, i, i')

  (* Transforming images *)

  let move v i = Tr (Move v, i)
  let rot a i = Tr (Rot a, i)
  let scale s i = Tr (Scale s, i)
  let tr m i = Tr (Matrix m, i)

  (* Tagging images with metadata *)

  let tag m i = Meta (m, i)

  (* Predicates and comparisons *)  

  let is_void i = i == void 
  let equal i i' = i = i'
  let equal_f eq i i' = 
    let eq_alpha eq a a' = match a, a' with 
    | Some a, Some a' -> eq a a' 
    | None, None -> true
    | _, _ -> false
    in
    let rec loop = function
    | [] -> false 
    | (i, i') :: acc -> 
        match i, i' with
        | Primitive i, Primitive i' -> 
            eq_primitive eq i i'
        | Cut (a, p, i), Cut (a', p', i') -> 
            P.eq_area eq a a' && P.equal_f eq p p' && loop ((i, i') :: acc)
        | Blend (b, a, i1, i2), Blend (b', a', i1', i2') -> 
            b = b' && eq_alpha eq a a' && loop ((i1, i1') :: (i2, i2') :: acc)
        | Tr (tr, i), Tr (tr', i') -> 
            eq_tr eq tr tr' && loop ((i, i') :: acc)
        | Meta (m, i), Meta (m', i') -> 
            Vgm.equal m m' && loop ((i, i') :: acc)
        | _, _ -> false
    in
    loop [(i, i')]
      
  let compare i i' = Pervasives.compare i i' 
  let compare_f cmp i i' =
    let compare_alpha cmp a a' = match a, a' with 
    | Some a, Some a' -> cmp a a' 
    | a, a' -> Pervasives.compare a a'
    in
    let rec loop = function
    | [] -> assert false
    | (i, i') :: acc -> 
        match i, i' with
        | Primitive i, Primitive i' -> 
            compare_primitive cmp i i'
        | Cut (a, p, i), Cut (a', p', i') ->
            let c = P.cmp_area cmp a a' in 
            if c <> 0 then c else 
            let c = P.compare_f cmp p p' in 
            if c <> 0 then c else loop ((i, i') :: acc)
        | Blend (b, a, i1, i2), Blend (b', a', i1', i2') -> 
            let c = Pervasives.compare b b' in 
            if c <> 0 then c else 
            let c = compare_alpha cmp a a' in 
            if c <> 0 then c else 
            loop ((i1, i1') :: (i2, i2') :: acc)
        | Tr (tr, i), Tr (tr', i') -> 
            let c = compare_tr cmp tr tr' in 
            if c <> 0 then c else 
            loop ((i, i') :: acc)
        | Meta (m, i), Meta (m', i') -> 
            let c = Vgm.compare m m' in 
            if c <> 0 then c else 
            loop ((i, i') :: acc)
        | i, i' -> Pervasives.compare i i'
    in
    loop [(i, i')]

  (* Printers *)
      
  let pp_image pp_f ppf i = 
    let pp_alpha pp_f ppf = function
    | None -> () | Some a -> pp ppf "@ (alpha@ %a)" pp_f a
    in
    let rec loop = function 
    | [] -> () 
    | `Pop :: todo -> pp ppf ")@]"; loop todo
    | `Sep :: todo -> pp ppf "@ "; loop todo 
    | `I i :: todo ->
        match i with
        | Primitive prim ->
            pp ppf "%a" (pp_primitive pp_f) prim; 
            loop todo
        | Cut (a, p, i) -> 
            pp ppf "@[<1>(i-cut@ %a@ %a@ "(P.pp_area_f pp_f) a (P.pp_f pp_f) p; 
            loop (`I i :: `Pop :: todo)
        | Blend (b, a, i, i') -> 
            pp ppf "@[<1>(i-blend@ %a%a@ " pp_blender b (pp_alpha pp_f) a;
            loop (`I i :: `Sep :: `I i' :: `Pop :: todo)
        | Tr (tr, i) ->
            pp ppf "@[<1>(i-tr@ %a@ " (pp_tr pp_f) tr; 
            loop (`I i :: `Pop :: todo)
        | Meta (m, i) -> 
            pp ppf "@[<1>(i-meta@ %a@ " Vgm.pp m; 
            loop (`I i :: `Pop :: todo)
    in
    loop [`I i]

  let pp_f pp_f ppf i = pp_image pp_f ppf i
  let pp ppf i = pp_image pp_float ppf i
  let to_string p = to_string_of_formatter pp p 
end

type image = I.t

(* Image renderers *)

module Vgr = struct

  (* Render warnings *)

  type warning =  
    [ `Unsupported_cut of P.area * I.t 
    | `Unsupported_glyph_cut of P.area * I.t
    | `Other of string ]

  type warn = warning -> unit

  let pp_warning ppf w = 
    let pp_area ppf = function
    | `Aeo -> pp ppf "even-odd"
    | `Anz -> pp ppf "non-zero"
    | `O _ -> pp ppf "outline"
    in
    match w with
    | `Other o -> 
        pp ppf "%s" o
    | `Unsupported_cut (a, _) -> 
        pp ppf "Unsupported cut: %a" pp_area a
    | `Unsupported_glyph_cut (a, _) -> 
        pp ppf "Unsupported glyph cut: %a" pp_area a

  (* Renderable *)

  type renderable = size2 * box2 * image

  (* Rendering *)

  type dst_stored = 
    [ `Buffer of Buffer.t | `Channel of Pervasives.out_channel | `Manual ] 
    
  type dst = [ dst_stored | `Other ]

  type t = 
    { dst : dst;                                     (* output destination. *)
      mutable o : string;            (* current output chunk (stored dsts). *)
      mutable o_pos : int;                (* next output position to write. *)
      mutable o_max : int;             (* maximal output position to write. *)
      limit : int;                                         (* render limit. *)
      warn : warn;                                     (* warning callback. *)
      meta : meta;                                      (* render metadata. *)
      mutable k :                                   (* render continuation. *)
        [`Await | `End | `Image of size2 * box2 * image ] -> t -> 
        [ `Ok | `Partial ] }

  type k = t -> [ `Ok | `Partial ]
  type render_fun = [`End | `Image of size2 * box2 * image ] -> k -> k 
  type 'a target = t -> 'a -> bool * render_fun constraint 'a = [< dst]
      
  let expect_await k v r = match v with 
  | `Await -> k r | _ -> invalid_arg err_exp_await

  let expect_none v r = match v with  
  | `Await | `End | `Image _ -> invalid_arg err_end

  let ok k r = r.k <- k; `Ok
  let partial k r = r.k <- expect_await k; `Partial
                        
  let rec r_once (rfun : render_fun) v r = match v with
  | `End -> rfun `End (ok expect_none) r
  | (`Image _) as i -> 
      let rec render_end v r = match v with
      | `End -> rfun `End (ok expect_none) r
      | `Image _ -> invalid_arg err_once
      | `Await -> ok render_end r
      in
      rfun i (ok render_end) r
  | `Await -> ok (r_once rfun) r
                
  let rec r_loop (rfun : render_fun) v r = match v with
  | `End -> rfun `End (ok expect_none) r
  | `Image _ as i -> rfun i (ok (r_loop rfun)) r
  | `Await -> ok (r_loop rfun) r

  let create ?(limit = max_int) ?(warn = fun _ -> ()) ?(meta = Vgm.empty) 
      target dst = 
    let o, o_pos, o_max = match dst with 
    | `Manual | `Other -> "", 1, 0          (* implies [o_rem e = 0]. *)
    | `Buffer _ 
    | `Channel _ -> String.create io_buffer_size, 0, io_buffer_size - 1
    in
    let k _ _ = assert false in
    let r = { dst = (dst :> dst); o; o_pos; o_max; limit; warn; meta; k} in
    let once, rfun = target r dst in 
    r.k <- if once then r_once rfun else r_loop rfun; 
    r
                                              
  let render r v = r.k (v :> [ `Await | `End | `Image of renderable ]) r
  let renderer_dst r = r.dst
  let renderer_meta r = r.meta
  let renderer_limit r = r.limit 

  (* Manual rendering destinations *)
      
  module Manual = struct
    let dst r s j l =                                (* set [r.o] with [s]. *)
      if (j < 0 || l < 0 || j + l > String.length s) then 
        invalid_arg (err_bounds j l);
      r.o <- s; r.o_pos <- j; r.o_max <- j + l - 1
          
    let dst_rem r = r.o_max - r.o_pos + 1   (* rem bytes to write in [r.o]. *)
  end

  (* Implementing renderers. *)

  module Private = struct

    (* Internal data *)

    module Data = struct
      
      (* Path representation *)

      type segment = P.segment
      type path = P.t 
      
      (* Image representation *)
    
      type tr = I.tr = Move of v2 | Rot of float | Scale of v2 | Matrix of m3
      
      type primitive = I.primitive = 
        | Const of color
        | Axial of Color.stops * p2 * p2
        | Radial of Color.stops * p2 * p2 * float
        | Raster of box2 * raster
              
      type image = I.t = 
        | Primitive of primitive
        | Cut of P.area * P.t * image
        | Blend of I.blender * float option * image * image
        | Tr of tr * image
        | Meta of meta * image
    end

    external path : Data.path -> P.t = "%identity"
    external image : Data.image -> I.t = "%identity"

    (* Path helpers *)

    module P = struct
      let earc_params = P.earc_params
    end

    (* Renderers *)

    type renderer = t

    type k = renderer -> [ `Ok | `Partial ]
    type render_fun = [`End | `Image of size2 * box2 * Data.image ] -> k -> k 
    type 'a render_target = renderer -> 'a -> bool * render_fun 
    constraint 'a = [< dst]

    let renderer r = r
    let create_target t = t
    let meta r = r.meta
    let limit r = r.limit
    let warn r w = r.warn w
    let partial = partial 
    let o_rem = Manual.dst_rem
    let flush k r =               (* get free space in [r.o] and [k]ontinue. *)
      match r.dst with
      | `Manual -> partial k r
      | `Buffer b -> Buffer.add_substring b r.o 0 r.o_pos; r.o_pos <- 0; k r
      | `Channel oc -> output oc r.o 0 r.o_pos; r.o_pos <- 0; k r
      | `Other -> assert false

    let rec writeb b k r =                 (* write byte [b] and [k]ontinue. *)
      if r.o_pos > r.o_max then flush (writeb b k) r else
      (unsafe_set_byte r.o r.o_pos b; r.o_pos <- r.o_pos + 1; k r)

    let rec writes s j l k r =  (* write [l] bytes from [s] starting at [j]. *)
      let rem = o_rem r in 
      if rem >= l
      then (unsafe_blit s j r.o r.o_pos l; r.o_pos <- r.o_pos + l; k r)
      else begin 
        unsafe_blit s j r.o r.o_pos rem; r.o_pos <- r.o_pos + rem; 
        flush (writes s (j + rem) (l - rem) k) r
      end

    let rec writebuf buf j l k r = (* write [l] bytes from [buf] start at [j].*)
      let rem = o_rem r in
      if rem >= l 
      then (Buffer.blit buf j r.o r.o_pos l; r.o_pos <- r.o_pos + l; k r)
      else begin 
        Buffer.blit buf j r.o r.o_pos rem; r.o_pos <- r.o_pos + rem; 
        flush (writebuf buf (j + rem) (l - rem) k) r
      end 
  end
end

type renderer = Vgr.t

(*---------------------------------------------------------------------------
   Copyright 2013 Daniel C. Bünzli.
   All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:
     
   1. Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

   2. Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

   3. Neither the name of Daniel C. Bünzli nor the names of
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  ---------------------------------------------------------------------------*)

