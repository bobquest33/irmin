(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open IrminTypes

(* From cstruct *)
type buffer = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

let create len ready = {
  buffer = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len;
  offset = 0;
  ready;
}

external unsafe_blit_string_to_bigstring
  : string -> int -> buffer -> int -> int -> unit
  = "caml_blit_string_to_bigstring" "noalloc"

external unsafe_blit_bigstring_to_string
  : buffer -> int -> string -> int -> int -> unit
  = "caml_blit_bigstring_to_string" "noalloc"

let poll t len =
  for_lwt i = t.offset to t.offset + len do
    t.ready i
  done

let set t len fn =
  lwt () = poll t len in
  fn t;
  t.offset <- t.offset + len;
  Lwt.return ()

let set_char t c =
  set t 1 (fun t ->
      EndianBigstring.BigEndian.set_char t.buffer t.offset c;
    )

let set_uint8 t c =
  Printf.printf "t.[%d] <- %dn%!" t.offset c;
  set t 1 (fun t ->
      EndianBigstring.BigEndian.set_int8 t.buffer t.offset c;
    )

let set_uint16 t c =
  set t 2 (fun t ->
      EndianBigstring.BigEndian.set_int16 t.buffer t.offset c;
    )

let set_uint32 t c =
  set t 4 (fun t ->
      EndianBigstring.BigEndian.set_int32 t.buffer t.offset c;
    )

let set_uint64 t c =
  set t 8 (fun t ->
      EndianBigstring.BigEndian.set_int64 t.buffer t.offset c;
    )

let set_string t str =
  let len = String.length str in
  set t len (fun t ->
      unsafe_blit_string_to_bigstring str 0 t.buffer t.offset len;
    )

let get t n fn =
  lwt () = poll t n in
  let i = fn t in
  t.offset <- t.offset + n;
  Lwt.return i

let get_char t =
  get t 1 (fun t ->
      EndianBigstring.BigEndian.get_char t.buffer t.offset
    )

let get_uint8 t =
  get t 1 (fun t ->
      EndianBigstring.BigEndian.get_uint8 t.buffer t.offset
    )

let get_uint16 t =
  get t 2 (fun t ->
      EndianBigstring.BigEndian.get_uint16 t.buffer t.offset
    )

let get_uint32 t =
  get t 4 (fun t ->
      EndianBigstring.BigEndian.get_int32 t.buffer t.offset
    )

let get_uint64 t =
  get t 8 (fun t ->
      EndianBigstring.BigEndian.get_int64 t.buffer t.offset
    )

let get_string t len =
  let str = String.create len in
  get t len (fun t ->
      unsafe_blit_bigstring_to_string t.buffer t.offset str 0 len;
      str
    )

module OCamlList = List
module OCamlString = String

exception Parse_error of string

let dump_buffer ~all t =
  let length = Bigarray.Array1.dim t.buffer in
  let str =
    if all then String.create length
    else String.create (length - t.offset) in
  if all then
    unsafe_blit_bigstring_to_string t.buffer 0 str 0 length
  else
    unsafe_blit_bigstring_to_string t.buffer t.offset str 0 length;
  Printf.eprintf "%16s\027[33m[[ offset:%d len:%d %S ]]\027[m\n" ""
    t.offset length str

let parse_error_buf buf fmt =
  Printf.kprintf (fun str ->
      Printf.eprintf "\027[31mParse error:\027[m %s\n" str;
      dump_buffer ~all:true buf;
      raise_lwt (Parse_error str)
    ) fmt

let parse_error fmt =
  Printf.kprintf (fun str ->
      Printf.eprintf "\027[31mParse error:\027[m %s\n" str;
      raise (Parse_error str)
    ) fmt

module List  (E: BASE) = struct

  let debug fmt = IrminMisc.debug "IO.LIST" fmt

  type t = E.t list

  let pretty t =
    String.concat "\n" (OCamlList.rev (OCamlList.rev_map E.pretty t))

  let to_json t =
    `A (OCamlList.rev (OCamlList.rev_map E.to_json t))

  let of_json = function
    | `A l -> OCamlList.rev (List.rev_map E.of_json l)
    | _    -> parse_error "List.of_json"

  let sizeof l =
    List.fold_left (fun acc e ->
        acc + E.sizeof e
      ) 4 l

  let read buf =
    debug "read";
    lwt keys = get_uint32 buf in
    let rec aux acc i =
      if i <= 0 then Lwt.return (OCamlList.rev acc)
      else
        lwt t = E.read buf in
        aux (t :: acc) (i-1) in
    aux [] (Int32.to_int keys)

  let write buf t =
    debug "write";
    let len = Int32.of_int (List.length t) in
    lwt () = set_uint32 buf len in
    Lwt_list.iter_s (E.write buf) t

end

module Option (E: BASE) = struct

  let debug fmt = IrminMisc.debug "IO.OPTION" fmt

  type t = E.t option

  let pretty = function
    | None   -> "<none>"
    | Some e -> E.pretty e

  let to_json = function
    | None   -> `Null
    | Some e -> E.to_json e

  let of_json = function
    | `Null -> None
    | j     -> Some (E.of_json j)

  module L = List(E)

  let sizeof = function
    | None   -> 4
    | Some e -> 4 + E.sizeof e

  let read buf =
    debug "read";
    lwt l = L.read buf in
    match l with
    | []  -> Lwt.return None
    | [e] -> Lwt.return (Some e)
    | _   -> parse_error_buf buf "Option.read"

  let write buf t =
    debug "write";
    let l = match t with
      | None   -> []
      | Some e -> [e] in
    L.write buf l

end

module Pair (K: BASE) (V: BASE) = struct

  let debug fmt = IrminMisc.debug "IO-PAIR" fmt

  type t = K.t * V.t

  let pretty (key, value) =
    Printf.sprintf "%s:%s" (K.pretty key) (V.pretty value)

  let to_json (key, value) =
    `O [ ("tag", K.to_json key);
         ("key", V.to_json value)]

  let of_json = function
    | `O l ->
      let key =
        try OCamlList.assoc "tag" l
        with Not_found -> parse_error "Product.of_json: missing tag" in
      let value =
        try OCamlList.assoc "key" l
        with Not_found -> parse_error "Product.of_json: missing key" in
      (K.of_json key, V.of_json value)
    | _ -> parse_error "Product.of_json: not an object"

  let sizeof (key, value) =
    K.sizeof key + V.sizeof value

  let read buf =
    debug "read";
    lwt tag = K.read buf in
    lwt key = V.read buf in
    Lwt.return (tag, key)

  let write buf (key, value) =
    debug "write";
    lwt () = K.write buf key in
    V.write buf value

end

module type STRINGABLE = sig
  type t
  val to_string: t -> string
  val of_string: string -> t
end

module String  (S: STRINGABLE) = struct

  let debug fmt = IrminMisc.debug "IO.STRING" fmt

  type t = S.t

  let pretty s =
    Printf.sprintf "%S" (S.to_string s)

  let to_json t =
    IrminJSON.of_string (S.to_string t)

  let of_json j =
    S.of_string (IrminJSON.to_string j)

  let sizeof s =
    4 + String.length (S.to_string s)

  let read buf =
    debug "read";
    lwt len = get_uint32 buf in
    lwt str = get_string buf (Int32.to_int len) in
    Lwt.return (S.of_string str)

  let write buf t =
    debug "write";
    let str = S.to_string t in
    let len = String.length str in
    lwt () = set_uint32 buf (Int32.of_int len) in
    set_string buf str

end

module Lwt_channel = struct

  let debug fmt = IrminMisc.debug "IO-LWT" fmt

  type t = {
    fd  : Lwt_unix.file_descr;
    name: string;
  }

  let create fd name = { fd; name }

  let name t = t.name

  let close t = Lwt_unix.close t.fd

  (* XXX: not optimized *)
  let ready _ _ = Lwt.return ()

  let read_string t len =
    debug "read_string %s %d" t.name len;
    let buf = OCamlString.create len in
    let rec rread fd buf ofs len =
      lwt n = Lwt_unix.read fd buf ofs len in
      if n = 0 then raise End_of_file;
      if n < len then rread fd buf (ofs + n) (len - n) else Lwt.return () in
    lwt () = rread t.fd buf 0 len in
    Lwt.return buf

  let read_buf t len =
    debug "read_buf %s %d" t.name len;
    let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len in
    let rec rread fd buf ofs len =
      lwt n = Lwt_bytes.read fd buf ofs len in
      if n = 0 then raise End_of_file;
      if n < len then rread fd buf (ofs + n) (len - n) else Lwt.return () in
    lwt () = rread t.fd buf 0 len in
    let buffer = {
      buffer = buf;
      offset = 0;
      ready  = ready t.fd;
    } in
    Lwt.return buffer

  let write_string t buf =
    debug "write_string %s" t.name;
    let rec rwrite fd buf ofs len =
      lwt n = Lwt_unix.write fd buf ofs len in
      if n = 0 then raise End_of_file;
      if n < len then rwrite fd buf (ofs + n) (len - n) else Lwt.return () in
    rwrite t.fd buf 0 (OCamlString.length buf)

  let write_buf t buf len =
    debug "write_buf %s %d" t.name len;
    dump_buffer ~all:true buf;
    let rec rwrite fd buf ofs len =
      lwt n = Lwt_bytes.write fd buf ofs len in
      if n = 0 then raise End_of_file;
      if n < len then rwrite fd buf (ofs + n) (len - n) else Lwt.return () in
    rwrite t.fd buf.buffer buf.offset len

  let read_length t =
    debug "read_size %s" t.name;
    lwt str = read_string t 4 in
    let len = EndianString.BigEndian.get_int32 str 0 in
    Lwt.return (Int32.to_int len)

  let write_length t len =
    debug "write_size %s %dl" t.name len;
    let str = OCamlString.create 4 in
    EndianString.BigEndian.set_int32 str 0 (Int32.of_int len);
    write_string t str

end

module Channel (B: BASE) = struct

  let debug = IrminMisc.debug "IO-CHANNEL"

  include B

  type channel = Lwt_channel.t

  let read_fd fd =
    debug "read_fd %s" (Lwt_channel.name fd);
    lwt len = Lwt_channel.read_length fd in
    lwt buf = Lwt_channel.read_buf fd len in
    B.read buf

  let write_fd fd t =
    debug "write_fd %s" (Lwt_channel.name fd);
    let len = B.sizeof t in
    let buf = create len (Lwt_channel.ready fd) in
    lwt () = Lwt_channel.write_length fd len in
    Lwt_channel.write_buf fd buf len

end
