(*----------------------------------------------------------------------------
 *  Copyright (c) 2017 Inhabited Type LLC.
 *  Copyright (c) 2019 Antonio N. Monteiro.
 *
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without
 *  modification, are permitted provided that the following conditions
 *  are met:
 *
 *  1. Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *
 *  2. Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 *  3. Neither the name of the author nor the names of his contributors
 *     may be used to endorse or promote products derived from this software
 *     without specific prior written permission.
 *
 *  THIS SOFTWARE IS PROVIDED BY THE CONTRIBUTORS ``AS IS'' AND ANY EXPRESS
 *  OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 *  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 *  DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR
 *  ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 *  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 *  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 *  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 *  STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 *  ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *  POSSIBILITY OF SUCH DAMAGE.
 *---------------------------------------------------------------------------*)

module Writer = Serialize.Writer

type _ t =
  { faraday : Faraday.t
  ; mutable read_scheduled : bool
  ; mutable write_final_data_frame : bool
  ; mutable on_eof : unit -> unit
  ; mutable on_read : Bigstringaf.t -> off:int -> len:int -> unit
  ; buffered_bytes : int ref
  ; ready_to_write : unit -> unit
  }

let default_on_eof = Sys.opaque_identity (fun () -> ())

let default_on_read = Sys.opaque_identity (fun _ ~off:_ ~len:_ -> ())

let default_ready_to_write = Sys.opaque_identity (fun () -> ())

let create buffer ready_to_write =
  { faraday = Faraday.of_bigstring buffer
  ; read_scheduled = false
  ; write_final_data_frame = true
  ; on_eof = default_on_eof
  ; on_read = default_on_read
  ; buffered_bytes = ref 0
  ; ready_to_write
  }

let create_empty () =
  let t = create Bigstringaf.empty default_ready_to_write in
  Faraday.close t.faraday;
  t

let empty = create_empty ()

let is_empty t = if (Bigstringaf.length t.faraday) = 0 then true else false

let ready_to_write t = t.ready_to_write ()

let write_char t c =
  Faraday.write_char t.faraday c;
  ready_to_write t

let write_string t ?off ?len s =
  Faraday.write_string ?off ?len t.faraday s;
  ready_to_write t

let write_bigstring t ?off ?len b =
  Faraday.write_bigstring ?off ?len t.faraday b;
  ready_to_write t

let schedule_bigstring t ?off ?len (b : Bigstringaf.t) =
  Faraday.schedule_bigstring ?off ?len t.faraday b;
  ready_to_write t

let flush t kontinue =
  Faraday.flush t.faraday kontinue;
  ready_to_write t

let is_closed t = Faraday.is_closed t.faraday

let close_writer t =
  Faraday.close t.faraday;
  ready_to_write t

let unsafe_faraday t = t.faraday

let rec do_execute_read t on_eof on_read =
  match Faraday.operation t.faraday with
  | `Yield ->
    ()
  | `Close ->
    t.read_scheduled <- false;
    t.on_eof <- default_on_eof;
    t.on_read <- default_on_read;
    on_eof ()
  | `Writev [] ->
    assert false
  | `Writev (iovec :: _) ->
    t.read_scheduled <- false;
    t.on_eof <- default_on_eof;
    t.on_read <- default_on_read;
    let { Httpaf.IOVec.buffer; off; len } = iovec in
    Faraday.shift t.faraday len;
    on_read buffer ~off ~len;
    execute_read t

and execute_read t =
  if t.read_scheduled then do_execute_read t t.on_eof t.on_read

let schedule_read t ~on_eof ~on_read =
  if t.read_scheduled then
    failwith "Body.schedule_read: reader already scheduled";
  if is_closed t then
    do_execute_read t on_eof on_read
  else (
    t.read_scheduled <- true;
    t.on_eof <- on_eof;
    t.on_read <- on_read)

let has_pending_output t =
  (* Force another write poll to make sure that the final chunk is emitted for
   * chunk-encoded bodies. *)
  Faraday.has_pending_output t.faraday
  || (Faraday.is_closed t.faraday && t.write_final_data_frame)

let close_reader t =
  Faraday.close t.faraday;
  execute_read t

let transfer_to_writer t writer ~max_frame_size ~max_bytes stream_id =
  let faraday = t.faraday in
  match Faraday.operation faraday with
  | `Yield ->
    0
  | `Close ->
    if t.write_final_data_frame then (
      t.write_final_data_frame <- false;

      (* Note: we don't need to check if we're flow-controlled here.
       *
       * From RFC7540§6.9.1:
       *   Frames with zero length with the END_STREAM flag set (that is, an
       *   empty DATA frame) MAY be sent if there is no available space in
       *   either flow-control window. *)
      let frame_info =
        Writer.make_frame_info
          ~max_frame_size
          ~flags:Flags.(set_end_stream default_flags)
          stream_id
      in
      Writer.schedule_data writer frame_info ~len:0 Bigstringaf.empty);
    0
  | `Writev iovecs ->
    let buffered = t.buffered_bytes in
    let iovecs = Httpaf.IOVec.shiftv iovecs !buffered in
    let lengthv = Httpaf.IOVec.lengthv iovecs in
    let writev_len = if max_bytes < lengthv then max_bytes else lengthv in
    buffered := !buffered + writev_len;
    let frame_info = Writer.make_frame_info ~max_frame_size stream_id in
    Writer.schedule_iovecs writer frame_info ~len:writev_len iovecs;
    Writer.flush writer (fun () ->
        Faraday.shift faraday writev_len;
        buffered := !buffered - writev_len);
    writev_len
