(*----------------------------------------------------------------------------
    Copyright (c) 2016 Inhabited Type LLC.

    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    3. Neither the name of the author nor the names of his contributors
       may be used to endorse or promote products derived from this software
       without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE CONTRIBUTORS ``AS IS'' AND ANY EXPRESS
    OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR
    ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
    OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
    STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
  ----------------------------------------------------------------------------*)

type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

type input =
  [ `String    of string
  | `Bigstring of bigstring ]

let input_length input =
  match input with
  | `String s    -> String.length s
  | `Bigstring b -> Bigarray.Array1.dim b

module Input = struct
  type t =
    { mutable commit_pos : int
    ; initial_commit_pos : int
    ; input : input
    }

  let create initial_commit_pos input =
    { commit_pos = initial_commit_pos
    ; initial_commit_pos
    ; input
    }

  let length { initial_commit_pos; input}  =
    input_length input + initial_commit_pos

  let committed_bytes { commit_pos; initial_commit_pos } =
    commit_pos - initial_commit_pos

  let initial_commit_pos t =
    t.initial_commit_pos

  let commit_pos t =
    t.commit_pos

  let uncommitted_bytes t =
    input_length t.input - commit_pos t

  let substring { initial_commit_pos; input } pos len =
    let off = pos - initial_commit_pos in
    match input with
    | `String    s -> String.sub s off len
    | `Bigstring b -> Cstruct.to_string (Cstruct.of_bigarray ~off ~len b)

  let get_char { initial_commit_pos; input } pos =
    let pos = pos - initial_commit_pos in
    match input with
    | `String s    -> String.unsafe_get s pos
    | `Bigstring b -> Bigarray.Array1.unsafe_get b pos

  let count_while { initial_commit_pos; input } pos f =
    let i = ref (pos - initial_commit_pos) in
    let len = input_length input in
    begin match input with
    | `String s    ->
      while !i < len && f (String.unsafe_get s !i) do incr i; done
    | `Bigstring b ->
      while !i < len && f (Bigarray.Array1.unsafe_get b !i) do incr i; done
    end;
    !i - (pos - initial_commit_pos)

  let commit t pos =
    t.commit_pos <- pos

end

type _unconsumed =
  { buffer : bigstring
  ; off : int
  ; len : int }

(* Encapsulate state with an object, Smalltalk style. Callers are not putting
 * this in tight loops so none of that performance jibber jabber. *)
class buffer cstruct =
  let internal = ref cstruct in
  let _writable_space t =
    let { Cstruct.buffer; len } = !internal in
    Bigarray.Array1.dim buffer - len
  in
  let _trailing_space t =
    let { Cstruct.buffer; off; len } = !internal in
    Bigarray.Array1.dim buffer - (off + len)
  in
  let compress () =
    let off, len = 0, Cstruct.len !internal in
    let buffer = Cstruct.of_bigarray ~off ~len (!internal).Cstruct.buffer in
    Cstruct.blit !internal 0 buffer 0 len;
    internal := buffer
  in
  let grow to_copy =
    let init_size = Bigarray.Array1.dim (!internal).Cstruct.buffer in
    let size  = ref init_size in
    let space = _writable_space () in
    while space + !size - init_size < to_copy do
      size := (3 * !size) / 2
    done;
    let buffer = Cstruct.(set_len (create !size)) (!internal).Cstruct.len in
    Cstruct.blit !internal 0 buffer 0 (!internal).Cstruct.len;
    internal := buffer
  in
  let ensure_space len =
    (* XXX(seliopou): could use some heuristics here to determine whether its
     * worth it to compress or grow *)
    begin if _trailing_space () >= len then
      () (* there is enough room at the end *)
    else if _writable_space () >= len then
      compress ()
    else
      grow len
    end;
    (* The above will grow the internal buffer but not change the length of the
     * view into the buffer. So it's necesasry to add the desired length at
     * this point. *)
    internal := Cstruct.add_len !internal len
  in
