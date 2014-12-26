Require Import Coq.Lists.List.
Require Import Coq.Lists.Streams.
Require Import Coq.NArith.NArith.
Require Import Coq.Strings.String.
Require Import ErrorHandlers.All.
Require Import ListString.All.
Require Import Computation.
Require Socket.

Import ListNotations.
Local Open Scope string.

Module Run.
  Inductive t : C.t -> Type :=
  | Ret : t C.Ret
  | Par : forall {c1 c2 : C.t}, t c1 -> t c2 -> t (C.Par c1 c2)
  | Let : forall {input output : Type} (i : input) (o : output)
    {handler : input -> C.t}, t (handler i) -> t (C.Let input o handler).

  Definition do {output : Type} (o : output) {handler : unit -> C.t}
    (handler_run : t (handler tt)) : t (C.Let _ _ _) :=
    Let tt o handler_run.
End Run.

Module Examples.
  Import C.Notations.

  (** Hello world. *)
  Module HelloWorld.
    Definition program : C.t :=
      do! LString.s "Hello world!" in
      C.Ret.

    Definition run : Run.t program.
      apply (Run.do (LString.s "Hello world!")).
      exact Run.Ret.
    Defined.
  End HelloWorld.

  (** Echo one message. *)
  Module EchoOne.
    Definition program : C.t :=
      let! message : LString.t := tt in
      do! message in
      C.Ret.

    Definition run (message : LString.t) : Run.t program.
      apply (Run.Let message tt).
      apply (Run.do message).
      exact Run.Ret.
    Defined.
  End EchoOne.

  (** Echo a list of messages in sequence. *)
  Module EchoOrdered.
    Fixpoint program (fuel : nat) : C.t :=
      match fuel with
      | O => C.Ret
      | S fuel =>
        let! message : LString.t := tt in
        do! message in
        program fuel
      end.

    Fixpoint run (messages : list LString.t)
      : Run.t (program (List.length messages)).
      destruct messages as [|message messages].
      - exact Run.Ret.
      - apply (Run.Let message tt).
        apply (Run.do message).
        exact (run messages).
    Defined.
  End EchoOrdered.

  (** Echo a list of messages in parallel. *)
  Module EchoUnordered.
    Fixpoint program (fuel : nat) : C.t :=
      match fuel with
      | O => C.Ret
      | S fuel => C.Par EchoOne.program (program fuel)
      end.

    Fixpoint run (messages : list LString.t)
      : Run.t (program (List.length messages)).
      destruct messages as [|message messages].
      - exact Run.Ret.
      - apply Run.Par.
        * exact (EchoOne.run message).
        * exact (run messages).
    Defined.
  End EchoUnordered.

  (** A simple server giving the time to each connection. *)
  Module TimeServer.
    (** Convert a time into a string. *)
    Parameter string_of_time : N -> LString.t.

    (** Send the current time to a client. *)
    Definition handle_client (client_socket : Socket.Client.Id.t) : C.t :=
      let! time : N := "time" in
      let message := string_of_time time in
      let! is_written : bool := ("write", client_socket, message) in
      if is_written then
        let! is_closed : bool := ("close", client_socket) in
        C.Ret
      else
        C.Ret.

    (** Accept in parallel `fuel` clients. *)
    Fixpoint accept_clients (server_socket : Socket.Server.Id.t) (fuel : nat)
      : C.t :=
      match fuel with
      | O => C.Ret
      | S fuel =>
        C.Par (accept_clients server_socket fuel) (
          let! client_socket : option Socket.Client.Id.t :=
            ("accept", server_socket) in
          match client_socket with
          | None => C.Ret
          | Some client_socket => handle_client client_socket
          end)
      end.

    (** The main program. *)
    Definition program (port : N) (fuel : nat) : C.t :=
      let! server_socket : option Socket.Server.Id.t := ("bind", port) in
      match server_socket with
      | None => C.Ret
      | Some server_socket => accept_clients server_socket fuel
      end.

    (** Run a client, assuming the socket writing and closing succeed. *)
    Definition run_handle_client (client_socket : Socket.Client.Id.t) (time : N)
      : Run.t (handle_client client_socket).
      apply (Run.Let time "time").
      apply (Run.Let true ("write", client_socket, _)).
      apply (Run.Let true ("close", client_socket)).
      exact Run.Ret.
    Defined.

    (** Accept a list of clients. *)
    Fixpoint run_accept_clients (server_socket : Socket.Server.Id.t)
      (client_sockets_times : list (Socket.Client.Id.t * N))
      : Run.t (accept_clients server_socket (List.length client_sockets_times)).
      destruct client_sockets_times as [| [client_socket time] client_sockets_times].
      - exact Run.Ret.
      - apply Run.Par.
        * exact (run_accept_clients server_socket client_sockets_times).
        * apply (Run.Let (Some client_socket) ("accept", server_socket)).
          exact (run_handle_client client_socket time).
    Defined.

    (** Run but fail to bind the socket server. *)
    Definition run_unbound (port : N) (fuel : nat) : Run.t (program port fuel).
      apply (Run.Let None ("bind", port)).
      exact Run.Ret.
    Defined.

    (** Run and succeed to bind the socket server. *)
    Definition run_bound (port : N) (server_socket : Socket.Server.Id.t)
      (client_sockets_times : list (Socket.Client.Id.t * N))
      : Run.t (program port (List.length client_sockets_times)).
      apply (Run.Let (Some server_socket) ("bind", port)).
      exact (run_accept_clients server_socket client_sockets_times).
    Defined.
  End TimeServer.
End Examples.

(*Module Database.
  Import C.Notations.

  Module Kernel.
    Module Message.
      Inductive t (A : Type) : Type :=
      | Read
      | Write (data : A).
    End Message.

    Fixpoint program (A : Type) (fuel : nat) (data : A) : C.t :=
      match fuel with
      | O => C.Ret
      | S fuel =>
        let! message := Command.Read (Message.t A) @ tt in
        match message with
        | Message.Read =>
          C.Par (program A fuel data) (
            do! Command.Write A @ data in
            C.Ret)
        | Message.Write data => program A fuel data
        end
      end.
  End Kernel.
End Database.*)

(** A group of clients can get connected. They must send their name as the
    first message. Next each message is considered as a text message and
    broadcast to other clients, with the sender name. On connection, all
    previous messages are sent to the new client. *)
(*Module ChatServer.
  Import C.Notations.

  Module Kernel.
    Module Argument.
      Inductive t : Set :=
      | NewClient (name : LString.t)
      | Message (message : LString.t).
    End Argument.

    Fixpoint kernel (fuel : nat) : C.t.
    Admitted.
  End Kernel.
End ChatServer.*)
