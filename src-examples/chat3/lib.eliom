
{shared{

  open Eliom_content
  open Eliom_lib
  open Lwt_ops
  module Int_set = struct
    include Set.Make (struct type t = int let compare = (-) end)
    let to_string set =
      String.concat ", " (List.map string_of_int (elements set))
  end
  let pcdataf fmt =
    Printf.ksprintf Eliom_content.Html5.F.pcdata fmt
  let failwithf fmt =
    Printf.ksprintf failwith fmt
  let counter () =
    let n = ref 0 in
    fun () ->
      incr n; !n
  exception Not_allowed

  let singleton_diff_event diff elements signal =
    React.E.fmap (fun x -> x)
      (React.S.diff
         (fun after before ->
            match elements (diff after before) with
              | [] -> None
              | [elt] -> Some elt
              | _ -> failwith "singleton_diff_event")
         signal)

}}

let messages_id = Html5.Id.new_elt_id ()
let messages =
  Html5.Id.create_named_elt ~id:messages_id
    (Html5.D.(ul ~a:[a_class ["log_messages"]] []))

{client{

  let js_stringf fmt =
    Printf.ksprintf Js.string fmt

  let remove_after_timeout ?timeout parent_id child =
    match Option.get (fun () -> Some 3.0) timeout with
      | Some t ->
          Lwt.async
            (fun () ->
               lwt () = Lwt_js.sleep 3.0 in
               Html5.Manip.Named.removeChild parent_id child;
               Lwt.return ())
      | None -> ()

  let show_message ?timeout fmt =
    Printf.ksprintf
      (fun str ->
         Eliom_client.withdom
           (fun () ->
              let li = Html5.D.(li [pcdata str]) in
              Html5.Manip.Named.appendChild %messages_id li;
              remove_after_timeout ?timeout %messages_id li))
      fmt

  let show_message' ?timeout li_contents =
    Eliom_client.withdom
      (fun () ->
         let li = Html5.D.li li_contents in
         Html5.Manip.Named.appendChild %messages_id li;
         remove_after_timeout ?timeout %messages_id li)
}}

{server{

  let get_eref_option option_eref none some =
    fun y ->
      match_lwt Eliom_reference.get option_eref with
        | None -> none y
        | Some x -> some x y

  let get_eref_option_2 option_eref none some =
    fun get post ->
      match_lwt Eliom_reference.get option_eref with
        | None -> none get post
        | Some x -> some x get post

  let debug fmt =
    Printf.eprintf (">> " ^^ fmt ^^ "\n%!")

}}

{client{
  let debug fmt =
    Eliom_lib.debug (">> " ^^ fmt ^^ "\n%!")
}}

{shared{
  exception Client_process_data_not_available
}}