object(self)
  method feed (input:input) =
    let len = input_length input in
    ensure_space len;
    let off = Cstruct.len !internal - len in
    match input with
    | `String s ->
      let allocator _ = Cstruct.sub !internal off len in
      ignore (Cstruct.of_string ~allocator s)
    | `Bigstring b ->
      Cstruct.blit (Cstruct.of_bigarray b) 0 !internal off len

  method commit len =
    internal := Cstruct.shift !internal len

  method internal =
    let { Cstruct.buffer; off; len } = !internal in
    Bigarray.Array1.sub buffer off len

  method uncommitted_with_shift n =
    let { Cstruct.buffer; off; len } = Cstruct.shift !internal n in
    { buffer; off; len }

  method uncommitted =
    self#uncommitted_with_shift 0
end

let buffer_of_cstruct cstruct =
  new buffer cstruct

let buffer_of_size size =
  new buffer Cstruct.(set_len (create size) 0)

let buffer_of_bigstring ?(off=0) ?len bigstring =
  buffer_of_cstruct (Cstruct.of_bigarray ~off ?len bigstring)

let buffer_of_unconsumed { buffer; off; len} =
  buffer_of_bigstring ~off ~len buffer

module Unbuffered = struct
  type more =
    | Complete
    | Incomplete

  type 'a state =
    | Partial of 'a partial
    | Done    of 'a * int
    | Fail    of string list * string
  and 'a partial =
    { committed : int
    ; continue  : input -> more -> 'a state }

  type 'a with_input =
    Input.t ->  int -> more -> 'a

  type 'a failure = (string list -> string -> 'a state) with_input
  type ('a, 'r) success = ('a -> 'r state) with_input

  let fail_k    buf pos _ marks msg = Fail(marks, msg)
  let succeed_k buf pos _       v   = Done(v, pos - Input.initial_commit_pos buf)

  type 'a t =
    { run : 'r. ('r failure -> ('a, 'r) success -> 'r state) with_input }

  let fail_to_string marks err =
    String.concat " > " marks ^ ": " ^ err

  let state_to_option = function
    | Done(v, _) -> Some v
    | _          -> None

  let state_to_result = function
    | Done(v, _)        -> Result.Ok v
    | Partial _         -> Result.Error "incomplete input"
    | Fail (marks, err) -> Result.Error (fail_to_string marks err)

  let parse ?(input=`String "") p =
    p.run (Input.create 0 input) 0 Incomplete fail_k succeed_k

  let parse_only p input =
    state_to_result (p.run (Input.create 0 input) 0 Complete fail_k succeed_k)
end

type more = Unbuffered.more =
  | Complete
  | Incomplete

type 'a state = 'a Unbuffered.state =
  | Partial of 'a partial
  | Done    of 'a * int
  | Fail    of string list * string
and 'a partial = 'a Unbuffered.partial =
  { committed : int
  ; continue  : input -> more -> 'a state }

type 'a t = 'a Unbuffered.t =
  { run : 'r. ('r Unbuffered.failure -> ('a, 'r) Unbuffered.success -> 'r state) Unbuffered.with_input }


module Buffered = struct
  type unconsumed = _unconsumed =
    { buffer : bigstring
    ; off : int
    ; len : int }

  type 'a state =
    | Partial of ([ input | `Eof ] -> 'a state)
    | Done    of 'a * unconsumed
    | Fail    of string list * string * unconsumed

  let from_unbuffered_state ~f buffer = function
    | Unbuffered.Partial p      -> Partial (f p)
    | Unbuffered.Done (v , con) -> Done(v, buffer#uncommitted_with_shift con)
    | Unbuffered.Fail (ms, err) -> Fail(ms, err, buffer#uncommitted)

  let parse ?(initial_buffer_size=0x1000) ?(input=`String "") p =
    if initial_buffer_size < 1 then
      failwith "parse: invalid argument, initial_buffer_size < 1";
    let initial_buffer_size = max initial_buffer_size (input_length input) in
    let buffer = buffer_of_size initial_buffer_size in
    buffer#feed input;
    let rec f p =
      ();
      function
      | `Eof  -> from_unbuffered_state buffer ~f (p.continue (`Bigstring buffer#internal) Complete)
      | #input as input ->
        buffer#commit p.committed;
        buffer#feed input;
        from_unbuffered_state buffer ~f (p.continue (`Bigstring buffer#internal) Incomplete)
    in
    from_unbuffered_state buffer ~f (Unbuffered.parse ~input:(`Bigstring buffer#internal) p)

  let feed state input =
    match state with
    | Partial k            -> k input
    | Fail(marks, msg, us) ->
      begin match input with
      | `Eof   -> state
      | #input as input ->
        let buffer = buffer_of_unconsumed us in
        buffer#feed input;
        Fail(marks, msg, buffer#uncommitted)
      end
    | Done(v, us) ->
      begin match input with
      | `Eof   -> state
      | #input as input ->
        let buffer = buffer_of_unconsumed us in
        buffer#feed input;
        Done(v, buffer#uncommitted)
      end

  let state_to_option = function
    | Done(v, _) -> Some v
    | _          -> None

  let state_to_result = function
    | Partial _           -> Result.Error "incomplete input"
    | Done(v, _)          -> Result.Ok v
    | Fail(marks, err, _) -> Result.Error (Unbuffered.fail_to_string marks err)

  let state_to_unconsumed = function
    | (Done(_, us) | Fail(_, _, us)) -> Some us
    | _                              -> None

end

let cons x xs = x :: xs

module Z = struct
  type 'a internal =
    | D of 'a * int
    | F of string list * string
    | P of 'a t * int
  and 'a t =
    Input.t -> int -> more -> 'a internal

  type 'a state =
    | Partial of 'a partial
    | Done    of 'a
    | Fail    of string list * string
  and 'a partial =
    input -> more -> 'a state

  let fail_to_string marks err =
    String.concat " > " marks ^ ": " ^ err

  let rec _parse p input pos more =
    match p input pos more with
    | D(v, _)    -> Done v
    | F(ms, msg) -> Fail(ms, msg)
    | P(p', pos) ->
      let committed = Input.committed_bytes input in
      Partial (fun input more ->
        _parse p' (Input.create committed input) pos more)

  let rec parse ?(input=`String "") p =
    _parse p Input.(create 0 input) 0 Incomplete

  let parse_only p input =
    match _parse p Input.(create 0 input) 0 Complete with
    | Done v        -> Result.Ok v
    | Fail(ms, msg) -> Result.Error (fail_to_string ms msg)
    | _             -> Result.Error "not enough input"

  let return v =
    fun input pos more -> D(v, pos)

  let fail (msg:string) =
    fun input pos more -> F([], msg)

  let rec (>>=) p f =
    fun input pos more ->
      match p input pos more with
      | D(a, pos') -> f a input pos' more
      | F(ms, msg) -> F(ms, msg)
      | P(k, pos)  -> P(k >>= f, pos)

  let rec (>>|) p f =
    fun input pos more ->
      match p input pos more with
      | D(a, pos') -> D(f a, pos')
      | F(ms, msg) -> F(ms, msg)
      | P(k, pos)  -> P(k >>| f, pos)

  let rec ( *>) p1 p2 =
    fun input pos more ->
      match p1 input pos more with
      | D(_, pos)  -> p2 input pos more
      | F(ms, msg) -> F(ms, msg)
      | P(k, pos)  -> P(k *> p2, pos)

  let rec (<* ) p1 p2 =
    fun input pos more ->
      match p1 input pos more with
      | D(x, pos)  ->
        begin match p2 input pos more with
        | D(_, pos)  -> D(x, pos)
        | F(ms, msg) -> F(ms, msg)
        | P(k, pos)  -> P(k >>| (fun _ -> x), pos)
        end
      | F(ms, msg) -> F(ms, msg)
      | P(k, pos)  -> P(k <* p2, pos)

  let rec (<?>) p mark =
    fun input pos more ->
      match p input pos more with
      | D(v, pos)  -> D(v, pos)
      | F(ms, msg) -> F(mark::ms, msg)
      | P(k, pos)  -> P(k <?> mark, pos)

  let rec (<|>) p q =
    fun input pos more ->
      match p input pos more with
      | D(v, pos)  -> D(v, pos)
      | F _        -> q input pos more
      | P(k, pos) -> P(k <|> q, pos)

  let choice ps =
    List.fold_right (<|>) ps (fail "empty")

  let commit =
    fun input pos more ->
      D((), pos)

  let (<$>) f p = p >>| f
  let lift  f p = p >>| f

  let rec lift2 f p1 p2 =
    fun input pos more ->
      match p1 input pos more with
      | D(x, pos)  ->
        begin match p2 input pos more with
        | D(y, pos)  -> D(f x y, pos)
        | F(ms, msg) -> F(ms, msg)
        | P(k, pos)  -> P(k >>| (fun y -> f x y), pos)
        end
      | F(ms, msg) -> F(ms, msg)
      | P(k, pos)  -> P(lift2 f k p2, pos)

  let rec lift3 f p1 p2 p3 =
    fun input pos more ->
      match p1 input pos more with
      | D(x, pos)      ->
        begin match p2 input pos more with
        | D(y, pos)  ->
          begin match p3 input pos more with
          | D(z, pos)  -> D(f x y z, pos)
          | F(ms, msg) -> F(ms, msg)
          | P(k, pos)  -> P(lift (fun z -> f x y z) k, pos)
          end
        | F(ms, msg) -> F(ms, msg)
        | P(k, pos)  -> P(lift2 (fun y z -> f x y z) k p3, pos)
        end
      | F(ms, msg) -> F(ms, msg)
      | P(k, pos)  -> P(lift3 f k p2 p3, pos)

  let rec lookahead ?back_to p =
    fun input pos more ->
      let back_to =
        match back_to with
        | None -> pos
        | Some pos -> pos
      in
      match p input pos more with
      | D(v, _)    -> D(v, back_to)
      | F(ms, msg) -> F(ms, msg)
      | P(k, pos)  -> P(lookahead ~back_to k, pos)

  let _char ~msg f =
    let rec go input pos more =
      if pos < Input.length input then
        match f (Input.get_char input pos) with
        | None -> F([], msg)
        | Some v -> D(v, pos + 1)
      else if more = Incomplete then
        F([], msg)
      else
        P(go, pos)
    in
    go

  let rec peek_char =
    fun input pos more ->
      if pos < Input.length input then
        D(Some (Input.get_char input pos), pos)
      else if more = Incomplete then
        P(peek_char, pos)
      else
        D(None, pos)

  let rec peek_char_fail =
    fun input pos more ->
      if pos < Input.length input then
        D(Input.get_char input pos, pos)
      else if more = Incomplete then
        P(peek_char_fail, pos)
      else
        F([], "peek_char_fail")

  let rec peek_string n =
    let rec go input pos more =
      if pos + n <= Input.length input then
        D(Input.substring input pos n, pos)
      else if more = Incomplete then
        P(go, pos)
      else
        F([], "peek_string")
    in
    go

  let char c =
    let msg = String.make 1 c in
    let rec go input pos more =
      if pos < Input.length input then
        if c = Input.get_char input pos then
          D(c, pos + 1)
        else
          F([], msg)
      else if more = Incomplete then
        P(go, pos)
      else
        F([], msg)
    in
    go

  let not_char c =
    let msg = String.make 1 c in
    let rec go input pos more =
      if pos < Input.length input then
        let c' = Input.get_char input pos in
        if c <> c' then
          D(c', pos + 1)
        else
          F([], msg)
      else if more = Incomplete then
        P(go, pos)
      else
        F([], msg)
    in
    go

  let any_char =
    let rec go input pos more =
      if pos < Input.length input then
        D(Input.get_char input pos, pos + 1)
      else if more = Incomplete then
        P(go, pos)
      else
        F([], "any_char")
    in
    go

  (* XXX(seliopou): manually inline if necessary. *)
  let satisfy f = _char ~msg:"satisfy" (fun c -> if f c then Some c  else None)
  let skip    f = _char ~msg:"skip"    (fun c -> if f c then Some () else None)

  let string_ f s =
    let len = String.length s in
    let rec go input pos more =
      if pos + len <= Input.length input then
        let s' = Input.substring input pos len in
        if f s = f s' then
          D(s', pos + len)
        else
          F([], "string")
      else if more = Incomplete then
        P(go, pos)
      else
        F([], Printf.sprintf "%S" s)
    in
    go

  let string    s = string_ (fun x -> x) s
  let string_ci s = string_ String.lowercase s

  let count_while msg f k =
    let rec go acc input pos more =
      let n = Input.count_while input pos f in
      let acc' = n + acc in
      if pos + acc' < Input.length input || more = Complete then
        match k input pos acc' with
        | None   -> F([], msg)
        | Some v -> D(v, pos + acc')
      else
        P(go acc', pos)
    in
    go 0

  let take n =
    let rec go input pos more =
      if pos + n <= Input.length input then
        D(Input.substring input pos n, pos + n)
      else if more = Complete then
        F([], "take")
      else
        P(go, pos)
    in
    go

  let take_while f =
    count_while "take_while" f (fun input pos len ->
      Some(Input.substring input pos len))

  let take_while1 f =
    count_while "take_while1" f (fun input pos len ->
      if len = 0 then None else Some(Input.substring input pos len))

  let skip_while f =
    count_while "skip_while" f (fun _ _ _ -> Some ())

  let take_till f =
    take_while (fun c -> not (f c))

  let rec take_rest = 
    fun input pos more ->
      let len = Input.length input in
      if pos < len then
        let chunk = Input.substring input pos (len - pos) in
        lift (fun cs -> chunk :: cs) take_rest input len more
      else if more = Complete then
        D([], pos)
      else
        P(take_rest, pos)

  let rec end_of_input =
    fun input pos more ->
      if pos < Input.length input then
        F([], "end_of_input")
      else if more = Complete then
        D((), pos)
      else
        P(end_of_input, pos)

  let fix f =
    let rec p = lazy (f r)
    and r = fun input pos more ->
      Lazy.force p input pos more
    in
    r

  let count n p =
    if n < 0 then
      failwith "count: invalid argument, n < 0";
    let rec loop = function
      | 0 -> return []
      | n -> lift2 cons p (loop (n - 1))
    in
    loop n

  let many p =
    fix (fun m ->
      (lift2 cons p m) <|> return [])

  let many1 p =
    lift2 cons p (many p)

  let many_till p t =
    fix (fun m ->
      (lift2 cons p m) <|> (t *> return []))

  let sep_by1 s p =
    fix (fun m ->
      lift2 cons p ((s *> m) <|> return []))

  let sep_by s p =
    (lift2 cons p ((s *> sep_by1 s p) <|> return [])) <|> return []


  let rec skip_many p =
    fun input pos more ->
      match p input pos more with
      | D(_    , pos) -> skip_many p input pos more
      | F(marks, msg) -> D((), pos)
      | P(k    , pos) -> P(k *> skip_many p, pos)

  let skip_many1 p =
    p *> skip_many p
end

let parse_only p input =
  Unbuffered.parse_only p input

let return =
  fun v ->
    { run = fun input pos more _fail succ ->
      succ input pos more v }

let fail msg =
  { run = fun input pos more fail succ ->
    fail input pos more [] msg
  }

let (>>=) p f =
  { run = fun input pos more fail succ ->
    let succ' input' pos' more' v = (f v).run input' pos' more' fail succ in
    p.run input pos more fail succ'
  }

let (>>|) p f =
  { run = fun input pos more fail succ ->
    let succ' input' pos' more' v = succ input' pos' more' (f v) in
    p.run input pos more fail succ'
  }

let (<$>) f m =
  m >>| f

let (<*>) f m =
  (* f >>= fun f -> m >>| f *)
  { run = fun input pos more fail succ ->
    let succ0 input0 pos0 more0 f =
      let succ1 input1 pos1 more1 m = succ input1 pos1 more1 (f m) in
      m.run input0 pos0 more0 fail succ1
    in
    f.run input pos more fail succ0 }

let lift f m =
  f <$> m

let lift2 f m1 m2 =
  { run = fun input pos more fail succ ->
    let succ1 input1 pos1 more1 m1 =
      let succ2 input2 pos2 more2 m2 = succ input2 pos2 more2 (f m1 m2) in
      m2.run input1 pos1 more1 fail succ2
    in
    m1.run input pos more fail succ1 }

let lift3 f m1 m2 m3 =
  { run = fun input pos more fail succ ->
    let succ1 input1 pos1 more1 m1 =
      let succ2 input2 pos2 more2 m2 =
        let succ3 input3 pos3 more3 m3 =
          succ input3 pos3 more3 (f m1 m2 m3) in
        m3.run input2 pos2 more2 fail succ3 in
      m2.run input1 pos1 more1 fail succ2
    in
    m1.run input pos more fail succ1 }

let lift4 f m1 m2 m3 m4 =
  { run = fun input pos more fail succ ->
    let succ1 input1 pos1 more1 m1 =
      let succ2 input2 pos2 more2 m2 =
        let succ3 input3 pos3 more3 m3 =
          let succ4 input4 pos4 more4 m4 =
            succ input4 pos4 more4 (f m1 m2 m3 m4) in
          m4.run input3 pos3 more3 fail succ4 in
        m3.run input2 pos2 more2 fail succ3 in
      m2.run input1 pos1 more1 fail succ2
    in
    m1.run input pos more fail succ1 }

let ( *>) a b =
  (* a >>= fun _ -> b *)
  { run = fun input pos more fail succ ->
    let succ' input' pos' more' _ = b.run input' pos' more' fail succ in
    a.run input pos more fail succ'
  }

let (<* ) a b =
  (* a >>= fun x -> b >>| fun _ -> x *)
  { run = fun input pos more fail succ ->
    let succ0 input0 pos0 more0 x =
      let succ1 input1 pos1 more1 _ = succ input1 pos1 more1 x in
      b.run input0 pos0 more0 fail succ1
    in
    a.run input pos more fail succ0 }

let (<?>) p mark =
  { run = fun input pos more fail succ ->
    let fail' input' pos' more' marks msg =
      fail input' pos' more' (mark::marks) msg in
    p.run input pos more fail' succ
  }

let (<|>) p q =
  { run = fun input pos more fail succ ->
    let fail' input' pos' more' marks msg =
      (* The only two constructors that introduce new failure continuations are
       * [<?>] and [<|>]. If the initial input position is less than the length
       * of the committed input, then calling the failure continuation will
       * have the effect of unwinding all choices and collecting marks along
       * the way. *)
      if pos < Input.commit_pos input' then
        fail input' pos' more marks msg
      else
        q.run input' pos more' fail succ in
    p.run input pos more fail' succ
  }

(** BEGIN: getting input *)

let rec prompt input pos fail succ =
  let uncommitted_bytes = Input.uncommitted_bytes input in
  let commit_pos        = Input.commit_pos input in
  (* The continuation should not hold any references to input above. *)
  let continue input more =
    let length = input_length input in
    if length < uncommitted_bytes then
      failwith "prompt: input shrunk!";
    let input = Input.create commit_pos input in
    if length = uncommitted_bytes then
      if more = Complete then
        fail input pos Complete
      else
        prompt input pos fail succ
    else
      succ input pos more
  in
  Partial { committed = Input.committed_bytes input; continue }

let demand_input =
  { run = fun input pos more fail succ ->
    match more with
    | Complete   -> fail input pos more [] "not enough input"
    | Incomplete ->
      let succ' input' pos' more' = succ input' pos' more' ()
      and fail' input' pos' more' = fail input' pos' more' [] "not enough input" in
      prompt input pos fail' succ'
  }

let ensure_suspended n input pos more fail succ =
  let rec go =
    { run = fun input' pos' more' fail' succ' ->
      if pos' + n <= Input.length input' then
        succ' input' pos' more' ()
      else
        (demand_input *> go).run input' pos' more' fail' succ'
    }
  in
  (demand_input *> go).run input pos more fail succ

let unsafe_substring n =
  { run = fun input pos more fail succ ->
    succ input (pos + n) more (Input.substring input pos n)
  }

let ensure n =
  { run = fun input pos more fail succ ->
    if pos + n <= Input.length input then
      succ input pos more ()
    else
      ensure_suspended n input pos more fail succ
  }
  *> unsafe_substring n


(** END: getting input *)

let at_end_of_input =
  { run = fun input pos more _ succ ->
    if pos < Input.length input then
      succ input pos more false
    else if more = Complete then
      succ input pos more true
    else
      let succ' input' pos' more' = succ input' pos' more' false
      and fail' input' pos' more' = succ input' pos' more' true in
      prompt input pos fail' succ'
  }

let end_of_input =
  at_end_of_input
  >>= function
    | true  -> return ()
    | false -> fail "end_of_input"

let advance n =
  { run = fun input pos more _fail succ -> succ input (pos + n) more () }

let pos =
  { run = fun input pos more _fail succ -> succ input pos more pos }

let available =
  { run = fun input pos more _fail succ ->
    succ input pos more (Input.length input - pos)
  }

let get_buffer_and_pos =
  { run = fun input pos more _fail succ -> succ input pos more (input, pos) }

let commit =
  { run = fun input pos more _fail succ ->
    Input.commit input pos;
    succ input pos more () }

(* Do not use this if [p] contains a [commit]. *)
let unsafe_lookahead p =
  { run = fun input pos more fail succ ->
    let succ' input' _ more' v = succ input' pos more' v in
    p.run input pos more fail succ' }

let peek_char =
  { run = fun input pos more fail succ ->
    if pos < Input.length input then
      succ input pos more (Some (Input.get_char input pos))
    else if more = Complete then
      succ input pos more None
    else
      let succ' input' pos' more' =
        succ input' pos' more' (Some (Input.get_char input' pos'))
      and fail' input' pos' more' =
        succ input' pos' more' None in
      prompt input pos fail' succ'
  }

let _char ~msg f =
  { run = fun input pos more fail succ ->
    if pos < Input.length input then
      match f (Input.get_char input pos) with
      | None   -> fail input pos more [] msg
      | Some v -> succ input (pos + 1) more v
    else
      let succ' input' pos' more' () =
        match f (Input.get_char input' pos') with
        | None   -> fail input' pos' more' [] msg
        | Some v -> succ input' (pos' + 1) more' v
      in
      ensure_suspended 1 input pos more fail succ'
  }

let peek_char_fail =
  unsafe_lookahead (_char ~msg:"peek_char_fail" (fun c -> Some c))

let satisfy f =
  _char ~msg:"satisfy" (fun c -> if f c then Some c else None)

let skip f =
  _char ~msg:"skip" (fun c -> if f c then Some () else None)

let char c =
  satisfy (fun c' -> c = c') <?> (String.make 1 c)

let not_char c =
  satisfy (fun c' -> c <> c') <?> ("not " ^ String.make 1 c)

let any_char =
  _char ~msg:"any_char" (fun c -> Some c)

let any_uint8 =
  _char ~msg:"any_uint8" (fun c -> Some (Char.code c))

let any_int8 =
  (* https://graphics.stanford.edu/~seander/bithacks.html#VariableSignExtendRisky *)
  let s = Sys.word_size - 1 - 8 in
  _char ~msg:"any_int8" (fun c -> Some ((Char.code c lsl s) asr s))

let count_while ?(init=0) f =
  (* NB: does not advance position. *)
  let rec go acc =
    { run = fun input pos more fail succ ->
      let n = Input.count_while input (pos + acc) f in
      let acc' = n + acc in
      (* Check if the loop terminated because it reached the end of the input
       * buffer. If so, then prompt for additional input and continue. *)
      if pos + acc' < Input.length input || more = Complete then
        succ input pos more acc'
      else
        let succ' input' pos' more' = (go acc').run input' pos' more' fail succ
        and fail' input' pos' more' = succ input' pos' more' acc' in
        prompt input pos fail' succ'
    }
  in
  go init

let string_ f s =
  (* XXX(seliopou): Inefficient. Could check prefix equality to short-circuit
   * the io. *)
  let len = String.length s in
  ensure len >>= fun s'->
    if f s = f s'
      then return s'
      else fail "string"

let string s    = string_ (fun x -> x) s
let string_ci s = string_ String.lowercase s

let skip_while f =
  count_while f >>= advance

let take n =
  ensure (max n 0)

let peek_string n =
  unsafe_lookahead (take n)

let take_while f =
  count_while f >>= unsafe_substring

let take_while1 f =
  count_while f
  >>= function
    | 0 -> fail "take_while1"
    | n -> unsafe_substring n

let take_till f =
  take_while (fun c -> not (f c))


let choice ps =
  List.fold_right (<|>) ps (fail "empty")

let fix f =
  let rec p = lazy (f r)
  and r = { run = fun buf pos more fail succ ->
    Lazy.(force p).run buf pos more fail succ }
  in
  r

let option x p =
  p <|> return x

let rec list ps =
  match ps with
  | []    -> return []
  | p::ps -> lift2 cons p (list ps)

let count n p =
  if n < 0 then
    failwith "count: invalid argument, n < 0";
  let rec loop = function
    | 0 -> return []
    | n -> lift2 cons p (loop (n - 1))
  in
  loop n

let many p =
  fix (fun m ->
    (lift2 cons p m) <|> return [])

let many1 p =
  lift2 cons p (many p)

let many_till p t =
  fix (fun m ->
    (lift2 cons p m) <|> (t *> return []))

let sep_by1 s p =
  fix (fun m ->
    lift2 cons p ((s *> m) <|> return []))

let sep_by s p =
  (lift2 cons p ((s *> sep_by1 s p) <|> return [])) <|> return []

let skip_many p =
  fix (fun m ->
    (p *> m) <|> return ())

let skip_many1 p =
  p *> skip_many p

let end_of_line =
  (char '\n' *> return ()) <|> (string "\r\n" *> return ()) <?> "end_of_line"

module type I = sig
  val int16 : int t
  val int32 : int32 t
  val int64 : int64 t

  val uint16 : int t
  val uint32 : int32 t
  val uint64 : int64 t

  val float : float t
  val double : float t
end

module Make_endian(Es : EndianString.EndianStringSig) : I = struct
  let get_float s = Es.get_float s 0
  let get_double s = Es.get_double s 0

  let get_int16 s = Es.get_int16 s 0
  let get_int32 s = Es.get_int32 s 0
  let get_int64 s = Es.get_int64 s 0

  let get_uint16 s = Es.get_uint16 s 0
  let get_uint32 s = Es.get_int32 s 0
  let get_uint64 s = Es.get_int64 s 0

  (* int *)
  let int16 = take 2 >>| get_int16
  let int32 = take 4 >>| get_int32
  let int64 = take 8 >>| get_int64

  let uint16 = take 2 >>| get_uint16
  let uint32 = take 4 >>| get_uint32
  let uint64 = take 8 >>| get_uint64

  (* float *)
  let float  = take 4 >>| get_float
  let double = take 8 >>| get_double
end

module Le = Make_endian(EndianString.LittleEndian_unsafe)
module Be = Make_endian(EndianString.BigEndian_unsafe)