{server{

  module Client_processes = struct

    module Make (Info : sig type t val get : unit -> t Lwt.t end) : sig
      val signal : Info.t Int_map.t React.S.t
      val assert_process : unit -> (int * bool) Lwt.t
      val erase_process : unit -> unit
    end = struct

      let next_process_id = counter ()

      (* Reset by Eliom, on erase_process, or when channel times out *)
      let client_process_id_eref =
        Eliom_reference.Volatile.eref
          ~scope:Eliom_common.default_process_scope None

      let signal, modify =
        let signal, set = React.S.create ~eq:(Int_map.equal (fun _ _ -> true)) Int_map.empty in
        let modify f =
          set (f (React.S.value signal))
        in
        signal, modify

      let erase_process () =
        match Eliom_reference.Volatile.get client_process_id_eref with
          | Some id ->
              Eliom_reference.Volatile.set client_process_id_eref None;
              modify (Int_map.remove id)
          | None ->
              ()

      let rec assert_process ?id' () =
        match Eliom_reference.Volatile.get client_process_id_eref with
          | Some id ->
              if id' = None || id' = Some id then
                (if not (Int_map.mem id (React.S.value signal)) then
                   Lwt.fail (Failure (Printf.sprintf "assert_process: Unknown id %d" id))
                 else
                   Lwt.return (id, false))
              else
                Lwt.fail (Failure
                            (Printf.sprintf "assert_process: Wrong id %d vs %d"
                               id (Option.get (fun () -> assert false) id')))
          | None ->
              let id = Option.get next_process_id id' in
              lwt info = Info.get () in
              Eliom_reference.Volatile.set client_process_id_eref (Some id);
              Lwt.async
                (fun () ->
                   lwt () = Eliom_comet.Channel.wait_timeout 1.0 in
                   debug "Client process %d timed out" id;
                   Eliom_reference.Volatile.set client_process_id_eref None;
                   modify (Int_map.remove id);
                   Lwt.return ());
              ignore {unit{
                let config = Eliom_comet.Configuration.new_configuration () in
                Eliom_comet.Configuration.set_timeout config (15.0 *. 60.0);
                (* Eliom_comet.Configuration.set_always_active config true; *)
                (* Eliom_comet.Configuration.set_active_until_timeout config true; *)
                Eliom_client.onload
                  (fun () ->
                     Dom_html.window##onfocus <-
                       Dom.handler
                         (fun _ ->
                            Lwt.async
                              (fun () ->
                                 try_lwt
                                   lwt _ = %(server_function (assert_process ~id':id)) () in
                                   Lwt.return ()
                                 with exn ->
                                   debug "Cannot assert process: %s" (Printexc.to_string exn);
                                   Lwt.return ());
                            Js._true))
              }};
              modify (Int_map.add id info);
              Lwt.return (id, true)

      let assert_process () = assert_process ()

    end

    include Make (struct type t = unit let get () = Lwt.return () let to_string () = "()" end)

    let signal : Int_set.t React.S.t =
      React.S.map
        (fun map ->
           List.fold_right Int_set.add
             (List.map fst (Int_map.bindings map))
             Int_set.empty)
        signal

    let accumulate_infos f =
      (fun client_process_info ->
         f (List.map snd (Int_map.bindings client_process_info)))

  end

}}

{client{
  let reflect_list_signal : Html5_types.ul Html5.D.elt -> ('a -> Html5_types.li_content Html5.elt list) -> 'a list React.S.t -> unit =
    fun li_element li_content signal ->
      Lwt_react.S.keep
        (React.S.map
           (fun elements ->
              Html5.Manip.replaceAllChild
                li_element
                (List.map (fun element -> Html5.F.li (li_content element)) elements))
           signal)

}}

(*
(* Server functions *)

{shared{
  open Eliom_lib
}}

{shared{
  type ('a, 'b) server_function_service =
    (unit, string,
     [ `Nonattached of [ `Post] Eliom_service.na_s ], [ `WithoutSuffix ],
     unit, [ `One of string ] Eliom_parameter.param_name,
     [ `Registrable ], string Eliom_service.caml_service)
    Eliom_service.service
  let server_function_id_int = 1001
}}

{server{
  module Server_function : sig
    type ('a, 'b) t
    val create : ('a -> 'b Lwt.t) -> ('a, 'b) t
  end = struct
    type ('a, 'b) t = ('a, 'b) server_function_service * Eliom_wrap.unwrapper
    let create f =
      Eliom_registration.Ocaml.register_post_coservice'
        ~post_params:Eliom_parameter.(string "marshalled_argument")
        (fun () marshalled_argument ->
           let argument =
             Marshal.from_string
               (Url.decode marshalled_argument) 0
           in
           lwt res = f argument in
           let marshalled_res = Url.encode (Marshal.to_string res []) in
           Lwt.return marshalled_res),
      Eliom_wrap.create_unwrapper
        (Eliom_wrap.id_of_int
           server_function_id_int)
  end
}}

{client{

  module Server_function : sig
    type ('a, 'b) t = 'a -> 'b Lwt.t
  end = struct

    type ('a, 'b) t = 'a -> 'b Lwt.t

    let call : ('a, 'b) server_function_service -> 'a -> 'b Lwt.t =
      fun sfs argument ->
        let marshalled_argument = Url.encode (Marshal.to_string argument []) in
        lwt marshalled_res =
          Eliom_client.call_caml_service
            ~service:(sfs :> (_, _, Eliom_service.service_kind, _, _, _, _, _) Eliom_service.service)
            () marshalled_argument
        in
        let res = Marshal.from_string (Url.decode marshalled_res) 0 in
        Lwt.return res

    let () =
      debug "Register server function unwrapper";
      Eliom_unwrap.register_unwrapper
        (Eliom_unwrap.id_of_int server_function_id_int)
        (fun (sf, _) ->
           debug "Unwrap server_function";
           (fun x -> call sf x))
  end

}}

 *)
